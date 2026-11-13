import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';

/// 播放进度记忆（跨会话恢复播放位置）
/// key：网络源用原始 URL，本地文件用文件路径（两者都稳定、跨会话有效）。
class PlaybackProgress extends ChangeNotifier {
  static final PlaybackProgress instance = PlaybackProgress._();

  PlaybackProgress._();

  final Map<String, int> _positions = {}; // key → 秒
  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map<String, dynamic>) {
          final m = j['positions'];
          if (m is Map<String, dynamic>) {
            for (final e in m.entries) {
              if (e.value is num) _positions[e.key] = (e.value as num).round();
            }
          }
        }
      }
    } catch (e, st) {
      AppLog.instance.error('player', '加载播放进度失败', e, st);
    }
  }

  /// 上次播放到的秒数；无记录返回 null
  int? positionOf(String key) => _positions[key];

  Future<void> save(String key, int seconds) async {
    if (seconds <= 0) return;
    _positions[key] = seconds;
    await _save();
  }

  /// 播放完成/删除后清除，下次从头播
  Future<void> clear(String key) async {
    if (_positions.remove(key) == null) return;
    await _save();
  }

  Future<File> _file() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'AppData'));
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'playback_progress.json'));
  }

  Future<void> _save() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode({'positions': _positions}));
    } catch (e, st) {
      AppLog.instance.error('player', '保存播放进度失败', e, st);
    }
  }
}
