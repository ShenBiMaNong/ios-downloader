// 内置浏览器页的行为用例：地址栏跟随 + 自动播放拦截注入
//
// 用假的 WebView 平台实现替换真实 WebView（真实 WebView 在测试环境不存在），
// 由测试手动触发 onPageStarted / onUrlChange 回调，检查地址栏文本是否跟着变化。
// 这正是本轮修复的 bug：此前只有用户手输地址才更新地址栏，页内跳转 / SPA 路由变化都不更新。
//
// ignore_for_file: depend_on_referenced_packages, invalid_use_of_protected_member
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'package:video_downloader/pages/browser_page.dart';
import 'package:video_downloader/services/app_data.dart';
import 'package:video_downloader/services/app_settings.dart';

class _FakeWebViewPlatform extends WebViewPlatform {
  _FakeController? controller;
  _FakeDelegate? delegate;

  /// 历次创建的控制器（强制重置会换实例，只记最新一个就看不出「有没有重建」）
  final List<_FakeController> controllers = [];

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final c = _FakeController(params);
    controller = c;
    controllers.add(c);
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
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
    // 必须真记下来：产品代码的通道注册走 WebViewController.addJavaScriptChannel
    // → platform.addJavaScriptChannel，fake 不记就等于测试里永远查不到通道。
    channels[params.name] = params.onMessageReceived;
  }

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
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    platform = _FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
    // 固定为空白启动页，避免启动流程把地址栏填成默认首页
    AppSettings.instance.browserStartPage = BrowserStartPage.blank;
    AppData.instance.lastUrl = '';
    AppData.instance.blockAutoplayEnabled = true;
    // 资产改为同步读盘（mock 'flutter/assets' 通道）：真实资产 IO 在 fake-async
    // zone 里的完成时机不稳定，v0.3.8 起脚本变大后 CI 上出现过「脚本等不到注入」。
    // 同步读盘让 loadString 只排一个 microtask，pump 一次就绪，断言不再赌时机。
    messenger.setMockMessageHandler('flutter/assets', (message) async {
      final key = utf8.decode(
        message!.buffer.asUint8List(message.offsetInBytes, message.lengthInBytes),
      );
      final f = File(key);
      if (!f.existsSync()) return null;
      return ByteData.sublistView(f.readAsBytesSync());
    });
  });

  tearDown(() {
    messenger.setMockMessageHandler('flutter/assets', null);
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

  // ── 强制重置浏览器状态（页面加载一半卡住、刷新无效时的自救入口）──────────────
  // 刷新只调 reload()：坏缓存、卡死的渲染进程都动不了。重置必须换掉整个 WebView 实例，
  // 并把当前地址重新加载回去。

  /// 打开「更多」菜单（按类型找，不依赖 tooltip 文案实现）
  Future<void> openMoreMenu(WidgetTester tester) async {
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
  }

  /// 走真实入口：更多 → 强制重置浏览器状态 → 立即重置
  Future<void> tapForceReset(WidgetTester tester) async {
    await openMoreMenu(tester);
    await tester.tap(find.text('强制重置浏览器状态'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('立即重置'));
    await tester.pumpAndSettle();
    // 导航在「重建实例后的一帧 + 250ms」里发出，让假时钟走完
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    // 重置会弹 toast（SnackBar 自带 2s 计时器），不走完测试收尾会报 pending timer
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('强制重置：换掉 WebView 实例并重新加载当前地址', (tester) async {
    await pumpBrowser(tester);
    platform.delegate!.pageStarted!('https://a.example/watch/1');
    await tester.pumpAndSettle();
    expect(addressBarText(tester), 'https://a.example/watch/1');

    final before = platform.controller!;
    expect(platform.controllers.length, 1);

    await tapForceReset(tester);

    expect(
      platform.controllers.length,
      greaterThan(1),
      reason: '应新建 WebViewController（=新平台 WebView 实例），而不是在原实例上 reload',
    );
    final after = platform.controller!;
    expect(identical(after, before), isFalse);
    expect(
      after.loaded,
      contains('https://a.example/watch/1'),
      reason: '重置后要把原地址重新加载回来',
    );
    // 旧实例不该被继续用它发导航
    expect(before.loaded, isNot(contains('https://a.example/watch/1')));
  });

  testWidgets('强制重置时先尽力注销 ServiceWorker（CacheStorage 是刷新修不好的那一类）', (tester) async {
    await pumpBrowser(tester);
    platform.delegate!.pageStarted!('https://a.example/x');
    await tester.pumpAndSettle();

    final before = platform.controller!;
    await tapForceReset(tester);

    // 测试环境没有 iOS 原生桥（MissingPluginException）→ 走 Dart 侧兜底注入，
    // 这段脚本要注销 ServiceWorker + 删光 CacheStorage。注意它跑在「重置前那个实例」上，
    // 所以按实例查会查不到，要看历次控制器的调用记录。
    // 兜底注入前面还挂着一个桥调用（异常回抛要等真实 IO），fake-async 下不会自己走完，
    // 按本文件既有做法用 waitFor 让出事件循环轮询。
    await waitFor(
      tester,
      () => platform.controllers.any((c) =>
          c.jsCalls.any((s) => s.contains('navigator.serviceWorker.getRegistrations'))),
    );
    final js = platform.controllers.expand((c) => c.jsCalls).toList();
    expect(
      js.any((s) =>
          s.contains('navigator.serviceWorker.getRegistrations') &&
          s.contains('caches.keys')),
      isTrue,
      reason: '重置应注销 ServiceWorker 并清空 CacheStorage',
    );
    expect(before.loaded, isNot(contains('https://a.example/x')));
  });

  testWidgets('取消确认框时不重建实例、不导航', (tester) async {
    await pumpBrowser(tester);
    platform.delegate!.pageStarted!('https://a.example/x');
    await tester.pumpAndSettle();
    expect(platform.controllers.length, 1);

    await openMoreMenu(tester);
    await tester.tap(find.text('强制重置浏览器状态'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(platform.controllers.length, 1, reason: '取消就什么都不该动');
    expect(platform.controller!.loaded, isNot(contains('https://a.example/x')));
  });
}
