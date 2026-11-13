import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_downloader/services/file_names.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('file_names_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('safeFileName 清洗非法字符、压缩空白并限长', () {
    expect(safeFileName('a/b\\c:d*e?f"g<h>i|j'), 'a_b_c_d_e_f_g_h_i_j');
    expect(safeFileName('  视频  名字  '), '视频 名字');
    expect(safeFileName('x' * 200).length, 80);
    expect(safeFileName('   '), startsWith('video_'));
  });

  test('uniqueFileName 同名时追加序号', () {
    File(p.join(dir.path, 'a.mp4')).writeAsStringSync('x');
    expect(uniqueFileName(dir, 'a.mp4'), 'a (2).mp4');
    File(p.join(dir.path, 'a (2).mp4')).writeAsStringSync('x');
    expect(uniqueFileName(dir, 'a.mp4'), 'a (3).mp4');
  });

  test('uniqueFileName 避让进行中的 .part 文件', () {
    File(p.join(dir.path, 'a.mp4.part')).writeAsStringSync('x');
    expect(uniqueFileName(dir, 'a.mp4'), 'a (2).mp4');
  });

  test('uniqueFileName 已存在的目录也视为占用', () {
    Directory(p.join(dir.path, 'b_m3u8')).createSync();
    expect(uniqueFileName(dir, 'b_m3u8'), 'b_m3u8 (2)');
  });
}
