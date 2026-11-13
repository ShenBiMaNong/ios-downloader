import 'package:flutter/services.dart';

import '../models/video_info.dart';

/// 剪贴板导入（MVP-4 前置）：
/// 分享扩展（待激活）写剪贴板 → 用户打开主 App → 这里读取并分类，给出导入动作
class ShareImport {
  static Future<String?> readClipboardUrl() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      final m = RegExp(r'https?://[^\s\u4e00-\u9fff]+').firstMatch(text);
      return m?.group(0);
    } catch (_) {
      return null;
    }
  }

  static bool isKnownVideoPage(String url) {
    final u = url.toLowerCase();
    return RegExp(
      r'(bilibili|douyin|kuaishou|youtube|b23\.tv|v\.douyin|v\.kuaishou|youtu\.be)',
    ).hasMatch(u);
  }

  static VideoInfo classify(String url) =>
      VideoInfo(url: url, frameUrl: '', pageTitle: '剪贴板导入');
}
