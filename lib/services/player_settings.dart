import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/playable_item.dart';
import 'app_log.dart';

/// 播放器设置（JSON 持久化，跟随项目现有 AppData 目录）
class PlayerSettings extends ChangeNotifier {
  static final PlayerSettings instance = PlayerSettings._();

  PlayerSettings._();

  /// 双击快进/快退的秒数
  int seekSeconds = 10;

  /// 按住视频右半边加速播放的倍速
  double holdSpeed = 2.0;

  /// 播放顺序（顺序 / 乱序）
  PlaybackOrder order = PlaybackOrder.sequential;

  /// 单个视频播放完成后的行为（重播 / 下一个）
  PlayCompleteAction onComplete = PlayCompleteAction.next;

  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map<String, dynamic>) {
          seekSeconds = (j['seekSeconds'] as num?)?.toInt() ?? seekSeconds;
          holdSpeed = (j['holdSpeed'] as num?)?.toDouble() ?? holdSpeed;
          order = _orderFrom((j['order'] as String?) ?? '') ?? order;
          onComplete =
              _completeFrom((j['onComplete'] as String?) ?? '') ?? onComplete;
          notifyListeners();
        }
      }
    } catch (e, st) {
      AppLog.instance.error('player', '加载播放设置失败', e, st);
    }
  }

  static PlaybackOrder? _orderFrom(String s) =>
      PlaybackOrder.values.asNameMap()[s];

  static PlayCompleteAction? _completeFrom(String s) =>
      PlayCompleteAction.values.asNameMap()[s];

  Future<File> _file() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'AppData'));
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'player_settings.json'));
  }

  Future<void> _save() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode({
        'seekSeconds': seekSeconds,
        'holdSpeed': holdSpeed,
        'order': order.name,
        'onComplete': onComplete.name,
      }));
    } catch (e, st) {
      AppLog.instance.error('player', '保存播放设置失败', e, st);
    }
  }

  Future<void> setSeekSeconds(int v) async {
    if (v == seekSeconds) return;
    seekSeconds = v;
    notifyListeners();
    await _save();
  }

  Future<void> setHoldSpeed(double v) async {
    if (v == holdSpeed) return;
    holdSpeed = v;
    notifyListeners();
    await _save();
  }

  Future<void> setOrder(PlaybackOrder v) async {
    if (v == order) return;
    order = v;
    notifyListeners();
    await _save();
  }

  Future<void> setOnComplete(PlayCompleteAction v) async {
    if (v == onComplete) return;
    onComplete = v;
    notifyListeners();
    await _save();
  }
}
