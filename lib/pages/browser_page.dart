import 'dart:convert';
import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart'
    show
        Clipboard,
        ClipboardData,
        MethodChannel,
        MissingPluginException,
        PlatformException,
        rootBundle;
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

  /// 地址栏焦点：用户正在输入时不覆盖他写的内容
  final _urlFocus = FocusNode();
  late final WebViewController _controller;
  String? _sniffer;
  String? _adblock;
  String? _marker;
  String? _redirectGuard;
  String? _noAutoplay;
  String _currentUrl = '';
  String _pageTitle = '';

  /// 跳转拦截：本页已处理过的跳转目标（去重，页面切换时清空）
  final Set<String> _handledRedirects = {};
  bool _redirectDialogOpen = false;

  /// 上次注入的跳转拦截开关状态（供 AppData 变更监听去重）
  bool? _lastGuardApplied;

  /// 上次注入的页面视频标记开关状态（供 AppData 变更监听去重）
  bool? _lastMarkerApplied;

  /// 上次应用的自动播放拦截开关状态（供 AppData 变更监听去重）
  bool? _lastNoAutoplayApplied;

  /// 上次应用的「点播放即接管」开关状态（供 AppData 变更监听去重）
  bool? _lastHijackApplied;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (url) {
          // 地址栏跟随：之前只更新 _currentUrl 且不 setState ——
          // 页内点击链接跳转后，地址栏还停在用户上次输入的地址（看起来「卡住不动」）
          _syncAddress(url);
          _handledRedirects.clear();
          AppData.instance.setLastUrl(url);
          _injectSniffer();
          _installEarlyScripts(); // 已装则秒回；未装（如 WebView 重建）再试一次
          _injectMarker();
          _injectRedirectGuard();
          _injectNoAutoplay();
          if (AppData.instance.adBlockEnabled) _injectAdBlock();
        },
        // SPA 路由变化（history.pushState / 页内锚点）不会触发 onPageStarted，
        // 只有 onUrlChange 能拿到 —— 否则单页应用里地址栏永远停在首屏地址
        onUrlChange: (change) {
          final url = change.url;
          if (url != null && url.isNotEmpty) _syncAddress(url);
        },
        onPageFinished: (url) async {
          _syncAddress(url);
          await _injectSniffer();
          await _injectMarker();
          await _injectRedirectGuard();
          await _injectNoAutoplay();
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
      ..addJavaScriptChannel('videoAction', onMessageReceived: (msg) {
        _handleVideoAction(msg.message);
      })
      ..addJavaScriptChannel('redirectAttempt', onMessageReceived: (msg) {
        _handleRedirectAttempt(msg.message);
      });
    AppData.instance.addListener(_onAppDataChanged);
    // iOS：把自动播放拦截 + 嗅探脚本注册为 WKUserScript（atDocumentStart + 全帧含跨域 iframe），
    // 必须在页面脚本之前执行；失败由 onPageStarted/onPageFinished 注入兜底
    _installEarlyScripts();
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
    _urlFocus.dispose();
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

  Future<String> _noAutoplayJs() async =>
      _noAutoplay ??= await rootBundle.loadString('assets/no_autoplay.js');

  Future<void> _injectSniffer() async {
    try {
      final js = await _snifferJs();
      // 附带源码：让脚本把自身扩散到同源 iframe（跨域 iframe 由平台限制，跳过）
      final boot = '\nwindow.__vdlSniffSource=${jsonEncode(js)};\n'
          'if (window.__vdlSniffPropagate) window.__vdlSniffPropagate(window.__vdlSniffSource);';
      await _controller.runJavaScript(js + boot);
    } catch (e, st) {
      AppLog.instance.warn('browser', '注入嗅探脚本失败', e, st);
    }
  }

  /// iOS 早期注入：把脚本注册为 WKUserScript（atDocumentStart + 全帧含跨域）。
  /// 相比 onPageFinished 注入的两个优势：
  /// 1) 先于页面脚本执行 —— 嗅探器因此在站点缓存原始 fetch 引用前挂钩，自动播放拦截
  ///    也必须在页面脚本之前覆盖 play()，否则站点已拿到原生引用就绕过去了；
  /// 2) 跨域 iframe 播放器帧同样注入 —— 跨域播放器的请求/自动播放也能管住。
  /// 非 iOS（无此原生通道）或 WebView 尚未创建时静默跳过/重试，不影响 Android。
  static const _sniffBridge = MethodChannel('video_downloader/sniffer');
  bool _earlySnifferInstalled = false;
  int _earlySnifferTries = 0;

  Future<void> _installEarlyScripts() async {
    if (_earlySnifferInstalled || _earlySnifferTries > 12) return;
    _earlySnifferTries++;
    try {
      // 顺序：自动播放拦截在嗅探器之前（先拿到 play() 的原生引用）
      final scripts = [await _noAutoplayJs(), await _snifferJs()];
      final ok = await _sniffBridge
              .invokeMethod<bool>('installUserScripts', scripts) ??
          false;
      if (ok) {
        _earlySnifferInstalled = true;
        AppLog.instance
            .info('browser', 'iOS 早期注入成功（WKUserScript 全帧：自动播放拦截 + 嗅探）');
        return;
      }
    } on MissingPluginException {
      return; // Android / 桌面：无此通道，走 onPageStarted/onPageFinished 注入
    } on PlatformException {
      return;
    } catch (e, st) {
      AppLog.instance.warn('browser', 'iOS 早期注入异常', e, st);
      return;
    }
    // WebView 平台视图尚未创建 → 稍后重试
    if (mounted) {
      Future<void>.delayed(const Duration(milliseconds: 500), _installEarlyScripts);
    }
  }

  /// 自动播放拦截：脚本自身幂等（已装则立即返回），开关值另行注入。
  /// 关掉开关时走 `__vdlNoAutoplaySetEnabled(false)` 把原型方法还原，无需刷新页面。
  /// 「点播放即接管」也由同一脚本实现（共用 play() 钩子与手势判据），任一开关开启都要确保脚本已注入。
  Future<void> _injectNoAutoplay() async {
    try {
      final on = AppData.instance.blockAutoplayEnabled;
      final hijack = AppData.instance.playHijackEnabled;
      if (on || hijack) {
        // 先设标志再注入：脚本只在该值不是 bool 时才用 sessionStorage 里的历史值兜底，
        // 否则「关过开关 → 再打开」会被历史值覆盖成关闭
        await _controller.runJavaScript('window.__vdlNoAutoplayEnabled=$on;');
        await _controller.runJavaScript(await _noAutoplayJs());
      } else {
        await _controller
            .runJavaScript('if (window.__vdlNoAutoplaySetEnabled) '
                'window.__vdlNoAutoplaySetEnabled(false);');
      }
      // 接管开关独立同步：脚本未装时只设窗口变量，装上后由 setter 一并写 sessionStorage
      // （供下个页面 atDocumentStart 阶段读取，那时 Dart 还没机会注入）
      await _controller.runJavaScript('window.__vdlHijackEnabled=$hijack;'
          'if (window.__vdlNoAutoplaySetHijack) window.__vdlNoAutoplaySetHijack($hijack);');
      _lastNoAutoplayApplied = on;
      _lastHijackApplied = hijack;
    } catch (e, st) {
      AppLog.instance.warn('browser', '注入自动播放拦截脚本失败', e, st);
    }
  }

  /// 地址栏 / 当前地址跟随页面变化。
  /// ref: onPageStarted（整页导航）、onUrlChange（SPA pushState、页内锚点）、onPageFinished（兜底）。
  /// 用户正在地址栏输入时不覆盖（否则打字打到一半被导航结果冲掉）。
  void _syncAddress(String url) {
    if (url.isEmpty) return;
    final changed = url != _currentUrl;
    _currentUrl = url;
    if (!_urlFocus.hasFocus && _urlController.text != url) {
      _urlController.value = TextEditingValue(
        text: url,
        selection: const TextSelection.collapsed(offset: 0),
      );
    }
    if (changed && mounted) {
      // 书签星标等依赖 _currentUrl 的 UI 必须跟着刷
      setState(() {});
    }
  }

  /// 页面视频标记（方案A）：开关打开才注入；关闭时清理已注入的标记
  Future<void> _injectMarker() async {
    try {
      if (AppData.instance.videoMarkEnabled) {
        final js = await _markerJs();
        // 附带源码：脚本自扩散到同源 iframe，让 iframe 内播放器也能出角标
        final boot = '\nwindow.__vdlMarkerSource=${jsonEncode(js)};\n'
            'if (window.__vdlMarkerPropagate) window.__vdlMarkerPropagate(window.__vdlMarkerSource);';
        await _controller.runJavaScript(js + boot);
      } else {
        await _controller.runJavaScript(
            'window.__vdlMarkerSource=null; if (window.__vdlCleanup) window.__vdlCleanup();');
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
    if (AppData.instance.blockAutoplayEnabled != _lastNoAutoplayApplied ||
        AppData.instance.playHijackEnabled != _lastHijackApplied) {
      _injectNoAutoplay();
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

  /// 页面视频标记（方案A）：页内操作卡回传的动作
  Future<void> _handleVideoAction(String raw) async {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final action = (j['action'] as String?) ?? '';
      final url = (j['url'] as String?) ?? '';
      final title = (j['title'] as String?) ?? '';
      // 页内标记卡不带 referer → 用主框架地址；「点播放即接管」会带当前帧地址，
      // 跨域 iframe 播放器必须用它，否则 CDN 拿主框架 Referer 直接 403
      final referer = (j['referer'] as String?) ?? '';
      // 自动播放拦截脚本的一次性上报（每个文档最多一条）：不弹 toast，只进系统日志，
      // 便于排查「为什么这个页面的视频不自动播了」
      if (action == 'autoplayBlocked') {
        AppLog.instance.info(
          'browser',
          '已拦截页面自动播放（${j['count'] ?? 1} 次）: ${url.isEmpty ? _currentUrl : url}',
        );
        return;
      }
      if (url.isEmpty) return;
      final v = VideoInfo(url: url, frameUrl: _currentUrl, pageTitle: title);
      switch (action) {
        case 'play':
          // 立即播放（边播边缓存）：先停掉页内播放，避免双音源
          await _pausePageVideos();
          final item = await PlaybackCacher.instance.start(
            url: url,
            title: title.isNotEmpty ? title : '网页视频',
            referer: referer.isNotEmpty ? referer : _currentUrl,
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
          if (!_isDirectMedia(v)) {
            _toast('该链接不是可直接下载的视频文件');
            return;
          }
          // 页内播放器继续播着会让系统一直挂「正在播放」媒体通知，且白耗流量
          await _pausePageVideos();
          DownloadManager.instance.download(v);
          _toast('已加入下载队列，进度见「资源库」');
          break;
        case 'bg':
          // 原生 background URLSession 是 iOS 专有；Android 无对应桥接，
          // 直接提交必然失败，降级为 Dart 侧分片包下载并明确告知用户。
          await _pausePageVideos();
          if (!Platform.isIOS) {
            ConvertManager.instance.downloadM3u8(v);
            _toast('当前平台不支持系统级后台下载，已改为下载 m3u8 分片包');
            break;
          }
          // 锁屏/切 App 后由系统继续下分片，齐备后回前台 ffmpeg -c copy 合成 mp4。
          ConvertManager.instance.nativeDownload(v);
          _toast('已提交后台下载；分片下完后回到 App 会自动合成 MP4（可锁屏）');
          break;
        case 'package':
          // 自己下 .ts 分片包（产物可离线、可随时「本地转 MP4」），
          // 与 case 'hls' 的系统 .movpkg 离线缓存是两条完全不同的链路
          await _pausePageVideos();
          ConvertManager.instance.downloadM3u8(v);
          _toast('已开始下载 m3u8 分片包，完成后可在资源库「本地转 MP4」');
          break;
        case 'hls':
          await _pausePageVideos();
          HlsManager.instance.start(url, title.isNotEmpty ? title : 'HLS视频');
          _toast('已开始 HLS 离线下载（系统私有格式，仅可播放），进度见「资源库」');
          break;
        case 'convert':
          await _pausePageVideos();
          ConvertManager.instance.convert(v);
          _toast('已开始 m3u8 → mp4 转换，进度见「资源库」');
          break;
        case 'copy':
          Clipboard.setData(ClipboardData(text: url));
          _toast('链接已复制');
          break;
        case 'ignore':
          // 页内角标由 video_marker.js 自行移除，这里只给个反馈
          _toast('已忽略该视频');
          break;
      }
    } catch (e) {
      AppLog.instance
          .warn('browser', '解析 videoAction 消息失败: ${_truncate(raw)}', e);
    }
  }

  /// 暂停页内所有 <video>/<audio>，并清掉页面设置的 Media Session：
  /// 一来避免下载/本地播放时页内继续出声、白耗流量，
  /// 二来避免浏览器/系统一直挂着「正在播放」的媒体通知（下载期间尤其明显）。
  Future<void> _pausePageVideos() async {
    try {
      await _controller.runJavaScript(
        '(function(){try{document.querySelectorAll("video,audio").forEach('
        'function(v){if(!v.paused)v.pause();});}catch(e){}'
        'try{if(navigator.mediaSession){navigator.mediaSession.metadata=null;}}catch(e){}})();',
      );
    } catch (e, st) {
      AppLog.instance.warn('browser', '暂停页内播放失败', e, st);
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
              } else if (v == 'noautoplay') {
                AppData.instance
                    .setBlockAutoplay(!AppData.instance.blockAutoplayEnabled);
                setState(() {});
              } else if (v == 'playhijack') {
                final on = !AppData.instance.playHijackEnabled;
                AppData.instance.setPlayHijack(on);
                setState(() {});
                if (on) {
                  _toast('点播放即接管：已开启（仅对能拿到直链的播放器生效）');
                }
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
              PopupMenuItem(
                value: 'noautoplay',
                child: Row(
                  children: [
                    Icon(
                      AppData.instance.blockAutoplayEnabled
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      AppData.instance.blockAutoplayEnabled
                          ? '禁止自动播放：开'
                          : '禁止自动播放：关',
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'playhijack',
                child: Row(
                  children: [
                    Icon(
                      AppData.instance.playHijackEnabled
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      AppData.instance.playHijackEnabled
                          ? '点播放即接管：开'
                          : '点播放即接管：关',
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
                    focusNode: _urlFocus,
                    decoration: const InputDecoration(
                      hintText: '输入网址',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.go,
                    // 回车后收起键盘并失焦，这样后续导航能把地址栏覆盖成真实地址
                    onSubmitted: (v) {
                      _urlFocus.unfocus();
                      _load(v);
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () {
                    // 同上：提交后失焦，否则地址栏会一直保留用户输入的简写地址
                    _urlFocus.unfocus();
                    _load(_urlController.text);
                  },
                ),
              ],
            ),
          ),
          // 页内角标（video_marker.js）是唯一的视频入口，不再额外挂底部列表
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }

  /// 是否可直接按文件下载：非清单的 http(s) 直链。
  /// 嗅探器会用响应 Content-Type 兜底上报**没有扩展名**的直链
  /// （如 /video/abc?sign=…，VideoInfo.kind 判为 other）。旧逻辑只认扩展名，
  /// 这类链接被直接拒绝 → 用户点了下载，资源库里既没有条目也没有进度。
  /// 放宽后仍由真实下载结果兜底：下不动会在资源库留下带 HTTP 状态的失败条目。
  bool _isDirectMedia(VideoInfo v) =>
      v.url.startsWith('http') && !v.isHls && v.kind != 'mpd';

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
