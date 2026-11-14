import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/library_item.dart' show libraryShareFolderName;
import '../models/video_info.dart';
import 'app_log.dart';
import 'background_task.dart';
import 'file_names.dart';
import 'hls_manager.dart';
import 'local_media_path.dart';
import 'm3u8_convert.dart';
import 'native_bg_downloader.dart';

enum DownloadStatus { queued, downloading, done, failed }

class DownloadTask {
  final String id;
  final String url;
  String title; // 重命名后同步更新（完成项仍驻留内存列表）
  final String kind;
  final DateTime startedAt;

  /// 防盗链 Referer（嗅探到的那个 frame 的地址）。空串 = 未知，不加该头。
  /// 页面能播而 Dio 直下 403，绝大多数就是缺这个（以及 Cookie）。
  final String referer;
  String? localPath;
  String? partPath;
  double progress = 0;
  double speed = 0; // 字节/秒
  Duration? eta;
  /// 已下载字节（含断点续传前已写入的部分）
  int bytesDone = 0;
  /// 总字节（Content-Length / Content-Range 给出；0 = 服务端未给长度）
  int bytesTotal = 0;
  DownloadStatus status = DownloadStatus.queued;
  String? error;

  /// iOS 后台单文件作业（原生 background URLSession）。
  /// true 时传输不由本文件负责：Dio 链、`.part`、`_cancels` 都不参与，
  /// 进度与成败全部来自原生作业状态（[nativeJobId]）。
  bool native = false;

  /// 原生作业 id（与 [id] 同值，分开存是因为降级后同一任务会转回 Dio 链）
  String? nativeJobId;

  /// 原生作业目录（`Documents/Downloads/.direct_<id>`），落盘文件在里面的
  /// direct.bin；搬运完成后目录删除。
  String? nativeDir;

  DownloadTask({
    required this.id,
    required this.url,
    required this.title,
    required this.kind,
    this.referer = '',
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now();

  /// 失败/中断后是否保留有 .part 文件、可断点续传
  ///
  /// 原生作业没有 .part（下载期间文件还在系统临时目录里），它的续传凭据是
  /// 原生侧存的 resumeData，只要作业记录还在就能继续；记录丢了才会被对账标成失败。
  bool get canResume {
    if (native) {
      if (status == DownloadStatus.done || status == DownloadStatus.downloading) {
        return false;
      }
      final id = nativeJobId;
      return id != null && id.isNotEmpty;
    }
    if (status != DownloadStatus.failed) return false;
    if (partPath == null || partPath!.isEmpty) return false;
    try {
      return File(partPath!).existsSync();
    } catch (_) {
      return false;
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'title': title,
        'kind': kind,
        'referer': referer,
        'localPath': localPath,
        'folder': '',
        'savedAt': DateTime.now().toIso8601String(),
      };

  factory DownloadTask.fromJson(Map<String, dynamic> j) => DownloadTask(
        id: j['id'] as String,
        url: j['url'] as String,
        title: (j['title'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? 'other',
        referer: (j['referer'] as String?) ?? '',
      );

  /// 中断时的持久化状态（供下次启动恢复续传）
  Map<String, dynamic> toPendingJson() => {
        'id': id,
        'url': url,
        'title': title,
        'kind': kind,
        'referer': referer,
        'part': partPath,
        'startedAt': startedAt.toIso8601String(),
        // 原生作业：老记录没有这两个字段，读回来按 Dio 链处理
        if (native) 'native': true,
        if (native) 'nativeDir': nativeDir,
      };

  factory DownloadTask.fromPendingJson(Map<String, dynamic> j) =>
      DownloadTask(
        id: j['id'] as String,
        url: j['url'] as String,
        title: (j['title'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? 'other',
        referer: (j['referer'] as String?) ?? '',
        startedAt: DateTime.tryParse((j['startedAt'] as String?) ?? ''),
      )
        ..partPath = j['part'] as String?
        ..native = (j['native'] as bool?) ?? false
        ..nativeDir = j['nativeDir'] as String?
        ..nativeJobId =
            ((j['native'] as bool?) ?? false) ? j['id'] as String : null;
}

/// 下载管理器：mp4 直链下载。
///
/// iOS 上优先走原生后台单文件作业（系统 background URLSession）：提交后传输交给
/// 系统，锁屏 / 切 App / 进程被回收都能继续；Dio 链保留作非 iOS 与原生通道不可用
/// 时的降级（前台下载 + `beginBackgroundTask` 约 30 秒宽限）。
/// Dio 过程始终写 `<名字>.part`，完成后重命名为 .mp4；失败/取消时保留 .part
/// 并持久化 pending 状态，可断点续传。原生作业的中间文件落在 `.direct_<id>/` 目录，
/// 下完由 Dart 搬到 Downloads 的唯一名，元数据格式与 Dio 链一致。
class DownloadManager extends ChangeNotifier {
  static final DownloadManager instance = DownloadManager._();

  DownloadManager._() {
    _dio = Dio(BaseOptions(
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
      },
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
    ));
  }

  late final Dio _dio;
  final List<DownloadTask> _tasks = [];
  final Map<String, CancelToken> _cancels = {};
  bool _loaded = false;

  /// 原生作业事件流（只在有原生任务时订阅；进程活着才有，正确性不依赖它）
  StreamSubscription<Map<String, dynamic>>? _nativeSub;

  /// 正在搬运产物的作业 id，防止事件与对账同时完成同一个任务
  final Set<String> _nativeFinishing = {};

  /// 字节进度采样（算速度用；原生不上报速度）
  final Map<String, int> _nativeBytesAt = {};
  final Map<String, DateTime> _nativeSampleAt = {};

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  /// 下载目录：Documents/Downloads
  Future<Directory> downloadsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'Downloads'));
    await dir.create(recursive: true);
    return dir;
  }

  /// 分享接收目录：Documents/Share（其他 App 分享来的视频文件落在这里）
  Future<Directory> shareDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'Share'));
    await dir.create(recursive: true);
    return dir;
  }

  /// 注册一个分享导入的已完成条目（文件已在 Share 目录；
  /// 这里在 Downloads 元数据区写 `<id>.json` 并通知资源库刷新；
  /// 默认归入内置「分享」文件夹）
  Future<String> addSharedItem(String localPath, String title) async {
    try {
      final dir = await downloadsDir();
      // 批量分享时同一毫秒会连开多条：id 撞了就会互相覆盖 `<id>.json`，
      // 资源库里只看得到最后一条（磁盘上文件都在）→ 顺延到未占用的 id
      var stamp = DateTime.now().millisecondsSinceEpoch;
      while (File(p.join(dir.path, '$stamp.json')).existsSync()) {
        stamp++;
      }
      final id = stamp.toString();
      final meta = {
        'id': id,
        'url': '',
        'title': title,
        'kind': 'share',
        'localPath': localPath,
        'folder': libraryShareFolderName,
        'savedAt': DateTime.now().toIso8601String(),
      };
      await File(p.join(dir.path, '$id.json')).writeAsString(jsonEncode(meta));
      notifyListeners();
      return id;
    } catch (_) {
      return '';
    }
  }

  /// 启动时恢复未完成的断点任务（Dio 链看 .part，原生链交回对账取真实状态）
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await downloadsDir();
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.pending.json')) {
          try {
            final j = jsonDecode(await entity.readAsString());
            if (j is! Map<String, dynamic>) continue;
            final t = DownloadTask.fromPendingJson(j);
            if (_tasks.any((x) => x.id == t.id)) continue;
            t.status = DownloadStatus.failed;
            // 原生作业没有 .part（中间文件在 .direct_<id>/ 里，续传凭据在原生
            // 作业状态中）：状态一律由 _reconcileNative 从原生侧取，这里先占位
            if (t.native) {
              t.status = DownloadStatus.queued;
              t.error = null;
              _ensureNativeListener();
              _tasks.insert(0, t);
              continue;
            }
            // 无 part 记录的无效 pending，直接清理
            if (t.partPath == null || t.partPath!.isEmpty) {
              final pend = File(entity.path);
              if (await pend.exists()) await pend.delete();
              continue;
            }
            final part = File(t.partPath!);
            if (await part.exists() && await part.length() > 0) {
              t.error = '已暂停';
              _tasks.insert(0, t);
            } else {
              // 残留文件已丢失，清理无效 pending 记录
              if (await part.exists()) await part.delete();
              final pend = File(entity.path);
              if (await pend.exists()) await pend.delete();
            }
          } catch (e, st) {
            AppLog.instance
                .warn('download', '解析断点记录失败: ${entity.path}', e, st);
          }
        }
      }
      if (_tasks.isNotEmpty) notifyListeners();
      // 冷启动也走一次对账：AppLifecycleListener 的 onResume 在启动时不一定触发，
      // 而后台期间事件流可能整段没订阅者
      await _reconcileNative();
    } catch (e, st) {
      AppLog.instance.error('download', '启动时恢复断点任务失败', e, st);
    }
  }

  /// App 回前台对账（main.dart 的 onResume 调）：后台期间 EventChannel 事件
  /// 可能整段丢失，以原生侧磁盘状态为准
  Future<void> onResume() async {
    await ensureLoaded();
    await _reconcileNative();
  }

  /// 扫描已完成的下载（读元数据 json）
  Future<List<Map<String, dynamic>>> scanSaved() async {
    final dir = await downloadsDir();
    final result = <Map<String, dynamic>>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File &&
          p.extension(entity.path) == '.json' &&
          !entity.path.endsWith('.pending.json') &&
          !entity.path.endsWith('.convert.json') &&
          !entity.path.endsWith('.hls.json')) {
        try {
          final j = jsonDecode(await entity.readAsString());
          if (j is Map<String, dynamic>) result.add(j);
        } catch (e) {
          AppLog.instance.warn('download', '元数据解析失败: ${entity.path}', e);
        }
      }
    }
    result.sort((a, b) {
      final ta = a['savedAt'] as String? ?? '';
      final tb = b['savedAt'] as String? ?? '';
      return tb.compareTo(ta);
    });
    await _repairSavedPaths(result);
    return result;
  }

  /// 把元数据里失效的绝对路径按当前容器重新定位，命中就地回写 `<id>.json`。
  ///
  /// `localPath` 记的是**下载那一刻**的绝对路径，里面的数据容器 UUID 并不保证
  /// 跨安装稳定 —— 换签名身份、删掉重装（sideload 的常态）之后，文件跟着
  /// Documents 一起换了容器，元数据却还指着老 UUID。表现就是整库历史视频
  /// 同时「打不开」，而 AVFoundation 只回一句不分成因的 OSStatus，
  /// 看上去跟「文件损坏」一模一样（可文件在系统「文件」App 里照常能播）。
  ///
  /// 只在原路径 stat 不到时才走重定位，稳态下每条多一次 existsSync。
  Future<void> _repairSavedPaths(List<Map<String, dynamic>> saved) async {
    if (saved.isEmpty) return;
    ContainerRelocator? relocator;
    for (final m in saved) {
      final stored = (m['localPath'] as String?) ?? '';
      final id = (m['id'] as String?) ?? '';
      if (stored.isEmpty || id.isEmpty) continue;
      // HLS 离线包（.movpkg）不在 Documents 下、由系统按任务寻址，
      // 按文件名回查只可能撞上同名的别的条目
      if ((m['hls'] as bool?) ?? false) continue;
      // 路径还指得到东西（文件或目录，分片包是目录）：正常条目，不动
      if (pathExists(stored)) continue;
      if (relocator == null) {
        try {
          relocator = await ContainerRelocator.current();
        } catch (e) {
          // 路径通道不可用（没注册插件的执行环境）：判不了就不猜，原样交回
          AppLog.instance
              .warn('download', '取不到当前 Documents 目录，跳过路径重定位', e);
          return;
        }
      }
      // null = 按当前容器也认不出这个文件（交给起播前的检查说清楚）
      final hit = relocator?.relocate(stored);
      // 前面已排除了活路径，same 理论上不会出现，出现也当无需处理
      if (hit == null || hit.kind == Relocation.same) continue;
      m['localPath'] = hit.path;
      AppLog.instance.info(
        'download',
        '元数据路径已按当前容器重新定位（${hit.kind.name}）: $stored → ${hit.path}',
      );
      try {
        final dl = await downloadsDir();
        final meta = File(p.join(dl.path, '$id.json'));
        if (await meta.exists()) {
          await meta.writeAsString(jsonEncode(m));
        }
      } catch (e) {
        AppLog.instance.warn('download', '重新定位后的元数据回写失败: $id', e);
      }
    }
  }

  Future<void> download(VideoInfo v) async {
    // 同一 URL 已有可续传任务 → 直接继续
    for (final t in _tasks) {
      if (t.url == v.url && t.canResume) {
        resume(t.id);
        return;
      }
    }
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final task = DownloadTask(
        id: id,
        url: v.url,
        title: v.pageTitle,
        kind: v.kind,
        referer: v.effectiveReferer);
    _tasks.insert(0, task);
    notifyListeners();
    // iOS：先把作业整体交给系统后台传输；通道不可用（模拟器 / 桥未注册）
    // 返回 false，这里就地降级为原来的 Dio 前台链
    if (await _startNative(task)) return;
    await _run(task);
  }

  Future<void> resume(String id) async {
    for (final t in _tasks) {
      if (t.id == id) {
        if (t.native) {
          await _resumeNative(t);
        } else {
          await _run(t);
        }
        return;
      }
    }
  }

  Future<void> _run(DownloadTask task) async {
    task.status = DownloadStatus.downloading;
    task.error = null;
    task.progress = 0;
    task.speed = 0;
    task.eta = null;
    task.bytesDone = 0;
    task.bytesTotal = 0;
    notifyListeners();

    final cancel = CancelToken();
    _cancels[task.id] = cancel;
    final bg = await BackgroundTask.begin();
    try {
      final dir = await downloadsDir();
      // 断点续传沿用原 part 文件名；新下载按标题取唯一名
      //（与已存文件/进行中任务重名时自动追加序号，不再覆盖旧文件）
      var fileName = _resumeFileName(task, dir);
      fileName ??= uniqueFileName(
          dir, _mp4Name(task.title.isNotEmpty ? task.title : task.url));
      final partPath = p.join(dir.path, '$fileName.part');
      final target = p.join(dir.path, fileName);
      task.partPath = partPath;

      // 预留 .part 文件：同标题并发下载也不会互相覆盖
      final partFile = File(partPath);
      if (!partFile.existsSync()) partFile.createSync();

      // 断点：已有 .part → 从文件末尾继续
      var offset = 0;
      if (await partFile.exists()) {
        offset = await partFile.length();
      }
      AppLog.instance.info(
        'download',
        '开始下载: ${task.title}${offset > 0 ? '（断点续传 $offset 字节）' : ''} ${task.url}',
      );

      final headers = <String, dynamic>{};
      if (offset > 0) headers['Range'] = 'bytes=$offset-';
      // 防盗链：带嗅探到的那个 frame 的地址。不带的话，能正常播放的直链在
      // Dio 这条链上会直接 403（用户看到的就是「网络问题」）。
      if (task.referer.isNotEmpty) headers['Referer'] = task.referer;

      final resp = await _dio.get<ResponseBody>(
        task.url,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: true,
          receiveTimeout: const Duration(seconds: 120),
          headers: headers,
        ),
        cancelToken: cancel,
      );

      var total = 0;
      var received = 0;
      final contentLength =
          int.tryParse(resp.headers.value(Headers.contentLengthHeader) ?? '') ?? 0;
      if (resp.statusCode == 206 && offset > 0) {
        // 服务端支持 Range，续传成功
        final cr = resp.headers.value('content-range');
        final m = cr == null ? null : RegExp(r'bytes \d+-\d+/(\d+)').firstMatch(cr);
        total = m != null
            ? int.parse(m.group(1)!)
            : contentLength + offset;
      } else if (resp.statusCode == 200) {
        // 服务端不支持 Range：删除残留，从头下载
        if (offset > 0) {
          if (await partFile.exists()) await partFile.delete();
          offset = 0;
        }
        total = contentLength;
      } else {
        try {
          await resp.data?.stream.drain<void>();
        } catch (_) {}
        throw Exception('下载失败，HTTP ${resp.statusCode}');
      }
      if (total < 0) total = 0;
      // 断点续传：已落盘的 offset 也算「已下载」，否则进度会从 0 重来
      task.bytesDone = offset;
      task.bytesTotal = total;
      task.progress = total > 0 ? offset / total : 0;

      final raf = await partFile.open(mode: FileMode.append);
      var lastBytes = 0;
      var lastTime = DateTime.now();
      try {
        await for (final chunk in resp.data!.stream) {
          await raf.writeFrom(chunk);
          received += chunk.length;
          final done = offset + received;
          if (total > 0) task.progress = done / total;
          task.bytesDone = done;
          task.bytesTotal = total;
          // 网速与预计剩余时间（每 ~1s 采样一次）
          final now = DateTime.now();
          final dtMs = now.difference(lastTime).inMilliseconds;
          if (dtMs >= 800) {
            final dBytes = received - lastBytes;
            if (dBytes > 0 && dtMs > 0) {
              task.speed = dBytes / (dtMs / 1000.0);
              if (total > 0) {
                final rem = total - done;
                task.eta = rem > 0 && task.speed > 0
                    ? Duration(seconds: (rem / task.speed).round())
                    : null;
              }
            }
            lastBytes = received;
            lastTime = now;
          }
          notifyListeners();
        }
      } finally {
        await raf.close();
      }

      // 校验：非空 + 长度吻合（长度未知时只查非空）
      final totalBytes = await partFile.length();
      if (totalBytes == 0) throw Exception('文件为空');
      if (total > 0 && totalBytes < total) {
        throw Exception('下载不完整：$totalBytes/$total');
      }

      // 完成：重命名 .part → 最终文件（目标若在下载期间被占用，自动改名避让），
      // 写元数据，清 pending
      var finalTarget = target;
      if (await File(finalTarget).exists()) {
        final alt = uniqueFileName(dir, fileName);
        finalTarget = p.join(dir.path, alt);
        AppLog.instance.info(
          'download',
          '目标文件已存在，自动改名保存: ${p.basename(finalTarget)}',
        );
      }
      await File(partPath).rename(finalTarget);
      task.localPath = finalTarget;
      task.partPath = null;
      task.status = DownloadStatus.done;
      task.progress = 1;
      await File(p.join(dir.path, '${task.id}.json'))
          .writeAsString(jsonEncode(task.toJson()));
      await _clearPending(task);
      AppLog.instance.info('download', '下载完成: ${task.title}（${task.localPath}）');
    } catch (e) {
      // 回收未消费的响应流（避免流残留告警）
      if (e is DioException && e.response?.data is ResponseBody) {
        try {
          await (e.response!.data as ResponseBody).stream.drain<void>();
        } catch (_) {}
      }
      if (cancel.isCancelled) {
        task.status = DownloadStatus.failed;
        task.error = '已暂停';
        AppLog.instance.info('download', '下载已暂停: ${task.title}');
      } else {
        task.status = DownloadStatus.failed;
        task.error = _explain(e);
        var detail = '下载失败: ${task.title}（${task.url}）';
        if (e is DioException) {
          detail += ' [${e.type.name} HTTP ${e.response?.statusCode ?? '-'}]';
        }
        AppLog.instance.error('download', detail, e);
      }
      await _savePending(task);
    } finally {
      _cancels.remove(task.id);
      await BackgroundTask.end(bg);
      notifyListeners();
    }
  }

  void cancel(String id) {
    final c = _cancels.remove(id);
    if (c != null) {
      c.cancel();
      return;
    }
    // 原生作业没有 Dio 的 CancelToken，暂停走原生 pause（保留断点续传数据）
    for (final t in _tasks) {
      if (t.id == id && t.native) {
        unawaited(_pauseNative(t));
        return;
      }
    }
  }

  // ── iOS 原生后台单文件作业 ──────────────────────────────────────

  /// 原生作业目录里的中间文件名（下载完成前由系统临时目录持有，完成后搬到这里）
  static const _directPartName = 'direct.bin';

  /// 提交原生后台作业。返回 false = 通道不可用（非 iOS / 桥未注册 / 模拟器），
  /// 调用方据此降级为 Dio 前台链。
  Future<bool> _startNative(DownloadTask task) async {
    if (!Platform.isIOS) return false;
    Directory? work;
    try {
      final dir = await downloadsDir();
      work = Directory(p.join(dir.path, '.direct_${task.id}'));
      await work.create(recursive: true);
      final ok = await NativeBgDownloader.submit(NativeSegJob(
        jobId: task.id,
        workDir: work.path,
        playlistPath: '',
        parts: [NativeSegPart(url: task.url, name: _directPartName)],
        headers: _nativeHeaders(task),
        singleFile: true,
      ));
      if (!ok) {
        await _deleteDir(work);
        return false;
      }
      _ensureNativeListener();
      task.native = true;
      task.nativeJobId = task.id;
      task.nativeDir = work.path;
      task.status = DownloadStatus.downloading;
      task.error = null;
      task.progress = 0;
      task.bytesDone = 0;
      task.bytesTotal = 0;
      task.speed = 0;
      task.eta = null;
      // 提交后 Dart 不再持有长任务，进程随时可能被系统回收 → 状态必须落盘，
      // 否则冷启动恢复时这条作业只剩原生侧记录，UI 里看不到
      await _savePending(task);
      AppLog.instance.info('download', '已提交原生后台单文件作业: ${task.title}');
      notifyListeners();
      return true;
    } catch (e, st) {
      if (work != null) await _deleteDir(work);
      AppLog.instance.error('download', '原生作业提交失败，降级为前台下载: ${task.title}', e, st);
      return false;
    }
  }

  /// 系统进程的请求没有页面会话，防盗链头只能显式给（与分片链路同一套）
  Map<String, String> _nativeHeaders(DownloadTask task) => {
        'User-Agent': (_dio.options.headers['User-Agent'] ?? '').toString(),
        if (task.referer.isNotEmpty) 'Referer': task.referer,
      };

  void _ensureNativeListener() {
    if (_nativeSub != null) return;
    // 事件只用于前台实时刷新；正确性由 _reconcileNative() 对账保证
    _nativeSub = NativeBgDownloader.events().listen(_onNativeEvent, onError: (_) {});
  }

  /// 暂停：原生保留断点续传数据与作业记录，之后可 [resume]
  Future<void> _pauseNative(DownloadTask task) async {
    final id = task.nativeJobId;
    if (id == null || id.isEmpty) return;
    final ok = await NativeBgDownloader.pause(id);
    task.status = DownloadStatus.failed;
    task.error = ok ? '已暂停' : '暂停失败';
    task.speed = 0;
    task.eta = null;
    _nativeBytesAt.remove(task.id);
    _nativeSampleAt.remove(task.id);
    await _savePending(task);
    notifyListeners();
  }

  /// 继续：交回原生重新拉起（有断点数据就续传，没有就从头下）
  Future<void> _resumeNative(DownloadTask task) async {
    final id = task.nativeJobId;
    if (id == null || id.isEmpty) {
      await _run(task);
      return;
    }
    _ensureNativeListener();
    task.status = DownloadStatus.downloading;
    task.error = null;
    notifyListeners();
    final ok = await NativeBgDownloader.resume(id);
    if (!ok) {
      // 作业记录已不存在（强杀后被清理 / 产物已搬走）：转 Dio 链从头下，
      // 中间文件在另一个目录，两条链不共用
      AppLog.instance.warn('download', '原生作业不可恢复，转前台下载: ${task.title}');
      task.native = false;
      task.nativeJobId = null;
      final dir = task.nativeDir;
      if (dir != null && dir.isNotEmpty) {
        await _deleteDir(Directory(dir));
        task.nativeDir = null;
      }
      await _run(task);
      return;
    }
    await _reconcileNative();
  }

  void _onNativeEvent(Map<String, dynamic> e) {
    final id = e['jobId'] as String? ?? '';
    DownloadTask? task;
    for (final t in _tasks) {
      if (t.id == id && t.native) {
        task = t;
        break;
      }
    }
    if (task == null || task.status == DownloadStatus.done) return;
    _applyNative(task, NativeJobStatus.fromMap(Map<String, dynamic>.from(e)));
    notifyListeners();
  }

  /// 把原生作业状态映射到 UI 用的 [DownloadTask] 字段。
  void _applyNative(DownloadTask task, NativeJobStatus s) {
    if (s.bytes > 0) {
      // 原生不上报速度：按采样间隔自己算。回前台时字节会一次性跳一大截
      //（锁屏期间 didWriteData 不回调），那一跳算不出有意义速度，跳过。
      final now = DateTime.now();
      final prevAt = _nativeSampleAt[task.id];
      final prevBytes = _nativeBytesAt[task.id];
      if (prevAt != null && prevBytes != null) {
        final dtMs = now.difference(prevAt).inMilliseconds;
        final d = s.bytes - prevBytes;
        if (dtMs >= 800 && dtMs <= 15000 && d > 0) {
          task.speed = d / (dtMs / 1000.0);
          final rem = s.bytesTotal - s.bytes;
          task.eta = rem > 0 && task.speed > 0
              ? Duration(seconds: (rem / task.speed).round())
              : null;
        }
      }
      _nativeSampleAt[task.id] = now;
      _nativeBytesAt[task.id] = s.bytes;
      task.bytesDone = s.bytes;
    }
    if (s.bytesTotal > 0) task.bytesTotal = s.bytesTotal;
    // 单文件作业分片数恒为 1，按分片比算出来的进度在下完前都是 0 → 用字节比。
    // 服务端没给 Content-Length 时算不出比例，保持上一次的值（进度单调前进）
    final bp = s.byteProgress;
    if (bp > 0) task.progress = bp;
    switch (s.state) {
      case 'ready':
        task.progress = 1;
        unawaited(_finishNative(task));
      case 'failed':
        _markNativeFailed(task, s.error);
      case 'paused':
        task.status = DownloadStatus.failed;
        task.error = '已暂停';
        task.speed = 0;
        task.eta = null;
        unawaited(_savePending(task));
      default:
        task.status = DownloadStatus.downloading;
        task.error = null;
    }
  }

  void _markNativeFailed(DownloadTask task, String? rawError) {
    task.status = DownloadStatus.failed;
    task.speed = 0;
    task.eta = null;
    task.error = _explainNative(rawError);
    unawaited(_savePending(task));
    AppLog.instance
        .error('download', '原生后台下载失败: ${task.title}（原始: $rawError）');
  }

  /// 原生侧给的原因只有 HTTP 状态码或 URLError 描述，翻成与 Dio 链一致的说法，
  /// 让用户看到的归因和能采取的行动不取决于底层用了哪条链。
  static String _explainNative(String? raw) {
    final msg = (raw ?? '').trim();
    if (msg.isEmpty) return '后台下载失败';
    final m = RegExp(r'HTTP\s*(\d+)').firstMatch(msg);
    if (m == null) return msg;
    final code = int.parse(m.group(1)!);
    if (code == 0) return '连接失败：DNS / 证书 / 网络不可达';
    if (code == 401 || code == 403) {
      return '源站拒绝访问（HTTP $code）：多为防盗链（缺 Referer / Cookie）或签名已失效';
    }
    if (code == 404 || code == 410) {
      return '链接已失效（HTTP $code）：回页面刷新后重新嗅探';
    }
    if (code >= 500) return '源站异常（HTTP $code），稍后重试';
    return '下载失败（HTTP $code）';
  }

  /// 产物搬运：原生作业目录里的 direct.bin → `Downloads/<唯一名>.mp4` + 元数据。
  /// 与 Dio 链共用同一套命名与元数据格式，资源库不需要区分来源。
  Future<void> _finishNative(DownloadTask task) async {
    if (task.status == DownloadStatus.done || _nativeFinishing.contains(task.id)) {
      return;
    }
    _nativeFinishing.add(task.id);
    try {
      final dir = await downloadsDir();
      final src = File(p.join(task.nativeDir ?? '', _directPartName));
      if (!await src.exists() || await src.length() == 0) {
        throw Exception('后台产物缺失');
      }
      final safe = uniqueFileName(
          dir, _mp4Name(task.title.isNotEmpty ? task.title : task.url));
      final target = p.join(dir.path, safe);
      await src.copy(target);
      task.localPath = target;
      task.partPath = null;
      task.status = DownloadStatus.done;
      task.progress = 1;
      task.error = null;
      task.speed = 0;
      task.eta = null;
      await File(p.join(dir.path, '${task.id}.json'))
          .writeAsString(jsonEncode(task.toJson()));
      if (task.nativeDir != null) await _deleteDir(Directory(task.nativeDir!));
      task.nativeDir = null;
      // 清原生作业记录：否则下次冷启动对账会把它当成待搬运输
      await NativeBgDownloader.markRemuxed(task.id);
      await _clearPending(task);
      AppLog.instance.info('download', '后台下载完成: ${task.title}（$target）');
    } catch (e, st) {
      task.status = DownloadStatus.failed;
      task.error = '搬运失败：$e';
      await _savePending(task);
      AppLog.instance.error('download', '后台产物搬运失败: ${task.title}', e, st);
    } finally {
      _nativeFinishing.remove(task.id);
      _nativeBytesAt.remove(task.id);
      _nativeSampleAt.remove(task.id);
      notifyListeners();
    }
  }

  /// 对账：以原生侧磁盘状态为准。冷启动与回前台都跑一次——后台期间
  /// EventChannel 可能整段丢失（引擎未启动），事件不能当唯一状态来源。
  Future<void> _reconcileNative() async {
    final natives = _tasks
        .where((t) =>
            t.native &&
            t.status != DownloadStatus.done &&
            t.status != DownloadStatus.queued)
        .toList(growable: false);
    final pending = _tasks
        .where((t) => t.native && t.status == DownloadStatus.queued)
        .toList(growable: false);
    if (natives.isEmpty && pending.isEmpty) return;
    final byId = <String, NativeJobStatus>{
      for (final s in await NativeBgDownloader.listJobs()) s.jobId: s,
    };
    var changed = false;
    for (final t in [...natives, ...pending]) {
      final s = byId[t.id];
      if (s == null) {
        // 记录没了：产物早已搬走（markRemuxed 清记录）或用户强杀后清理。
        // 磁盘上还能找到中间文件就搬，找不到才判失败
        if (t.status != DownloadStatus.failed) {
          final src = File(p.join(t.nativeDir ?? '', _directPartName));
          if (await src.exists() && await src.length() > 0) {
            await _finishNative(t);
          } else {
            t.status = DownloadStatus.failed;
            t.error = '作业记录丢失';
          }
        }
        changed = true;
        continue;
      }
      if (s.workDir.isNotEmpty && Directory(s.workDir).existsSync()) {
        t.nativeDir = s.workDir;
      }
      _applyNative(t, s);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  Future<void> _deleteDir(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// 把异常翻成用户能看懂、且能据此行动的失败原因。
  ///
  /// 旧实现把 `e.toString()` 直接当提示，用户看到的一律是「网络问题」——
  /// 而真实原因里最常见的是 403 防盗链和 404 过期，两者都不是网络问题，
  /// 提示归因错了，用户既没法自查也没法自查要不要重试。
  static String _explain(Object e) {
    if (e is! DioException) return e.toString();
    final code = e.response?.statusCode ?? 0;
    if (code == 401 || code == 403) {
      return '源站拒绝访问（HTTP $code）：多为防盗链（缺 Referer / Cookie）或签名已失效';
    }
    if (code == 404 || code == 410) {
      return '链接已失效（HTTP $code）：回页面刷新后重新嗅探';
    }
    if (code >= 500) return '源站异常（HTTP $code），稍后重试';
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接超时：网络不通或源站限速';
      case DioExceptionType.connectionError:
        return '连接失败：DNS / 证书 / 网络不可达';
      case DioExceptionType.cancel:
        return '已暂停';
      default:
        return code > 0 ? 'HTTP $code' : (e.message ?? e.toString());
    }
  }

  /// 移动单个已保存视频到文件夹（'' = 移回「全部」）。
  /// 只改写 `<id>.json` 元数据中的 folder 字段，不移动磁盘文件。
  Future<void> setFolder(String id, String folder) async {
    try {
      final dir = await downloadsDir();
      final f = File(p.join(dir.path, '$id.json'));
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map<String, dynamic>) return;
      j['folder'] = folder;
      await f.writeAsString(jsonEncode(j));
    } catch (_) {}
  }

  /// 批量改写所有已保存视频元数据的 folder 字段
  /// （from == null 表示所有条目；to == null 表示移回「全部」）
  Future<void> moveFolderItems(String? from, String? to) async {
    try {
      final dir = await downloadsDir();
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File &&
            p.extension(entity.path) == '.json' &&
            !entity.path.endsWith('.pending.json') &&
            !entity.path.endsWith('.convert.json') &&
            !entity.path.endsWith('.hls.json')) {
          try {
            final j = jsonDecode(await entity.readAsString());
            if (j is! Map<String, dynamic>) continue;
            final cur = (j['folder'] as String?) ?? '';
            if (from != null && cur != from) continue;
            j['folder'] = to ?? '';
            await entity.writeAsString(jsonEncode(j));
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> delete(String id, String localPath) async {
    DownloadTask? t;
    for (final x in _tasks) {
      if (x.id == id) {
        t = x;
        break;
      }
    }
    _tasks.removeWhere((x) => x.id == id);
    try {
      final dir = await downloadsDir();
      final meta = File(p.join(dir.path, '$id.json'));
      if (await meta.exists()) await meta.delete();
      final pend = File(p.join(dir.path, '$id.pending.json'));
      if (await pend.exists()) await pend.delete();
      if (t?.partPath != null) {
        final f = File(t!.partPath!);
        if (await f.exists()) await f.delete();
      }
      // 原生作业：取消系统侧传输并清掉中间目录，否则它会继续在后台下载，
      // 完成后还把文件搬回资源库（用户看到的是一条已删除的条目复活）
      if (t != null && t.native) {
        final jobId = t.nativeJobId;
        if (jobId != null && jobId.isNotEmpty) {
          await NativeBgDownloader.cancel(jobId);
        }
        final workDir = t.nativeDir;
        if (workDir != null && workDir.isNotEmpty) {
          await _deleteDir(Directory(workDir));
        }
        _nativeBytesAt.remove(id);
        _nativeSampleAt.remove(id);
      }
      if (localPath.isNotEmpty) {
        final d = Directory(localPath);
        if (await d.exists()) {
          await d.delete(recursive: true);
        } else {
          final f = File(localPath);
          if (await f.exists()) await f.delete();
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _savePending(DownloadTask t) async {
    try {
      final dir = await downloadsDir();
      await File(p.join(dir.path, '${t.id}.pending.json'))
          .writeAsString(jsonEncode(t.toPendingJson()));
    } catch (_) {}
  }

  Future<void> _clearPending(DownloadTask t) async {
    try {
      final dir = await downloadsDir();
      final f = File(p.join(dir.path, '${t.id}.pending.json'));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 已有 part 文件（断点续传）时沿用其对应的最终文件名；否则 null
  String? _resumeFileName(DownloadTask task, Directory dir) {
    final old = task.partPath;
    if (old == null || old.isEmpty) return null;
    var name = p.basename(old);
    if (name.toLowerCase().endsWith('.part')) {
      name = name.substring(0, name.length - '.part'.length);
    }
    // part 文件还在才沿用（否则按新标题取唯一名）
    if (!File(p.join(dir.path, '$name.part')).existsSync()) return null;
    return name;
  }

  String _mp4Name(String raw) {
    var name = safeFileName(raw);
    if (!name.toLowerCase().endsWith('.mp4')) name = '$name.mp4';
    return name;
  }

  /// 重命名已保存视频：更新元数据标题；磁盘文件/文件夹存在时同步改名并更新 localPath；
  /// 原生 HLS 条目（无 localPath）仅更新标题。
  /// 元数据 json 缺失（如删除后仍驻留内存列表的转换任务）时不报失败，仅更新内存标题。
  /// 返回是否成功。
  Future<bool> rename(String id, String newTitle) async {
    final title = newTitle.trim();
    if (title.isEmpty) return false;
    try {
      final dir = await downloadsDir();
      final meta = File(p.join(dir.path, '$id.json'));
      final hasMeta = await meta.exists();
      var j = <String, dynamic>{};
      var oldPath = '';
      if (hasMeta) {
        final decoded = jsonDecode(await meta.readAsString());
        if (decoded is! Map<String, dynamic>) return false;
        j = decoded;
        oldPath = (j['localPath'] as String?) ?? '';
      }
      // json 缺失（删除后仍驻留内存的转换任务）：从内存任务取磁盘路径继续改名
      if (oldPath.isEmpty && !hasMeta) {
        for (final t in ConvertManager.instance.tasks) {
          if (t.id == id && t.localPath != null && t.localPath!.isNotEmpty) {
            oldPath = t.localPath!;
            break;
          }
        }
      }
      var newPath = oldPath;
      if (oldPath.isNotEmpty) {
        final renamed = await _renameOnDisk(oldPath, title);
        if (renamed == null) return false; // 磁盘改名失败 → 元数据不动
        newPath = renamed;
      }
      // 内存中驻留的完成/进行中任务同步（避免展示旧标题/旧路径；
      // ConvertManager 完成态任务可能在元数据 json 被删后仍驻留列表）
      for (final t in _tasks) {
        if (t.id == id) {
          t.title = title;
          t.localPath = newPath;
        }
      }
      for (final t in HlsManager.instance.tasks) {
        if (t.taskId == id) t.title = title;
      }
      for (final t in ConvertManager.instance.tasks) {
        if (t.id == id) {
          t.title = title;
          t.localPath = newPath;
        }
      }
      if (hasMeta) {
        j['title'] = title;
        j['localPath'] = newPath;
        await meta.writeAsString(jsonEncode(j));
      }
      notifyListeners();
      return true;
    } catch (e, st) {
      AppLog.instance.error('download', '重命名失败: $id', e, st);
      return false;
    }
  }

  /// 磁盘改名：文件（mp4/分享导入）或文件夹（m3u8 分片包）。保留原扩展名；
  /// 新名与现存文件冲突时自动追加序号；磁盘文件已不存在时返回原路径（仅改标题）。
  /// 新文件名与现文件名相同（含大小写差异）时不动磁盘文件，仅改标题。
  Future<String?> _renameOnDisk(String oldPath, String newTitle) async {
    try {
      final parent = p.dirname(oldPath);
      final dir = Directory(parent);
      final oldName = p.basename(oldPath);
      // 分片包文件夹沿用 _m3u8 后缀约定；文件保留原扩展名
      var base = oldName.endsWith('_m3u8')
          ? '${safeFileName(newTitle)}_m3u8'
          : safeFileName(newTitle);
      final ext = p.extension(oldName);
      if (!oldName.endsWith('_m3u8') &&
          ext.isNotEmpty &&
          !base.toLowerCase().endsWith(ext.toLowerCase())) {
        base = '$base$ext';
      }
      // 目标文件名与现文件名相同 → 仅改标题，不搬磁盘文件（避免改出 " (2)" 副本）
      if (base.toLowerCase() == oldName.toLowerCase()) return oldPath;
      final newName = uniqueFileName(dir, base);
      if (newName == oldName) return oldPath;
      final targetPath = p.join(parent, newName);
      final type = FileSystemEntity.typeSync(oldPath);
      if (type == FileSystemEntityType.directory) {
        await Directory(oldPath).rename(targetPath);
        return targetPath;
      }
      if (type == FileSystemEntityType.file) {
        await File(oldPath).rename(targetPath);
        return targetPath;
      }
      // 磁盘文件已不在（外部删除）：仅允许改标题
      return oldPath;
    } catch (_) {
      return null;
    }
  }
}
