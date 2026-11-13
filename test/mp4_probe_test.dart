import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_downloader/services/mp4_probe.dart';

/// 构造一个 MP4 box：4B 大端 size + 4B fourcc + payloadLen 字节填充
Uint8List _box(String type, [int payloadLen = 0]) {
  final b = BytesBuilder();
  void be32(int v) {
    b.add([(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);
  }

  be32(8 + payloadLen);
  b.add(type.codeUnits); // fourcc 恰为 4 个 ASCII 字符
  for (var i = 0; i < payloadLen; i++) {
    b.addByte(0);
  }
  return b.toBytes();
}

Uint8List _concat(List<List<int>> parts) {
  final b = BytesBuilder();
  for (final p in parts) {
    b.add(p);
  }
  return b.toBytes();
}

void main() {
  group('faststartFromHead', () {
    test('faststart：ftyp → moov → mdat 返回 true', () {
      final head = _concat([_box('ftyp', 4), _box('moov', 8), _box('mdat', 16)]);
      expect(faststartFromHead(head), isTrue);
    });

    test('fMP4：ftyp → moov → moof → mdat 返回 true（moov 前置）', () {
      final head = _concat([_box('ftyp', 4), _box('moov', 8), _box('moof', 8), _box('mdat', 8)]);
      expect(faststartFromHead(head), isTrue);
    });

    test('非 faststart：ftyp → mdat → moov（moov 在尾部）返回 false', () {
      final head = _concat([_box('ftyp', 4), _box('mdat', 16), _box('moov', 8)]);
      expect(faststartFromHead(head), isFalse);
    });

    test('moof 先于 moov（异常布局）返回 false', () {
      final head = _concat([_box('ftyp', 4), _box('moof', 8)]);
      expect(faststartFromHead(head), isFalse);
    });

    test('窗口内仅有 ftyp（无法判定）返回 null', () {
      expect(faststartFromHead(_box('ftyp', 4)), isNull);
    });

    test('空数据返回 null', () {
      expect(faststartFromHead(const []), isNull);
    });

    test('free/wide 等前置 box 不影响判定', () {
      final head = _concat([
        _box('ftyp', 4),
        _box('free', 8),
        _box('wide', 8),
        _box('moov', 8),
        _box('mdat', 16),
      ]);
      expect(faststartFromHead(head), isTrue);
    });
  });
}
