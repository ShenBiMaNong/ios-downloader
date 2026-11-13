import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';

/// 原生桥接通道（iOS: AVAssetDownloadTask）
class HlsDownloader {
  static const _method = MethodChannel('video_downloader/hls');
  static const _events = EventChannel('video_downloader/hls/events');

  /// 返回 taskId
  static Future<String> download(String url, String title) async {
    final r = await _method.invokeMethod<String>('download', {
      'url': url,
      'title': title,
    });
    return r ?? '';
  }

  static Future<void> cancel(String taskId) =>
      _method.invokeMethod('cancel', {'taskId': taskId});

  static Future<bool> playOffline(String taskId) async {
    final r = await _method.invokeMethod<bool>('playOffline', {'taskId': taskId});
    return r ?? false;
  }

  /// 下载进行中边下边看：复用同一 AVURLAsset 建 AVPlayerItem（读已缓存分段）
  static Future<bool> playWhileDownloading(String taskId) async {
    final r = await _method
        .invokeMethod<bool>('playWhileDownloading', {'taskId': taskId});
    return r ?? false;
  }

  /// 恢复原生侧在途任务（重建映射）；返回被匹配到的 taskId 列表
  static Future<List<String>> restore(List<Map<String, String>> tasks) async {
    try {
      final r = await _method.invokeMethod<List<dynamic>>('restore', {
        'tasks': [for (final t in tasks) {...t}],
      });
      return (r ?? const []).whereType<String>().toList();
    } catch (_) {
      return const [];
    }
  }

  /// 重试失败任务（原生重建 AVAssetDownloadTask，沿用同一 taskId）
  static Future<bool> retry(String taskId, String url, String title) async {
    try {
      final r = await _method.invokeMethod<bool>('retry', {
        'taskId': taskId,
        'url': url,
        'title': title,
      });
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  static Stream<Map<String, dynamic>> events() => _events
      .receiveBroadcastStream()
      .map((e) => Map<String, dynamic>.from((e as Map).cast<String, dynamic>()));
}

class HlsTask {
  final String taskId;
  final String url;
  String title; // 重命名后同步更新（完成项仍驻留内存列表）
  final DateTime startedAt;
  double progress = 0;
  Duration? eta; // 按进度速率估算
  bool done = false;
  bool failed = false;
  String? error;

  HlsTask({
    required this.taskId,
    required this.url,
    required this.title,
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now();

  /// 失败/中断后可点击「继续下载」
  bool get resumable => failed;
}

/// HLS 离线下载管理（MVP-2）
class HlsManager extends ChangeNotifier {
  static final HlsManager instance = HlsManager._();

  HlsManager._() {
    HlsDownloader.events().listen(_onEvent);
  }

  final List<HlsTask> tasks = [];
  final Set<String> _started = {};
  final Map<String, ({double p, DateTime t})> _lastSample = {};
  bool _loaded = false;

  /// 启动时恢复未完成的 HLS 任务：读取 pending 记录，原生侧重新挂接在途任务
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'Downloads'));
      if (!await dir.exists()) return;
      final restored = <Map<String, String>>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.hls.json')) {
          try {
            final j = jsonDecode(await entity.readAsString());
            if (j is! Map<String, dynamic>) continue;
            final taskId = (j['taskId'] as String?) ?? '';
            final url = (j['url'] as String?) ?? '';
            if (taskId.isEmpty || url.isEmpty) continue;
            if (tasks.any((t) => t.taskId == taskId)) continue;
            final t = HlsTask(
              taskId: taskId,
              url: url,
              title: (j['title'] as String?) ?? '',
              startedAt: DateTime.tryParse((j['startedAt'] as String?) ?? ''),
            )
              ..failed = true
              ..error = '已暂停，可继续下载';
            tasks.add(t);
            restored.add({'taskId': taskId, 'url': url, 'title': t.title});
          } catch (e, st) {
            AppLog.instance
                .warn('hls', '解析 HLS 断点记录失败: ${entity.path}', e, st);
          }
        }
      }
      if (restored.isNotEmpty) {
        // 原生侧重新挂接在途任务；匹配上的任务立即恢复为进行中
        final matched = await HlsDownloader.restore(restored);
        for (final id in matched) {
          for (final t in tasks) {
            if (t.taskId == id) {
              t.failed = false;
              t.error = null;
              break;
            }
          }
        }
      }
      if (tasks.isNotEmpty) notifyListeners();
    } catch (e, st) {
      AppLog.instance.error('hls', '启动时恢复 HLS 任务失败', e, st);
    }
  }

  void _onEvent(Map<String, dynamic> e) {
    final id = e['taskId'] as String? ?? '';
    HlsTask? task;
    for (final t in tasks) {
      if (t.taskId == id) {
        task = t;
        break;
      }
    }
    if (task == null) return;
    if (e['progress'] is num) {
      final p = (e['progress'] as num).toDouble();
      task.progress = p;
      // 按进度速率估算剩余时间（AVAssetDownloadTask 不提供字节数）
      final now = DateTime.now();
      final prev = _lastSample[task.taskId];
      if (prev != null) {
        final dtMs = now.difference(prev.t).inMilliseconds;
        if (dtMs >= 800) {
          final rate = (p - prev.p) / (dtMs / 1000.0);
          if (rate > 0 && p < 1) {
            task.eta = Duration(seconds: ((1 - p) / rate).round());
          }
          _lastSample[task.taskId] = (p: p, t: now);
        }
      } else {
        _lastSample[task.taskId] = (p: p, t: now);
      }
      notifyListeners();
    }
    if (e['done'] == true) {
      task.done = true;
      task.failed = false;
      task.error = null;
      task.progress = 1;
      notifyListeners();
      _persist(task);
      _clearPending(task.taskId);
      AppLog.instance.info('hls', 'HLS 离线缓存完成: ${task.title}');
    } else if (e['done'] == false) {
      task.failed = true;
      final err = (e['error'] as String?) ?? '下载中断，可点击继续';
      task.error = err;
      notifyListeners();
      AppLog.instance
          .error('hls', 'HLS 下载失败: ${task.title}（${task.url}）: $err');
    }
  }

  Future<void> start(String url, String title) async {
    if (_started.contains(url)) return;
    // 同 URL 已有任务：失败→继续，进行中→忽略
    for (final t in tasks) {
      if (t.url == url && !t.done) {
        if (t.failed) retry(t.taskId);
        return;
      }
    }
    _started.add(url);
    try {
      final taskId = await HlsDownloader.download(url, title);
      if (taskId.isNotEmpty) {
        final t = HlsTask(taskId: taskId, url: url, title: title);
        tasks.add(t);
        notifyListeners();
        await _persistPending(t);
        AppLog.instance.info('hls', '开始 HLS 离线缓存: $title（$url）');
      }
    } catch (e, st) {
      _started.remove(url);
      AppLog.instance.error('hls', '发起 HLS 下载失败: $title（$url）', e, st);
    }
  }

  /// 继续下载失败/中断的任务（原生重建下载任务，同一 taskId）
  Future<void> retry(String taskId) async {
    HlsTask? task;
    for (final t in tasks) {
      if (t.taskId == taskId) {
        task = t;
        break;
      }
    }
    if (task == null || task.done || !task.failed) return;
    task.failed = false;
    task.error = null;
    task.progress = 0;
    task.eta = null;
    notifyListeners();
    final ok = await HlsDownloader.retry(task.taskId, task.url, task.title);
    if (!ok) {
      task.failed = true;
      task.error = '继续失败，请重试';
      notifyListeners();
      AppLog.instance
          .error('hls', 'HLS 继续下载失败: ${task.title}（${task.url}）');
    }
  }

  Future<void> cancel(String taskId) async {
    await HlsDownloader.cancel(taskId);
  }

  /// 播放：下载完成走离线播放（本地 .movpkg）；
  /// whileDownloading=true 时在下载进行中直接播（复用同一 AVURLAsset，读已缓存分段）
  Future<void> play(String taskId, {bool whileDownloading = false}) =>
      whileDownloading
          ? HlsDownloader.playWhileDownloading(taskId)
          : HlsDownloader.playOffline(taskId);

  Future<void> delete(String taskId) async {
    tasks.removeWhere((t) => t.taskId == taskId);
    await _removePending(taskId);
    notifyListeners();
  }

  /// 完成后写元数据，供本地库展示
  Future<void> _persist(HlsTask t) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'Downloads'));
      await dir.create(recursive: true);
      final meta = {
        'id': t.taskId,
        'url': t.url,
        'title': t.title,
        'kind': 'm3u8',
        'hls': true,
        'folder': '',
        'savedAt': DateTime.now().toIso8601String(),
      };
      await File(p.join(dir.path, '${t.taskId}.json')).writeAsString(jsonEncode(meta));
    } catch (_) {}
  }

  /// 中断/进行中的任务持久化（供重启恢复）
  Future<void> _persistPending(HlsTask t) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'Downloads'));
      await dir.create(recursive: true);
      final j = {
        'taskId': t.taskId,
        'url': t.url,
        'title': t.title,
        'startedAt': t.startedAt.toIso8601String(),
      };
      await File(p.join(dir.path, '${t.taskId}.hls.json'))
          .writeAsString(jsonEncode(j));
    } catch (_) {}
  }

  Future<void> _clearPending(String taskId) => _removePending(taskId);

  Future<void> _removePending(String taskId) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'Downloads'));
      final f = File(p.join(dir.path, '$taskId.hls.json'));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
