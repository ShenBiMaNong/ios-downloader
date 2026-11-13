import 'package:flutter/services.dart';

/// iOS 本地文件夹选择桥接（UIDocumentPickerViewController）
/// 返回被复制到沙盒 tmp 的文件夹路径；取消或不可用时返回 null。
class FilesBridge {
  static const _ch = MethodChannel('video_downloader/files');

  static Future<String?> pickFolder() async {
    try {
      final r = await _ch.invokeMethod<String>('pickFolder');
      return r;
    } catch (_) {
      return null;
    }
  }
}
