import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';

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

  /// 跳转拦截开关：网站自动跳转时先询问是否跳转（默认开）
  bool redirectGuardEnabled = true;

  /// 页面视频标记开关：嗅探到的 `<video>` 直接描边 + 角标展示（默认开）
  bool videoMarkEnabled = true;

  /// 禁止视频自动播放：页面自己开始的播放一律拦下（默认开）
  bool blockAutoplayEnabled = true;

  /// 点播放即接管：用户点页面播放器时，若拿到 http(s) 直链就不让页面自己播，
  /// 直接交给 App 播放器（默认关 —— 它会改变页面的播放行为，需要用户主动开）
  bool playHijackEnabled = false;

  /// 上次打开的页面（供「浏览器启动页 = 上次打开页」恢复）
  String lastUrl = '';

  /// 加载中的 Future，而不是「已开始加载」的 bool：
  /// 浏览器页 initState 里 `_installEarlyScripts` 与 `_initStartPage` 会并发调用
  /// 本方法，若第二个调用者一看到标记就返回，它读到的是尚未落盘的 [lastUrl]
  /// （空串）→ 启动页回落到默认首页 bilibili，并且随后的 onPageStarted
  /// 还会把 bilibili 当成「上次打开页」覆盖存档，于是每次启动都停在 bilibili。
  Future<void>? _loading;

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
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
          redirectGuardEnabled = (j['redirectGuard'] as bool?) ?? true;
          videoMarkEnabled = (j['videoMark'] as bool?) ?? true;
          blockAutoplayEnabled = (j['blockAutoplay'] as bool?) ?? true;
          playHijackEnabled = (j['playHijack'] as bool?) ?? false;
          lastUrl = (j['lastUrl'] as String?) ?? '';
          notifyListeners();
        }
      }
    } catch (e, st) {
      AppLog.instance.error('data', '加载书签/历史数据失败', e, st);
    }
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
        'redirectGuard': redirectGuardEnabled,
        'videoMark': videoMarkEnabled,
        'blockAutoplay': blockAutoplayEnabled,
        'playHijack': playHijackEnabled,
        'lastUrl': lastUrl,
      }));
    } catch (e, st) {
      AppLog.instance.error('data', '保存书签/历史数据失败', e, st);
    }
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

  Future<void> setRedirectGuard(bool v) async {
    if (v == redirectGuardEnabled) return;
    redirectGuardEnabled = v;
    notifyListeners();
    await _save();
  }

  Future<void> setVideoMark(bool v) async {
    if (v == videoMarkEnabled) return;
    videoMarkEnabled = v;
    notifyListeners();
    await _save();
  }

  Future<void> setBlockAutoplay(bool v) async {
    if (v == blockAutoplayEnabled) return;
    blockAutoplayEnabled = v;
    notifyListeners();
    await _save();
  }

  Future<void> setPlayHijack(bool v) async {
    if (v == playHijackEnabled) return;
    playHijackEnabled = v;
    notifyListeners();
    await _save();
  }

  /// 记录最近打开的页面（页面开始加载时调用）
  Future<void> setLastUrl(String url) async {
    // 只记真实网页：选「空白页」启动时 WebView 会加载 about:blank，
    // 记下来会让「上次打开页」下次去加载 https://about:blank 这种废地址
    if (!url.startsWith('http://') && !url.startsWith('https://')) return;
    if (url == lastUrl) return;
    lastUrl = url;
    notifyListeners();
    await _save();
  }
}
