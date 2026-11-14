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
  /// 瞬时速度（字节/秒）。0 = 该链路拿不到速度（系统 HLS 缓存）
  final double speed;
  /// 预计剩余时长。null = 总量未知或还没采样到速度
  final Duration? eta;
  final String? localPath;
  final String? hlsTaskId;
  final String? url;
  final String? error;
  /// 已下分片 / 总分片。只有分片链路（m3u8 转 MP4）才有，0 表示不显示
  final int doneSegments;
  final int totalSegments;
  /// 进行中条目的字节进度（0 表示该链路还没拿到字节数）
  final int bytesDone;
  /// 总字节；[bytesEstimated] 为 true 时是外推估算值（HLS 清单不带分片大小）
  final int bytesTotal;
  final bool bytesEstimated;
  final bool resumable; // 失败/中断后是否可续传（断点续传）
  /// 分片下载失败数（仅 convert 链路有值）。>0 且 [canForceMerge] 时
  /// 失败条目出现「仍要合成」入口
  final int failedSegments;
  /// 是否允许「仍要合成」（用已下分片强制出片，放弃缺失片段）
  final bool canForceMerge;
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
    this.speed = 0,
    this.eta,
    this.localPath,
    this.hlsTaskId,
    this.url,
    this.error,
    this.doneSegments = 0,
    this.totalSegments = 0,
    this.bytesDone = 0,
    this.bytesTotal = 0,
    this.bytesEstimated = false,
    this.resumable = false,
    this.failedSegments = 0,
    this.canForceMerge = false,
    this.folder = '',
    this.stage,
  });

  String get sortName => title.isEmpty ? (url ?? '未命名') : title;

  /// 下载中条目的统一进度行（所有链路同一字段、同一顺序）：
  /// `速度 → 已下/总量 → 剩余时长 → 已下分片/总分片`
  String get progressLine => formatProgressLine(
        speed: speed,
        bytesDone: bytesDone,
        bytesTotal: bytesTotal,
        bytesEstimated: bytesEstimated,
        eta: eta,
        doneSegments: doneSegments,
        totalSegments: totalSegments,
        progress: progress,
      );

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
  if (s < 60) return '剩余 $s 秒';
  if (s < 3600) {
    final m = s ~/ 60;
    final sec = s % 60;
    return sec > 0 ? '剩余 $m 分 $sec 秒' : '剩余 $m 分';
  }
  final h = (s / 3600).floor();
  final m = (s % 3600) ~/ 60;
  return m > 0 ? '剩余 $h 小时 $m 分' : '剩余 $h 小时';
}

/// 进度行专用的紧凑大小：`100MB` / `1.2GB` / `512KB`
/// （整数值不带 `.0`，数字与单位之间不留空格，方便一行塞下四段）
String formatBytesTight(int bytes) {
  if (bytes <= 0) return '';
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()}KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${_tight(bytes / (1024 * 1024), 1)}MB';
  }
  return '${_tight(bytes / (1024 * 1024 * 1024), 2)}GB';
}

/// 进度行专用的紧凑速度：`1MB/s` / `3.2MB/s` / `800KB/s`
String formatSpeedTight(double bytesPerSec) {
  if (bytesPerSec <= 0) return '';
  if (bytesPerSec < 1024 * 1024) {
    return '${(bytesPerSec / 1024).round()}KB/s';
  }
  return '${_tight(bytesPerSec / (1024 * 1024), 1)}MB/s';
}

/// 去掉小数末尾的 0（`100.0` → `100`，`1.20` → `1.2`）
String _tight(double v, int decimals) {
  var s = v.toStringAsFixed(decimals);
  if (s.contains('.')) s = s.replaceFirst(RegExp(r'\.?0+$'), '');
  return s;
}

/// 全链路统一的下载进度行，字段顺序固定：
/// **速度 → 已下载/总大小 → 预估剩余时长 → 已下载分片/总分片**
///
/// 例：`3.2MB/s · 12.4MB/≈86MB · 剩余 2 分 10 秒 · 120/300`
///
/// - 缺什么就跳过什么：mp4 直链没有分片概念，第四段自然不出现；
///   系统 HLS 缓存不给字节，只出「剩余时长」和百分比。
/// - 一个量化字段都拿不到时返回空串，调用方回落「准备中…」。
String formatProgressLine({
  double speed = 0,
  int bytesDone = 0,
  int bytesTotal = 0,
  bool bytesEstimated = false,
  Duration? eta,
  int doneSegments = 0,
  int totalSegments = 0,
  double progress = 0,
}) {
  final parts = <String>[];

  final sp = formatSpeedTight(speed);
  if (sp.isNotEmpty) parts.add(sp);

  final done = formatBytesTight(bytesDone);
  if (done.isNotEmpty) {
    // 总量还没拿到（或只拿到等于已下的值）时只出「已下」，不假造 x/y
    parts.add(bytesTotal > bytesDone
        ? '$done/${bytesEstimated ? '≈' : ''}${formatBytesTight(bytesTotal)}'
        : done);
  }

  final remain = formatEta(eta);
  if (remain.isNotEmpty) parts.add(remain);

  if (totalSegments > 0) {
    final d = doneSegments.clamp(0, totalSegments).toInt();
    parts.add('$d/$totalSegments');
  }

  // 既没有字节也没有分片的链路（系统 HLS 离线缓存只按媒体时长报进度）：
  // 百分比是唯一的量化信息，跟在最后补上。
  if (bytesDone <= 0 && totalSegments <= 0 && progress > 0) {
    parts.add('${(progress * 100).toStringAsFixed(0)}%');
  }
  return parts.join(' · ');
}
