import 'dart:io';

import 'package:path/path.dart' as p;

/// 文件名清洗：替换非法字符、压缩空白、限长；空名回退为时间戳名。
String safeFileName(String raw, {int maxLen = 80}) {
  var s = raw.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  s = s.replaceAll(RegExp(r'\s+'), ' ');
  if (s.length > maxLen) s = s.substring(0, maxLen);
  return s.isEmpty ? 'video_${DateTime.now().millisecondsSinceEpoch}' : s;
}

/// 在 [dir] 内找一个不冲突的名字：`name` 或其 `.part` 已存在（文件或目录）时
/// 追加 ` (2)`、` (3)`…。`.part` 一并避让，保证进行中下载与已完成文件互不覆盖。
/// 同步实现，调用方可紧接着预留文件，避免并发任务撞名。
String uniqueFileName(Directory dir, String name) {
  if (!_occupied(dir, name)) return name;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var i = 2; i < 100; i++) {
    final candidate = '$stem ($i)$ext';
    if (!_occupied(dir, candidate)) return candidate;
  }
  return '${stem}_${DateTime.now().millisecondsSinceEpoch}$ext';
}

bool _occupied(Directory dir, String name) {
  final path = p.join(dir.path, name);
  if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
    return true;
  }
  return FileSystemEntity.typeSync('$path.part') !=
      FileSystemEntityType.notFound;
}
