/// 资源库统一条目（合并下载任务与已保存视频，支持多字段排序）
enum SortField { name, size, created }

class LibraryItem {
  final String id;
  final String title;
  final int size; // 字节（完成任务取文件大小；进行中为 0）
  final DateTime created;
  final String kind; // mp4 | m3u8 | convert
  final bool active;
  final bool failed;
  final double progress; // 0~1（进行中）
  final String? speedText; // 如 "3.2 MB/s"（HLS 无网速，显示 null）
  final String? etaText; // 如 "剩余约 40 秒"
  final String? localPath;
  final String? hlsTaskId;
  final String? url;
  final String? error;
  final int? doneSegments;
  final int? totalSegments;

  const LibraryItem({
    required this.id,
    required this.title,
    required this.size,
    required this.created,
    required this.kind,
    required this.active,
    required this.failed,
    required this.progress,
    this.speedText,
    this.etaText,
    this.localPath,
    this.hlsTaskId,
    this.url,
    this.error,
    this.doneSegments,
    this.totalSegments,
  });

  String get sortName => title.isEmpty ? (url ?? '未命名') : title;

  /// 排序（字段 + 方向），默认创建时间倒序由调用方传入
  static List<LibraryItem> sort(List<LibraryItem> items, SortField field, bool desc) {
    int cmp(LibraryItem a, LibraryItem b) {
      switch (field) {
        case SortField.name:
          return a.sortName.toLowerCase().compareTo(b.sortName.toLowerCase());
        case SortField.size:
          return a.size.compareTo(b.size);
        case SortField.created:
          return a.created.compareTo(b.created);
      }
    }

    final list = List<LibraryItem>.of(items)..sort(cmp);
    if (desc) return list.reversed.toList();
    return list;
  }
}

/// 格式化文件大小
String formatBytes(int bytes) {
  if (bytes <= 0) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// 格式化网速
String formatSpeed(double bytesPerSec) {
  if (bytesPerSec <= 0) return '';
  if (bytesPerSec < 1024 * 1024) {
    return '${(bytesPerSec / 1024).toStringAsFixed(0)} KB/s';
  }
  return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
}

/// 格式化预计剩余时间
String formatEta(Duration? eta) {
  if (eta == null) return '';
  final s = eta.inSeconds;
  if (s <= 0) return '';
  if (s < 60) return '剩余约 $s 秒';
  if (s < 3600) return '剩余约 ${(s / 60).floor()} 分 ${s % 60} 秒';
  return '剩余约 ${(s / 3600).floor()} 小时';
}
