import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_downloader/models/playable_item.dart';

void main() {
  group('播放顺序索引', () {
    test('顺序模式：下一个向后并循环', () {
      expect(nextPlaylistIndex(0, 4, PlaybackOrder.sequential), 1);
      expect(nextPlaylistIndex(2, 4, PlaybackOrder.sequential), 3);
      expect(nextPlaylistIndex(3, 4, PlaybackOrder.sequential), 0);
    });

    test('顺序模式：上一个向前并循环', () {
      expect(previousPlaylistIndex(0, 4, PlaybackOrder.sequential), 3);
      expect(previousPlaylistIndex(2, 4, PlaybackOrder.sequential), 1);
      expect(previousPlaylistIndex(3, 4, PlaybackOrder.sequential), 2);
    });

    test('乱序模式：不与当前重复且在范围内', () {
      final r = Random(42);
      for (var i = 0; i < 100; i++) {
        final n = nextPlaylistIndex(2, 5, PlaybackOrder.shuffle, r);
        expect(n, inInclusiveRange(0, 4));
        expect(n, isNot(2));
      }
    });

    test('乱序模式：上一个同样不重复', () {
      final r = Random(7);
      for (var i = 0; i < 100; i++) {
        final n = previousPlaylistIndex(2, 5, PlaybackOrder.shuffle, r);
        expect(n, inInclusiveRange(0, 4));
        expect(n, isNot(2));
      }
    });

    test('单条列表：始终回到 0', () {
      expect(nextPlaylistIndex(0, 1, PlaybackOrder.sequential), 0);
      expect(nextPlaylistIndex(0, 1, PlaybackOrder.shuffle, Random(1)), 0);
      expect(previousPlaylistIndex(0, 1, PlaybackOrder.sequential), 0);
      expect(previousPlaylistIndex(0, 1, PlaybackOrder.shuffle, Random(1)), 0);
    });
  });

  test('PlayableItem 字段', () {
    final it = PlayableItem(path: '/tmp/a.mp4', title: '示例');
    expect(it.path, '/tmp/a.mp4');
    expect(it.title, '示例');
  });

  test('PlayableItem 网络源字段（边播边缓存）', () {
    final it = PlayableItem(
      title: '示例',
      url: 'https://example.com/a.mp4',
      playUrl: 'http://127.0.0.1:4612/example.com/a.mp4',
      fallbackUrl: 'https://example.com/a.mp4',
      httpHeaders: const {'Referer': 'https://example.com'},
    );
    expect(it.path, isNull);
    expect(it.url, 'https://example.com/a.mp4');
    expect(it.playUrl, startsWith('http://127.0.0.1'));
    expect(it.fallbackUrl, it.url);
    expect(it.httpHeaders?['Referer'], 'https://example.com');
  });
}
