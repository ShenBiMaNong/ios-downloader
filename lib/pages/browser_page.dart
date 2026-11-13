import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:webview_flutter/webview_flutter.dart';

import '../models/video_info.dart';
import '../services/app_data.dart';
import '../services/download_manager.dart';
import '../services/hls_manager.dart';
import '../services/m3u8_convert.dart';

/// 内置浏览器 + 视频嗅探 + 书签/历史/广告过滤
class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key});

  @override
  State<BrowserPage> createState() => BrowserPageState();
}

class BrowserPageState extends State<BrowserPage> {
  final _urlController = TextEditingController(text: 'https://www.bilibili.com');
  late final WebViewController _controller;
  final List<VideoInfo> _found = [];
  String? _sniffer;
  String? _adblock;
  String _currentUrl = '';
  String _pageTitle = '';

  @override
  void initState() {
    super.initState();
    AppData.instance.ensureLoaded();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (url) {
          _currentUrl = url;
          _injectSniffer();
          if (AppData.instance.adBlockEnabled) _injectAdBlock();
        },
        onPageFinished: (url) async {
          await _injectSniffer();
          if (AppData.instance.adBlockEnabled) await _injectAdBlock();
          final t = await _controller.getTitle();
          if (mounted) setState(() => _pageTitle = t ?? '');
          AppData.instance.recordHistory(t ?? '', url);
        },
      ))
      ..addJavaScriptChannel('videoFound', onMessageReceived: (msg) {
        _handleFound(msg.message);
      });
    _load(_urlController.text);
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<String> _snifferJs() async =>
      _sniffer ??= await rootBundle.loadString('assets/sniffer.js');

  Future<String> _adblockJs() async =>
      _adblock ??= await rootBundle.loadString('assets/adblock.js');

  Future<void> _injectSniffer() async {
    try {
      final js = await _snifferJs();
      await _controller.runJavaScript(js);
    } catch (_) {}
  }

  Future<void> _injectAdBlock() async {
    try {
      final js = await _adblockJs();
      await _controller.runJavaScript(js);
    } catch (_) {}
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
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('内置浏览器'),
        actions: [
          IconButton(
            icon: Icon(
              AppData.instance.isBookmarked(_currentUrl)
                  ? Icons.star
                  : Icons.star_border,
              color: AppData.instance.isBookmarked(_currentUrl)
                  ? Colors.amber
                  : null,
            ),
            tooltip: '书签',
            onPressed: () {
              AppData.instance.toggleBookmark(
                _pageTitle.isNotEmpty ? _pageTitle : _currentUrl,
                _currentUrl,
              );
              setState(() {});
            },
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
