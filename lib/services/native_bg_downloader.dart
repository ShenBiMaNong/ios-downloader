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

  /// 取消作业（取消在途 task + 删除状态记录；分片目录由调用方清理）
  static Future<bool> cancel(String jobId) async {
    try {
      final r = await _method.invokeMethod<bool>('cancel', {'jobId': jobId});
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 暂停：原生给在途 task 产生断点续传数据并落进作业状态，之后可 [resume]。
  /// 与 [cancel] 的区别是保留状态记录和已落盘分片。
  static Future<bool> pause(String jobId) async {
    try {
      final r = await _method.invokeMethod<bool>('pause', {'jobId': jobId});
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 继续：重新拉起磁盘上还不存在的分片。
  /// [url] 只用于单文件作业换链接（签名过期后重新嗅探到的新地址）；
  /// 传了它原生会丢掉旧的断点数据从头下——续传凭据绑的是原请求。
  static Future<bool> resume(String jobId, {String? url}) async {
    try {
      final r = await _method.invokeMethod<bool>('resume', {
        'jobId': jobId,
        if (url != null && url.isNotEmpty) 'url': url,
      });
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

  /// 单文件作业（mp4 直链）：parts 只有一项，落盘文件本身就是产物，
  /// 原生不需要清单，也不需要后续合成。
  final bool singleFile;

  const NativeSegJob({
    required this.jobId,
    required this.workDir,
    required this.playlistPath,
    required this.parts,
    required this.headers,
    this.singleFile = false,
  });

  Map<String, dynamic> toMap() => {
        'jobId': jobId,
        'workDir': workDir,
        'playlistPath': playlistPath,
        'parts': [for (final p in parts) p.toMap()],
        'headers': headers,
        'singleFile': singleFile,
      };
}

class NativeSegPart {
  final String url;
  final String name;

  const NativeSegPart({required this.url, required this.name});

  Map<String, String> toMap() => {'url': url, 'name': name};
}

/// 作业状态：downloading / paused / ready / failed / remuxed
class NativeJobStatus {
  final String jobId;
  final String state;
  final String workDir;
  final int done;
  final int total;

  /// 已下字节 = 已落盘分片 + 在途 task 已写字节（原生成交时统计）
  final int bytes;

  /// 总字节。HLS 清单本身不带分片大小，原生按已知分片的 Content-Length
  /// 外推未知分片，因此 [bytesEstimated] 为 true 时这是估算值。
  final int bytesTotal;
  final bool bytesEstimated;

  /// 单文件作业：落盘文件即产物，进度只有 0/1 两态，展示必须按字节口径
  final bool single;
  final String? error;

  const NativeJobStatus({
    required this.jobId,
    required this.state,
    required this.workDir,
    required this.done,
    required this.total,
    this.bytes = 0,
    this.bytesTotal = 0,
    this.bytesEstimated = false,
    this.single = false,
    this.error,
  });

  factory NativeJobStatus.fromMap(Map<String, dynamic> j) => NativeJobStatus(
        jobId: (j['jobId'] as String?) ?? '',
        state: (j['state'] as String?) ?? 'downloading',
        workDir: (j['workDir'] as String?) ?? '',
        done: (j['done'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt() ?? 0,
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        bytesTotal: (j['bytesTotal'] as num?)?.toInt() ?? 0,
        bytesEstimated: (j['bytesEstimated'] as bool?) ?? false,
        single: (j['single'] as bool?) ?? false,
        error: j['error'] as String?,
      );

  bool get isReady => state == 'ready';
  bool get isFailed => state == 'failed';
  bool get isPaused => state == 'paused';
  double get progress =>
      total <= 0 ? 0 : (done / total).clamp(0.0, 1.0).toDouble();

  /// 字节口径进度。单文件作业分片数恒为 1，[progress] 在它下完前一直是 0，
  /// 只有这个值会动；总大小未知（服务器没给 Content-Length）时返回 0，
  /// 调用方按「已下 X B」降级展示。
  double get byteProgress =>
      bytesTotal <= 0 ? 0 : (bytes / bytesTotal).clamp(0.0, 1.0).toDouble();
}
