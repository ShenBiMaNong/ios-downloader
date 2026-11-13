import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
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

/// 「锁屏 / 灵动岛下载进度」开关的因果链：
/// 设置项 → 落到 app_settings.json → 下发原生 video_downloader/hls#setSilent
///
/// 背景：这条「正在下载 + 转圈」是 iOS 给 AVAssetDownloadTask 非酌情下载自动挂的
/// 实时活动（不是 App 发的通知）。唯一开关是 isDiscretionary：
/// 隐藏通知 ⇒ silent=true（酌情下载）；显示进度 ⇒ silent=false（立即下载）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('video_downloader/hls');
  late Directory docs;
  late List<Object?> setSilentArgs;

  setUp(() async {
    docs = Directory.systemTemp.createTempSync('settings_hls_');
    PathProviderPlatform.instance = _FakePathProvider(docs);
    setSilentArgs = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setSilent') {
        setSilentArgs.add((call.arguments as Map)['silent']);
      }
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    try {
      docs.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('启动时按存档偏好下发原生；切换开关后立即下发并落盘', () async {
    // 存档里是「显示下载进度」= true
    final dir = Directory(p.join(docs.path, 'AppData'));
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'app_settings.json')).writeAsString(jsonEncode({
      'showHlsProgressOnLockScreen': true,
    }));

    await AppSettings.instance.ensureLoaded();

    // ① 启动即同步：显示进度 ⇒ 原生 silent=false
    expect(AppSettings.instance.showHlsProgressOnLockScreen, isTrue);
    expect(setSilentArgs, [false], reason: '设置加载后必须把偏好下发给原生');

    // ② 用户关掉通知 ⇒ 原生 silent=true
    await AppSettings.instance.setShowHlsProgressOnLockScreen(false);
    expect(setSilentArgs, [false, true]);
    expect(AppSettings.instance.showHlsProgressOnLockScreen, isFalse);

    // ③ 落盘（重开 App 仍是关）
    final saved = jsonDecode(
        await File(p.join(dir.path, 'app_settings.json')).readAsString());
    expect((saved as Map)['showHlsProgressOnLockScreen'], isFalse);

    // ④ 重复设置同一值不应再打通道（避免在途任务被无谓重建 session）
    await AppSettings.instance.setShowHlsProgressOnLockScreen(false);
    expect(setSilentArgs, [false, true]);
  });
}
