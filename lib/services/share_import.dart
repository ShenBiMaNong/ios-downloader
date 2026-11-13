import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/video_info.dart';
import 'app_log.dart';
import 'download_manager.dart';
import 'file_names.dart';

/// 资源库数据变更信号：分享导入完成后 bump，资源库页监听后重新扫描
class LibraryRefresh extends ChangeNotifier {
  static final LibraryRefresh instance = LibraryRefresh._();

  LibraryRefresh._();

  int _generation = 0;

  int get generation => _generation;

  void bump() {
    _generation++;
    notifyListeners();
  }
}

/// 其他 App 分享接收（原生桥）：
/// - Android：`video_downloader/share` 通道，source 为 content:// URI，copy() 落盘；
/// - iOS：系统「用 App 打开 / 分享」时原生先把文件拷进沙盒 tmp，source 为本地路径。
class ShareBridge {
  static const _channel = MethodChannel('video_downloader/share');

  /// 原生侧「有新分享入队」回调（通知到达即导入，不必等 App 走一次 resume）
  static void Function()? onPendingAdded;
  static bool _listenerInstalled = false;

  /// 挂接原生推送（只在同一通道上用反向调用，不影响 Dart→原生 invokeMethod）
  static void installListener() {
    if (_listenerInstalled) return;
    _listenerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pendingAdded') {
        AppLog.instance.info('share', '收到原生推送：有新分享待导入');
        onPendingAdded?.call();
      }
      return null;
    });
  }

  /// 取回待导入的分享条目（取后清空原生队列）
  static Future<List<Map<String, dynamic>>> takePending() async {
    try {
      final r = await _channel.invokeMethod<List<dynamic>>('takePending');
      final items = (r ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e.cast<String, dynamic>()))
          .toList();
      AppLog.instance.info('share', 'takePending 取到 ${items.length} 条待导入');
      return items;
    } catch (e, st) {
      AppLog.instance.warn('share', 'takePending 失败', e, st);
      return const [];
    }
  }

  /// Android：把 content:// URI 拷贝到指定路径
  static Future<bool> copy(String uri, String dest) async {
    try {
      final r =
          await _channel.invokeMethod<bool>('copy', {'uri': uri, 'dest': dest});
      return r ?? false;
    } catch (e, st) {
      AppLog.instance.warn('share', 'copy 失败', e, st);
      return false;
    }
  }
}

/// 分享导入（MVP-4）：
/// 1) 剪贴板交接（iOS 免费账号）：分享扩展写剪贴板 → 启动时检测 URL → 导入面板；
/// 2) 文件接收：Android 直接收系统分享；iOS 经「用 App 打开」收文件
///    → 统一拷贝进 Documents/Share 并登记到资源库（kind: share）。
class ShareImport {
  static Future<String?> readClipboardUrl() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      final m = RegExp(r'https?://[^\s\u4e00-\u9fff]+').firstMatch(text);
      return m?.group(0);
    } catch (e, st) {
      AppLog.instance.warn('share', '读取剪贴板失败', e, st);
      return null;
    }
  }

  static bool isKnownVideoPage(String url) {
    final u = url.toLowerCase();
    return RegExp(
      r'(bilibili|douyin|kuaishou|youtube|b23\.tv|v\.douyin|v\.kuaishou|youtu\.be)',
    ).hasMatch(u);
  }

  static VideoInfo classify(String url) =>
      VideoInfo(url: url, frameUrl: '', pageTitle: '剪贴板导入');

  /// 处理原生队列里的分享文件：拷贝到 Documents/Share 并登记，返回成功数
  /// 并发调用（启动时 / onResume / 原生推送可能同时来）只跑一份，
  /// 否则两次 takePending 会互相抢队列，后一次拿空、前一次被丢掉。
  /// 并发期间来的请求标记成「再扫一轮」，本轮结束后补跑，条目不会滞留。
  static Future<int> importPending() async {
    if (_importing) {
      _again = true;
      return 0;
    }
    _importing = true;
    var total = 0;
    try {
      do {
        _again = false;
        total += await _importPending();
      } while (_again);
      return total;
    } finally {
      _importing = false;
    }
  }

  static bool _importing = false;
  static bool _again = false;

  static Future<int> _importPending() async {
    final items = await ShareBridge.takePending();
    if (items.isEmpty) return 0;
    AppLog.instance.info('share', '开始导入 ${items.length} 个分享文件');
    var ok = 0;
    for (final m in items) {
      final source = (m['source'] as String?) ?? '';
      final name = (m['name'] as String?) ?? '';
      if (source.isEmpty) {
        AppLog.instance.warn('share', '分享条目缺少 source，跳过');
        continue;
      }
      try {
        final dir = await DownloadManager.instance.shareDir();
        // 与下载一致：同名自动追加序号，绝不覆盖
        final base =
            name.trim().isEmpty ? 'shared_video.mp4' : safeFileName(name, maxLen: 120);
        final fileName = uniqueFileName(dir, base);
        final dest = p.join(dir.path, fileName);
        final copied = source.startsWith('content://')
            ? await ShareBridge.copy(source, dest)
            : await File(source).copy(dest).then((_) => true);
        if (!copied) {
          AppLog.instance.warn('share', '拷贝失败 $source');
          continue;
        }
        await DownloadManager.instance.addSharedItem(dest, _titleFrom(fileName));
        AppLog.instance.info('share', '已导入 $fileName');
        ok++;
      } catch (e, st) {
        AppLog.instance.warn('share', '导入失败 $source', e, st);
      }
    }
    if (ok > 0) LibraryRefresh.instance.bump();
    AppLog.instance.info('share', '分享导入完成：成功 $ok / ${items.length}');
    return ok;
  }

  static String _titleFrom(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot > 0 ? fileName.substring(0, dot) : fileName;
  }
}
