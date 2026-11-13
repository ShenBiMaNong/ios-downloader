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

  test('文件夹：默认未分组（folder 为空）', () {
    expect(_item('1', 'x', 1, base).folder, '');
  });

  test('文件夹过滤：全部显示所有条目', () {
    final withFolder = [
      ...items,
      LibraryItem(
        id: '4',
        title: 'd视频',
        size: 300,
        created: base,
        kind: 'mp4',
        active: false,
        failed: false,
        progress: 1,
        folder: '教程',
      ),
    ];
    final r = LibraryItem.filterByFolder(withFolder, '');
    expect(r.length, 4);
  });

  test('文件夹过滤：只保留归属该文件夹的条目', () {
    final withFolder = [
      ...items,
      LibraryItem(
        id: '4',
        title: 'd视频',
        size: 300,
        created: base,
        kind: 'mp4',
        active: false,
        failed: false,
        progress: 1,
        folder: '教程',
      ),
      LibraryItem(
        id: '5',
        title: 'e视频',
        size: 400,
        created: base,
        kind: 'mp4',
        active: false,
        failed: false,
        progress: 1,
        folder: '教程',
      ),
    ];
    final r = LibraryItem.filterByFolder(withFolder, '教程');
    expect(r.map((e) => e.id).toList(), ['4', '5']);
  });

  test('分组：未分组在前，组内按排序字段', () {
    final withFolder = [
      LibraryItem(
        id: '1',
        title: 'b视频',
        size: 100,
        created: base,
        kind: 'mp4',
        active: false,
        failed: false,
        progress: 1,
      ),
      LibraryItem(
        id: '2',
        title: 'a视频',
        size: 100,
        created: base,
        kind: 'mp4',
        active: false,
        failed: false,
        progress: 1,
      ),
      LibraryItem(
        id: '3',
        title: 'c视频',
        size: 100,
        created: base,
        kind: 'mp4',
        active: false,
        failed: false,
        progress: 1,
        folder: '教程',
      ),
    ];
    final sections =
        LibraryItem.groupSections(withFolder, ['教程'], SortField.name, false);
    expect(sections.length, 2);
    expect(sections[0].name, '');
    expect(sections[0].items.map((e) => e.id).toList(), ['2', '1']);
    expect(sections[1].name, '教程');
    expect(sections[1].items.map((e) => e.id).toList(), ['3']);
  });

  test('分组：空文件夹不输出分组', () {
    final sections =
        LibraryItem.groupSections(items, ['空文件夹'], SortField.created, true);
    expect(sections.length, 1);
    expect(sections[0].name, '');
  });

  test('分组：内置「分享」文件夹排在用户文件夹前', () {
    final withShare = [
      LibraryItem(
        id: '1',
        title: '分享视频',
        size: 100,
        created: base,
        kind: 'share',
        active: false,
        failed: false,
        progress: 1,
        folder: libraryShareFolderName,
      ),
      ...items,
      LibraryItem(
        id: '2',
        title: '归组视频',
        size: 100,
        created: base,
        kind: 'mp4',
        active: false,
        failed: false,
        progress: 1,
        folder: '教程',
      ),
    ];
    final sections = LibraryItem.groupSections(
        withShare, [libraryShareFolderName, '教程'], SortField.created, true);
    expect(sections.map((s) => s.name).toList(), ['', '分享', '教程']);
    expect(sections[1].items.map((e) => e.id).toList(), ['1']);
  });
}
