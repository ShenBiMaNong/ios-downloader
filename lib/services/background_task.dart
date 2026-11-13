import 'package:flutter/services.dart';

/// iOS beginBackgroundTask 桥接（尽力而为：系统可能随时结束任务）
/// 仅 iOS 生效；其它平台调用返回 null，静默降级为普通前台运行。
class BackgroundTask {
  static const _ch = MethodChannel('video_downloader/bg');

  /// 开启一个后台任务，返回任务 id；不可用时返回 null
  static Future<int?> begin() async {
    try {
      final r = await _ch.invokeMethod<int>('begin');
      return r;
    } catch (_) {
      return null;
    }
  }

  /// 结束后台任务
  static Future<void> end(int? id) async {
    if (id == null) return;
    try {
      await _ch.invokeMethod('end', {'id': id});
    } catch (_) {}
  }
}
