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
          // 系统深链（videodl:// 唤起、iOS「用 App 打开」文件 URL 等）会被框架
          // 当作命名路由推送；本 App 没有对应的命名路由页面。兜底吞掉这类路由，
          // 避免 release 模式下框架 onUnknownRoute 空检查崩溃（见 _onUnknownRoute）。
          onUnknownRoute: _discardDeepLinkRoute,
        );
      },
    );
  }
}

/// 未知命名路由兜底：推一个零时长透明占位页并在首帧后立即退出，
/// 不产生可见跳转，也不触发框架 onUnknownRoute 的空检查崩溃路径。
Route<dynamic> _discardDeepLinkRoute(RouteSettings settings) {
  return PageRouteBuilder<void>(
    settings: settings,
    opaque: false,
    pageBuilder: (_, __, ___) => const _DiscardDeepLinkPage(),
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
  );
}

class _DiscardDeepLinkPage extends StatefulWidget {
  const _DiscardDeepLinkPage();

  @override
  State<_DiscardDeepLinkPage> createState() => _DiscardDeepLinkPageState();
}

class _DiscardDeepLinkPageState extends State<_DiscardDeepLinkPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
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

  /// 进度数据源（导航角标监听）
  late final Listenable _progressSources;

  @override
  void initState() {
    super.initState();
    _pages = [
      BrowserPage(key: _browserKey),
      const LibraryPage(),
    ];
    _progressSources = Listenable.merge([
      DownloadManager.instance,
      HlsManager.instance,
      ConvertManager.instance,
      PlaybackCacher.instance,
    ]);
    // 回到前台：处理分享队列 + 恢复本地代理 socket（iOS 后台可能被回收）
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    // 原生推送：新分享入队即导入（含批量分享；不必等 onResume）
    ShareBridge.installListener();
    ShareBridge.onPendingAdded = _importPendingShares;
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkClipboard());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _onResume() async {
    PlaybackCacher.instance.ensureActive();
    // 后台分片事件在锁屏期间可能整段丢失：回前台以原生磁盘状态对账，
    // 已下齐的作业立即触发 ffmpeg 合成（合成放前台，后台唤醒窗口不够跑）。
    await ConvertManager.instance.onResume();
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
              HlsManager.instance.start(v.url, v.pageTitle,
                  referer: v.effectiveReferer);
              _toast('已开始 HLS 离线下载');
            },
          ),
          ListTile(
            leading: const Icon(Icons.download_for_offline),
            title: const Text('后台下载并转 MP4'),
            onTap: () {
              Navigator.pop(ctx);
              if (!Platform.isIOS) {
                ConvertManager.instance.downloadM3u8(v);
                _toast('当前平台不支持系统级后台下载，已改为下载 m3u8 分片包');
                return;
              }
              ConvertManager.instance.nativeDownload(v);
              _toast('已提交后台下载；分片下完后回到 App 会自动合成 MP4');
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
      bottomNavigationBar: _navBar(),
    );
  }

  /// 进行中的任务数（mp4 下载 / HLS 离线 / m3u8 转换 / 边播边缓存）
  int _activeCount() {
    var n = 0;
    for (final t in DownloadManager.instance.tasks) {
      if (t.status == DownloadStatus.queued ||
          t.status == DownloadStatus.downloading) {
        n++;
      }
    }
    n += HlsManager.instance.tasks.where((t) => !t.done && !t.failed).length;
    n += ConvertManager.instance.tasks.where((t) => !t.done && !t.failed).length;
    n += PlaybackCacher.instance.tasks.where((t) => !t.done && !t.failed).length;
    return n;
  }

  /// 底部导航：「资源库」带在下载数量角标，让用户在浏览器页也能看到任务已开始
  Widget _navBar() {
    return ListenableBuilder(
      listenable: _progressSources,
      builder: (context, _) {
        final active = _activeCount();
        Widget badge(IconData icon) => Badge.count(
              count: active,
              isLabelVisible: active > 0,
              child: Icon(icon),
            );
        return NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.language),
              selectedIcon: Icon(Icons.language),
              label: '浏览器',
            ),
            NavigationDestination(
              icon: badge(Icons.video_library_outlined),
              selectedIcon: badge(Icons.video_library),
              label: '资源库',
            ),
          ],
        );
      },
    );
  }
}
