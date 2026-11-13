import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/library_item.dart' show libraryShareFolderName;
import 'download_manager.dart';

/// 资源库文件夹（虚拟分组）
class LibraryFolder {
  final String name;
  final DateTime createdAt;

  const LibraryFolder({required this.name, required this.createdAt});

  Map<String, dynamic> toJson() =>
      {'name': name, 'createdAt': createdAt.toIso8601String()};

  factory LibraryFolder.fromJson(Map<String, dynamic> j) => LibraryFolder(
        name: (j['name'] as String?) ?? '',
        createdAt:
            DateTime.tryParse((j['createdAt'] as String?) ?? '') ?? DateTime.now(),
      );
}

/// 资源库文件夹管理：
/// - 文件夹列表本身 JSON 持久化到 AppData 目录（与书签/设置同一套机制）；
/// - 视频归属写入各条目元数据 json 的 `folder` 字段（见 [DownloadManager.setFolder]），
///   只改元数据、不移动磁盘文件，因此对 mp4 / HLS 离线 / m3u8 分片包都适用。
/// - 「分享」为内置文件夹（分享导入的视频默认归入），用户不可新建/重命名/删除同名。
class LibraryFolders extends ChangeNotifier {
  static final LibraryFolders instance = LibraryFolders._();

  /// 内置分享文件夹名（分享导入的视频默认归属）
  static const String reservedName = libraryShareFolderName;

  LibraryFolders._();

  final List<LibraryFolder> folders = [];
  bool _loaded = false;

  /// 是否为内置文件夹名（用户不可占用）
  static bool isReserved(String name) => name.trim() == reservedName;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map<String, dynamic>) {
          for (final x in (j['folders'] as List? ?? [])) {
            if (x is Map<String, dynamic>) {
              final folder = LibraryFolder.fromJson(x);
              if (folder.name.isNotEmpty) folders.add(folder);
            }
          }
          notifyListeners();
        }
      }
    } catch (_) {}
  }

  Future<File> _file() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'AppData'));
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'library_folders.json'));
  }

  Future<void> _save() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode({
        'folders': folders.map((e) => e.toJson()).toList(),
      }));
    } catch (_) {}
  }

  bool exists(String name) =>
      folders.any((f) => f.name.toLowerCase() == name.toLowerCase());

  /// 新建文件夹（同名忽略大小写则失败；内置名不可用）
  Future<bool> create(String name) async {
    final n = name.trim();
    if (n.isEmpty || isReserved(n) || exists(n)) return false;
    folders.add(LibraryFolder(name: n, createdAt: DateTime.now()));
    notifyListeners();
    await _save();
    return true;
  }

  /// 重命名文件夹，并同步更新所有归属该文件夹的视频元数据
  Future<bool> rename(String oldName, String newName) async {
    final n = newName.trim();
    if (n.isEmpty || isReserved(n) || oldName == n) return false;
    if (exists(n)) return false;
    final i = folders.indexWhere((f) => f.name == oldName);
    if (i < 0) return false;
    folders[i] = LibraryFolder(name: n, createdAt: folders[i].createdAt);
    notifyListeners();
    await _save();
    await DownloadManager.instance.moveFolderItems(oldName, n);
    return true;
  }

  /// 删除文件夹（其中视频移回「全部」，不删除视频文件）
  Future<void> delete(String name) async {
    folders.removeWhere((f) => f.name == name);
    notifyListeners();
    await _save();
    await DownloadManager.instance.moveFolderItems(name, null);
  }
}
