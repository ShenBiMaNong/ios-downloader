import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/video_info.dart';
import 'app_log.dart';
import 'background_task.dart';
import 'file_names.dart';
import 'native_bg_downloader.dart';

class ConvertTask {
  final String id;
  final String url; // 远程 URL；本地转换为本地 m3u8 / 文件夹路径
  String title; // 重命名后同步更新（完成项仍驻留内存列表）
  final DateTime startedAt;

  /// 防盗链 Referer（嗅探到的那个 frame 的地址）。空串 = 未知。
  ///
  /// 这是「清单请求」必须带的东西：Dio 这条链拉 master/media 清单时如果 Referer
  /// 不对，源站直接 403 或返回一张 HTML 错误页，而分片阶段根本走不到。
  final String referer;

  /// 页面播放器报告的时长（秒），0 = 未知。用于核对清单是不是同一个视频。
  final double pageDur;

  /// remote: 远程 m3u8 URL → mp4；local: 本地 m3u8 → mp4；package: 下载 m3u8 分片包
  final String mode;

  double progress = 0; // 0~1（分片下载阶段）
  double speed = 0; // 字节/秒（分片下载阶段）
  Duration? eta;
  int doneSegments = 0;
  int totalSegments = 0;

  /// 已下 / 总字节。原生后台链由原生按「已落盘分片 + 在途已写字节」上报；
  /// HLS 清单不含分片大小，[bytesTotal] 是按已知 Content-Length 外推的估算值，
  /// [bytesEstimated] 为 true 时 UI 标 ≈。
  int bytes = 0;
  int bytesTotal = 0;
  bool bytesEstimated = false;

  /// 速度采样时间点（不持久化）。回前台第一次采样只重建基线，不参与计算，
  /// 否则「后台代下的几百 MB」会被算成一个巨大的瞬时速度。
  DateTime? bytesSampledAt;

  bool done = false;
  bool failed = false;
  String? error;
  String? localPath;

  /// 原生后台链（mode == 'native'）的阶段：
  /// downloading | ready | remuxing | failed。其它模式为空串。
  /// 后台下载拿不到字节级速度/ETA，UI 靠这个字段区分「锁屏继续下」与「待合成」。
  String stage = '';

  /// 工作目录；失败/中断时保留，供 retry() 续传
  String? workDir;

  ConvertTask({
    required this.id,
    required this.url,
    required this.title,
    required this.mode,
    this.referer = '',
    this.pageDur = 0,
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now();

  bool get resumable => !done && workDir != null && workDir!.isNotEmpty;

  /// 中断时的持久化状态（供下次启动恢复续传）
  Map<String, dynamic> toPendingJson() => {
        'id': id,
        'url': url,
        'title': title,
        'mode': mode,
        'referer': referer,
        'pageDur': pageDur,
        'workDir': workDir,
        'startedAt': startedAt.toIso8601String(),
        'error': error,
        'stage': stage,
        // 冷启动对账时按原生进度换算「已下 x/y」，没有总分片数会显示 0/0
        'totalSegments': totalSegments,
        // 回前台对账前先显示上次已知的字节数，避免列表短暂闪回「准备中」
        'bytes': bytes,
        'bytesTotal': bytesTotal,
        'bytesEstimated': bytesEstimated,
      };

  factory ConvertTask.fromPendingJson(Map<String, dynamic> j) => ConvertTask(
        id: j['id'] as String,
        url: (j['url'] as String?) ?? '',
        title: (j['title'] as String?) ?? '',
        mode: (j['mode'] as String?) ?? 'remote',
        referer: (j['referer'] as String?) ?? '',
        pageDur: (j['pageDur'] as num?)?.toDouble() ?? 0,
        startedAt: DateTime.tryParse((j['startedAt'] as String?) ?? ''),
      )
        ..workDir = j['workDir'] as String?
        ..stage = (j['stage'] as String?) ?? ''
        ..totalSegments = (j['totalSegments'] as num?)?.toInt() ?? 0
        ..bytes = (j['bytes'] as num?)?.toInt() ?? 0
        ..bytesTotal = (j['bytesTotal'] as num?)?.toInt() ?? 0
        ..bytesEstimated = (j['bytesEstimated'] as bool?) ?? true
        ..failed = true
        ..error = (j['error'] as String?) ?? '已暂停';
}

/// m3u8 → mp4（MVP-3）：
/// 拉 master/media 清单 → 解析分片与 AES-128 密钥 → 并发下载 → ffmpeg -c copy 无损转封装
/// 支持：远程 URL / 本地 m3u8 文件（文件夹）直接转换 / 下载 m3u8 分片包离线备用；
/// 加密分片（AES-128）由 ffmpeg 解封装时解密；失败保留分片可续传。
class ConvertManager extends ChangeNotifier {
  static final ConvertManager instance = ConvertManager._();

  ConvertManager._() {
    _dio = Dio(BaseOptions(
      // 注意：这里曾经写死 'Referer': 'https://www.bilibili.com/'。
      // 那是为了让某个 B 站源过防盗链，但 Dio 的 Options.headers 是「合并」而非
      // 「替换」—— 于是所有站点的清单请求都顶着 bilibili 的 Referer 发出去，
      // 防盗链源站直接 403 / 返回 HTML 错误页，表现为「嗅探到了、探测也通，
      // 一点下载就网络异常」。Referer 必须按任务动态给（见 _refFor）。
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
      },
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
    ));
    // 后台期间 EventChannel 可能根本没有订阅者（引擎未启动），
    // 所以事件仅用于前台刷新；正确性由 onResume()/ensureLoaded() 对账保证。
    NativeBgDownloader.events().listen(_onNativeEvent, onError: (_) {});
  }

  late final Dio _dio;
  final List<ConvertTask> tasks = [];
  final Set<String> _active = {};
  final Set<String> _nativeFinishing = {};
  bool _loaded = false;

  /// 启动时恢复未完成的转换任务（复用保留的分片工作目录）
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'Downloads'));
      if (!await dir.exists()) return;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.convert.json')) {
          try {
            final j = jsonDecode(await entity.readAsString());
            if (j is! Map<String, dynamic>) continue;
            final t = ConvertTask.fromPendingJson(j);
            if (tasks.any((x) => x.id == t.id)) continue;
            if (t.workDir == null || !Directory(t.workDir!).existsSync()) {
              // 分片缓存已丢失，无法续传，清理记录
              if (await entity.exists()) await entity.delete();
              continue;
            }
            tasks.insert(0, t);
          } catch (e, st) {
            AppLog.instance
                .warn('convert', '解析转换断点记录失败: ${entity.path}', e, st);
          }
        }
      }
      if (tasks.isNotEmpty) notifyListeners();
      // 冷启动对账：后台分片可能已在系统进程里下完，但事件整段丢失。
      await _resumeNativeJobs();
    } catch (e, st) {
      AppLog.instance.error('convert', '启动时恢复转换任务失败', e, st);
    }
  }

  // ---------- 入口 ----------

  /// 远程 m3u8 URL → mp4
  Future<void> convert(VideoInfo v) => _start(
        mode: 'remote',
        key: v.url,
        url: v.url,
        title: v.pageTitle.isNotEmpty ? v.pageTitle : 'HLS视频',
        referer: v.effectiveReferer,
        pageDur: v.duration,
      );

  /// 下载 m3u8 分片包（含密钥）到 Downloads，可离线本地转 mp4
  Future<void> downloadM3u8(VideoInfo v) => _start(
        mode: 'package',
        key: v.url,
        url: v.url,
        title: v.pageTitle.isNotEmpty ? v.pageTitle : 'HLS视频',
        referer: v.effectiveReferer,
        pageDur: v.duration,
      );

  /// 原生 background URLSession 分片下载 → 回前台自动 -c copy 合成 mp4。
  /// 锁屏 / 切 App / 系统回收后仍由系统进程继续下分片，产物是自有 mp4。
  Future<void> nativeDownload(VideoInfo v) {
    // _start 的 _active 只覆盖「提交中」这一小段；提交完 Dart 就退出了，
    // 所以还要按 url 查一次在途作业，避免重复 submit 覆盖同一 state.json。
    final dup = tasks.any((t) =>
        t.mode == 'native' && t.url == v.url && !t.done && !t.failed);
    if (dup) return Future<void>.value();
    return _start(
      mode: 'native',
      key: v.url,
      url: v.url,
      title: v.pageTitle.isNotEmpty ? v.pageTitle : 'HLS视频',
      referer: v.effectiveReferer,
      pageDur: v.duration,
    );
  }

  /// 本地 m3u8 文件或包含 .m3u8 的文件夹 → mp4
  Future<void> convertLocal(String folderOrFile) {
    final name = p.basenameWithoutExtension(folderOrFile);
    return _start(
      mode: 'local',
      key: folderOrFile,
      url: folderOrFile,
      title: name.isEmpty ? '本地HLS' : name,
    );
  }

  /// 续传失败/中断的转换任务（复用保留的工作目录与分片）
  Future<void> retry(String id) async {
    ConvertTask? task;
    for (final t in tasks) {
      if (t.id == id) {
        task = t;
        break;
      }
    }
    if (task == null || task.done) return;
    if (task.workDir == null ||
        !Directory(task.workDir!).existsSync()) {
      task.failed = false;
      task.error = '缓存已失效';
      task.workDir = null;
      notifyListeners();
      return;
    }
    if (_active.contains(task.url)) return;
    _active.add(task.url);
    task.failed = false;
    task.error = null;
    task.progress = 0;
    task.doneSegments = 0;
    notifyListeners();
    await _run(task);
    _active.remove(task.url);
    notifyListeners();
  }

  Future<void> delete(String id) async {
    ConvertTask? t;
    for (final x in tasks) {
      if (x.id == id) {
        t = x;
        break;
      }
    }
    if (t?.mode == 'native') {
      // 取消原生在途 task，否则 App 关掉后系统仍会把分片下完
      await NativeBgDownloader.cancel(id);
    }
    tasks.removeWhere((x) => x.id == id);
    try {
      if (t?.workDir != null && Directory(t!.workDir!).existsSync()) {
        await Directory(t.workDir!).delete(recursive: true);
      }
      final docs = await getApplicationDocumentsDirectory();
      final dl = Directory(p.join(docs.path, 'Downloads'));
      final meta = File(p.join(dl.path, '$id.json'));
      if (await meta.exists()) await meta.delete();
      if (t?.localPath != null) {
        final lp = t!.localPath!;
        final d = Directory(lp);
        if (await d.exists()) {
          await d.delete(recursive: true);
        } else {
          final f = File(lp);
          if (await f.exists()) await f.delete();
        }
      }
      await _removePendingById(id);
    } catch (_) {}
    notifyListeners();
  }

  /// 取消进行中的转换任务（含原生后台作业）。
  /// 资源库「取消」原来对 kind=='convert' 会误调 HlsManager，这里统一收口。
  Future<void> cancel(String id) async {
    ConvertTask? t;
    for (final x in tasks) {
      if (x.id == id) {
        t = x;
        break;
      }
    }
    if (t == null) return;
    // _start 用 url 去重，取消后必须释放，否则同链接再也发不起新任务
    _active.remove(t.url);
    await delete(id);
  }

  Future<void> _savePending(ConvertTask t) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'Downloads'));
      await dir.create(recursive: true);
      await File(p.join(dir.path, '${t.id}.convert.json'))
          .writeAsString(jsonEncode(t.toPendingJson()));
    } catch (_) {}
  }

  Future<void> _clearPending(ConvertTask t) => _removePendingById(t.id);

  Future<void> _removePendingById(String id) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'Downloads'));
      final f = File(p.join(dir.path, '$id.convert.json'));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> _start({
    required String mode,
    required String key,
    required String url,
    required String title,
    String referer = '',
    double pageDur = 0,
  }) async {
    if (_active.contains(key)) return;
    _active.add(key);
    final task = ConvertTask(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      url: url,
      title: title,
      mode: mode,
      referer: referer,
      pageDur: pageDur,
    );
    tasks.add(task);
    notifyListeners();
    await _savePending(task);
    await _run(task);
    _active.remove(key);
    notifyListeners();
  }

  Future<void> _run(ConvertTask task) async {
    final bg = await BackgroundTask.begin();
    try {
      Directory? work;
      if (task.workDir != null && Directory(task.workDir!).existsSync()) {
        work = Directory(task.workDir!);
      } else {
        // native 链的分片要由原生后台进程写入：tmp 可能被系统回收，且进程
        // 被杀后路径失效 → 固定放 Documents/Downloads/.native_<id>。
        final root = task.mode == 'native'
            ? (await getApplicationDocumentsDirectory()).path
            : (await getTemporaryDirectory()).path;
        final sub = task.mode == 'native'
            ? p.join('Downloads', '.native_${task.id}')
            : 'm3u8_${task.id}';
        work = await Directory(p.join(root, sub)).create(recursive: true);
        task.workDir = work.path;
      }
      // 工作目录确定后落盘，确保进程被杀后重启可恢复
      await _savePending(task);
      switch (task.mode) {
        case 'local':
          await _convertLocal(task, work);
          await _finishMp4(task, work);
          break;
        case 'package':
          await _downloadPackage(task, work);
          break;
        case 'native':
          await _runNative(task, work);
          break;
        default:
          await _convertRemote(task, work);
          await _finishMp4(task, work);
          break;
      }
    } catch (e) {
      task.failed = true;
      task.error = e.toString();
      // 工作目录保留，供 retry() 续传；持久化以便重启后恢复
      await _savePending(task);
      AppLog.instance.error(
        'convert',
        'm3u8 ${task.mode} 失败: ${task.title}（${task.url}）',
        e,
      );
    } finally {
      await BackgroundTask.end(bg);
      notifyListeners();
    }
  }

  // ---------- 远程 m3u8 → mp4 ----------

  Future<void> _convertRemote(ConvertTask task, Directory work) async {
    // 1) 拉取清单（master → media）。两次请求都要带 Referer，否则防盗链源站
    //    在第一步就 403 —— 分片阶段的 Referer 加得再对也走不到。
    final playlistText =
        await _fetchText(task.url, referer: _refFor(task.url, task.referer));
    final mediaUrl = _selectMediaPlaylist(task.url, playlistText);
    final mediaText =
        await _fetchText(mediaUrl, referer: _refFor(mediaUrl, task.referer));
    // 先核对「这条清单是不是页面那个视频」，再决定要不要下几百 MB
    _verifyDuration(task, mediaText);

    // 2) 解析分片 + 密钥（AES-128）
    final lines = _parsePlaylist(mediaUrl, mediaText);
    final segs = lines.where((l) => l.type == 'seg').toList();
    if (segs.isEmpty) throw Exception('清单中没有可下载的分片');
    task.totalSegments = segs.length;

    final ref = _refFor(mediaUrl, task.referer);

    // 3) 密钥下载
    final keyLocal = await _fetchKeys(work, lines, referer: ref);

    // 4) 并发下载分片（跳过已存在的，断点续传）
    final urls = segs.map((s) => s.url!).toList();
    final names = segs.map((s) => s.name!).toList();
    await _downloadSegments(task, work, urls, names, referer: ref);

    // 5) 生成本地清单
    final localPlaylist = p.join(work.path, 'local.m3u8');
    _writeLocalPlaylist(localPlaylist, lines, keyLocal, names);

    // 6) ffmpeg 无损转封装（解密在解封装阶段由 ffmpeg 完成）
    await _remux(localPlaylist, p.join(work.path, 'out.mp4'));
  }

  // ---------- 本地 m3u8 → mp4 ----------

  Future<void> _convertLocal(ConvertTask task, Directory work) async {
    // 优先复用工作目录中已有的本地清单（重启恢复：原始文件夹可能已不可访问）
    final resumePlaylist = File(p.join(work.path, 'local.m3u8'));
    var text = '';
    var mediaDir = work.path;
    // 分片源目录：恢复时即工作目录自身；首次转换时为源 m3u8 所在目录
    Directory baseDir = Directory(work.path);
    if (await resumePlaylist.exists()) {
      text = await resumePlaylist.readAsString();
    } else {
      // 定位 m3u8：文件本身，或文件夹内第一个 .m3u8
      File? src;
      if (Directory(task.url).existsSync()) {
        src = _findM3u8(Directory(task.url));
      } else if (File(task.url).existsSync()) {
        src = File(task.url);
      }
      if (src == null) throw Exception('未找到 m3u8 文件: ${task.url}');
      baseDir = src.parent;

      text = await src.readAsString();
      // master 清单 → 选择最高码率 media 清单（本地变体），以其所在目录解析分片
      var mediaPath = src.path;
      if (text.contains('#EXT-X-STREAM-INF')) {
        final rel = _selectMediaPlaylistLocal(baseDir.path, text);
        mediaPath = rel;
        text = await File(rel).readAsString();
      }
      mediaDir = p.dirname(mediaPath);
    }

    final lines = _parsePlaylistLocal(mediaDir, text);
    final segs = lines.where((l) => l.type == 'seg').toList();
    if (segs.isEmpty) throw Exception('清单中没有可用的本地分片');
    task.totalSegments = segs.length;

    // 密钥：本地复制 / 远程下载
    final keyLocal =
        await _fetchKeys(work, lines, referer: _refFor(task.url, task.referer));

    // 复制分片（已存在的跳过）
    final names = segs.map((s) => s.name!).toList();
    await _copyLocalSegments(task, work, baseDir.path, segs, names);

    final localPlaylist = p.join(work.path, 'local.m3u8');
    _writeLocalPlaylist(localPlaylist, lines, keyLocal, names);

    await _remux(localPlaylist, p.join(work.path, 'out.mp4'));
  }

  // ---------- 下载 m3u8 分片包（离线备用，可再本地转 mp4） ----------

  Future<void> _downloadPackage(ConvertTask task, Directory work) async {
    final playlistText =
        await _fetchText(task.url, referer: _refFor(task.url, task.referer));
    final mediaUrl = _selectMediaPlaylist(task.url, playlistText);
    final mediaText =
        await _fetchText(mediaUrl, referer: _refFor(mediaUrl, task.referer));
    _verifyDuration(task, mediaText);

    final lines = _parsePlaylist(mediaUrl, mediaText);
    final segs = lines.where((l) => l.type == 'seg').toList();
    if (segs.isEmpty) throw Exception('清单中没有可下载的分片');
    task.totalSegments = segs.length;

    final ref = _refFor(mediaUrl, task.referer);
    final keyLocal = await _fetchKeys(work, lines, referer: ref);

    final urls = segs.map((s) => s.url!).toList();
    final names = segs.map((s) => s.name!).toList();
    await _downloadSegments(task, work, urls, names, referer: ref);

    final localPlaylist = p.join(work.path, 'playlist.m3u8');
    _writeLocalPlaylist(localPlaylist, lines, keyLocal, names);

    // 整个工作目录 → Downloads/<标题>_m3u8/（重名时自动追加序号，不再覆盖旧包）
    final docs = await getApplicationDocumentsDirectory();
    final dl = Directory(p.join(docs.path, 'Downloads'));
    await dl.create(recursive: true);
    final folderName = uniqueFileName(dl, '${safeFileName(task.title)}_m3u8');
    final folder = Directory(p.join(dl.path, folderName));
    await _copyDir(work, folder);
    task.localPath = folder.path;
    task.done = true;
    task.progress = 1;
    final meta = {
      'id': task.id,
      'url': task.url,
      'title': task.title,
      'kind': 'm3u8',
      'localPath': folder.path,
      'm3u8Package': true,
      'folder': '',
      'savedAt': DateTime.now().toIso8601String(),
    };
    await File(p.join(dl.path, '${task.id}.json')).writeAsString(jsonEncode(meta));
    // 成功：清理工作目录与 pending 记录
    if (work.existsSync()) {
      try {
        await work.delete(recursive: true);
      } catch (_) {}
    }
    task.workDir = null;
    await _clearPending(task);
  }

  // ---------- 原生后台分片下载（mode == 'native'） ----------

  /// 用字节数刷新进度 / 速度 / ETA。
  ///
  /// 分片计数只能说明「有多少个 task / 批次结束了」——分片大小差异极大（几十 KB
  /// 的广告片到几 MB 的 TS），Dio 链还按批 4 计数且失败片也进 done，所以它既不
  /// 准也不能反映真实下行量。字节进度才是用户看到的「真下载」。
  void _applyByteProgress(
    ConvertTask t,
    int bytes,
    int bytesTotal,
    bool estimated,
  ) {
    final now = DateTime.now();
    final prevAt = t.bytesSampledAt;
    if (bytes > t.bytes && prevAt != null) {
      final dt = now.difference(prevAt).inMilliseconds / 1000.0;
      // dt 太小除出来是尖峰；太大说明刚从后台回来，那段流量不是「当前速度」
      if (dt >= 0.4 && dt <= 5.0) {
        final inst = (bytes - t.bytes) / dt;
        t.speed = t.speed <= 0 ? inst : t.speed * 0.55 + inst * 0.45;
      }
    }
    t.bytes = bytes;
    if (bytesTotal > 0) {
      t.bytesTotal = bytesTotal;
      t.bytesEstimated = estimated;
    }
    t.bytesSampledAt = now;
    // 只有拿到「总量 > 已下」时才用字节比；总量未知时退回分片比，
    // 否则（total 缺失被当成 == bytes）进度会瞬间跳到 100%。
    if (t.bytesTotal > t.bytes && t.bytes > 0) {
      t.progress = (t.bytes / t.bytesTotal).clamp(0.0, 1.0).toDouble();
    }
    // 分片计数不再从字节比反推：原生上报的是真实落盘片数，反推出来的数字
    // 会在「大分片还没下完」时虚高（几百片里差几十 MB 只体现为 0.1%）。
    if (t.speed > 0 && t.bytesTotal > t.bytes) {
      final secs = ((t.bytesTotal - t.bytes) / t.speed).ceil();
      t.eta = secs > 0 ? Duration(seconds: secs) : null;
    }
  }

  /// Dart 前台只做清单解析与本地 playlist 生成，把整个作业一次性交给原生。
  /// 提交后立刻返回：分片下载由系统进程托管，锁屏 / 切 App 仍继续。
  Future<void> _runNative(ConvertTask task, Directory work) async {
    final playlistText =
        await _fetchText(task.url, referer: _refFor(task.url, task.referer));
    final mediaUrl = _selectMediaPlaylist(task.url, playlistText);
    final mediaText =
        await _fetchText(mediaUrl, referer: _refFor(mediaUrl, task.referer));
    _verifyDuration(task, mediaText);
    final lines = _parsePlaylist(mediaUrl, mediaText);
    final segs = lines.where((l) => l.type == 'seg').toList();
    if (segs.isEmpty) throw Exception('清单中没有可下载的分片');

    // 原生链不预下密钥：key 也作为 part 交给原生，避免同一文件重复下载。
    final keyLocal = <String, String>{};
    for (final e in lines.where((l) => l.type == 'key')) {
      final src = e.url!;
      if (!keyLocal.containsKey(src)) {
        keyLocal[src] = 'key_${keyLocal.length}.bin';
      }
    }
    final names = segs.map((s) => s.name!).toList();
    final playlistPath = p.join(work.path, 'playlist.m3u8');
    _writeLocalPlaylist(playlistPath, lines, keyLocal, names);

    final parts = <NativeSegPart>[
      for (final e in keyLocal.entries)
        NativeSegPart(url: e.key, name: e.value),
      for (var i = 0; i < segs.length; i++)
        NativeSegPart(url: segs[i].url!, name: names[i]),
    ];
    // 防盗链：优先用嗅探到的那条清单所属 frame 的地址；拿不到再用清单 origin。
    // 原生后台分片是系统进程发的请求，没有页面会话，Referer 只能靠这里显式给。
    final ref = _refFor(mediaUrl, task.referer);
    final headers = <String, String>{
      'User-Agent': (_dio.options.headers['User-Agent'] ?? '').toString(),
      if (ref.isNotEmpty) 'Referer': ref,
    };

    task.totalSegments = segs.length;
    task.doneSegments = 0;
    task.progress = 0;
    task.stage = 'downloading';
    // 已经落盘的分片由原生扫盘计入 bytes，这里只重置速度采样
    task.speed = 0;
    task.eta = null;
    task.bytesSampledAt = null;
    // 提交后 Dart 不再持有长任务，进程随时可能被系统回收；这里必须把 stage 与
    // 分片总数写回断点记录，否则冷启动恢复后 totalSegments=0，UI 永远显示 0/0。
    await _savePending(task);
    notifyListeners();

    final ok = await NativeBgDownloader.submit(NativeSegJob(
      jobId: task.id,
      workDir: work.path,
      playlistPath: playlistPath,
      parts: parts,
      headers: headers,
    ));
    if (!ok) {
      throw Exception('后台下载不可用');
    }
    // 刻意不 await 下载完成：这一步交给系统，Dart 侧不留长任务。
    AppLog.instance.info(
        'convert', '已提交原生后台分片作业: ${task.title}（${parts.length} 个文件）');
  }

  /// 分片齐备后合成 mp4。系统唤醒窗口只有几秒，ffmpeg -c copy 必须放前台做。
  Future<void> _finishNative(ConvertTask task) async {
    if (task.done || _nativeFinishing.contains(task.id)) return;
    final dir = task.workDir;
    if (dir == null || !Directory(dir).existsSync()) {
      task.failed = true;
      task.stage = 'failed';
      task.error = '目录已丢失';
      notifyListeners();
      return;
    }
    _nativeFinishing.add(task.id);
    final work = Directory(dir);
    try {
      task.stage = 'remuxing';
      task.progress = 1;
      task.failed = false;
      task.error = null;
      notifyListeners();
      final playlist = p.join(work.path, 'playlist.m3u8');
      if (!File(playlist).existsSync()) throw Exception('本地清单缺失');
      await _remux(playlist, p.join(work.path, 'out.mp4'));
      await _finishMp4(task, work);
      await NativeBgDownloader.markRemuxed(task.id);
      AppLog.instance.info('convert', '后台分片转封装完成: ${task.title}');
    } catch (e, st) {
      task.failed = true;
      task.stage = 'failed';
      task.error = '合成失败';
      unawaited(_savePending(task));
      AppLog.instance.error(
          'convert', '后台分片转封装失败: ${task.title}', e, st);
    } finally {
      _nativeFinishing.remove(task.id);
      notifyListeners();
    }
  }

  /// 前台实时进度（后台期间可能收不到，不能当唯一状态来源）
  void _onNativeEvent(Map<String, dynamic> e) {
    final id = e['jobId'] as String? ?? '';
    ConvertTask? task;
    for (final t in tasks) {
      if (t.id == id && t.mode == 'native') {
        task = t;
        break;
      }
    }
    if (task == null || task.done) return;
    final segTotal = (e['total'] as num?)?.toInt() ?? 0;
    final segDone = (e['done'] as num?)?.toInt() ?? 0;
    final bytes = (e['bytes'] as num?)?.toInt() ?? 0;
    final bytesTotal = (e['bytesTotal'] as num?)?.toInt() ?? 0;
    // 分片数用原生上报的真实值（真实落盘片数），不要由字节比反推
    if (segTotal > 0) task.totalSegments = segTotal;
    task.doneSegments = segDone;
    if (bytes > 0) {
      _applyByteProgress(
          task, bytes, bytesTotal, (e['bytesEstimated'] as bool?) ?? false);
    }
    // 字节总量还没拿到（首个 Content-Length 未回 / 全部排队中）：退回分片比例，
    // 别让进度条卡在 0%。算不出字节比时也走这条，保证进度单调前进。
    if (segTotal > 0 && task.bytesTotal <= task.bytes) {
      task.progress = (segDone / segTotal).clamp(0.0, 1.0).toDouble();
    }
    switch (e['state'] as String? ?? 'downloading') {
      case 'ready':
        task.stage = 'ready';
        unawaited(_finishNative(task));
      case 'failed':
        task.failed = true;
        task.stage = 'failed';
        final err = e['error'] as String? ?? '';
        task.error = err.isEmpty ? '后台分片下载失败' : err;
        unawaited(_savePending(task));
      default:
        task.stage = 'downloading';
    }
    notifyListeners();
  }

  /// App 回前台 / 冷启动对账：后台期间事件可能整段丢失，以原生磁盘状态为准。
  Future<void> onResume() => _resumeNativeJobs();

  Future<void> _resumeNativeJobs() async {
    final natives = tasks
        .where((t) => t.mode == 'native' && !t.done)
        .toList(growable: false);
    if (natives.isEmpty) return;
    final byId = <String, NativeJobStatus>{
      for (final s in await NativeBgDownloader.listJobs()) s.jobId: s,
    };
    for (final t in natives) {
      final s = byId[t.id];
      if (s == null) {
        if (!t.failed) {
          t.failed = true;
          t.stage = 'failed';
          t.error = '作业记录丢失';
        }
        continue;
      }
      if (s.workDir.isNotEmpty && Directory(s.workDir).existsSync()) {
        t.workDir = s.workDir;
      }
      if (s.bytes > 0) {
        // 这批字节是系统在后台代下的，不能当成瞬时速度：先清基线再采样
        t.bytesSampledAt = null;
        t.speed = 0;
        _applyByteProgress(t, s.bytes, s.bytesTotal, s.bytesEstimated);
      }
      // 分片数以原生磁盘状态为准（冷启动后 Dart 侧的内存计数已丢失）
      if (s.total > 0) t.totalSegments = s.total;
      t.doneSegments = s.done;
      // 字节总量未知时仍按分片比例兜底（冷启动 total 可能是 0）
      if (t.bytesTotal <= t.bytes) {
        t.progress = s.progress;
      }
      if (s.isReady) {
        t.failed = false;
        t.error = null;
        t.stage = 'ready';
        // 不 await：ffmpeg 可能跑几十秒，别卡 App 启动 / 回前台
        unawaited(_finishNative(t));
      } else if (s.isFailed) {
        t.failed = true;
        t.stage = 'failed';
        final err = s.error ?? '';
        t.error = err.isEmpty ? '下载失败' : err;
      } else {
        t.failed = false;
        t.error = null;
        t.stage = 'downloading';
      }
    }
    notifyListeners();
  }

  // ---------- 收尾（mp4 输出 → Downloads） ----------

  Future<void> _finishMp4(ConvertTask task, Directory work) async {
    final outMp4 = p.join(work.path, 'out.mp4');
    final f = File(outMp4);
    if (!await f.exists() || await f.length() == 0) throw Exception('输出文件为空');

    final docs = await getApplicationDocumentsDirectory();
    final dl = Directory(p.join(docs.path, 'Downloads'));
    await dl.create(recursive: true);
    // 与已存文件重名时自动追加序号，不再覆盖
    final safe = uniqueFileName(dl, '${safeFileName(task.title)}.mp4');
    final target = p.join(dl.path, safe);
    await f.copy(target);
    task.localPath = target;
    task.done = true;
    task.progress = 1;
    final meta = {
      'id': task.id,
      'url': task.url,
      'title': task.title,
      'kind': 'mp4',
      'localPath': target,
      'folder': '',
      'savedAt': DateTime.now().toIso8601String(),
    };
    await File(p.join(dl.path, '${task.id}.json')).writeAsString(jsonEncode(meta));
    // 成功：清理工作目录与 pending 记录
    if (work.existsSync()) {
      try {
        await work.delete(recursive: true);
      } catch (_) {}
    }
    task.workDir = null;
    await _clearPending(task);
  }

  // ---------- 网络/IO 基础 ----------

  /// scheme://host[:port]，非 http(s) / 解析失败时返回空串
  static String _originOf(String u) {
    try {
      final uri = Uri.tryParse(u);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) return '';
      final port = uri.hasPort ? ':${uri.port}' : '';
      return '${uri.scheme}://${uri.host}$port';
    } catch (_) {
      return '';
    }
  }

  /// 本次请求该带的 Referer。
  ///
  /// 优先用嗅探到的那条清单所属 frame 的地址：它和浏览器发请求时的 Referer
  /// 一致，能过绝大多数防盗链；拿不到时退回清单自身的 origin（防盗链通常只校验
  /// 域名）。两者都没有就不带 —— 绝不写死某个站点的地址。
  static String _refFor(String target, String pageRef) =>
      pageRef.isNotEmpty ? pageRef : _originOf(target);

  /// 清单总时长 = Σ#EXTINF（master 清单没有该指令 → 0）
  static double _playlistDuration(String text) {
    final re = RegExp(r'#EXTINF:\s*([0-9]+(?:\.[0-9]+)?)');
    var sum = 0.0;
    var n = 0;
    for (final m in re.allMatches(text)) {
      sum += double.tryParse(m.group(1)!) ?? 0;
      if (++n > 20000) break;
    }
    return n == 0 ? 0 : sum;
  }

  /// 下载前核对「这条清单是不是页面上那个视频」。
  ///
  /// 站点常见形态：主视频 + 预加载的下一集 + 预卷广告，三条 m3u8 都合法、都能
  /// 200，光看 URL 和状态码分不出来，选中错了就是「下出来是别的视频」。
  /// 清单的 Σ#EXTINF 与页面 video.duration 是唯一能对上的标尺：
  /// - 差得不多（片头广告 / 元数据取整）→ 只记日志；
  /// - 差得离谱（几十秒以上且超过 20%）→ 直接拦下，别白下几百 MB。
  void _verifyDuration(ConvertTask task, String mediaText) {
    if (task.pageDur <= 0) return;
    final listDur = _playlistDuration(mediaText);
    if (listDur <= 0) return; // 读不到时长（master / 加密清单）→ 无从核对
    final diff = (listDur - task.pageDur).abs();
    final tol = task.pageDur * 0.04 > 5 ? task.pageDur * 0.04 : 5.0;
    if (diff <= tol) return;
    final msg = '清单时长 ${listDur.toStringAsFixed(0)}s 与页面视频 '
        '${task.pageDur.toStringAsFixed(0)}s 不符（差 ${diff.toStringAsFixed(0)}s），'
        '这条 m3u8 可能不是页面上正在播的那个视频';
    if (diff > 60 && diff > task.pageDur * 0.2) {
      throw Exception(msg);
    }
    AppLog.instance.warn('convert', '${task.title}: $msg');
  }

  Future<String> _fetchText(String url, {String referer = ''}) async {
    final resp = await _dio.get<String>(url, options: Options(
      responseType: ResponseType.plain,
      headers: {
        'Accept': '*/*',
        // 清单请求同样要过防盗链：这里是最容易漏的一步，也是「点下载就报网络
        // 问题」的第一现场（分片阶段的 Referer 反倒早就加对了）
        if (referer.isNotEmpty) 'Referer': referer,
      },
    ));
    return resp.data ?? '';
  }

  /// 下载单个分片：3 次重试（300/600ms 退避），先写 `<name>.tmp` 再原子改名。
  ///
  /// 分片链路上 `Connection closed while receiving data` 很常见，成因只有两类：
  /// - 锁屏 / 切后台后 Dart isolate 被挂起，socket 冻结，回前台读到 EOF；
  /// - 单例 Dio 的连接池复用了服务端已关闭的 keep-alive 连接。
  /// 两者都只影响「当前这一片」，重试即可，不该让整个作业失败。
  ///
  /// 落盘改 `.tmp` → rename 是为了续传正确性：进程被杀/系统回收时 `.tmp` 会留在
  /// 磁盘上，但它不叫正式名，下次 `_downloadSegments` 不会把半截分片当成已完成。
  Future<void> _downloadTo(String url, String path, {String? referer}) async {
    final tmp = File('$path.tmp');
    Object? lastErr;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        if (await tmp.exists()) await tmp.delete();
        await _dio.download(
          url,
          tmp.path,
          options: Options(
            headers: {
              // 与 _fetchKeys 对齐：用 media 清单 origin，而不是 Dio 全局写死的
              // B 站 Referer，避免防盗链源站直接 RST。
              if (referer != null && referer.isNotEmpty) 'Referer': referer,
              // 前两次沿用连接池（省 TLS 握手）；第三次强制短连接，绕开
              // 「池里那条已经死掉的 keep-alive」这条确定性死路。
              if (attempt >= 3) 'Connection': 'close',
            },
            receiveTimeout: const Duration(seconds: 30),
          ),
        );
        if (!await tmp.exists() || await tmp.length() == 0) {
          throw Exception('分片内容为空');
        }
        await tmp.rename(path);
        return;
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) rethrow;
        lastErr = e;
      } catch (e) {
        lastErr = e;
      }
      if (attempt < 3) {
        await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
      }
    }
    throw Exception('分片下载失败: $url${_briefErr(lastErr)}');
  }

  /// 把最后一次失败压成短标记：分片链上「422/403」和「断连」完全是两回事，
  /// 只报「分片下载失败」会让用户以为是网络问题，实际上多半是被源站拒了。
  static String _briefErr(Object? e) {
    if (e is DioException) {
      final c = e.response?.statusCode ?? 0;
      if (c > 0) return '（HTTP $c）';
      return '（${e.type.name}）';
    }
    return e == null ? '' : '（$e）';
  }

  /// 并发下载分片（批 4 个）；已存在且非空的分片跳过（续传）。
  ///
  /// 单片失败不再让整轮作废：每片自带重试（见 [_downloadTo]），仍失败的记下标，
  /// 跑完所有批次再统一抛错 —— 已下好的分片全部保留，点「继续下载」只补缺的。
  /// 旧实现是 `Future.wait(batch)` 直接冒泡，几百片里断一片就整任务 failed。
  Future<void> _downloadSegments(ConvertTask task, Directory work,
      List<String> urls, List<String> names, {String? referer}) async {
    // 待下载集合先算好：续传起点 + 顺手清掉上次遗留的 .tmp 残片
    final pending = <int>[];
    var existing = 0;
    var existingBytes = 0;
    for (var i = 0; i < names.length; i++) {
      final f = File(p.join(work.path, names[i]));
      if (await f.exists() && await f.length() > 0) {
        existing++;
        existingBytes += await f.length();
        continue;
      }
      pending.add(i);
      final tmp = File(p.join(work.path, '${names[i]}.tmp'));
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }

    var done = 0;
    var cumulative = 0;
    var lastBytes = 0;
    var lastTime = DateTime.now();
    final failed = <int>[];
    for (var k = 0; k < pending.length; k += 4) {
      final end = k + 4 > pending.length ? pending.length : k + 4;
      final slice = pending.sublist(k, end);
      final failBefore = failed.length;
      final batch = <Future<void>>[];
      for (final j in slice) {
        // 单片失败只记录，不冒泡：否则一片断流就丢掉整轮进度
        batch.add(() async {
          try {
            await _downloadTo(urls[j], p.join(work.path, names[j]),
                referer: referer);
          } catch (e, st) {
            failed.add(j);
            AppLog.instance.warn(
              'convert',
              '分片失败 #$j（${names[j]}）: ${urls[j]}',
              e,
              st,
            );
          }
        }());
      }
      await Future.wait(batch);
      // 失败的分片不算「已下」：进度条停在真实完成度上，用户看到的 x/y 才可信
      done += slice.length - (failed.length - failBefore);
      task.doneSegments = existing + done;
      task.progress = urls.isEmpty ? 0 : (existing + done) / urls.length;
      // 熔断：连续整批全灭说明源站/网络整体不可用。不熔断的话每片要耗 3 次重试
      // × 30s 超时，几百片能空转十几分钟才报错。
      if (failed.length - failBefore == slice.length && failed.length >= 8) {
        throw Exception(
            '源站不可用，已中止（${failed.length}/${urls.length} 片失败）');
      }
      var batchBytes = 0;
      for (final j in slice) {
        try {
          batchBytes += File(p.join(work.path, names[j])).lengthSync();
        } catch (_) {}
      }
      cumulative += batchBytes;
      // 顺带给出字节进度：分片计数在「批 4」下每次跳 4 片，看不出真实下行量。
      // 总量按已下分的均值外推（清单里没有分片大小）。
      final doneCount = existing + done;
      task.bytes = existingBytes + cumulative;
      task.bytesTotal = doneCount > 0
          ? (task.bytes / doneCount * urls.length).round()
          : 0;
      task.bytesEstimated = true;
      final now = DateTime.now();
      final dtMs = now.difference(lastTime).inMilliseconds;
      if (dtMs >= 800) {
        final dBytes = cumulative - lastBytes;
        if (dBytes > 0 && dtMs > 0) {
          task.speed = dBytes / (dtMs / 1000.0);
          if (done > 0 && task.speed > 0) {
            final avg = cumulative / done;
            final remBytes = avg * (urls.length - existing - done);
            task.eta = Duration(seconds: (remBytes / task.speed).round());
          }
        }
        lastBytes = cumulative;
        lastTime = now;
      }
      notifyListeners();
    }

    if (failed.isNotEmpty) {
      throw Exception('${failed.length}/${urls.length} 个分片下载失败');
    }
  }

  /// 复制本地分片到工作目录（已存在的跳过）
  Future<void> _copyLocalSegments(ConvertTask task, Directory work,
      String baseDir, List<_PlaylistEntry> segs, List<String> names) async {
    var existing = 0;
    var totalBytes = 0;
    for (var i = 0; i < names.length; i++) {
      final f = File(p.join(work.path, names[i]));
      if (await f.exists() && await f.length() > 0) {
        existing++;
        task.bytes += await f.length();
      }
    }
    // 本地件大小完全已知：给精确总量，UI 不标 ≈
    for (final s in segs) {
      try {
        totalBytes += await File(s.url!).length();
      } catch (_) {}
    }
    task.bytesTotal = totalBytes;
    task.bytesEstimated = false;
    var done = 0;
    for (var i = 0; i < segs.length; i++) {
      final srcPath = segs[i].url!;
      final src = File(srcPath);
      if (!await src.exists()) {
        throw Exception('本地缺少分片文件: $srcPath');
      }
      final dst = p.join(work.path, names[i]);
      if (File(dst).existsSync() && File(dst).lengthSync() > 0) continue;
      await src.copy(dst);
      done++;
      task.doneSegments = existing + done;
      task.progress = segs.isEmpty ? 0 : (existing + done) / segs.length;
      try {
        task.bytes += await File(dst).length();
      } catch (_) {}
      if (task.bytesTotal > 0) {
        task.progress =
            (task.bytes / task.bytesTotal).clamp(0.0, 1.0).toDouble();
      }
      notifyListeners();
    }
  }

  /// 下载/复制 AES-128 密钥到工作目录；返回 源地址 → 本地文件名 映射
  Future<Map<String, String>> _fetchKeys(Directory work,
      List<_PlaylistEntry> lines, {String? referer}) async {
    final map = <String, String>{};
    var i = 0;
    for (final e in lines.where((l) => l.type == 'key')) {
      final src = e.url!;
      if (map.containsKey(src)) continue;
      final localName = 'key_$i.bin';
      final localPath = p.join(work.path, localName);
      try {
        if (e.remote) {
          final resp = await _dio.get<List<int>>(src, options: Options(
            responseType: ResponseType.bytes,
            headers: {
              if (referer != null && referer.isNotEmpty) 'Referer': referer,
            },
          ));
          await File(localPath).writeAsBytes(resp.data ?? const [], flush: true);
        } else {
          final srcFile = File(src);
          if (!await srcFile.exists()) throw Exception('本地缺少密钥文件: $src');
          await srcFile.copy(localPath);
        }
        if (await File(localPath).length() == 0) {
          throw Exception('密钥文件为空: $src');
        }
      } catch (err) {
        throw Exception('获取 AES-128 密钥失败: $src ($err)');
      }
      map[src] = localName;
      i++;
    }
    return map;
  }

  Future<void> _remux(String playlist, String out) async {
    // -allowed_extensions ALL：本地清单把 AES-128 密钥写成 key_0.bin，
    // 而 ffmpeg HLS 解复用器默认白名单不含 bin（只有 ts/m3u8/mp4…），
    // 会直接报「Filename extension of ... not recognized / set allowed_extensions to 'ALL'」。
    // 该选项是 demuxer 私有选项，必须放在 -i 之前。
    final session = await FFmpegKit.execute(
      '-y -allowed_extensions ALL -i "$playlist" -c copy -movflags +faststart "$out"',
    );
    final rc = await session.getReturnCode();
    if (!ReturnCode.isSuccess(rc)) {
      // 详细报错：收集 ffmpeg 输出尾部，便于排查
      var tail = '';
      try {
        final so = await session.getOutput();
        final sl = await session.getLogs();
        tail = _lastLines('$so\n$sl', 8);
      } catch (_) {}
      AppLog.instance.error(
        'convert',
        'ffmpeg 转封装失败（$playlist）',
        tail.isEmpty ? null : tail,
      );
      throw Exception('合成失败${tail.isEmpty ? '' : '：$tail'}');
    }
    final f = File(out);
    if (!await f.exists() || await f.length() == 0) throw Exception('输出文件为空');
  }

  /// 取文本末尾 n 行（报错摘要）
  static String _lastLines(String text, int n) {
    final lines = text.trim().split('\n');
    if (lines.length <= n) return lines.join('\n');
    return lines.sublist(lines.length - n).join('\n');
  }

  // ---------- 清单解析 ----------

  /// master 清单选最高码率 media playlist；若本身就是 media 清单则原样返回
  String _selectMediaPlaylist(String baseUrl, String text) {
    if (!text.contains('#EXT-X-STREAM-INF')) return baseUrl;
    final lines = text.split('\n');
    Uri? best;
    var bestBandwidth = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('#EXT-X-STREAM-INF')) {
        final bw = RegExp(r'BANDWIDTH=(\d+)').firstMatch(lines[i]);
        if (bw != null && int.tryParse(bw.group(1)!)! > bestBandwidth) {
          bestBandwidth = int.parse(bw.group(1)!);
          best = Uri.parse(baseUrl).resolve(lines[i + 1].trim());
        }
      }
    }
    if (best == null) throw Exception('未找到 media playlist');
    return best.toString();
  }

  /// 本地 master 清单 → 最高码率 media 清单相对路径
  String _selectMediaPlaylistLocal(String baseDir, String text) {
    final lines = text.split('\n');
    String? best;
    var bestBandwidth = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('#EXT-X-STREAM-INF')) {
        final bw = RegExp(r'BANDWIDTH=(\d+)').firstMatch(lines[i]);
        if (bw != null && int.tryParse(bw.group(1)!)! > bestBandwidth) {
          bestBandwidth = int.parse(bw.group(1)!);
          best = lines[i + 1].trim();
        }
      }
    }
    if (best == null) throw Exception('未找到本地 media playlist');
    return p.normalize(p.join(baseDir, best));
  }

  /// 解析远程 media 清单：分片 + AES-128 密钥位置（保持原始顺序）
  List<_PlaylistEntry> _parsePlaylist(String playlistUrl, String text) {
    final base = Uri.parse(playlistUrl);
    final result = <_PlaylistEntry>[];
    var segCount = 0;
    final lines = text.split('\n');
    for (final raw in lines) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('#EXT-X-KEY')) {
        final k = _parseKey(t);
        if (k.method == 'AES-128') {
          if (k.uri == null || k.uri!.isEmpty) continue;
          result.add(_PlaylistEntry.key(
            url: base.resolve(k.uri!).toString(),
            iv: k.iv,
            remote: true,
            raw: raw,
          ));
        } else if (k.method == 'NONE') {
          result.add(_PlaylistEntry.plain(raw)); // 保持位置（清除密钥状态）
        } else {
          throw Exception('暂不支持的加密方式: ${k.method}');
        }
        continue;
      }
      if (t.startsWith('#')) {
        result.add(_PlaylistEntry.plain(raw));
        continue;
      }
      final abs = base.resolve(t).toString();
      result.add(_PlaylistEntry.seg(
        url: abs,
        name: 'seg_$segCount.ts',
        remote: true,
        raw: raw,
      ));
      segCount++;
    }
    return result;
  }

  /// 解析本地 media 清单：分片为本地路径，密钥可为本地文件或远程 URL
  List<_PlaylistEntry> _parsePlaylistLocal(String baseDir, String text) {
    final result = <_PlaylistEntry>[];
    var segCount = 0;
    final lines = text.split('\n');
    for (final raw in lines) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('#EXT-X-KEY')) {
        final k = _parseKey(t);
        if (k.method == 'AES-128') {
          if (k.uri == null || k.uri!.isEmpty) continue;
          final isRemote = k.uri!.toLowerCase().startsWith('http');
          result.add(_PlaylistEntry.key(
            url: isRemote ? k.uri! : p.normalize(p.join(baseDir, k.uri!)),
            iv: k.iv,
            remote: isRemote,
            raw: raw,
          ));
        } else if (k.method == 'NONE') {
          result.add(_PlaylistEntry.plain(raw));
        } else {
          throw Exception('暂不支持的加密方式: ${k.method}');
        }
        continue;
      }
      if (t.startsWith('#')) {
        result.add(_PlaylistEntry.plain(raw));
        continue;
      }
      final local = p.normalize(p.join(baseDir, t));
      result.add(_PlaylistEntry.seg(
        url: local,
        name: 'seg_$segCount.ts',
        remote: false,
        raw: raw,
      ));
      segCount++;
    }
    return result;
  }

  /// 解析 #EXT-X-KEY 行 → (method, uri, iv)
  ({String method, String? uri, String? iv}) _parseKey(String line) {
    final m = RegExp(r'#EXT-X-KEY:(.+)').firstMatch(line);
    if (m == null) return (method: 'NONE', uri: null, iv: null);
    final attrs = <String, String>{};
    final re = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,"]*)');
    for (final mm in re.allMatches(m.group(1)!)) {
      var v = mm.group(2)!;
      if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
        v = v.substring(1, v.length - 1);
      }
      attrs[mm.group(1)!] = v;
    }
    return (
      method: attrs['METHOD'] ?? 'NONE',
      uri: attrs['URI'],
      iv: attrs['IV'],
    );
  }

  /// 生成本地清单：密钥行改写为本地密钥文件（保留 IV），分片行改写为本地文件名
  void _writeLocalPlaylist(String path, List<_PlaylistEntry> lines,
      Map<String, String> keyLocal, List<String> names) {
    final buf = StringBuffer('#EXTM3U\n');
    var segIndex = 0;
    for (final e in lines) {
      switch (e.type) {
        case 'seg':
          buf.writeln(names[segIndex]);
          segIndex++;
          break;
        case 'key':
          final local = keyLocal[e.url];
          if (local == null) continue;
          var line = '#EXT-X-KEY:METHOD=AES-128,URI="$local"';
          if (e.iv != null && e.iv!.isNotEmpty) line += ',IV=${e.iv}';
          buf.writeln(line);
          break;
        default:
          // 保留 EXTINF / MEDIA-SEQUENCE 等指令（默认 IV 依赖序列号）；跳过 MAP
          if (e.raw.trim().startsWith('#EXT-X-MAP')) continue;
          buf.writeln(e.raw);
          break;
      }
    }
    File(path).writeAsStringSync(buf.toString());
  }

  File? _findM3u8(Directory dir) {
    if (!dir.existsSync()) return null;
    for (final e in dir.listSync(followLinks: false)) {
      if (e is File && p.extension(e.path).toLowerCase() == '.m3u8') return e;
    }
    return null;
  }

  Future<void> _copyDir(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final e in from.list(followLinks: false)) {
      if (e is Directory) {
        await _copyDir(e, Directory(p.join(to.path, p.basename(e.path))));
      } else if (e is File) {
        // 跳过下载中的半截分片（`.tmp`）：它们不是产物，拷进分片包只会变成垃圾
        if (e.path.endsWith('.tmp')) continue;
        await File(p.join(to.path, p.basename(e.path)))
            .writeAsBytes(await e.readAsBytes());
      }
    }
  }
}

/// 清单行：分片 / 密钥 / 其它指令（保持顺序）
class _PlaylistEntry {
  final String type; // seg | key | plain
  final String raw;
  final String? url; // seg: 下载地址（URI 或本地绝对路径）；key: 密钥源地址
  final bool remote; // url 是否为网络地址
  final String? name; // seg 文件名
  final String? iv; // key: 显式 IV

  _PlaylistEntry.seg({
    required this.url,
    required this.name,
    required this.remote,
    required this.raw,
  })  : type = 'seg',
        iv = null;

  _PlaylistEntry.key({
    required this.url,
    required this.iv,
    required this.remote,
    required this.raw,
  })  : type = 'key',
        name = null;

  _PlaylistEntry.plain(this.raw)
      : type = 'plain',
        url = null,
        remote = false,
        name = null,
        iv = null;
}
