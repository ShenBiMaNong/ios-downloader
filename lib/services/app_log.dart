import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 日志级别（从轻到重）
enum LogLevel { debug, info, warn, error }

extension LogLevelX on LogLevel {
  String get label => switch (this) {
        LogLevel.debug => 'DEBUG',
        LogLevel.info => 'INFO',
        LogLevel.warn => 'WARN',
        LogLevel.error => 'ERROR',
      };

  /// 是否重于（含）[other]
  bool atLeast(LogLevel other) => index >= other.index;
}

/// 一条日志记录
class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String tag;
  final String message;

  /// 错误详情（异常对象 toString 或堆栈），可多行，导出时缩进展示
  final String? detail;

  const LogEntry({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
    this.detail,
  });

  /// 人类可读的单条文本（复制 / 导出 / 展示用）
  String get line {
    final t = time.toLocal();
    final ts = '${t.year.toString().padLeft(4, '0')}-'
        '${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
    final base = '[$ts] [${level.label}] [$tag] $message';
    if (detail == null || detail!.isEmpty) return base;
    return '$base\n${detail!.split('\n').map((l) => '    $l').join('\n')}';
  }

  /// 用于日志行内（单行）展示的时间
  String get timeShort {
    final t = time.toLocal();
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toJson() => {
        't': time.toIso8601String(),
        'l': level.index,
        'g': tag,
        'm': message,
        if (detail != null && detail!.isNotEmpty) 's': detail,
      };

  factory LogEntry.fromJson(Map<String, dynamic> j) => LogEntry(
        time: DateTime.tryParse((j['t'] as String?) ?? '') ?? DateTime.now(),
        level: (j['l'] is int && (j['l'] as int) >= 0 &&
                (j['l'] as int) < LogLevel.values.length)
            ? LogLevel.values[j['l'] as int]
            : LogLevel.info,
        tag: (j['g'] as String?) ?? '',
        message: (j['m'] as String?) ?? '',
        detail: j['s'] as String?,
      );
}

/// 系统日志（报错排查用）：
/// - 内存环形缓冲（保留最近 [maxMemoryEntries] 条），UI 实时可读；
/// - 持久化到 Documents/AppData/Logs/app_log.log（JSONL，追加写，超限自动轮转）；
/// - 不记录下载进度等高频数据，只记录关键事件与报错，日志尽量详细；
/// - 提供复制全文 / 导出到 Downloads / 清空 能力。
class AppLog extends ChangeNotifier {
  static final AppLog instance = AppLog._();

  AppLog._();

  /// 内存保留条数上限
  static const int maxMemoryEntries = 3000;

  /// 单日志文件大小上限（超出后轮转 app_log.1.log）
  static const int maxFileBytes = 2 * 1024 * 1024;

  /// 保留的轮转备份文件数（app_log.1.log / app_log.2.log）
  static const int maxBackups = 2;

  final List<LogEntry> _entries = [];
  File? _file;
  bool _ready = false;

  /// 文件日志是否已就绪（内存日志始终可用）
  bool get ready => _ready;

  /// 日志文件所在目录（用于 UI 提示；未就绪时返回 null）
  String? get logDirPath => _file?.parent.path;

  /// 全部条目（按时间正序）
  List<LogEntry> get entries => List.unmodifiable(_entries);

  int get count => _entries.length;
  int get errorCount => _entries.where((e) => e.level == LogLevel.error).length;
  int get warnCount => _entries.where((e) => e.level == LogLevel.warn).length;

  /// 启动时初始化：创建日志目录，载入上一次会话的日志尾部
  Future<void> init() async {
    if (_ready) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'AppData', 'Logs'));
      await dir.create(recursive: true);
      _file = File(p.join(dir.path, 'app_log.log'));
      if (await _file!.exists()) {
        try {
          final lines = await _file!.readAsLines();
          // 只取尾部，避免旧日志撑爆内存
          final start = lines.length > maxMemoryEntries
              ? lines.length - maxMemoryEntries
              : 0;
          for (var i = start; i < lines.length; i++) {
            _parseLine(lines[i]);
          }
        } catch (_) {}
      }
      _ready = true;
      info('log', '日志服务就绪');
    } catch (_) {
      // 日志目录不可用时降级为纯内存日志，不影响使用
      _ready = true;
    }
  }

  void _parseLine(String line) {
    if (line.trim().isEmpty) return;
    try {
      final j = jsonDecode(line);
      if (j is Map<String, dynamic>) _entries.add(LogEntry.fromJson(j));
    } catch (_) {}
  }

  // ---------- 记录接口 ----------

  /// 指定级别记录（供级别动态决定的场景，如浏览器资源错误）
  void log(LogLevel level, String tag, String message,
          [Object? error, StackTrace? st]) =>
      _log(level, tag, message, error, st);

  void debug(String tag, String message) => _log(LogLevel.debug, tag, message);

  void info(String tag, String message) => _log(LogLevel.info, tag, message);

  void warn(String tag, String message, [Object? error, StackTrace? st]) =>
      _log(LogLevel.warn, tag, message, error, st);

  void error(String tag, String message, [Object? error, StackTrace? st]) =>
      _log(LogLevel.error, tag, message, error, st);

  void _log(LogLevel level, String tag, String message,
      [Object? error, StackTrace? st]) {
    String? detail;
    if (error != null || st != null) {
      final b = StringBuffer();
      if (error != null) {
        b.writeln('$error');
        if (st != null) b.write(st);
      } else if (st != null) {
        b.write(st);
      }
      detail = b.toString().trim();
    }
    _entries.add(LogEntry(
      time: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
      detail: detail,
    ));
    if (_entries.length > maxMemoryEntries) {
      _entries.removeRange(0, _entries.length - maxMemoryEntries);
    }
    notifyListeners();
    if (_ready) _enqueueWrite(level, tag, message, detail);
  }

  // ---------- 文件写入（串行追加 + 轮转） ----------

  Future<void> _writeChain = Future.value();

  void _enqueueWrite(LogLevel level, String tag, String message, String? detail) {
    final line = jsonEncode(LogEntry(
      time: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
      detail: detail,
    ).toJson());
    _writeChain = _writeChain.then((_) async {
      final f = _file;
      if (f == null) return;
      try {
        if (await f.exists() && await f.length() > maxFileBytes) {
          await _rotate(f);
        }
        await f.writeAsString('$line\n', mode: FileMode.append);
      } catch (_) {}
    });
  }

  Future<void> _rotate(File f) async {
    // app_log.2.log ← app_log.1.log ← app_log.log
    for (var i = maxBackups; i >= 1; i--) {
      final cur = File('${f.path}.$i.log');
      if (i == maxBackups) {
        if (await cur.exists()) await cur.delete();
      } else {
        final next = File('${f.path}.${i + 1}.log');
        if (await cur.exists()) {
          await cur.rename(next.path);
        } else if (await next.exists()) {
          await next.delete();
        }
      }
    }
    await f.rename('${f.path}.1.log');
  }

  // ---------- 复制 / 导出 / 清空 ----------

  /// 生成可复制 / 导出的完整文本
  String exportText() {
    final buf = StringBuffer();
    buf.writeln('视频下载器 · 系统日志');
    buf.writeln('导出时间：${DateTime.now().toLocal()}');
    buf.writeln('共 ${_entries.length} 条（错误 $errorCount 条，警告 $warnCount 条）');
    buf.writeln('------------------------------');
    for (final e in _entries) {
      buf.writeln(e.line);
    }
    return buf.toString();
  }

  /// 导出为 .txt 到 Downloads 目录（资源库可见，iOS 开启文件共享后也可在「文件」中取用）
  /// 返回导出文件路径；失败返回 null。
  Future<String?> exportToFile() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dl = Directory(p.join(docs.path, 'Downloads'));
      await dl.create(recursive: true);
      final now = DateTime.now();
      final name = '系统日志_${now.year}'
          '${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}'
          '_${now.hour.toString().padLeft(2, '0')}'
          '${now.minute.toString().padLeft(2, '0')}'
          '${now.second.toString().padLeft(2, '0')}.txt';
      final f = File(p.join(dl.path, name));
      await f.writeAsString(exportText());
      return f.path;
    } catch (e) {
      error('log', '导出日志失败', e);
      return null;
    }
  }

  /// 清空内存日志与日志文件（含轮转备份）
  Future<void> clear() async {
    _entries.clear();
    notifyListeners();
    final f = _file;
    if (f == null) return;
    try {
      if (await f.exists()) await f.delete();
      for (var i = 1; i <= maxBackups; i++) {
        final b = File('${f.path}.$i.log');
        if (await b.exists()) await b.delete();
      }
    } catch (_) {}
    info('log', '日志已清空');
  }

  // ---------- 全局错误捕获 ----------

  /// 挂接 Flutter / Platform 全局错误，未捕获的异常也会进日志
  void installGlobalHandlers() {
    FlutterError.onError = (details) {
      // 与框架默认行为一致：红色控制台输出（调试时仍可见）
      FlutterError.dumpErrorToConsole(details);
      error(
        'flutter',
        '未捕获的框架异常：${details.exceptionAsString()}',
        details.exception,
        details.stack,
      );
    };
    PlatformDispatcher.instance.onError = (Object err, StackTrace st) {
      error('platform', '未捕获的平台异常：$err', err, st);
      return true; // 已处理，避免向系统上报
    };
  }
}
