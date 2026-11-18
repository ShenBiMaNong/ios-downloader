import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:video_downloader/services/download_manager.dart';
import 'package:video_downloader/services/hls_manager.dart';

/// 假平台：getApplicationDocumentsDirectory 指向测试临时目录
class _FakePathProvider extends PathProviderPlatform {
  final Directory docs;
  _FakePathProvider(this.docs);

  @override
  Future<String?> getApplicationDocumentsPath() async => docs.path;

  @override
  Future<String?> getApplicationSupportPath() async => docs.path;

  @override
  Future<String?> getTemporaryPath() async =>
      Directory.systemTemp.createTempSync('dm_pause_tmp_').path;

  @override
  Future<String?> getApplicationCachePath() async => docs.path;

  @override
  Future<String?> getDownloadsPath() async => docs.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;
  late Directory downloads;

  setUp(() async {
    docs = Directory.systemTemp.createTempSync('dm_pause_');
    downloads = Directory(p.join(docs.path, 'Downloads'));
    await downloads.create(recursive: true);
    PathProviderPlatform.instance = _FakePathProvider(docs);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('video_downloader/hls'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('video_downloader/hls/events'), null);
    if (await docs.exists()) await docs.delete(recursive: true);
  });

  test('mp4 断点任务重启恢复为「已暂停」；取消时清理 .part 与断点记录', () async {
    // 上次中断留下的断点：pending.json + 半截 .part
    final part = File(p.join(downloads.path, '半截视频.part'));
    await part.writeAsBytes(List.filled(1024, 1));
    const id = '1000000000000';
    await File(p.join(downloads.path, '$id.pending.json'))
        .writeAsString(jsonEncode({
          'id': id,
          'url': 'https://a.com/v.mp4',
          'title': '半截视频',
          'kind': 'mp4',
          'part': part.path,
          'startedAt': DateTime.now().toIso8601String(),
        }));

    await DownloadManager.instance.ensureLoaded();

    final task = DownloadManager.instance.tasks.firstWhere((t) => t.id == id);
    expect(task.status, DownloadStatus.paused, reason: '断点任务应恢复为已暂停');
    expect(task.canResume, isTrue, reason: '有 .part 的暂停任务应可继续下载');
    expect(task.error, '已暂停，可继续下载');

    // 取消（放弃续传）：条目、.part、断点记录全部清理
    await DownloadManager.instance.cancel(id);
    expect(DownloadManager.instance.tasks.any((t) => t.id == id), isFalse,
        reason: '取消后任务应移出列表');
    expect(await File(p.join(downloads.path, '$id.pending.json')).exists(),
        isFalse, reason: '取消后断点记录应删除');
    expect(await part.exists(), isFalse, reason: '取消后 .part 应删除');
  });

  test('HLS 手动暂停：保留断点记录、原生中断不误标失败；继续/取消正常', () async {
    final channel = const MethodChannel('video_downloader/hls');
    final eventChannel = const EventChannel('video_downloader/hls/events');
    final methodCalls = <String>[];
    final sink = <MockStreamHandlerEventSink?>[null];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      methodCalls.add(call.method);
      switch (call.method) {
        case 'restore':
          return <dynamic>[];
        case 'cancel':
        case 'retry':
          return true;
        default:
          return null;
      }
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(
        onListen: (args, events) {
          sink[0] = events;
        },
        onCancel: (args) {},
      ),
    );

    // 上次中断留下的 HLS 断点记录
    const taskId = 'hls1';
    await File(p.join(downloads.path, '$taskId.hls.json'))
        .writeAsString(jsonEncode({
          'taskId': taskId,
          'url': 'https://a.com/playlist.m3u8',
          'title': 'HLS 视频',
          'startedAt': DateTime.now().toIso8601String(),
        }));

    await HlsManager.instance.ensureLoaded();
    final task = HlsManager.instance.tasks.firstWhere((t) => t.taskId == taskId);
    expect(task.paused, isTrue, reason: '断点恢复的任务应标记为已暂停');
    expect(task.resumable, isTrue);
    expect(methodCalls, contains('restore'));

    // 继续下载 → 恢复进行中
    await HlsManager.instance.retry(taskId);
    expect(task.paused, isFalse);
    expect(task.failed, isFalse);

    // 手动暂停 → 原生 cancel 被调用，断点记录保留
    await HlsManager.instance.pause(taskId);
    expect(task.paused, isTrue);
    expect(methodCalls, contains('cancel'));
    expect(await File(p.join(downloads.path, '$taskId.hls.json')).exists(),
        isTrue, reason: '暂停后断点记录必须保留（重启可继续）');

    // 原生中断事件（done=false）不应把暂停任务标成失败
    sink[0]?.success({'taskId': taskId, 'progress': 0.3, 'done': false});
    await Future<void>.delayed(Duration.zero);
    expect(task.failed, isFalse, reason: '暂停触发的原生中断不能显示为失败');
    expect(task.paused, isTrue);

    // 暂停后再继续 → 恢复
    await HlsManager.instance.retry(taskId);
    expect(task.paused, isFalse);

    // 取消（放弃续传）→ 条目移除 + 断点记录删除
    await HlsManager.instance.cancel(taskId);
    expect(HlsManager.instance.tasks.any((t) => t.taskId == taskId), isFalse,
        reason: '取消后 HLS 任务应移出列表');
    expect(await File(p.join(downloads.path, '$taskId.hls.json')).exists(),
        isFalse, reason: '取消后 HLS 断点记录应删除');
  });
}
