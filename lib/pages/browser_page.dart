import 'dart:async' show Timer, TimeoutException;
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
  late WebViewController _controller;

  /// WebView 实例代次：强制重置时自增，并作为平台视图的 Key ——
  /// Key 变了 Flutter 才会拆掉旧 WebView（连带它的数据存储会话与渲染进程）
  int _viewEpoch = 0;

  /// 强制重置进行中（防重入 + 地址栏下方出进度条）
  bool _resetting = false;
  String? _sniffer;
  String? _adblock;
  String? _marker;
  String? _redirectGuard;
  String? _noAutoplay;
  String? _swipe;
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
    _controller = _newController();
    AppData.instance.addListener(_onAppDataChanged);
    // iOS：把自动播放拦截 + 嗅探脚本注册为 WKUserScript（atDocumentStart + 全帧含跨域 iframe），
    // 必须在页面脚本之前执行；失败由 onPageStarted/onPageFinished 注入兜底
    _installEarlyScripts();
    _initStartPage();
  }

  /// 建一个 WebView 控制器并挂上导航代理 + JS 通道。
  /// 单独成方法是因为「强制重置浏览器状态」要整个换掉 WebView 实例：
  /// 只有重建平台视图才会把卡死的渲染进程一起丢掉，`reload()` 做不到。
  WebViewController _newController() {
    return WebViewController()
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
          _injectSwipe();
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
          await _injectSwipe();
          if (AppData.instance.adBlockEnabled) await _injectAdBlock();
          final t = await _controller.getTitle();
          if (mounted) setState(() => _pageTitle = t ?? '');
          AppData.instance.recordHistory(t ?? '', url);
          // 导航竞态补刀：onPageStarted 阶段的 evaluateJavaScript 可能打在旧文档上，
          // onPageFinished 时播放器也常常还没布局出 <video>。1.2s 后再补一次注入
          // （marker 幂等，已装则秒回）—— 这是「刷新后角标不出」的最后一道兜底。
          Future<void>.delayed(const Duration(milliseconds: 1200), () {
            if (mounted) _injectMarker();
          });
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
      })
      // 页面左右滑动手势（右滑=后退、左滑=前进）：browser_swipe.js 回传方向
      ..addJavaScriptChannel('browserGesture', onMessageReceived: (msg) {
        _handleBrowserGesture(msg.message);
      });
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

  Future<String> _swipeJs() async =>
      _swipe ??= await rootBundle.loadString('assets/browser_swipe.js');

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
      // 开关快照要取已加载的持久化值（initState 时 AppData 可能还没读完文件）
      await AppData.instance.ensureLoaded();
      // 顺序：自动播放拦截在嗅探器之前（先拿到 play() 的原生引用）；
      // 视频标记最后（依赖嗅探器的 __vdlSniff，且要读前面写入的 __vdlMarkEnabled）。
      // marker 进 WKUserScript 的意义：每个新文档自动装上角标，不再依赖
      // onPageStarted/onPageFinished 的 runJavaScript —— 那条路在导航竞态下会把脚本
      // 打到旧文档上，症状就是「刷新页面角标不出、开关关→开又有了」。
      final scripts = [
        'window.__vdlMarkEnabled=${AppData.instance.videoMarkEnabled};',
        await _noAutoplayJs(),
        await _snifferJs(),
        await _markerJs(),
        // 手势导航：touch 监听也要赶在页面脚本之前挂上（页面可能自己吞 touch）
        await _swipeJs(),
      ];
      final ok = await _sniffBridge
              .invokeMethod<bool>('installUserScripts', scripts) ??
          false;
      if (ok) {
        _earlySnifferInstalled = true;
        AppLog.instance.info('browser',
            'iOS 早期注入成功（WKUserScript 全帧：自动播放拦截 + 嗅探 + 视频标记）');
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

  /// 左右滑动手势：脚本自身幂等（已装则立即返回），无开关、常开
  Future<void> _injectSwipe() async {
    try {
      await _controller.runJavaScript(await _swipeJs());
    } catch (e, st) {
      AppLog.instance.warn('browser', '注入手势脚本失败', e, st);
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
  ///
  /// 串行化：注入/清理必须按调用顺序执行。「关→开」会连续调两次本方法（一次 cleanup、
  /// 一次注入），二者都是 async（await loadString + runJavaScript），并发时完成顺序
  /// 不确定 —— 注入先完成、cleanup 后执行的话，角标就被清没了，表现为「开关关了又开，
  /// 角标时有时无」。用 Future 链排队，前一个跑完再跑下一个。
  Future<void>? _markerChain;

  Future<void> _injectMarker() {
    final prev = _markerChain;
    final task = prev == null ? _doInjectMarker() : prev.then((_) => _doInjectMarker());
    _markerChain = task.catchError((_) {});
    return task;
  }

  Future<void> _doInjectMarker() async {
    try {
      if (AppData.instance.videoMarkEnabled) {
        final js = await _markerJs();
        // 先纠正开关再注入：WKUserScript 里的开关是安装时快照，用户改过设置后
        // 新文档可能带着旧值（marker 看到 false 会直接不启动）。前缀一行就地修正。
        // 附带源码：脚本自扩散到同源 iframe，让 iframe 内播放器也能出角标。
        final code = 'window.__vdlMarkEnabled=true;\n$js\n'
            'window.__vdlMarkerSource=${jsonEncode(js)};\n'
            'if (window.__vdlMarkerPropagate) window.__vdlMarkerPropagate(window.__vdlMarkerSource);';
        await _controller.runJavaScript(code);
      } else {
        await _controller.runJavaScript('window.__vdlMarkEnabled=false;'
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
      // 页面播放器报告的时长：下载前用来核对「这条清单是不是同一个视频」
      final pageDur = (j['duration'] as num?)?.toDouble() ?? 0;
      // 自动播放拦截脚本的一次性上报（每个文档最多一条）：不弹 toast，只进系统日志，
      // 便于排查「为什么这个页面的视频不自动播了」
      if (action == 'autoplayBlocked') {
        AppLog.instance.info(
          'browser',
          '已拦截页面自动播放（${j['count'] ?? 1} 次）: ${url.isEmpty ? _currentUrl : url}',
        );
        return;
      }
      // 标记层诊断（每个文档最多两条：boot + 首次发现播放）：排查「角标不出来」时，
      // 这行日志就能分清是 video 在别的帧/shadow 里（frames/shadow > 0、dom=0）、
      // 还是角标建了被盖住（covered > 0）、还是 iOS 原生全屏播放（nativefs > 0）。
      if (action == 'markerDiag') {
        AppLog.instance.info(
          'browser',
          '标记诊断[${j['tag'] ?? ''}] 帧=${j['frame']} 视频=${j['videos']}(dom=${j['dom']} '
              'shadow=${j['shadow']} frames=${j['frames']}) 播放中=${j['playing']} '
              'srcObj=${j['srcobj']} 原生全屏=${j['nativefs']} 角标=${j['badged']} '
              '可见=${j['shown']} 被遮挡=${j['covered']} ${j['href'] ?? ''}',
        );
        return;
      }
      if (url.isEmpty) return;
      // referer/duration 必须一路传到下载器：嗅探是在 WKWebView 里做的（自带
      // 站点 Cookie 和正确 origin），而下载在原生 URLSession / Dio 里发 ——
      // 不带这两个就必然出现「页面能播、探测也 ok，一下载就 403/网络问题」。
      final v = VideoInfo(
        url: url,
        frameUrl: _currentUrl,
        pageTitle: title,
        referer: referer,
        duration: pageDur,
      );
      switch (action) {
        case 'play':
          // 立即播放（边播边缓存）：先停掉页内播放，避免双音源
          await _pausePageVideos();
          final item = await PlaybackCacher.instance.start(
            url: url,
            title: title.isNotEmpty ? title : '网页视频',
            referer: v.effectiveReferer,
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
            _toast('不是可下载的视频文件');
            return;
          }
          // 页内播放器继续播着会让系统一直挂「正在播放」媒体通知，且白耗流量
          await _pausePageVideos();
          DownloadManager.instance.download(v);
          // iOS 走原生后台传输（锁屏后系统继续下）；安卓/模拟器仍是前台 Dio 链
          _toast(Platform.isIOS ? '已开始下载，锁屏后继续' : '已加入下载');
          break;
        case 'package':
          // 自己下 .ts 分片包（产物可离线、可随时「本地转 MP4」），
          // 与 case 'hls' 的系统 .movpkg 离线缓存是两条完全不同的链路
          await _pausePageVideos();
          ConvertManager.instance.downloadM3u8(v);
          _toast('已开始下载分片包');
          break;
        case 'hls':
          await _pausePageVideos();
          HlsManager.instance.start(url, title.isNotEmpty ? title : 'HLS视频',
              referer: v.effectiveReferer);
          _toast('已开始离线下载');
          break;
        case 'convert':
          await _pausePageVideos();
          // iOS：分片交给系统后台进程，锁屏继续下，齐备后回 App 自动 -c copy 合成。
          // 其它平台没有系统级后台传输，是前台下完直接出片。
          ConvertManager.instance.convert(v);
          _toast(Platform.isIOS
              ? '已开始转 MP4，锁屏后继续下载'
              : '已开始转换');
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

  /// 暂停页内所有 `<video>`/`<audio>`，并清掉页面设置的 Media Session：
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

  /// 页面左右滑动手势（browser_swipe.js）：右滑=后退、左滑=前进，
  /// 与地址栏后退/前进按钮同语义。无历史时 goBack/goForward 由 WebView 自行忽略。
  void _handleBrowserGesture(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['action'] != 'swipe') return;
      final dir = (j['direction'] as String?) ?? '';
      final url = (j['url'] as String?) ?? _currentUrl;
      switch (dir) {
        case 'back':
          AppLog.instance.info('browser', '手势右滑 → 后退（$url）');
          _controller.goBack();
        case 'forward':
          AppLog.instance.info('browser', '手势左滑 → 前进（$url）');
          _controller.goForward();
      }
    } catch (e) {
      AppLog.instance
          .warn('browser', '解析 browserGesture 消息失败: ${_truncate(raw)}', e);
    }
  }

  /// 注销当前源的 ServiceWorker + 清空它的 CacheStorage（脚本自身返回 Promise）。
  /// 「刷新也没用」有一半出在这里：站点 ServiceWorker 用 cache-first 把半截响应
  /// 喂给每一个新文档，reload() 读的正是同一份缓存，永远修不好。
  /// 同一份脚本两处用：iOS 交给原生 evaluateJavaScript（它会等这里返回的 Promise 落定，
  /// 页内注销与清 CacheStorage 才算真的做完）；没有原生桥时（Android）直接 runJavaScript
  /// 尽力而为。脚本按当前源生效，且自身不抛异常。
  static const _serviceWorkerCleanupJs = r'''
(function () {
  var jobs = [];
  try {
    if (navigator.serviceWorker && navigator.serviceWorker.getRegistrations) {
      jobs.push(navigator.serviceWorker.getRegistrations().then(function (rs) {
        return Promise.all((rs || []).map(function (r) {
          try { return r.unregister(); } catch (e) { return null; }
        }));
      }));
    }
  } catch (e) {}
  try {
    if (window.caches && caches.keys) {
      jobs.push(caches.keys().then(function (ks) {
        return Promise.all((ks || []).map(function (k) {
          try { return caches.delete(k); } catch (e) { return null; }
        }));
      }));
    }
  } catch (e) {}
  return Promise.all(jobs).then(function () { return 1; }, function () { return 0; });
})();
''';

  /// 「强制重置浏览器状态」菜单入口：先确认，免得误触把导航历史清掉
  Future<void> _confirmForceReset() async {
    if (_resetting) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        // 标题刻意与菜单项文案不同：让测试/无障碍能按文本唯一找到那一项
        title: const Text('确定要强制重置浏览器状态？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text('适用于「页面加载一半就卡住、点刷新也没用」。依次做四件事：'),
            SizedBox(height: 8),
            Text('1. 停掉当前还在跑的加载'),
            Text('2. 注销 ServiceWorker，清空它的 CacheStorage'),
            Text('3. 清掉 HTTP 内存/磁盘缓存（登录 Cookie 与站点数据不动）'),
            Text('4. 销毁并重建 WebView 实例，重新加载本页'),
            SizedBox(height: 8),
            Text('第 4 步是刷新做不到的：卡死的渲染进程只有重建才换得掉。'),
            Text('代价：前进/后退历史清空（仍停在当前地址），页内播放中断。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('立即重置'),
          ),
        ],
      ),
    );
    if (ok == true) await _forceReset();
  }

  /// 强制重置浏览器状态。「加载一半卡住、刷新也没用」的三条成因，reload() 一条都治不了：
  /// 1) 渲染进程假死 —— 只有销毁重建 WKWebView 才会换新进程；
  /// 2) 坏缓存 / ServiceWorker 把半截响应喂给每个新文档 —— 要清 HTTP 缓存 + SW 注册；
  /// 3) 旧请求还在占连接 —— 由原生 resetWebsiteData 先 stopLoading。
  /// Cookie 与站点存储有意保留：一个自救按钮不该把已登录的站点全登出。
  Future<void> _forceReset() async {
    if (_resetting) return;
    setState(() => _resetting = true);
    final target = _currentUrl.isNotEmpty ? _currentUrl : _urlController.text.trim();
    final reloadUri = target.isEmpty ? null : Uri.tryParse(target);
    try {
      final cleared = await _resetWebsiteData();
      // 换控制器 == 换 WebView 实例：旧实例连同它的渲染进程、内存缓存、正在跑的页内
      // 脚本一起销毁（新实例的 configuration 也拿不到旧实例那份 WKUserScript）
      _handledRedirects.clear();
      _markerChain = null;
      setState(() {
        _viewEpoch++;
        _controller = _newController();
      });
      AppLog.instance.info('browser',
          '强制重置浏览器状态：$target（清缓存=${cleared ? 'ok' : '未生效'}）');
      _toast(cleared ? '已重建浏览器，正在重新加载' : '已重建浏览器实例（缓存清理未生效）');
      // 等这一帧把旧 WebView 平台视图真正拆掉，再动新实例：早了的话原生按视图树找到的
      // 还是旧实例，WKUserScript 会装进正在销毁的那个，新页面反而没角标
      //（和 v0.3.5 修的「刷新后角标不出」同一个坑）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _earlySnifferInstalled = false;
        _earlySnifferTries = 0;
        _installEarlyScripts();
        // 装脚本只是一次通道往返，给它 250ms，别让重置卡在白屏上。
        // 真没装上也不影响正确性：onPageStarted/onPageFinished 的 runJavaScript 照样注入，
        // 且 _installEarlyScripts 自身会重试，下一次导航起 WKUserScript 就位。
        Timer(const Duration(milliseconds: 250), () {
          if (!mounted) return;
          final uri = reloadUri;
          if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
            _urlController.text = uri.toString();
            _controller.loadRequest(uri);
          }
          // 进度条走到「新实例真的开始加载」为止，而不是 setState 一结束就灭
          _endReset();
        });
      });
    } catch (e, st) {
      AppLog.instance.warn('browser', '强制重置浏览器状态失败', e, st);
      _toast('重置失败，详情见日志');
      _endReset();
    }
  }

  /// 结束重置态（进度条 + 菜单项禁用）
  void _endReset() {
    if (mounted && _resetting) setState(() => _resetting = false);
  }

  /// 限时跑一步重置：WebView 假死时这些调用可能永远不返回，
  /// 卡在任何一步上都等于「重置按钮也没用」—— 超时/异常只记日志，继续往下走。
  Future<void> _timebox(Future<void> Function() op, String step) async {
    try {
      await op().timeout(const Duration(milliseconds: 1500));
    } catch (e) {
      AppLog.instance.warn('browser', '重置：$step 未完成，跳过继续', e);
    }
  }

  /// iOS：原生侧注销 ServiceWorker + 清 HTTP 缓存（保留 Cookie），返回是否清成功。
  /// 非 iOS 无此桥接 → 只做页内注销，重建实例那一步照样有效。
  ///
  /// 「桥没成功」的形态不止一种：通道未注册抛 MissingPluginException、原生侧执行报错、
  /// 假死导致超时、回包为空。这些都同一条兜底路 —— 页内自己注销。以前只认
  /// MissingPluginException，于是 iOS 上一次桥失败就等于静默放弃了 ServiceWorker 清理，
  /// 而它正是「刷新也治不好」那半条成因。
  Future<bool> _resetWebsiteData() async {
    String? status;
    try {
      // 回包是状态串（sw=页内注销结果 cache=清缓存），出问题时日志能分清哪步没成
      status = await _sniffBridge
          .invokeMethod<String>('resetWebsiteData', [_serviceWorkerCleanupJs])
          .timeout(const Duration(seconds: 8));
    } on TimeoutException {
      AppLog.instance.warn('browser', '重置：原生清缓存超时，改走页内注销 + 重建 WebView');
    } catch (e, st) {
      AppLog.instance.warn('browser', '重置：原生清网站数据不可用，改走页内注销', e, st);
    }
    if (status != null) {
      AppLog.instance.info('browser', '重置：原生清网站数据 $status');
      return true;
    }
    await _timebox(
        () => _controller.runJavaScript(_serviceWorkerCleanupJs), '注销 ServiceWorker');
    return false;
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
                  _toast('点播放即接管：已开启');
                }
              } else if (v == 'forcereset') {
                _confirmForceReset();
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
              const PopupMenuDivider(),
              // 不是开关，是一次性动作：页面加载一半卡住、刷新无效时用（见 _forceReset）
              PopupMenuItem(
                value: 'forcereset',
                enabled: !_resetting,
                child: Row(
                  children: [
                    Icon(
                      _resetting ? Icons.hourglass_top : Icons.autorenew,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(_resetting ? '正在重置…' : '强制重置浏览器状态'),
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
          // 重置要清缓存 + 重建实例，耗时可见（避免看起来「点了没反应」）
          if (_resetting) const LinearProgressIndicator(minHeight: 2),
          // 页内角标（video_marker.js）是唯一的视频入口，不再额外挂底部列表
          // key：强制重置时靠换 key 让 Flutter 拆掉旧 WebView 平台视图，换新实例
          Expanded(
            child: WebViewWidget(
              key: ValueKey(_viewEpoch),
              controller: _controller,
            ),
          ),
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
