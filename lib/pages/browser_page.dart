import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:webview_flutter/webview_flutter.dart';

import '../models/video_info.dart';
import '../services/download_manager.dart';
import '../services/hls_manager.dart';
import '../services/m3u8_convert.dart';

/// 内置浏览器 + 视频嗅探页
class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key});

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  final _urlController = TextEditingController(text: 'https://www.bilibili.com');
  late final WebViewController _controller;
  final List<VideoInfo> _found = [];
  String? _sniffer;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (url) => _injectSniffer(),
        onPageFinished: (url) => _injectSniffer(),
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

  Future<String> _snifferJs() async {
    return _sniffer ??= await rootBundle.loadString('assets/sniffer.js');
  }

  Future<void> _injectSniffer() async {
    try {
      final js = await _snifferJs();
      await _controller.runJavaScript(js);
    } catch (_) {}
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
                                      const SnackBar(content: Text('已开始 m3u8 → mp4 转换，进度见「下载」页')),
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
        const SnackBar(content: Text('已开始 HLS 离线下载，进度见「下载」页')),
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
}
