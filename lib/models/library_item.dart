/// 内置「分享」文件夹名（分享导入的视频默认归入；用户不可新建同名文件夹）
const String libraryShareFolderName = '分享';

/// 资源库统一条目（合并下载任务与已保存视频，支持多字段排序）
enum SortField { name, size, created }

/// 资源库分组（文件夹视角的排序结果：未分组在前，其余按文件夹创建顺序）
class LibrarySection {
  final String name; // 文件夹名（'' = 未分组）
  final List<LibraryItem> items;

  const LibrarySection(this.name, this.items);
}

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
  final bool resumable; // 失败/中断后是否可续传（断点续传）
  final String folder; // 归属文件夹（'' = 全部 / 未分组）
  /// 原生后台分片下载阶段（仅 mode=='native' 的 convert 任务有值）：
  /// downloading | ready | remuxing | failed
  final String? stage;

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
    this.resumable = false,
    this.folder = '',
    this.stage,
  });

  String get sortName => title.isEmpty ? (url ?? '未命名') : title;

  /// 按文件夹过滤（folder == '' 表示「全部」）
  static List<LibraryItem> filterByFolder(
      List<LibraryItem> items, String folder) {
    if (folder.isEmpty) return items;
    return items.where((i) => i.folder == folder).toList();
  }

  /// 分组排序：未分组在前，其余按 folderNames 顺序；组内按 field/desc 排序。
  /// 空分组不输出。注意这里用严格匹配（未分组 = folder 为空），
  /// 与 filterByFolder('') 的「不过滤」语义不同。
  static List<LibrarySection> groupSections(List<LibraryItem> items,
      List<String> folderNames, SortField field, bool desc) {
    final result = <LibrarySection>[];
    final root = items.where((i) => i.folder.isEmpty).toList();
    if (root.isNotEmpty) {
      result.add(LibrarySection('', sort(root, field, desc)));
    }
    for (final name in folderNames) {
      final list = items.where((i) => i.folder == name).toList();
      if (list.isNotEmpty) {
        result.add(LibrarySection(name, sort(list, field, desc)));
      }
    }
    return result;
  }

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
