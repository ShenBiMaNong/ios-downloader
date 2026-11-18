import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:video_downloader/services/download_manager.dart';
import 'package:video_downloader/services/local_media_path.dart';
import 'package:video_downloader/services/mp4_probe.dart';

/// 假平台：Documents 指向测试临时目录（与 library_operations_test 同一套路）
class _FakePathProvider extends PathProviderPlatform {
  final Directory docs;
  _FakePathProvider(this.docs);

  @override
  Future<String?> getApplicationDocumentsPath() async => docs.path;

  @override
  Future<String?> getApplicationSupportPath() async => docs.path;

  @override
  Future<String?> getApplicationCachePath() async => docs.path;

  @override
  Future<String?> getTemporaryPath() async => docs.path;

  @override
  Future<String?> getDownloadsPath() async => docs.path;
}

/// 一个 ISO-BMFF 文件头：size + 'ftyp' + major brand
List<int> ftypHead() => [
      0, 0, 0, 0x20, // box size = 32
      ...'ftyp'.codeUnits,
      ...'isom'.codeUnits,
      0, 0, 0, 2,
      ...'isom'.codeUnits,
      ...'mp42'.codeUnits,
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('remapToDocuments', () {
    test('容器 UUID 变了：按当前 Documents 重挂，保留 Documents 以内的结构', () {
      expect(
        remapToDocuments(
          '/var/mobile/Containers/Data/Application/OLD-UUID/Documents/Downloads/a.mp4',
          '/var/mobile/Containers/Data/Application/NEW-UUID/Documents',
        ),
        '/var/mobile/Containers/Data/Application/NEW-UUID/Documents/Downloads/a.mp4',
      );
    });

    test('路径里没有 Documents：不做翻译', () {
      expect(remapToDocuments('/private/var/tmp/a.mp4', '/x/Documents'), isNull);
    });

    test('已经在当前 Documents 下：返回 null（没有位移可修）', () {
      expect(
        remapToDocuments('/x/Documents/Downloads/a.mp4', '/x/Documents'),
        isNull,
      );
    });

    test('Documents 后面是空串：返回 null', () {
      expect(remapToDocuments('/old/Documents', '/x/Documents'), isNull);
    });
  });

  group('planRelocation', () {
    const docs = '/new/Documents';
    const stale = '/old/Documents/Downloads/a.mp4';
    const fresh = '/new/Documents/Downloads/a.mp4';

    test('原路径还在 → same，不做任何位移', () {
      final r = planRelocation(
        stored: stale,
        documentsPath: docs,
        exists: (path) => path == stale,
      );
      expect(r!.kind, Relocation.same);
      expect(r.path, stale);
    });

    test('原路径失效、改挂当前 Documents 命中 → remapped', () {
      final r = planRelocation(
        stored: stale,
        documentsPath: docs,
        exists: (path) => path == fresh,
      );
      expect(r!.kind, Relocation.remapped);
      expect(r.path, fresh);
    });

    test('连 Documents 结构也变了 → 按文件名回查命中 foundByName', () {
      final r = planRelocation(
        stored: '/old/Documents/Downloads/deep/a.mp4',
        documentsPath: docs,
        exists: (path) => path == '/new/Documents/Share/a.mp4',
        findByBasename: (base) => base == 'a.mp4' ? '/new/Documents/Share/a.mp4' : null,
      );
      expect(r!.kind, Relocation.foundByName);
      expect(r.path, '/new/Documents/Share/a.mp4');
    });

    test('三条都不中 → null（文件真不在，不猜）', () {
      expect(
        planRelocation(
          stored: stale,
          documentsPath: docs,
          exists: (_) => false,
          findByBasename: (_) => null,
        ),
        isNull,
      );
    });

    test('回查命中的路径本身不存在时不采纳', () {
      expect(
        planRelocation(
          stored: stale,
          documentsPath: docs,
          exists: (_) => false,
          findByBasename: (_) => '/nowhere/a.mp4',
        ),
        isNull,
      );
    });

    test('空路径 → null', () {
      expect(
        planRelocation(stored: '', documentsPath: docs, exists: (_) => true),
        isNull,
      );
    });
  });

  group('looksLikeMp4Head', () {
    test('ftyp 起头认得', () {
      expect(looksLikeMp4Head(ftypHead()), isTrue);
    });

    test('moov / mdat / free 起头也算 ISO-BMFF', () {
      for (final type in ['moov', 'mdat', 'free']) {
        expect(
          looksLikeMp4Head([0, 0, 0, 8, ...type.codeUnits, 0, 0, 0, 0]),
          isTrue,
          reason: type,
        );
      }
    });

    test('HTML 错误页不是视频', () {
      expect(looksLikeMp4Head('<!DOCTYPE html>'.codeUnits), isFalse);
    });

    test('裸 TS 分片（0x47 同步字节）不是视频容器头', () {
      final ts = List<int>.filled(188, 0);
      ts[0] = 0x47;
      ts[1] = 0x40;
      ts[2] = 0x00;
      ts[3] = 0x10;
      expect(looksLikeMp4Head(ts), isFalse);
    });

    test('不足 8 字节判不了', () {
      expect(looksLikeMp4Head([0, 0, 0]), isFalse);
    });
  });

  group('preflightLocalFile', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('preflight_'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('路径为空 → emptyPath', () {
      expect(preflightLocalFile(''), LocalFileIssue.emptyPath);
    });

    test('文件不存在 → missing（用户看到的不是「损坏」而是「不在了」）', () {
      expect(
        preflightLocalFile(p.join(tmp.path, 'nope.mp4')),
        LocalFileIssue.missing,
      );
    });

    test('0 字节 → empty', () {
      final f = File(p.join(tmp.path, 'e.mp4'))..createSync();
      expect(preflightLocalFile(f.path), LocalFileIssue.empty);
    });

    test('有内容但不是 mp4 → notVideo', () {
      final f = File(p.join(tmp.path, 'x.mp4'))
        ..writeAsBytesSync('<!DOCTYPE html><html>'.codeUnits);
      expect(preflightLocalFile(f.path), LocalFileIssue.notVideo);
    });

    test('正常 mp4 头 → none，且不把文件读进内存整份', () {
      final bytes = <int>[...ftypHead(), ...List.filled(4096, 7)];
      final f = File(p.join(tmp.path, 'ok.mp4'))..writeAsBytesSync(bytes);
      expect(preflightLocalFile(f.path), LocalFileIssue.none);
    });

    test('目录型产物不在预检职责内 → none', () {
      final d = Directory(p.join(tmp.path, 'pkg'))..createSync();
      expect(preflightLocalFile(d.path), LocalFileIssue.none);
    });

    test('missing 有可读说法，none 不覆盖通用文案', () {
      expect(localIssueText(LocalFileIssue.missing), contains('不在原路径'));
      expect(localIssueText(LocalFileIssue.none), isNull);
    });
  });

  group('scanSaved 路径自愈', () {
    late Directory docs;
    late Directory downloads;

    setUp(() async {
      docs = Directory.systemTemp.createTempSync('lm_docs_');
      downloads = Directory(p.join(docs.path, 'Downloads'))
        ..createSync(recursive: true);
      PathProviderPlatform.instance = _FakePathProvider(docs);
    });
    tearDown(() {
      if (docs.existsSync()) docs.deleteSync(recursive: true);
    });

    /// 写一条元数据：视频文件放在当前 Downloads 里，但记录的路径指向别的容器
    Future<void> seed({
      required String id,
      required String fileName,
      required String storedPath,
    }) async {
      File(p.join(downloads.path, fileName)).writeAsBytesSync(ftypHead());
      File(p.join(downloads.path, '$id.json')).writeAsStringSync(jsonEncode({
        'id': id,
        'url': 'https://a.com/v.mp4',
        'title': '标题',
        'kind': 'mp4',
        'localPath': storedPath,
        'folder': '',
        'savedAt': DateTime.now().toIso8601String(),
      }));
    }

    test('重装换了容器：返回修正后的路径并回写元数据', () async {
      await seed(
        id: '111',
        fileName: 'a.mp4',
        storedPath: '/var/OLD-UUID/Documents/Downloads/a.mp4',
      );
      final saved = await DownloadManager.instance.scanSaved();
      final item = saved.firstWhere((m) => m['id'] == '111');
      expect(p.equals(item['localPath'] as String, p.join(downloads.path, 'a.mp4')),
          isTrue,
          reason: '应指向当前容器里的同名文件：${item['localPath']}');
      // 回写：下次冷启动不必再重定位一遍
      final rewritten = jsonDecode(
        File(p.join(downloads.path, '111.json')).readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(
          p.equals(rewritten['localPath'] as String,
              p.join(downloads.path, 'a.mp4')),
          isTrue);
      // 其余字段不能被写坏
      expect(rewritten['title'], '标题');
      expect(rewritten['kind'], 'mp4');
    });

    test('文件真被删了：保持原路径，交回上层报「找不到文件」', () async {
      await seed(
        id: '222',
        fileName: 'b.mp4',
        storedPath: '/var/OLD-UUID/Documents/Downloads/gone.mp4',
      );
      final saved = await DownloadManager.instance.scanSaved();
      final item = saved.firstWhere((m) => m['id'] == '222');
      expect(item['localPath'], '/var/OLD-UUID/Documents/Downloads/gone.mp4');
    });

    test('路径本来就有效：不动、不改写', () async {
      final ok = p.join(downloads.path, 'c.mp4');
      await seed(id: '333', fileName: 'c.mp4', storedPath: ok);
      final meta = File(p.join(downloads.path, '333.json'));
      final before = meta.readAsStringSync();
      final saved = await DownloadManager.instance.scanSaved();
      expect(
          p.equals(saved.firstWhere((m) => m['id'] == '333')['localPath'] as String,
              ok),
          isTrue);
      expect(meta.readAsStringSync(), before);
    });
  });
}
