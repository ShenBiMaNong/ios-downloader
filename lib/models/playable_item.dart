import 'dart:math';

/// 播放列表条目：本地文件或网络源
class PlayableItem {
  final String? path; // 本地文件路径（本地播放时使用）
  final String title;

  /// 原始源 URL；网络源时同时用作「播放进度记忆」的稳定 key
  final String? url;

  /// 实际交给播放器的地址（本地缓存代理 URL；为空则直接用 [url]）
  final String? playUrl;

  /// 主源（如本地缓存代理）起播失败时的兜底地址（直连原始 URL）
  final String? fallbackUrl;

  /// 网络源请求头（Referer/UA 等防盗链）
  final Map<String, String>? httpHeaders;

  const PlayableItem({
    required this.title,
    this.path,
    this.url,
    this.playUrl,
    this.fallbackUrl,
    this.httpHeaders,
  });
}

/// 播放顺序
enum PlaybackOrder { sequential, shuffle }

/// 单个视频播放完成后的行为
enum PlayCompleteAction { replay, next }

/// 计算下一个播放位置：
/// - 顺序模式：向后一位，末尾回到开头（循环播放）
/// - 乱序模式：随机选取且不与当前重复
int nextPlaylistIndex(int current, int length, PlaybackOrder order,
    [Random? random]) {
  if (length <= 1) return 0;
  switch (order) {
    case PlaybackOrder.sequential:
      return (current + 1) % length;
    case PlaybackOrder.shuffle:
      final r = random ?? Random();
      var next = r.nextInt(length);
      while (next == current) {
        next = r.nextInt(length);
      }
      return next;
  }
}

/// 计算上一个播放位置（规则与 [nextPlaylistIndex] 对称）
int previousPlaylistIndex(int current, int length, PlaybackOrder order,
    [Random? random]) {
  if (length <= 1) return 0;
  switch (order) {
    case PlaybackOrder.sequential:
      return (current - 1 + length) % length;
    case PlaybackOrder.shuffle:
      final r = random ?? Random();
      var next = r.nextInt(length);
      while (next == current) {
        next = r.nextInt(length);
      }
      return next;
  }
}
