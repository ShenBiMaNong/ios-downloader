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

  /// 返回 taskId（原生建任务成功即返回，不等下载完成）
  static Future<String> download(String url, String title,
      {String taskId = ''}) async {
    final r = await _method.invokeMethod<String>('download', {
      'url': url,
      'title': title,
      // 由 Dart 侧预生成，保证进度事件到达时能对上资源库条目
      if (taskId.isNotEmpty) 'taskId': taskId,
    });
    return r ?? '';
  }

  static Future<void> cancel(String taskId) =>
      _method.invokeMethod('cancel', {'taskId': taskId});

  /// 系统「正在下载」实时活动（锁屏 / 灵动岛）开关。
  ///
  /// silent=true：改用酌情下载 —— 系统不会挂那条「正在下载 + 转圈」通知，
  /// 但会把任务择机（网络/电量合适时）启动；silent=false：立即开始，但系统会
  /// 自动显示实时活动。这是 Apple 给的唯一开关（见 AVAssetDownloadTask 文档）。
  static Future<void> setSilent(bool silent) async {
    try {
      await _method.invokeMethod('setSilent', {'silent': silent});
      AppLog.instance.info(
        'hls',
        silent
            ? '锁屏下载进度：已隐藏（改用酌情下载，系统可能择机启动）'
            : '锁屏下载进度：已显示（立即下载，系统会挂实时活动）',
      );
    } catch (_) {
      // 非 iOS / 通道未就绪：静默降级
    }
  }

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
  String taskId;
  final String url;
  String title; // 重命名后同步更新（完成项仍驻留内存列表）
  final DateTime startedAt;
  double progress = 0;
  Duration? eta; // 按进度速率估算
  bool done = false;
  bool failed = false;
  String? error;

  /// 原生下载任务是否已创建成功（建任务失败时条目仍在列表里，
  /// 但没有可续传的原生任务）
  bool startedOk = false;

  HlsTask({
    required this.taskId,
    required this.url,
    required this.title,
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now();

  /// 失败/中断后可点击「继续下载」（未建过原生任务的失败条目由 retry 重新发起）
  bool get resumable => failed;
}

/// HLS 离线下载管理（MVP-2）
class HlsManager extends ChangeNotifier {
  static final HlsManager instance = HlsManager._();

  HlsManager._() {
    HlsDownloader.events().listen(_onEvent);
  }

  final List<HlsTask> tasks = [];
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
            // 历史脏数据：旧桥接把「本地文件路径」当成 taskId 回传
            // （pendingResults 里 result(localUrls[taskId]?.path)），这种 id 在原生侧
            // 查不到任务 → 列表里永久 0% 转圈，边下边看/取消全都没反应。直接清掉。
            if (_isZombieTaskId(taskId)) {
              try {
                if (await entity.exists()) await entity.delete();
              } catch (_) {}
              AppLog.instance.warn(
                'hls',
                '清理无效 HLS 断点记录（taskId 不是原生任务 id）: $taskId',
              );
              continue;
            }
            if (tasks.any((t) => t.taskId == taskId)) continue;
            final t = HlsTask(
              taskId: taskId,
              url: url,
              title: (j['title'] as String?) ?? '',
              startedAt: DateTime.tryParse((j['startedAt'] as String?) ?? ''),
            )
              ..failed = true
              ..startedOk = true
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

  /// 是否旧的「路径型 taskId」僵尸记录：原生侧永远查不到这个 id，
  /// 表现为条目永久 0% 转圈、操作按钮全部无响应
  static bool _isZombieTaskId(String id) {
    if (id.isEmpty) return true;
    return id.contains('/') ||
        id.contains('\\') ||
        id.toLowerCase().endsWith('.movpkg');
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
    // 同 URL 已有未完成任务：失败→继续，进行中→忽略（避免重复建条目）；
    // 已完成→允许重新下载（旧实现用 _started 永久去重，第二次点下载毫无反应）
    for (final t in tasks) {
      if (t.url == url && !t.done) {
        if (t.failed) await retry(t.taskId);
        return;
      }
    }
    // 先入列表再发起原生任务：用户点下载后立刻能在资源库看到条目（0% 进度），
    // 原生建任务失败时也留下带原因的失败条目，而不是「什么都没有」
    final task = HlsTask(
      taskId: DateTime.now().millisecondsSinceEpoch.toString(),
      url: url,
      title: title,
    );
    tasks.add(task);
    notifyListeners();
    try {
      // 超时兜底：原生若迟迟不回（通道未注册/引擎异常），不能让它一直 0% 转圈
      final taskId = await HlsDownloader.download(url, title, taskId: task.taskId)
          .timeout(const Duration(seconds: 10));
      if (taskId.isEmpty) throw Exception('原生下载任务未创建');
      if (taskId != task.taskId) task.taskId = taskId;
      task.startedOk = true;
      task.error = null;
      notifyListeners();
      await _persistPending(task);
      AppLog.instance.info('hls', '开始 HLS 离线缓存: $title（$url）');
    } catch (e, st) {
      task.failed = true;
      task.error = e is MissingPluginException
          ? '当前平台不支持 HLS 离线缓存'
          : '无法创建 HLS 下载任务：$e';
      task.startedOk = false;
      notifyListeners();
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
    // 从未成功创建过原生任务（建任务即失败）：没有可续传的任务，直接重发
    if (!task.startedOk) {
      tasks.remove(task);
      notifyListeners();
      await start(task.url, task.title);
      return;
    }
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
    HlsTask? task;
    for (final t in tasks) {
      if (t.taskId == taskId) {
        task = t;
        break;
      }
    }
    if (task == null) return;
    // 没有真正在跑的原生任务（未建成功 / 已是失败态的历史记录）：
    // 取消 = 把条目连同断点记录一起清掉，否则点「取消」毫无反应
    if (!task.startedOk || task.failed) {
      tasks.remove(task);
      await _removePending(task.taskId);
      notifyListeners();
      return;
    }
    await HlsDownloader.cancel(taskId);
  }

  /// 播放：下载完成走离线播放（本地 .movpkg）；
  /// whileDownloading=true 时在下载进行中直接播（复用同一 AVURLAsset，读已缓存分段）
  /// 返回是否成功（原生找不到对应任务/离线包时为 false），
  /// 调用方据此给用户明确提示，而不是「点了没反应」
  Future<bool> play(String taskId, {bool whileDownloading = false}) =>
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
