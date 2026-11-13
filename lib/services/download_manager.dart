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
import 'm3u8_convert.dart';

enum DownloadStatus { queued, downloading, done, failed }

class DownloadTask {
  final String id;
  final String url;
  String title; // 重命名后同步更新（完成项仍驻留内存列表）
  final String kind;
  final DateTime startedAt;
  String? localPath;
  String? partPath;
  double progress = 0;
  double speed = 0; // 字节/秒
  Duration? eta;
  DownloadStatus status = DownloadStatus.queued;
  String? error;

  DownloadTask({
    required this.id,
    required this.url,
    required this.title,
    required this.kind,
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now();

  /// 失败/中断后是否保留有 .part 文件、可断点续传
  bool get canResume {
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
        'localPath': localPath,
        'folder': '',
        'savedAt': DateTime.now().toIso8601String(),
      };

  factory DownloadTask.fromJson(Map<String, dynamic> j) => DownloadTask(
        id: j['id'] as String,
        url: j['url'] as String,
        title: (j['title'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? 'other',
      );

  /// 中断时的持久化状态（供下次启动恢复续传）
  Map<String, dynamic> toPendingJson() => {
        'id': id,
        'url': url,
        'title': title,
        'kind': kind,
        'part': partPath,
        'startedAt': startedAt.toIso8601String(),
      };

  factory DownloadTask.fromPendingJson(Map<String, dynamic> j) =>
      DownloadTask(
        id: j['id'] as String,
        url: j['url'] as String,
        title: (j['title'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? 'other',
        startedAt: DateTime.tryParse((j['startedAt'] as String?) ?? ''),
      )..partPath = j['part'] as String?;
}

/// 下载管理器：mp4 直链走 Dio（支持 Range 断点续传 + iOS 后台任务桥接）
/// 下载过程始终写 <名字>.part，完成后重命名为 .mp4；
/// 失败/取消时保留 .part 并持久化 pending 状态，可断点续传。
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
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    try {
      final dir = await downloadsDir();
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
    } catch (_) {}
    return id;
  }

  /// 启动时恢复未完成的断点任务
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
            // 无 part 记录的无效 pending，直接清理
            if (t.partPath == null || t.partPath!.isEmpty) {
              final pend = File(entity.path);
              if (await pend.exists()) await pend.delete();
              continue;
            }
            final part = File(t.partPath!);
            if (await part.exists() && await part.length() > 0) {
              t.error = '已暂停，可继续下载';
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
    } catch (e, st) {
      AppLog.instance.error('download', '启动时恢复断点任务失败', e, st);
    }
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
    return result;
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
        id: id, url: v.url, title: v.pageTitle, kind: v.kind);
    _tasks.insert(0, task);
    notifyListeners();
    await _run(task);
  }

  Future<void> resume(String id) async {
    for (final t in _tasks) {
      if (t.id == id) {
        await _run(t);
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
    notifyListeners();

    final cancel = CancelToken();
    _cancels[task.id] = cancel;
    final bg = await BackgroundTask.begin();
    try {
      final dir = await downloadsDir();
      // 断点续传沿用原 part 文件名；新下载按标题取唯一名
      //（与已存文件/进行中任务重名时自动追加序号，不再覆盖旧文件）
      var fileName = _resumeFileName(task, dir);
      if (fileName == null) {
        fileName = uniqueFileName(
            dir, _mp4Name(task.title.isNotEmpty ? task.title : task.url));
      }
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

      final raf = await partFile.open(mode: FileMode.append);
      var lastBytes = 0;
      var lastTime = DateTime.now();
      try {
        await for (final chunk in resp.data!.stream) {
          await raf.writeFrom(chunk);
          received += chunk.length;
          final done = offset + received;
          if (total > 0) task.progress = done / total;
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
        task.error = '已暂停，可继续下载';
        AppLog.instance.info('download', '下载已暂停: ${task.title}');
      } else {
        task.status = DownloadStatus.failed;
        task.error = e.toString();
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
    _cancels.remove(id)?.cancel();
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
  /// 原生 HLS 条目（无 localPath）仅更新标题。返回是否成功。
  Future<bool> rename(String id, String newTitle) async {
    final title = newTitle.trim();
    if (title.isEmpty) return false;
    try {
      final dir = await downloadsDir();
      final meta = File(p.join(dir.path, '$id.json'));
      if (!await meta.exists()) return false;
      final j = jsonDecode(await meta.readAsString());
      if (j is! Map<String, dynamic>) return false;
      final oldPath = (j['localPath'] as String?) ?? '';
      var newPath = oldPath;
      if (oldPath.isNotEmpty) {
        final renamed = await _renameOnDisk(oldPath, title);
        if (renamed == null) return false; // 磁盘改名失败 → 元数据不动
        newPath = renamed;
      }
      j['title'] = title;
      j['localPath'] = newPath;
      await meta.writeAsString(jsonEncode(j));
      // 内存中驻留的完成/进行中任务同步（避免展示旧标题/旧路径）
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
      notifyListeners();
      return true;
    } catch (e, st) {
      AppLog.instance.error('download', '重命名失败: $id', e, st);
      return false;
    }
  }

  /// 磁盘改名：文件（mp4/分享导入）或文件夹（m3u8 分片包）。保留原扩展名；
  /// 新名与现存文件冲突时自动追加序号；磁盘文件已不存在时返回原路径（仅改标题）。
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
