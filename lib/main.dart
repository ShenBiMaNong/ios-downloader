import 'package:material_ui/material_ui.dart';

import 'models/video_info.dart';
import 'pages/browser_page.dart';
import 'pages/library_page.dart';
import 'services/download_manager.dart';
import 'services/hls_manager.dart';
import 'services/m3u8_convert.dart';
import 'services/share_import.dart';

void main() {
  runApp(const VideoDownloaderApp());
}

class VideoDownloaderApp extends StatelessWidget {
  const VideoDownloaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '视频下载器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  final _browserKey = GlobalKey<BrowserPageState>();
  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _pages = [
      BrowserPage(key: _browserKey),
      const LibraryPage(),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkClipboard());
  }

  /// 剪贴板导入（MVP-4 前置）：打开 App 时检测，给出导入动作
  Future<void> _checkClipboard() async {
    final url = await ShareImport.readClipboardUrl();
    if (url == null || !mounted) return;
    final v = ShareImport.classify(url);
    final isDirect = v.isMp4 || v.isHls;
    final isPage = ShareImport.isKnownVideoPage(url);
    if (!isDirect && !isPage) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(child: _importSheet(ctx, v)),
    );
  }

  Widget _importSheet(BuildContext ctx, VideoInfo v) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('检测到剪贴板链接', style: Theme.of(ctx).textTheme.titleMedium),
        ),
        ListTile(
          leading: Icon(
            v.isHls ? Icons.stream : Icons.link,
            color: v.isHls ? Colors.orange : Colors.blue,
          ),
          title: Text(v.url, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(v.kind.toUpperCase(), style: const TextStyle(fontSize: 12)),
        ),
        if (v.isMp4)
          ListTile(
            leading: const Icon(Icons.download),
            title: const Text('下载 mp4'),
            onTap: () {
              Navigator.pop(ctx);
              DownloadManager.instance.download(v);
              _toast('已加入下载队列');
            },
          ),
        if (v.isHls) ...[
          ListTile(
            leading: const Icon(Icons.download),
            title: const Text('HLS 离线缓存'),
            onTap: () {
              Navigator.pop(ctx);
              HlsManager.instance.start(v.url, v.pageTitle);
              _toast('已开始 HLS 离线下载');
            },
          ),
          ListTile(
            leading: const Icon(Icons.transform),
            title: const Text('m3u8 转 MP4'),
            onTap: () {
              Navigator.pop(ctx);
              ConvertManager.instance.convert(v);
              _toast('已开始 m3u8 → mp4 转换');
            },
          ),
        ],
        ListTile(
          leading: const Icon(Icons.language),
          title: const Text('在浏览器打开'),
          onTap: () {
            Navigator.pop(ctx);
            setState(() => _index = 0);
            _browserKey.currentState?.loadUrl(v.url);
          },
        ),
      ],
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.language),
            selectedIcon: Icon(Icons.language),
            label: '浏览器',
          ),
          NavigationDestination(
            icon: Icon(Icons.video_library_outlined),
            selectedIcon: Icon(Icons.video_library),
            label: '资源库',
          ),
        ],
      ),
    );
  }
}
