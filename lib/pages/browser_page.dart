import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, rootBundle;
import 'package:webview_flutter/webview_flutter.dart';

import '../models/video_info.dart';
import '../services/ad_detect.dart';
import '../services/app_data.dart';
import '../services/app_log.dart';
import '../services/app_settings.dart';
import '../services/download_manager.dart';
import '../services/hls_manager.dart';
import '../services/m3u8_convert.dart';
import '../services/playback_cacher.dart';
import 'player_page.dart';

/// 跳转弹窗的三种结果
enum _RedirectChoice { allow, block, blockEnableAd }

/// 内置浏览器 + 视频嗅探 + 书签/历史/广告过滤 + 跳转拦截
class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key});

  @override
  State<BrowserPage> createState() => BrowserPageState();
}

class BrowserPageState extends State<BrowserPage> {
  /// 没有历史记录可恢复时的默认首页（仅「上次打开页」且从未访问过时使用）
  static const _defaultUrl = 'https://www.bilibili.com';

  final _urlController = TextEditingController();
  late final WebViewController _controller;
  final List<VideoInfo> _found = [];
  String? _sniffer;
  String? _adblock;
  String? _marker;
  String? _redirectGuard;
  String _currentUrl = '';
  String _pageTitle = '';

  /// 跳转拦截：本页已处理过的跳转目标（去重，页面切换时清空）
  final Set<String> _handledRedirects = {};
  bool _redirectDialogOpen = false;

  /// 上次注入的跳转拦截开关状态（供 AppData 变更监听去重）
  bool? _lastGuardApplied;

  /// 上次注入的页面视频标记开关状态（供 AppData 变更监听去重）
  bool? _lastMarkerApplied;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (url) {
          _currentUrl = url;
          _handledRedirects.clear();
          AppData.instance.setLastUrl(url);
          _injectSniffer();
          _injectMarker();
          _injectRedirectGuard();
          if (AppData.instance.adBlockEnabled) _injectAdBlock();
        },
        onPageFinished: (url) async {
          await _injectSniffer();
          await _injectMarker();
          await _injectRedirectGuard();
          if (AppData.instance.adBlockEnabled) await _injectAdBlock();
          final t = await _controller.getTitle();
          if (mounted) setState(() => _pageTitle = t ?? '');
          AppData.instance.recordHistory(t ?? '', url);
        },
        onWebResourceError: (err) {
          // 主框架加载失败→警告；子资源（广告/图标等）失败→调试级，避免刷屏
          AppLog.instance.log(
            err.isForMainFrame == true ? LogLevel.warn : LogLevel.debug,
            'browser',
            '页面资源加载失败 ${err.url ?? ''}: ${err.errorType?.name ?? err.errorCode} ${err.description}',
          );
        },
      ))
      ..addJavaScriptChannel('videoFound', onMessageReceived: (msg) {
        _handleFound(msg.message);
      })
      ..addJavaScriptChannel('videoAction', onMessageReceived: (msg) {
        _handleVideoAction(msg.message);
      })
      ..addJavaScriptChannel('redirectAttempt', onMessageReceived: (msg) {
        _handleRedirectAttempt(msg.message);
      });
    AppData.instance.addListener(_onAppDataChanged);
    _initStartPage();
  }

  /// 按设置决定启动页：空白页 / 上次打开页（无记录时用默认首页兜底）
  Future<void> _initStartPage() async {
    await AppData.instance.ensureLoaded();
    if (!mounted) return;
    switch (AppSettings.instance.browserStartPage) {
      case BrowserStartPage.blank:
        _urlController.clear();
        _controller.loadRequest(Uri.parse('about:blank'));
      case BrowserStartPage.lastPage:
        final last = AppData.instance.lastUrl;
        if (last.isNotEmpty) {
          _load(last);
        } else {
          _load(_defaultUrl);
        }
    }
  }

  @override
  void dispose() {
    AppData.instance.removeListener(_onAppDataChanged);
    _urlController.dispose();
    super.dispose();
  }

  Future<String> _snifferJs() async =>
      _sniffer ??= await rootBundle.loadString('assets/sniffer.js');

  Future<String> _adblockJs() async =>
      _adblock ??= await rootBundle.loadString('assets/adblock.js');

  Future<String> _markerJs() async =>
      _marker ??= await rootBundle.loadString('assets/video_marker.js');

  Future<String> _redirectGuardJs() async =>
      _redirectGuard ??= await rootBundle.loadString('assets/redirect_guard.js');

  Future<void> _injectSniffer() async {
    try {
      final js = await _snifferJs();
      await _controller.runJavaScript(js);
    } catch (e, st) {
      AppLog.instance.warn('browser', '注入嗅探脚本失败', e, st);
    }
  }

  /// 页面视频标记（方案A）：开关打开才注入；关闭时清理已注入的标记
  Future<void> _injectMarker() async {
    try {
      if (AppData.instance.videoMarkEnabled) {
        final js = await _markerJs();
        await _controller.runJavaScript(js);
      } else {
        await _controller
            .runJavaScript('if (window.__vdlCleanup) window.__vdlCleanup();');
      }
      _lastMarkerApplied = AppData.instance.videoMarkEnabled;
    } catch (e, st) {
      AppLog.instance.warn('browser', '注入视频标记脚本失败', e, st);
    }
  }

  Future<void> _injectAdBlock() async {
    try {
      final js = await _adblockJs();
      await _controller.runJavaScript(js);
    } catch (e, st) {
      AppLog.instance.warn('browser', '注入广告过滤脚本失败', e, st);
    }
  }

  /// 按当前开关状态注入跳转拦截脚本；关闭时仅把运行标志置 false（已注入的钩子放行）
  Future<void> _injectRedirectGuard() async {
    try {
      if (AppData.instance.redirectGuardEnabled) {
        final js = await _redirectGuardJs();
        await _controller.runJavaScript(js);
      } else {
        await _controller.runJavaScript('window.__vdRedirectGuardEnabled = false;');
      }
      _lastGuardApplied = AppData.instance.redirectGuardEnabled;
    } catch (e, st) {
      AppLog.instance.warn('browser', '注入跳转拦截脚本失败', e, st);
    }
  }

  /// AppData 变更（如设置页改开关）时保持注入状态同步
  void _onAppDataChanged() {
    if (!mounted) return;
    if (AppData.instance.redirectGuardEnabled != _lastGuardApplied) {
      _injectRedirectGuard();
    }
    if (AppData.instance.videoMarkEnabled != _lastMarkerApplied) {
      _injectMarker();
    }
  }

  /// 供外部（剪贴板导入等）加载 URL
  void loadUrl(String raw) {
    _load(raw);
  }

  void _load(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    _urlController.text = url;
    _controller.loadRequest(Uri.parse(url));
  }

  void _handleFound(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final v = VideoInfo(
        url: j['url'] as String,
        frameUrl: (j['frame'] as String?) ?? '',
        pageTitle: (j['page'] as String?) ?? '',
      );
      if (_found.any((e) => e.url == v.url)) return;
      setState(() => _found.insert(0, v));
    } catch (e) {
      AppLog.instance
          .warn('browser', '解析 videoFound 消息失败: ${_truncate(raw)}', e);
    }
  }

  /// 页面视频标记（方案A）：页内操作卡回传的动作
  Future<void> _handleVideoAction(String raw) async {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final action = (j['action'] as String?) ?? '';
      final url = (j['url'] as String?) ?? '';
      final title = (j['title'] as String?) ?? '';
      if (url.isEmpty) return;
      final v = VideoInfo(url: url, frameUrl: _currentUrl, pageTitle: title);
      switch (action) {
        case 'play':
          // 立即播放（边播边缓存）：先暂停页内正在播放的视频，避免双音源
          await _controller.runJavaScript(
              'document.querySelectorAll("video").forEach(function(v){ if(!v.paused) v.pause(); });');
          final item = await PlaybackCacher.instance.start(
            url: url,
            title: title.isNotEmpty ? title : '网页视频',
            referer: _currentUrl,
          );
          if (item == null) {
            _toast('无法播放该视频');
            return;
          }
          if (!mounted) return;
          Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => PlayerPage(playlist: [item], initialIndex: 0),
            ),
          );
          break;
        case 'mp4':
          if (!v.isMp4) {
            _toast('该链接不是可直接下载的视频文件');
            return;
          }
          DownloadManager.instance.download(v);
          _toast('已加入下载队列');
          break;
        case 'hls':
          HlsManager.instance.start(url, title.isNotEmpty ? title : 'HLS视频');
          _toast('已开始 HLS 离线下载，进度见「资源库」');
          break;
        case 'convert':
          ConvertManager.instance.convert(v);
          _toast('已开始 m3u8 → mp4 转换，进度见「资源库」');
          break;
        case 'copy':
          Clipboard.setData(ClipboardData(text: url));
          _toast('链接已复制');
          break;
        case 'ignore':
          setState(() => _found.removeWhere((e) => e.url == url));
          _toast('已忽略该视频');
          break;
      }
    } catch (e) {
      AppLog.instance
          .warn('browser', '解析 videoAction 消息失败: ${_truncate(raw)}', e);
    }
  }

  /// 跳转拦截：脚本发现「非用户点击」的自动跳转时回调。
  /// 广告目标且广告过滤已开 → 静默拦截；否则弹窗询问。
  void _handleRedirectAttempt(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final url = j['url'] as String;
      final from = (j['from'] as String?) ?? _currentUrl;
      if (_handledRedirects.contains(url)) return;
      _handledRedirects.add(url);
      final isAd = isAdHost(url);
      if (isAd && AppData.instance.adBlockEnabled) {
        _toast('已拦截广告跳转：${Uri.tryParse(url)?.host ?? url}');
        return;
      }
      _askRedirect(url, from, isAd);
    } catch (e) {
      AppLog.instance
          .warn('browser', '解析 redirectAttempt 消息失败: ${_truncate(raw)}', e);
    }
  }

  Future<void> _askRedirect(String url, String from, bool isAd) async {
    if (!mounted || _redirectDialogOpen) return;
    _redirectDialogOpen = true;
    final choice = await showDialog<_RedirectChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isAd ? '疑似广告跳转' : '检测到自动跳转'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isAd) ...[
              Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('目标地址命中广告域名库')),
                ],
              ),
              const SizedBox(height: 12),
            ],
            Text('当前页', style: Theme.of(ctx).textTheme.labelSmall),
            Text(from, maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 8),
            Text('目标页', style: Theme.of(ctx).textTheme.labelSmall),
            Text(url, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _RedirectChoice.block),
            child: const Text('拦截'),
          ),
          if (isAd)
            TextButton(
              onPressed: () => Navigator.pop(ctx, _RedirectChoice.blockEnableAd),
              child: const Text('拦截并开广告过滤'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _RedirectChoice.allow),
            child: const Text('允许跳转'),
          ),
        ],
      ),
    );
    _redirectDialogOpen = false;
    switch (choice) {
      case _RedirectChoice.allow:
        await _controller.loadRequest(Uri.parse(url));
      case _RedirectChoice.block:
        _toast('已拦截跳转');
      case _RedirectChoice.blockEnableAd:
        await AppData.instance.setAdBlock(true);
        _toast('已拦截，并开启广告过滤');
      case null:
        break;
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  /// 日志用：截断过长的原始消息
  static String _truncate(String s, [int max = 300]) =>
      s.length <= max ? s : '${s.substring(0, max)}…（共 ${s.length} 字符）';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('内置浏览器'),
        actions: [
          ListenableBuilder(
            listenable: AppData.instance,
            builder: (ctx, _) {
              final marked = AppData.instance.isBookmarked(_currentUrl);
              return IconButton(
                icon: Icon(marked ? Icons.star : Icons.star_border),
                color: marked ? Colors.amber : null,
                tooltip: '书签',
                onPressed: () {
                  AppData.instance.toggleBookmark(
                    _pageTitle.isNotEmpty ? _pageTitle : _currentUrl,
                    _currentUrl,
                  );
                  setState(() {});
                },
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.bookmarks_outlined),
            tooltip: '书签列表',
            onPressed: _showBookmarksSheet,
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '历史记录',
            onPressed: _showHistorySheet,
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (v) {
              if (v == 'adblock') {
                AppData.instance.setAdBlock(!AppData.instance.adBlockEnabled);
                setState(() {});
                _injectAdBlock();
              } else if (v == 'redirectguard') {
                AppData.instance.setRedirectGuard(!AppData.instance.redirectGuardEnabled);
                setState(() {});
              } else if (v == 'videomark') {
                AppData.instance.setVideoMark(!AppData.instance.videoMarkEnabled);
                setState(() {});
              }
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'adblock',
                child: Row(
                  children: [
                    Icon(
                      AppData.instance.adBlockEnabled
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(AppData.instance.adBlockEnabled ? '广告过滤：开' : '广告过滤：关'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'redirectguard',
                child: Row(
                  children: [
                    Icon(
                      AppData.instance.redirectGuardEnabled
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      AppData.instance.redirectGuardEnabled ? '跳转拦截：开' : '跳转拦截：关',
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'videomark',
                child: Row(
                  children: [
                    Icon(
                      AppData.instance.videoMarkEnabled
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      AppData.instance.videoMarkEnabled ? '视频标记：开' : '视频标记：关',
                    ),
                  ],
                ),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller.reload(),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => _controller.goBack(),
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: () => _controller.goForward(),
                ),
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    decoration: const InputDecoration(
                      hintText: '输入网址',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.go,
                    onSubmitted: _load,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () => _load(_urlController.text),
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                WebViewWidget(controller: _controller),
                if (_found.isNotEmpty) _foundBanner(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _foundBanner() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 12,
      child: Center(
        child: Material(
          color: Theme.of(context).colorScheme.inverseSurface,
          borderRadius: BorderRadius.circular(24),
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: () => _showFoundSheet(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.play_circle_outline, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '发现 ${_found.length} 个视频',
                    style: const TextStyle(color: Colors.white),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.expand_more, color: Colors.white, size: 18),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showFoundSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text('发现视频', style: Theme.of(ctx).textTheme.titleMedium),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _found.length,
                  itemBuilder: (ctx, i) {
                    final v = _found[i];
                    return ListTile(
                      leading: Icon(
                        v.isHls ? Icons.stream : Icons.movie_outlined,
                        color: v.isHls ? Colors.orange : Colors.blue,
                      ),
                      title: Text(v.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        v.kind.toUpperCase(),
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: v.isHls
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.download),
                                  tooltip: 'HLS 离线缓存',
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    _startDownload(v);
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.download_for_offline),
                                  tooltip: '下载 m3u8（含分片）',
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    ConvertManager.instance.downloadM3u8(v);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content: Text('已开始下载 m3u8 分片包')),
                                    );
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.transform),
                                  tooltip: '转 MP4',
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    ConvertManager.instance.convert(v);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('已开始 m3u8 → mp4 转换，进度见「资源库」')),
                                    );
                                  },
                                ),
                              ],
                            )
                          : IconButton(
                              icon: const Icon(Icons.download),
                              tooltip: '下载',
                              onPressed: () {
                                Navigator.pop(ctx);
                                _startDownload(v);
                              },
                            ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _startDownload(VideoInfo v) {
    if (v.isHls) {
      HlsManager.instance.start(v.url, v.pageTitle.isNotEmpty ? v.pageTitle : 'HLS视频');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已开始 HLS 离线下载，进度见「资源库」')),
      );
      return;
    }
    if (!v.isMp4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该链接不是可直接下载的 mp4')),
      );
      return;
    }
    DownloadManager.instance.download(v);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已加入下载队列')),
    );
  }

  void _showBookmarksSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    Text('书签', style: Theme.of(ctx).textTheme.titleMedium),
                    const Spacer(),
                    TextButton(
                      onPressed: () async {
                        for (final b in List.of(AppData.instance.bookmarks)) {
                          await AppData.instance.removeBookmark(b.url);
                        }
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('清除全部'),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListenableBuilder(
                  listenable: AppData.instance,
                  builder: (ctx, _) {
                    final bs = AppData.instance.bookmarks;
                    if (bs.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: Text('暂无书签（点右上角星标收藏当前页）')),
                      );
                    }
                    return ListView.builder(
                      shrinkWrap: true,
                      itemCount: bs.length,
                      itemBuilder: (ctx, i) {
                        final b = bs[i];
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.star, size: 20, color: Colors.amber),
                          title: Text(
                            b.title.isNotEmpty ? b.title : b.url,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(b.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: () => AppData.instance.removeBookmark(b.url),
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            _load(b.url);
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showHistorySheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    Text('历史记录', style: Theme.of(ctx).textTheme.titleMedium),
                    const Spacer(),
                    TextButton(
                      onPressed: () async {
                        await AppData.instance.clearHistory();
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('清除全部'),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListenableBuilder(
                  listenable: AppData.instance,
                  builder: (ctx, _) {
                    final h = AppData.instance.history;
                    if (h.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: Text('暂无历史记录')),
                      );
                    }
                    return ListView.builder(
                      shrinkWrap: true,
                      itemCount: h.length,
                      itemBuilder: (ctx, i) {
                        final e = h[i];
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.link, size: 20),
                          title: Text(
                            e.title.isNotEmpty ? e.title : e.url,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(e.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: () => AppData.instance.removeHistory(e.url),
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            _load(e.url);
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
