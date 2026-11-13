import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

  static Stream<Map<String, dynamic>> events() => _events
      .receiveBroadcastStream()
      .map((e) => Map<String, dynamic>.from((e as Map).cast<String, dynamic>()));
}

class HlsTask {
  final String taskId;
  final String url;
  final String title;
  final DateTime startedAt;
  double progress = 0;
  Duration? eta; // 按进度速率估算
  bool done = false;
  bool failed = false;

  HlsTask({
    required this.taskId,
    required this.url,
    required this.title,
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now();
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
      task.progress = 1;
      notifyListeners();
      _persist(task);
    } else if (e['done'] == false) {
      task.failed = true;
      notifyListeners();
    }
  }

  Future<void> start(String url, String title) async {
    if (_started.contains(url)) return;
    _started.add(url);
    try {
      final taskId = await HlsDownloader.download(url, title);
      if (taskId.isNotEmpty) {
        tasks.add(HlsTask(taskId: taskId, url: url, title: title));
        notifyListeners();
      }
    } catch (_) {
      _started.remove(url);
    }
  }

  Future<void> cancel(String taskId) async {
    await HlsDownloader.cancel(taskId);
  }

  Future<void> play(String taskId) => HlsDownloader.playOffline(taskId);

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
        'savedAt': DateTime.now().toIso8601String(),
      };
      await File(p.join(dir.path, '${t.taskId}.json')).writeAsString(jsonEncode(meta));
    } catch (_) {}
  }
}
