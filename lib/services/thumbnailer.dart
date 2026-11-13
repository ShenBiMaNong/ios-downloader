import 'dart:io';

import 'package:flutter/services.dart';

import 'app_log.dart';

/// 视频缩略图（原生 AVAssetImageGenerator 抽帧）
///
/// 为什么不用纯 Dart 方案：本工程的视频有三类来源 ——
///  - 直链下载的 mp4（有本地文件路径）
///  - m3u8 转码产物（mp4 路径）
///  - HLS 离线缓存（AVAssetDownloadTask 生成的 .movpkg 目录）
/// .movpkg 是 AVFoundation 私有封装的目录，ffmpeg/纯 Dart 解不开，
/// 只有 AVAssetImageGenerator 能直接读，所以缩略图统一走原生。
///
/// 缓存：原生把 jpg 落在 Caches/video_thumbnails/<条目id>.jpg，
/// Dart 侧再挂一层内存 memo —— 列表滚动时同一 id 只发起一次异步请求。
class Thumbnailer {
  static const MethodChannel _channel = MethodChannel('video_downloader/thumb');

  /// 条目 id → 生成结果（null 表示无法出图，回退图标；也缓存，避免反复重试）
  static final Map<String, Future<String?>> _memo = {};

  /// 取缩略图本地路径；无法生成时返回 null
  ///
  /// [key] 缓存键（用条目 id），[path] 本地视频文件，[taskId] HLS 离线任务 id
  static Future<String?> get({
    required String key,
    String? path,
    String? taskId,
    String? url,
  }) {
    final p = (path ?? '').isNotEmpty ? path : null;
    final t = (taskId ?? '').isNotEmpty ? taskId : null;
    final u = (url ?? '');
    if (p == null && t == null && !u.startsWith('http')) {
      return Future.value(null);
    }
    return _memo.putIfAbsent(key, () async {
      try {
        final r = await _channel.invokeMethod<String>('get', {
          'key': key,
          'path': p ?? '',
          'taskId': t ?? '',
          'url': u.startsWith('http') ? u : '',
        });
        if (r == null || r.isEmpty) return null;
        // 原生可能返回已被系统清理的缓存路径，落地校验一次
        if (!File(r).existsSync()) return null;
        return r;
      } on MissingPluginException {
        // 非 iOS 平台（或插件未注册）：静默回退图标
        return null;
      } catch (e) {
        AppLog.instance.warn('thumb', '生成缩略图失败: $key', e);
        return null;
      }
    });
  }

  /// 条目被删除/覆盖后清掉缓存，下次重新抽帧
  static void evict(String key) => _memo.remove(key);

  static void clear() => _memo.clear();
}
