import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_cache_stream/http_cache_stream.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/playable_item.dart';
import 'app_log.dart';
import 'download_manager.dart';
import 'mp4_probe.dart';

/// 「边播边缓存」管理器（调研路线 A：本地 HTTP 代理）。
///
/// 原理：下载器把源站字节顺序写入缓存文件（暂存于 Documents/.caching），
/// 本地 HTTP 代理按 Range 从缓存文件喂播放器——播放字节 == 落盘字节，零重复下载；
/// 下载完成把缓存文件移动到资源库 Downloads/ 并写元数据 = 最终产物。
///
/// 分流：起播前先做 faststart 探测——
/// - faststart/fMP4 → 缓存代理通道；
/// - 非 faststart / 探测失败 → 降级为原始网络直连播放（同时暂停同名下载任务，保留 .part）。
class PlaybackCacher extends ChangeNotifier {
  static final PlaybackCacher instance = PlaybackCacher._();

  static const idPrefix = 'pc_';
  static const _ua =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 '
      'Safari/604.1';

  PlaybackCacher._();

  final List<CacheTask> tasks = [];

  Future<void>? _initFuture;
  final Map<String, String> _referers = {}; // 源 URL → Referer
  final Set<String> _starting = {}; // 进行中的 start（同 URL 去重）
  Directory? _staging;

  /// 启动时初始化（main 中 await；此后 start 立即可用）
  Future<void> init() async {
    if (_initFuture != null) return;
    _initFuture = _doInit();
    await _initFuture;
  }

  Future<void> _doInit() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final staging = Directory(p.join(docs.path, '.caching'));
      _staging = staging;
      // 启动时清理上次遗留的半成品（此刻无活跃流）
      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
      await staging.create(recursive: true);
      final config = GlobalCacheConfig(
        cacheDirectory: staging,
        // 所有流都显式传 file:（staging 下），此解析器仅兜底
        cacheFileResolver: (dir, uri) =>
            File(p.join(staging.path, '${_safeName(uri.toString())}.mp4')),
        customHttpClient: _RefererClient(_referers),
        requestHeaders: {'User-Agent': _ua},
        savePartialCache: true,
        // seek 到远超当前缓存位置时另开直连回源取回写盘（每字节仍只取一次）
        rangeRequestSplitThreshold: 5 * 1024 * 1024,
      );
      await HttpCacheManager.init(config: config);
      // 缓存完整写盘后：校验 → 移动就位 → 写资源库元数据
      HttpCacheManager.instance.config.onCacheDone = (stream, file) {
        _onCacheDone(stream, file);
      };
      AppLog.instance.info('cacher', '边播边缓存服务已就绪');
    } catch (e, st) {
      AppLog.instance.error('cacher', '初始化边播边缓存服务失败', e, st);
      _initFuture = null; // 允许重试
    }
  }

  /// iOS 后台恢复后确保本地代理 socket 可用
  Future<void> ensureActive() async {
    try {
      if (HttpCacheManager.isInitialized) {
        await HttpCacheManager.instance.ensureActive();
      }
    } catch (e, st) {
      AppLog.instance.warn('cacher', '本地代理恢复失败', e, st);
    }
  }

  /// 开始「边播边缓存」：返回交给 PlayerPage 的条目。
  /// 返回 null 表示完全不可播（探测与建流均失败且无直连兜底可用）。
  Future<PlayableItem?> start({
    required String url,
    required String title,
    String? referer,
  }) async {
    await init();
    if (url.isEmpty) return null;

    // 同 URL 已在处理中 → 稍等重试（防双击双开）
    if (_starting.contains(url)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return start(url: url, title: title, referer: referer);
    }
    _starting.add(url);
    try {
      // 已完成任务同 URL → 直接本地播放
      for (final t in tasks) {
        if (t.url == url && t.done && t.localPath != null) {
          return PlayableItem(path: t.localPath, title: t.title);
        }
      }
      // 进行中任务同 URL → 复用其缓存通道
      for (final t in tasks) {
        if (t.url == url && !t.done && !t.failed) {
          try {
            await _ensureStream(t);
            if (t.cacheUrl != null) return _playableOf(t);
          } catch (_) {
            // 复用失败 → 走下方新建/降级流程
          }
        }
      }
      if (referer != null && referer.isNotEmpty) _referers[url] = referer;
      // 暂停同名 mp4 下载任务（避免播放流 + 下载流双通道重复拉取）
      _pauseDownloader(url);

      // faststart 探测：true → 缓存代理；否则（非 faststart/未知）→ 直连兜底
      final fast = await probeFaststart(url, referer: referer);
      if (fast != true) {
        return PlayableItem(
          url: url,
          title: title,
          playUrl: url,
          httpHeaders: _headers(referer),
        );
      }

      final task = CacheTask(
        id: '$idPrefix${DateTime.now().millisecondsSinceEpoch}',
        url: url,
        title: title,
        referer: referer,
      );
      tasks.insert(0, task);
      notifyListeners();
      try {
        await _ensureStream(task);
      } catch (e, st) {
        // 建流失败 → 降级直连
        task.failed = true;
        task.error = '缓存通道失败';
        AppLog.instance.error('cacher', '建立缓存流失败: $url', e, st);
        notifyListeners();
        return PlayableItem(
          url: url,
          title: title,
          playUrl: url,
          httpHeaders: _headers(referer),
        );
      }
      return _playableOf(task);
    } finally {
      _starting.remove(url);
    }
  }

  /// 取消缓存任务：删除暂存/已就位文件与元数据，任务移出列表
  Future<void> cancel(String id) async {
    final t = tasks.firstWhere((x) => x.id == id,
        orElse: () => CacheTask(id: '', url: '', title: ''));
    if (t.id.isEmpty) return;
    tasks.removeWhere((x) => x.id == id);
    await t.sub?.cancel();
    try {
      await t.stream?.dispose(force: true);
    } catch (_) {}
    if (t.stagingPath != null) {
      final f = File(t.stagingPath!);
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
    if (t.localPath != null) {
      final dl = await DownloadManager.instance.downloadsDir();
      final meta = File(p.join(dl.path, '${t.id}.json'));
      if (await meta.exists()) {
        try {
          await meta.delete();
        } catch (_) {}
      }
      final f = File(t.localPath!);
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
    notifyListeners();
  }

  // ---- 内部 ----

  Future<void> _ensureStream(CacheTask t) async {
    if (t.stream != null && !t.stream!.isDisposed && t.cacheUrl != null) {
      return;
    }
    final file = File(p.join(
        _staging!.path,
        '${_safeName(t.title.isNotEmpty ? t.title : t.url)}.mp4'));
    t.stagingPath = file.path;
    final stream =
        HttpCacheManager.instance.createStream(Uri.parse(t.url), file: file);
    t.stream = stream;
    t.cacheUrl = stream.cacheUrl.toString();
    _subscribe(stream, t);
    // 显式开始下载（也可由播放器首个请求触发）；失败时标记任务
    unawaited(stream.download().catchError((Object e, StackTrace st) {
      if (t.done) return file;
      t.failed = true;
      t.error = e.toString();
      notifyListeners();
      AppLog.instance.error('cacher', '缓存下载失败: ${t.title}（${t.url}）', e, st);
      return file;
    }));
    notifyListeners();
  }

  void _subscribe(HttpCacheStream stream, CacheTask t) {
    t.sub = stream.cacheStateStream.listen(
      (state) {
        if (t.done) return;
        t.progress = state.progress ?? 0;
        _sampleBytes(t);
        notifyListeners();
      },
      onError: (Object e) {
        if (t.done) return;
        t.failed = true;
        t.error = e.toString();
        notifyListeners();
      },
    );
  }

  /// 从暂存文件补出字节口径的进度：http_cache_stream 的 CacheState 只给比例，
  /// 但缓存文件就是最终产物，长度即真实已下字节 —— 采样差值就是真实下载速度。
  void _sampleBytes(CacheTask t) {
    final path = t.stagingPath;
    if (path == null || path.isEmpty) return;
    int len;
    try {
      len = File(path).lengthSync();
    } catch (_) {
      return;
    }
    if (len <= 0) return;
    final now = DateTime.now();
    final prevAt = t.bytesSampledAt;
    if (prevAt != null && len > t.bytesDone) {
      final dt = now.difference(prevAt).inMilliseconds / 1000.0;
      // 采样间隔太短除出尖峰，太长（后台回来）不是当前速度
      if (dt >= 0.4 && dt <= 5.0) {
        final inst = (len - t.bytesDone) / dt;
        t.speed = t.speed <= 0 ? inst : t.speed * 0.55 + inst * 0.45;
      }
    }
    t.bytesDone = len;
    t.bytesSampledAt = now;
    final ratio = t.progress;
    if (ratio >= 0.999) {
      t.bytesTotal = len;
    } else if (ratio > 0.02) {
      t.bytesTotal = (len / ratio).round();
    }
    if (t.speed > 0 && t.bytesTotal > len) {
      t.eta = Duration(seconds: ((t.bytesTotal - len) / t.speed).ceil());
    }
  }

  void _onCacheDone(HttpCacheStream stream, File completedFile) {
    final t = tasks.firstWhere((x) => x.url == stream.sourceUrl.toString(),
        orElse: () => CacheTask(id: '', url: '', title: ''));
    if (t.id.isEmpty || t.done) return;
    unawaited(_finalize(t, stream, completedFile));
  }

  Future<void> _finalize(
      CacheTask t, HttpCacheStream stream, File completedFile) async {
    try {
      // 底线校验：缓存字节必须完整（包尚年轻，防部分缓存损坏）
      final ok = await stream.validateCache();
      if (ok == false) {
        t.failed = true;
        t.error = '校验失败';
        AppLog.instance.error('cacher', '缓存校验失败: ${t.title}');
        notifyListeners();
        return;
      }
      final dl = await DownloadManager.instance.downloadsDir();
      final finalPath = p.join(
          dl.path,
          '${_safeName(t.title.isNotEmpty ? t.title : t.url)}.mp4');
      if (await File(finalPath).exists()) await File(finalPath).delete();
      await completedFile.rename(finalPath);
      t.localPath = finalPath;
      t.done = true;
      t.progress = 1;
      // 写资源库元数据（与 DownloadManager 完成态 JSON 同构，scanSaved 可读）
      final meta = {
        'id': t.id,
        'url': t.url,
        'title': t.title,
        'kind': 'mp4',
        'localPath': finalPath,
        'folder': '',
        'savedAt': DateTime.now().toIso8601String(),
      };
      await File(p.join(dl.path, '${t.id}.json'))
          .writeAsString(jsonEncode(meta));
      AppLog.instance.info('cacher', '边播边缓存完成: ${t.title}（$finalPath）');
    } catch (e, st) {
      t.failed = true;
      t.error = '入库失败';
      AppLog.instance.error('cacher', '缓存就位失败: ${t.title}', e, st);
    }
    notifyListeners();
  }

  PlayableItem _playableOf(CacheTask t) => PlayableItem(
        url: t.url,
        title: t.title,
        playUrl: t.cacheUrl!,
        fallbackUrl: t.url,
        httpHeaders: _headers(t.referer),
      );

  Map<String, String>? _headers(String? referer) {
    final h = <String, String>{'User-Agent': _ua};
    if (referer != null && referer.isNotEmpty) h['Referer'] = referer;
    return h;
  }

  /// 暂停同 URL 的进行中下载任务（保留 .part，可继续下载）
  void _pauseDownloader(String url) {
    for (final t in DownloadManager.instance.tasks) {
      if (t.url == url &&
          (t.status == DownloadStatus.queued ||
              t.status == DownloadStatus.downloading)) {
        DownloadManager.instance.cancel(t.id);
        return;
      }
    }
  }

  String _safeName(String raw) {
    var s = raw.trim();
    s = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    if (s.length > 80) s = s.substring(0, 80);
    return s.isEmpty ? 'video_${DateTime.now().millisecondsSinceEpoch}' : s;
  }
}

/// 「边播边缓存」任务（内存态；完成时通过 `<id>.json` 持久化入库）
class CacheTask {
  final String id;
  final String url;
  final String title;
  final String? referer;
  final DateTime startedAt;
  HttpCacheStream? stream;
  StreamSubscription<CacheState>? sub;
  String? cacheUrl;
  String? stagingPath;
  String? localPath; // 最终资源库路径（完成时设置）
  double progress = 0;
  /// 已缓存字节（直接 stat 暂存文件：缓存文件就是最终产物，长度即已下量）
  int bytesDone = 0;
  /// 总字节。http_cache_stream 只给比例，这里按 bytesDone/progress 反推，
  /// 因此是估算值（UI 会带 ≈）。
  int bytesTotal = 0;
  double speed = 0; // 字节/秒，按暂存文件长度增量采样
  Duration? eta;
  DateTime? bytesSampledAt;
  bool done = false;
  bool failed = false;
  String? error;

  CacheTask({
    required this.id,
    required this.url,
    required this.title,
    this.referer,
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now();
}

/// 给 http_cache_stream 的回源请求注入 Referer（按源 URL 匹配）/ UA 兜底
class _RefererClient extends http.BaseClient {
  final Map<String, String> referers;
  final http.Client _inner = http.Client();

  _RefererClient(this.referers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final ref = referers[request.url.toString()];
    if (ref != null && ref.isNotEmpty) {
      request.headers['Referer'] = ref;
    }
    request.headers['User-Agent'] ??= PlaybackCacher._ua;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
