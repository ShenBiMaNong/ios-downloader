import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class Bookmark {
  final String title;
  final String url;
  final DateTime addedAt;

  const Bookmark({required this.title, required this.url, required this.addedAt});

  Map<String, dynamic> toJson() =>
      {'title': title, 'url': url, 'addedAt': addedAt.toIso8601String()};

  factory Bookmark.fromJson(Map<String, dynamic> j) => Bookmark(
        title: (j['title'] as String?) ?? '',
        url: j['url'] as String,
        addedAt: DateTime.tryParse((j['addedAt'] as String?) ?? '') ?? DateTime.now(),
      );
}

class HistoryEntry {
  final String title;
  final String url;
  final DateTime visitedAt;

  const HistoryEntry({required this.title, required this.url, required this.visitedAt});

  Map<String, dynamic> toJson() =>
      {'title': title, 'url': url, 'visitedAt': visitedAt.toIso8601String()};

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        title: (j['title'] as String?) ?? '',
        url: j['url'] as String,
        visitedAt: DateTime.tryParse((j['visitedAt'] as String?) ?? '') ?? DateTime.now(),
      );
}

/// 浏览器辅助数据：书签 / 历史记录 / 广告过滤开关（JSON 持久化）
class AppData extends ChangeNotifier {
  static final AppData instance = AppData._();

  AppData._();

  final List<Bookmark> bookmarks = [];
  final List<HistoryEntry> history = [];
  bool adBlockEnabled = false;
  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map<String, dynamic>) {
          for (final b in (j['bookmarks'] as List? ?? [])) {
            bookmarks.add(Bookmark.fromJson(b as Map<String, dynamic>));
          }
          for (final h in (j['history'] as List? ?? [])) {
            history.add(HistoryEntry.fromJson(h as Map<String, dynamic>));
          }
          adBlockEnabled = (j['adBlock'] as bool?) ?? false;
          notifyListeners();
        }
      }
    } catch (_) {}
  }

  Future<File> _file() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'AppData'));
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'appdata.json'));
  }

  Future<void> _save() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode({
        'bookmarks': bookmarks.map((e) => e.toJson()).toList(),
        'history': history.map((e) => e.toJson()).toList(),
        'adBlock': adBlockEnabled,
      }));
    } catch (_) {}
  }

  bool isBookmarked(String url) => bookmarks.any((b) => b.url == url);

  Future<void> toggleBookmark(String title, String url) async {
    if (isBookmarked(url)) {
      bookmarks.removeWhere((b) => b.url == url);
    } else {
      bookmarks.insert(0, Bookmark(title: title, url: url, addedAt: DateTime.now()));
    }
    notifyListeners();
    await _save();
  }

  Future<void> removeBookmark(String url) async {
    bookmarks.removeWhere((b) => b.url == url);
    notifyListeners();
    await _save();
  }

  /// 记录访问（同 URL 去重置顶，上限 500 条）
  Future<void> recordHistory(String title, String url) async {
    history.removeWhere((h) => h.url == url);
    history.insert(0, HistoryEntry(title: title, url: url, visitedAt: DateTime.now()));
    if (history.length > 500) history.removeRange(500, history.length);
    notifyListeners();
    await _save();
  }

  Future<void> removeHistory(String url) async {
    history.removeWhere((h) => h.url == url);
    notifyListeners();
    await _save();
  }

  Future<void> clearHistory() async {
    history.clear();
    notifyListeners();
    await _save();
  }

  Future<void> setAdBlock(bool v) async {
    adBlockEnabled = v;
    notifyListeners();
    await _save();
  }
}
