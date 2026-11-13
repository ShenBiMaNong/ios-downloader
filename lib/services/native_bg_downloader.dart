import 'package:flutter/services.dart';

/// 原生后台分片下载（iOS background URLSession）Dart 侧通道。
///
/// 设计要点（见 docs/后台分片下载-实施方案.md）：
/// - Dart 只负责「前台解析清单 + 生成待下载清单」，一次性把整个作业交给原生；
/// - 原生用一个 background session 批量提交全部 URLSessionDownloadTask，
///   锁屏 / 切 App / 系统回收后由系统进程继续传输；
/// - 分片齐备后 **不在后台合成 mp4**（系统给的唤醒窗口不够跑 ffmpeg），
///   而是把作业标成 ready；App 回到前台时由 ConvertManager 做 -c copy 转封装；
/// - 作业状态以原生侧磁盘 json 为准，EventChannel 只用于前台实时刷新，
///   后台期间事件丢失不影响正确性（回前台会重新 listJobs 对账）。
class NativeBgDownloader {
  static const _method = MethodChannel('video_downloader/native_seg');
  static const _events = EventChannel('video_downloader/native_seg/events');

  /// 提交作业。原生建完 task 立即返回 true，不代表下载完成。
  /// 非 iOS / 通道未注册时返回 false，调用方据此降级或报错。
  static Future<bool> submit(NativeSegJob job) async {
    try {
      final r = await _method.invokeMethod<bool>('submit', job.toMap());
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 取消作业（取消在途 task + 删除状态记录；分片目录由 ConvertManager 清理）
  static Future<bool> cancel(String jobId) async {
    try {
      final r = await _method.invokeMethod<bool>('cancel', {'jobId': jobId});
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Dart 侧 mp4 合成成功后调用：清掉原生状态记录，避免重启后被当成待合成作业。
  static Future<void> markRemuxed(String jobId) async {
    try {
      await _method.invokeMethod<bool>('markRemuxed', {'jobId': jobId});
    } catch (_) {
      // 通道未就绪：状态记录会在下次回前台对账时被忽略（产物元数据已存在）
    }
  }

  /// 拉取全部作业状态（冷启动 / 回前台对账用）。以磁盘状态为准。
  static Future<List<NativeJobStatus>> listJobs() async {
    try {
      final r = await _method.invokeMethod<List<dynamic>>('listJobs');
      return (r ?? const [])
          .whereType<Map>()
          .map((e) => NativeJobStatus.fromMap(
              Map<String, dynamic>.from(e.cast<String, dynamic>())))
          .toList();
    } catch (_) {
      return const <NativeJobStatus>[];
    }
  }

  /// 前台实时进度事件（后台期间可能收不到，不能作为唯一状态来源）
  static Stream<Map<String, dynamic>> events() => _events
      .receiveBroadcastStream()
      .map((e) => Map<String, dynamic>.from((e as Map).cast<String, dynamic>()));
}

/// 一次提交给原生的完整作业。
///
/// [parts] 里既有分片也有 AES-128 密钥文件；[name] 是相对 [workDir] 的文件名，
/// 必须与 Dart 生成的本地 playlist.m3u8 里引用的名字一致。
class NativeSegJob {
  final String jobId;
  final String workDir;
  final String playlistPath;
  final List<NativeSegPart> parts;
  final Map<String, String> headers;

  const NativeSegJob({
    required this.jobId,
    required this.workDir,
    required this.playlistPath,
    required this.parts,
    required this.headers,
  });

  Map<String, dynamic> toMap() => {
        'jobId': jobId,
        'workDir': workDir,
        'playlistPath': playlistPath,
        'parts': [for (final p in parts) p.toMap()],
        'headers': headers,
      };
}

class NativeSegPart {
  final String url;
  final String name;

  const NativeSegPart({required this.url, required this.name});

  Map<String, String> toMap() => {'url': url, 'name': name};
}

/// 作业状态：downloading / ready / failed / remuxed
class NativeJobStatus {
  final String jobId;
  final String state;
  final String workDir;
  final int done;
  final int total;
  final String? error;

  const NativeJobStatus({
    required this.jobId,
    required this.state,
    required this.workDir,
    required this.done,
    required this.total,
    this.error,
  });

  factory NativeJobStatus.fromMap(Map<String, dynamic> j) => NativeJobStatus(
        jobId: (j['jobId'] as String?) ?? '',
        state: (j['state'] as String?) ?? 'downloading',
        workDir: (j['workDir'] as String?) ?? '',
        done: (j['done'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt() ?? 0,
        error: j['error'] as String?,
      );

  bool get isReady => state == 'ready';
  bool get isFailed => state == 'failed';
  double get progress =>
      total <= 0 ? 0 : (done / total).clamp(0.0, 1.0).toDouble();
}
