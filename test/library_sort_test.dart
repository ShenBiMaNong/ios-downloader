import 'package:flutter_test/flutter_test.dart';
import 'package:video_downloader/models/library_item.dart';

LibraryItem _item(String id, String name, int size, DateTime created) {
  return LibraryItem(
    id: id,
    title: name,
    size: size,
    created: created,
    kind: 'mp4',
    active: false,
    failed: false,
    progress: 1,
  );
}

void main() {
  final base = DateTime(2026, 11, 1, 12);
  final items = [
    _item('1', 'b视频', 200, base.add(const Duration(days: 1))),
    _item('2', 'a视频', 500, base),
    _item('3', 'c视频', 100, base.add(const Duration(days: 3))),
  ];

  test('按创建时间倒序（默认场景）', () {
    final r = LibraryItem.sort(items, SortField.created, true);
    expect(r.map((e) => e.id).toList(), ['3', '1', '2']);
  });

  test('按名称正序', () {
    final r = LibraryItem.sort(items, SortField.name, false);
    expect(r.map((e) => e.title).toList(), ['a视频', 'b视频', 'c视频']);
  });

  test('按名称倒序', () {
    final r = LibraryItem.sort(items, SortField.name, true);
    expect(r.map((e) => e.title).toList(), ['c视频', 'b视频', 'a视频']);
  });

  test('按大小正序', () {
    final r = LibraryItem.sort(items, SortField.size, false);
    expect(r.map((e) => e.size).toList(), [100, 200, 500]);
  });

  test('按大小倒序', () {
    final r = LibraryItem.sort(items, SortField.size, true);
    expect(r.map((e) => e.size).toList(), [500, 200, 100]);
  });

  test('格式化：大小与网速', () {
    expect(formatBytes(0), '');
    expect(formatBytes(2048), '2 KB');
    expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
    expect(formatSpeed(3 * 1024 * 1024), '3.0 MB/s');
    expect(formatSpeed(512 * 1024), '512 KB/s');
  });
}
