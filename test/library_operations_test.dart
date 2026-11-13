import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:video_downloader/services/download_manager.dart';
import 'package:video_downloader/services/m3u8_convert.dart';

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
      Directory.systemTemp.createTempSync('dm_repro_tmp_').path;

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
    docs = Directory.systemTemp.createTempSync('dm_repro_');
    downloads = Directory(p.join(docs.path, 'Downloads'));
    await downloads.create(recursive: true);
    PathProviderPlatform.instance = _FakePathProvider(docs);
  });

  tearDown(() async {
    if (await docs.exists()) await docs.delete(recursive: true);
  });

  Future<String> seedMeta({
    required String id,
    required String title,
    required String fileName,
  }) async {
    final file = File(p.join(downloads.path, fileName));
    await file.writeAsBytes(List.filled(100, 1));
    await File(p.join(downloads.path, '$id.json')).writeAsString(jsonEncode({
      'id': id,
      'url': 'https://a.com/v.mp4',
      'title': title,
      'kind': 'mp4',
      'localPath': file.path,
      'folder': '',
      'savedAt': DateTime.now().toIso8601String(),
    }));
    return file.path;
  }

  test('重命名（普通 mp4）：改文件名 + 元数据 + 内存任务同步', () async {
    final id = '1111111111111';
    final oldPath = await seedMeta(
        id: id, title: '旧名字', fileName: '旧名字.mp4');

    final ok = await DownloadManager.instance.rename(id, '新名字');
    expect(ok, isTrue, reason: '普通 mp4 重命名应当成功');

    final meta = jsonDecode(
        await File(p.join(downloads.path, '$id.json')).readAsString());
    expect(meta['title'], '新名字');
    expect(meta['localPath'], endsWith('新名字.mp4'));
    expect(File(meta['localPath'] as String).existsSync(), isTrue);
    expect(await File(oldPath).exists(), isFalse,
        reason: '旧文件应被改名');
  });

  test('重命名原样保存：不产生 " (2)" 副本，文件保持原名', () async {
    final id = '2222222222222';
    final oldPath =
        await seedMeta(id: id, title: '原名', fileName: '原名.mp4');

    final ok = await DownloadManager.instance.rename(id, '原名');
    expect(ok, isTrue);
    expect(await File(oldPath).exists(), isTrue,
        reason: '原样保存不应产生 (2) 副本');
    final meta = jsonDecode(
        await File(p.join(downloads.path, '$id.json')).readAsString());
    expect(meta['title'], '原名');
    expect(meta['localPath'], oldPath);
  });

  test('删除：元数据 json 与磁盘文件都应移除', () async {
    final id = '3333333333333';
    final file = File(p.join(downloads.path, '待删.mp4'));
    await file.writeAsBytes(List.filled(100, 1));
    final metaFile = File(p.join(downloads.path, '$id.json'));
    await metaFile.writeAsString(jsonEncode({
      'id': id,
      'url': 'https://a.com/v.mp4',
      'title': '待删',
      'kind': 'mp4',
      'localPath': file.path,
      'folder': '',
      'savedAt': DateTime.now().toIso8601String(),
    }));

    await DownloadManager.instance.delete(id, file.path);
    expect(await metaFile.exists(), isFalse, reason: '元数据 json 应被删除');
    expect(await file.exists(), isFalse, reason: '磁盘文件应被删除');
    expect(DownloadManager.instance.tasks.any((t) => t.id == id), isFalse);
  });

  test('元数据 json 缺失时重命名：不报失败，更新内存任务与磁盘文件', () async {
    final id = '4444444444444';
    final file = File(p.join(downloads.path, '残留.mp4'));
    await file.writeAsBytes(List.filled(100, 1));
    // 模拟「json 已删但内存任务仍在」的残留态（ConvertManager 完成态任务）
    final t = ConvertTask(
        id: id, url: 'https://a.com/v.mp4', title: '残留', mode: 'remote')
      ..localPath = file.path
      ..done = true
      ..progress = 1;
    ConvertManager.instance.tasks.add(t);

    final ok = await DownloadManager.instance.rename(id, '改名');
    expect(ok, isTrue, reason: 'json 缺失时也应当成功（更新内存任务与磁盘文件）');
    expect(t.title, '改名');
    expect(t.localPath, endsWith('改名.mp4'));
    expect(await File(t.localPath!).exists(), isTrue);
  });

  test('转换任务删除：内存任务、元数据 json、产物文件全部清理', () async {
    final id = '5555555555555';
    final file = File(p.join(downloads.path, '转换产物.mp4'));
    await file.writeAsBytes(List.filled(100, 1));
    final metaFile = File(p.join(downloads.path, '$id.json'));
    await metaFile.writeAsString(jsonEncode({
      'id': id,
      'url': 'https://a.com/x.m3u8',
      'title': '转换产物',
      'kind': 'mp4',
      'localPath': file.path,
      'folder': '',
      'savedAt': DateTime.now().toIso8601String(),
    }));
    // 完成态转换任务驻留 ConvertManager 内存列表（与真实行为一致）
    final t = ConvertTask(
        id: id, url: 'https://a.com/x.m3u8', title: '转换产物', mode: 'remote')
      ..localPath = file.path
      ..done = true
      ..progress = 1;
    ConvertManager.instance.tasks.add(t);

    await ConvertManager.instance.delete(id);
    expect(ConvertManager.instance.tasks.any((x) => x.id == id), isFalse,
        reason: '删除后内存任务必须移除，否则列表残留记录');
    expect(await metaFile.exists(), isFalse);
    expect(await file.exists(), isFalse);
  });
}
