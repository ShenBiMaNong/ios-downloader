import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';

import 'models/video_info.dart';
import 'pages/browser_page.dart';
import 'pages/library_page.dart';
import 'services/app_log.dart';
import 'services/app_settings.dart';
import 'services/download_manager.dart';
import 'services/hls_manager.dart';
import 'services/m3u8_convert.dart';
import 'services/playback_cacher.dart';
import 'services/playback_progress.dart';
import 'services/share_import.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 系统日志：先挂接全局错误捕获，再初始化（载入上次会话日志）
  AppLog.instance.installGlobalHandlers();
  await AppLog.instance.init();
  AppLog.instance.info(
    'app',
    '应用启动 '
        '${kIsWeb ? 'Web' : Platform.operatingSystem} '
        '${kIsWeb ? '' : Platform.version}',
  );
  // 先加载设置（主题、浏览器启动页），让首次界面按用户偏好渲染
  await AppSettings.instance.ensureLoaded();
  // 恢复上次未完成的断点任务（mp4 直链 / m3u8 转换 / HLS 离线缓存）
  await DownloadManager.instance.ensureLoaded();
  await ConvertManager.instance.ensureLoaded();
  await HlsManager.instance.ensureLoaded();
  // 边播边缓存：启动本地 HTTP 代理；加载播放进度记忆
  await PlaybackCacher.instance.init();
  await PlaybackProgress.instance.ensureLoaded();
  // 接收其他 App 分享过来的视频文件（Android 直收；iOS 经「用 App 打开」收文件）
  // 不阻塞首帧：导入完成后 LibraryRefresh 通知资源库刷新
  ShareImport.importPending();
  // 捕获异步/Zone 级未处理异常进日志
  runZonedGuarded(() {
    runApp(const VideoDownloaderApp());
  }, (error, stack) {
    AppLog.instance.error('zone', '未捕获的异步异常：$error', error, stack);
  });
}

class VideoDownloaderApp extends StatelessWidget {
  const VideoDownloaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppSettings.instance,
      builder: (context, _) {
        return MaterialApp(
          title: '视频下载器',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.indigo,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          themeMode: AppSettings.instance.themeMode.flutter,
          home: const HomeShell(),
        );
      },
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
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _pages = [
      BrowserPage(key: _browserKey),
      const LibraryPage(),
    ];
    // 回到前台：处理分享队列 + 恢复本地代理 socket（iOS 后台可能被回收）
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkClipboard());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _onResume() async {
    PlaybackCacher.instance.ensureActive();
    await _importPendingShares();
  }

  /// 处理其他 App 分享过来的视频文件（拷贝进 Documents/Share 并登记资源库）
  Future<void> _importPendingShares() async {
    final n = await ShareImport.importPending();
    if (n > 0 && mounted) _toast('已导入 $n 个分享视频');
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
            leading: const Icon(Icons.download_for_offline),
            title: const Text('下载 m3u8（含分片）'),
            onTap: () {
              Navigator.pop(ctx);
              ConvertManager.instance.downloadM3u8(v);
              _toast('已开始下载 m3u8 分片包');
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
      body: IndexedStack(index: _index, children: _pages),
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
