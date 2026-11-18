// 浏览器启动页 =「上次打开页」的回归用例
//
// 曾经的 bug：AppData.ensureLoaded() 用 bool 标记「已开始加载」而不是「已加载完」。
// 浏览器页 initState 里 `_installEarlyScripts()` 先发起加载，紧接着
// `_initStartPage()` 再调一次 —— 第二个调用者立刻返回，读到还是空串的 lastUrl，
// 于是回落到默认首页 bilibili；随后 onPageStarted 又把 bilibili 存成 lastUrl，
// 从此每次启动都停在 bilibili。
//
// ignore_for_file: depend_on_referenced_packages, invalid_use_of_protected_member
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'package:video_downloader/pages/browser_page.dart';
import 'package:video_downloader/services/app_data.dart';
import 'package:video_downloader/services/app_settings.dart';

/// 假平台：getApplicationDocumentsDirectory 指向测试临时目录
class _FakePathProvider extends PathProviderPlatform {
  final Directory docs;
  _FakePathProvider(this.docs);

  @override
  Future<String?> getApplicationDocumentsPath() async => docs.path;

  @override
  Future<String?> getApplicationSupportPath() async => docs.path;

  @override
  Future<String?> getTemporaryPath() async => docs.path;

  @override
  Future<String?> getApplicationCachePath() async => docs.path;

  @override
  Future<String?> getDownloadsPath() async => docs.path;
}

class _FakeWebViewPlatform extends WebViewPlatform {
  _FakeController? controller;

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
  ) =>
      _FakeDelegate(params);

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

  final List<String> loaded = [];

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(PlatformNavigationDelegate handler) async {}

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {}

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    loaded.add(params.uri.toString());
  }

  @override
  Future<void> runJavaScript(String javaScript) async {}

  @override
  Future<String?> getTitle() async => '';

  @override
  Future<void> reload() async {}

  @override
  Future<void> goBack() async {}

  @override
  Future<void> goForward() async {}
}

class _FakeDelegate extends PlatformNavigationDelegate {
  _FakeDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {}

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async {}

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback onWebResourceError) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;

  setUp(() {
    docs = Directory.systemTemp.createTempSync('browser_start_page_');
    PathProviderPlatform.instance = _FakePathProvider(docs);
  });

  tearDown(() {
    try {
      docs.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('并发调用 ensureLoaded：后到者必须等读盘完成，不能拿到空 lastUrl', () async {
    final dir = Directory(p.join(docs.path, 'AppData'));
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'appdata.json'))
        .writeAsString(jsonEncode({'lastUrl': 'https://example.com/watch/42'}));

    // 模拟 initState 里的并发：早期脚本注入先发起，启动页恢复紧随其后
    final first = AppData.instance.ensureLoaded();
    final second = AppData.instance.ensureLoaded();
    await second;

    expect(
      AppData.instance.lastUrl,
      'https://example.com/watch/42',
      reason: '第二个调用者提前返回就会读到空串，启动页回落到 bilibili',
    );
    await first;
  });

  /// 轮询等待真实异步完成：testWidgets 跑在 fake-async zone 里，
  /// 只有让出到 runAsync 并 pump，资产读取 / 文件 IO 的后续才会被推进
  /// （与 browser_page_navigation_test 里的 waitFor 同一做法）
  Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 50; i++) {
      if (ready()) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  testWidgets('冷启动按设置恢复上次打开页，而不是默认首页 bilibili', (tester) async {
    // 存档必须用同步 API 写：testWidgets 的 body 在 fake-async zone 里执行，
    // 真实文件 IO 的异步后续不会自己完成，`await dir.create(...)` 会一直挂到
    // 10 分钟框架超时（CI 上就是这么超时的，不是断言失败）
    final dir = Directory(p.join(docs.path, 'AppData'));
    dir.createSync(recursive: true);
    File(p.join(dir.path, 'appdata.json'))
        .writeAsStringSync(jsonEncode({'lastUrl': 'https://example.com/watch/42'}));

    final platform = _FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
    AppSettings.instance.browserStartPage = BrowserStartPage.lastPage;

    // 首帧也在真实异步环境里 pump：initState 会读 assets / appdata.json
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: BrowserPage()));
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    // 不再用 pumpAndSettle 兜底：存档加载若没走完，settle 只会空转，
    // 用有界轮询把失败落成一条可读的断言
    await waitFor(
      tester,
      () => platform.controller != null && platform.controller!.loaded.isNotEmpty,
    );

    expect(platform.controller!.loaded, isNotEmpty, reason: '启动页应发起一次加载');
    expect(
      platform.controller!.loaded.first,
      'https://example.com/watch/42',
      reason: '存档有 lastUrl 时不能加载默认首页',
    );
    final bar = tester.widget<TextField>(find.byType(TextField));
    expect(bar.controller!.text, 'https://example.com/watch/42');
  });

  test('空白页（about:blank）不会污染「上次打开页」存档', () async {
    AppData.instance.lastUrl = 'https://example.com/watch/42';
    await AppData.instance.setLastUrl('about:blank');
    expect(AppData.instance.lastUrl, 'https://example.com/watch/42');
  });
}
