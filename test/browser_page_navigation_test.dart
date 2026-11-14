// 内置浏览器页的行为用例：地址栏跟随 + 自动播放拦截注入
//
// 用假的 WebView 平台实现替换真实 WebView（真实 WebView 在测试环境不存在），
// 由测试手动触发 onPageStarted / onUrlChange 回调，检查地址栏文本是否跟着变化。
// 这正是本轮修复的 bug：此前只有用户手输地址才更新地址栏，页内跳转 / SPA 路由变化都不更新。
//
// ignore_for_file: depend_on_referenced_packages, invalid_use_of_protected_member
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'package:video_downloader/pages/browser_page.dart';
import 'package:video_downloader/services/app_data.dart';
import 'package:video_downloader/services/app_settings.dart';

class _FakeWebViewPlatform extends WebViewPlatform {
  _FakeController? controller;
  _FakeDelegate? delegate;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final c = _FakeController(params);
    controller = c;
    return c;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) {
    final d = _FakeDelegate(params);
    delegate = d;
    return d;
  }

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) =>
      _FakeWidget(params);
}

class _FakeWidget extends PlatformWebViewWidget {
  _FakeWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _FakeController extends PlatformWebViewController {
  _FakeController(super.params) : super.implementation();

  final List<String> jsCalls = [];
  final List<String> loaded = [];
  final Map<String, void Function(JavaScriptMessage)> channels = {};
  final List<String> navOps = [];
  _FakeDelegate? delegate;
  String title = '测试页标题';

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(PlatformNavigationDelegate handler) async {
    delegate = handler as _FakeDelegate;
  }

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {}

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    loaded.add(params.uri.toString());
  }

  @override
  Future<void> runJavaScript(String javaScript) async {
    jsCalls.add(javaScript);
  }

  @override
  Future<String?> getTitle() async => title;

  @override
  Future<void> reload() async {}

  @override
  Future<void> goBack() async {
    navOps.add('back');
  }

  @override
  Future<void> goForward() async {
    navOps.add('forward');
  }
}

class _FakeDelegate extends PlatformNavigationDelegate {
  _FakeDelegate(super.params) : super.implementation();

  PageEventCallback? pageStarted;
  PageEventCallback? pageFinished;
  UrlChangeCallback? urlChange;
  WebResourceErrorCallback? webResourceError;

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {
    pageStarted = onPageStarted;
  }

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {
    pageFinished = onPageFinished;
  }

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async {
    urlChange = onUrlChange;
  }

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback onWebResourceError) async {
    webResourceError = onWebResourceError;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeWebViewPlatform platform;

  setUp(() {
    platform = _FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
    // 固定为空白启动页，避免启动流程把地址栏填成默认首页
    AppSettings.instance.browserStartPage = BrowserStartPage.blank;
    AppData.instance.lastUrl = '';
    AppData.instance.blockAutoplayEnabled = true;
  });

  String addressBarText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  /// 首帧要在真实异步环境里 pump：initState 会读 assets（script 源），
  /// 这类 IO 在 fake-async zone 里不会完成，之后注入时就会永远挂住
  Future<void> pumpBrowser(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: BrowserPage()));
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    await tester.pumpAndSettle();
  }

  /// 注入脚本要读 asset（真实异步 IO），pumpAndSettle 不会推进这类 Future，
  /// 用 runAsync 让出事件循环轮询到条件成立
  Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 25; i++) {
      if (ready()) return;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  testWidgets('页内跳转（onPageStarted）时地址栏跟着变', (tester) async {
    await pumpBrowser(tester);
    expect(addressBarText(tester), '');

    platform.delegate!.pageStarted!('https://a.example/list');
    await tester.pumpAndSettle();
    expect(addressBarText(tester), 'https://a.example/list');

    platform.delegate!.pageStarted!('https://a.example/detail?id=2');
    await tester.pumpAndSettle();
    expect(addressBarText(tester), 'https://a.example/detail?id=2');
  });

  testWidgets('SPA 路由变化（onUrlChange）时地址栏跟着变', (tester) async {
    await pumpBrowser(tester);

    platform.delegate!.pageStarted!('https://spa.example/');
    await tester.pumpAndSettle();
    expect(addressBarText(tester), 'https://spa.example/');

    // pushState 不触发整页导航，只有 onUrlChange 会来
    platform.delegate!.urlChange!(const UrlChange(url: 'https://spa.example/watch/9'));
    await tester.pumpAndSettle();
    expect(addressBarText(tester), 'https://spa.example/watch/9');
  });

  testWidgets('用户正在输入地址时，页面变化不覆盖他写的内容', (tester) async {
    await pumpBrowser(tester);

    platform.delegate!.pageStarted!('https://a.example/x');
    await tester.pumpAndSettle();
    expect(addressBarText(tester), 'https://a.example/x');

    await tester.tap(find.byType(TextField));
    await tester.pump();

    platform.delegate!.urlChange!(const UrlChange(url: 'https://a.example/y'));
    await tester.pumpAndSettle();
    expect(addressBarText(tester), 'https://a.example/x');
  });

  testWidgets('允许自动播放（开关关）时注入的是放行指令而不是拦截脚本', (tester) async {
    AppData.instance.blockAutoplayEnabled = false;
    await pumpBrowser(tester);

    platform.delegate!.pageStarted!('https://a.example/x');
    await tester.pumpAndSettle();
    await waitFor(
      tester,
      () => platform.controller!.jsCalls.any((s) => s.contains('__vdlNoAutoplaySetEnabled(false)')),
    );

    final js = platform.controller!.jsCalls;
    expect(
      js.any((s) => s.contains('__vdlNoAutoplaySetEnabled(false)')),
      isTrue,
      reason: '关闭开关时应把原型方法还原，而不是注入拦截脚本',
    );
    expect(
      js.any((s) => s.contains('__vdlNoAutoplayInstalled = true')),
      isFalse,
      reason: '关闭开关时不应注入拦截脚本本体',
    );
  });

  testWidgets('开启自动播放拦截时会注入脚本本体', (tester) async {
    await pumpBrowser(tester);

    platform.delegate!.pageStarted!('https://a.example/x');
    await tester.pumpAndSettle();
    await waitFor(
      tester,
      () => platform.controller!.jsCalls.any((s) => s.contains('__vdlNoAutoplayInstalled')),
    );

    final js = platform.controller!.jsCalls;
    expect(js.any((s) => s.contains('__vdlNoAutoplayInstalled')), isTrue);
    expect(js.any((s) => s.contains('window.__vdlNoAutoplayEnabled=true')), isTrue);
  });

  testWidgets('加载页面时注入手势脚本本体', (tester) async {
    await pumpBrowser(tester);
    platform.delegate!.pageStarted!('https://a.example/x');
    await tester.pumpAndSettle();
    await waitFor(
      tester,
      () => platform.controller!.jsCalls.any((s) => s.contains('__vdlSwipeInstalled')),
    );
    expect(
      platform.controller!.jsCalls.any((s) => s.contains('__vdlSwipeInstalled')),
      isTrue,
      reason: '手势脚本（browser_swipe.js）应随页面注入',
    );
  });

  testWidgets('手势通道：右滑=后退、左滑=前进', (tester) async {
    await pumpBrowser(tester);
    platform.delegate!.pageStarted!('https://a.example/x');
    await tester.pumpAndSettle();

    final ch = platform.controller!.channels['browserGesture'];
    expect(ch, isNotNull, reason: '应注册 browserGesture 通道');

    ch!(JavaScriptMessage(
        message: '{"action":"swipe","direction":"back","url":"https://a.example/x"}'));
    ch(JavaScriptMessage(
        message: '{"action":"swipe","direction":"forward","url":"https://a.example/x"}'));
    expect(platform.controller!.navOps, ['back', 'forward']);
  });

  testWidgets('手势通道收到非法消息时不崩溃、不导航', (tester) async {
    await pumpBrowser(tester);
    final ch = platform.controller!.channels['browserGesture'];
    expect(ch, isNotNull);

    ch!(JavaScriptMessage(message: 'not json'));
    ch(JavaScriptMessage(message: '{"action":"other"}'));
    ch(JavaScriptMessage(message: '{"action":"swipe","direction":"up"}'));
    expect(platform.controller!.navOps, isEmpty);
  });
}
