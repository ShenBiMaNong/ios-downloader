import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/video_info.dart';

enum DownloadStatus { queued, downloading, done, failed }

class DownloadTask {
  final String id;
  final String url;
  final String title;
  final String kind;
  final DateTime startedAt;
  String? localPath;
  double progress = 0;
  double speed = 0; // 字节/秒（仅 mp4 直链）
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'title': title,
        'kind': kind,
        'localPath': localPath,
        'savedAt': DateTime.now().toIso8601String(),
      };

  factory DownloadTask.fromJson(Map<String, dynamic> j) => DownloadTask(
        id: j['id'] as String,
        url: j['url'] as String,
        title: (j['title'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? 'other',
      );
}

/// 下载管理器：mp4 直链走 Dio；m3u8 后续版本接入原生桥接
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

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  /// 下载目录：Documents/Downloads
  Future<Directory> downloadsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'Downloads'));
    await dir.create(recursive: true);
    return dir;
  }

  /// 扫描已完成的下载（读元数据 json）
  Future<List<Map<String, dynamic>>> scanSaved() async {
    final dir = await downloadsDir();
    final result = <Map<String, dynamic>>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File && p.extension(entity.path) == '.json') {
        try {
          final j = jsonDecode(await entity.readAsString());
          if (j is Map<String, dynamic>) result.add(j);
        } catch (_) {}
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
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final task = DownloadTask(id: id, url: v.url, title: v.pageTitle, kind: v.kind);
    _tasks.insert(0, task);
    notifyListeners();
    await _run(task);
  }

  Future<void> _run(DownloadTask task) async {
    task.status = DownloadStatus.downloading;
    task.progress = 0;
    notifyListeners();

    final cancel = CancelToken();
    _cancels[task.id] = cancel;
    final dir = await downloadsDir();
    var lastBytes = 0;
    var lastTime = DateTime.now();

    var fileName = _safeName(task.title.isNotEmpty ? task.title : task.url);
    if (!fileName.toLowerCase().endsWith('.mp4')) fileName = '$fileName.mp4';
    final target = p.join(dir.path, fileName);

    try {
      await _dio.download(
        task.url,
        target,
        cancelToken: cancel,
        options: Options(
          followRedirects: true,
          receiveTimeout: const Duration(seconds: 120),
        ),
        onReceiveProgress: (received, total) {
          task.progress = total > 0 ? received / total : 0;
          // 网速与预计剩余时间（每 ~1s 采样一次）
          final now = DateTime.now();
          final dtMs = now.difference(lastTime).inMilliseconds;
          if (dtMs >= 800) {
            final dBytes = received - lastBytes;
            if (dBytes > 0 && dtMs > 0) {
              task.speed = dBytes / (dtMs / 1000.0);
              if (total > 0) {
                final rem = total - received;
                task.eta = rem > 0 && task.speed > 0
                    ? Duration(seconds: (rem / task.speed).round())
                    : null;
              }
            }
            lastBytes = received;
            lastTime = now;
          }
          notifyListeners();
        },
      );
      // 校验文件
      final f = File(target);
      if (await f.exists() && await f.length() > 0) {
        task.localPath = target;
        task.status = DownloadStatus.done;
        task.progress = 1;
        final meta = task.toJson();
        await File(p.join(dir.path, '${task.id}.json')).writeAsString(jsonEncode(meta));
      } else {
        throw Exception('文件为空');
      }
    } catch (e) {
      if (cancel.isCancelled) {
        task.status = DownloadStatus.failed;
        task.error = '已取消';
      } else {
        task.status = DownloadStatus.failed;
        task.error = e.toString();
      }
      final f = File(target);
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    } finally {
      _cancels.remove(task.id);
      notifyListeners();
    }
  }

  void cancel(String id) {
    _cancels.remove(id)?.cancel();
  }

  Future<void> delete(String id, String localPath) async {
    _tasks.removeWhere((t) => t.id == id);
    try {
      final dir = await downloadsDir();
      final f = File(localPath);
      if (await f.exists()) await f.delete();
      final meta = File(p.join(dir.path, '$id.json'));
      if (await meta.exists()) await meta.delete();
    } catch (_) {}
    notifyListeners();
  }

  String _safeName(String raw) {
    var s = raw.trim();
    s = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    if (s.length > 80) s = s.substring(0, 80);
    return s.isEmpty ? 'video_${DateTime.now().millisecondsSinceEpoch}' : s;
  }
}
