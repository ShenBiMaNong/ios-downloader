import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';

/// 主题模式：浅色 / 深色 / 跟随系统
enum AppThemeMode { light, dark, system }

extension AppThemeModeX on AppThemeMode {
  ThemeMode get flutter {
    switch (this) {
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
      case AppThemeMode.system:
        return ThemeMode.system;
    }
  }
}

/// 打开应用时浏览器显示的页面：空白页 / 上次打开页
enum BrowserStartPage { blank, lastPage }

/// 资源库视频列表展示方式：宫格 / 列表
enum LibraryViewMode { grid, list }

/// 应用通用设置（主题、浏览器启动页），JSON 持久化到项目现有 AppData 目录
class AppSettings extends ChangeNotifier {
  static final AppSettings instance = AppSettings._();

  AppSettings._();

  /// 主题模式，默认跟随系统
  AppThemeMode themeMode = AppThemeMode.system;

  /// 打开应用时浏览器显示的页面，默认恢复上次打开页
  BrowserStartPage browserStartPage = BrowserStartPage.lastPage;

  /// 资源库展示方式，默认宫格
  LibraryViewMode libraryViewMode = LibraryViewMode.grid;

  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map<String, dynamic>) {
          themeMode =
              _themeFrom((j['themeMode'] as String?) ?? '') ?? themeMode;
          browserStartPage = _startFrom((j['browserStartPage'] as String?) ?? '') ??
              browserStartPage;
          libraryViewMode =
              _viewFrom((j['libraryViewMode'] as String?) ?? '') ??
                  libraryViewMode;
          notifyListeners();
        }
      }
    } catch (e, st) {
      AppLog.instance.error('settings', '加载设置失败', e, st);
    }
  }

  static AppThemeMode? _themeFrom(String s) =>
      AppThemeMode.values.asNameMap()[s];

  static BrowserStartPage? _startFrom(String s) =>
      BrowserStartPage.values.asNameMap()[s];

  static LibraryViewMode? _viewFrom(String s) =>
      LibraryViewMode.values.asNameMap()[s];

  Future<File> _file() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'AppData'));
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'app_settings.json'));
  }

  Future<void> _save() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode({
        'themeMode': themeMode.name,
        'browserStartPage': browserStartPage.name,
        'libraryViewMode': libraryViewMode.name,
      }));
    } catch (e, st) {
      AppLog.instance.error('settings', '保存设置失败', e, st);
    }
  }

  Future<void> setThemeMode(AppThemeMode v) async {
    if (v == themeMode) return;
    themeMode = v;
    notifyListeners();
    await _save();
  }

  Future<void> setBrowserStartPage(BrowserStartPage v) async {
    if (v == browserStartPage) return;
    browserStartPage = v;
    notifyListeners();
    await _save();
  }

  Future<void> setLibraryViewMode(LibraryViewMode v) async {
    if (v == libraryViewMode) return;
    libraryViewMode = v;
    notifyListeners();
    await _save();
  }
}
