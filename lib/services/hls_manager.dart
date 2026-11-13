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
  double progress = 0;
  bool done = false;
  bool failed = false;

  HlsTask({
    required this.taskId,
    required this.url,
    required this.title,
  });
}

/// HLS 离线下载管理（MVP-2）
class HlsManager extends ChangeNotifier {
  static final HlsManager instance = HlsManager._();

  HlsManager._() {
    HlsDownloader.events().listen(_onEvent);
  }

  final List<HlsTask> tasks = [];
  final Set<String> _started = {};

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
      task.progress = (e['progress'] as num).toDouble();
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
