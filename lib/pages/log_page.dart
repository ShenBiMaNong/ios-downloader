import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:material_ui/material_ui.dart';

import '../services/app_log.dart';

/// 系统日志页：查看 / 筛选 / 复制 / 导出 / 清空
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  /// 0=全部，1=警告及以上，2=仅错误
  int _filter = 0;

  @override
  void initState() {
    super.initState();
    AppLog.instance.addListener(_onLog);
  }

  @override
  void dispose() {
    AppLog.instance.removeListener(_onLog);
    super.dispose();
  }

  void _onLog() {
    if (mounted) setState(() {});
  }

  List<LogEntry> get _visible {
    final all = AppLog.instance.entries;
    if (_filter == 0) return all;
    final min = _filter == 1 ? LogLevel.warn : LogLevel.error;
    return all.where((e) => e.level.atLeast(min)).toList();
  }

  Future<void> _copyAll() async {
    final text = AppLog.instance.exportText();
    await Clipboard.setData(ClipboardData(text: text));
    _toast('已复制全部日志（${text.length} 字符）');
  }

  Future<void> _export() async {
    final path = await AppLog.instance.exportToFile();
    if (!mounted) return;
    if (path == null) {
      _toast('导出失败，请查看日志详情');
      return;
    }
    final name = path.split('/').last;
    _toast('已导出到「下载」目录：$name\n可在「资源库」查看或通过「文件」App 取用');
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空日志'),
        content: const Text('将删除全部日志记录（含文件备份），确定清空吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await AppLog.instance.clear();
      _toast('日志已清空');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg, maxLines: 3, overflow: TextOverflow.ellipsis)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final log = AppLog.instance;
    final visible = _visible;
    return Scaffold(
      appBar: AppBar(
        title: const Text('系统日志'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: '复制全部',
            onPressed: visible.isEmpty ? null : _copyAll,
          ),
          IconButton(
            icon: const Icon(Icons.save_alt),
            tooltip: '导出日志文件',
            onPressed: visible.isEmpty ? null : _export,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: '清空日志',
            onPressed: log.count == 0 ? null : _clear,
          ),
        ],
      ),
      body: Column(
        children: [
          _filterBar(log),
          if (visible.isEmpty)
            const Expanded(
              child: Center(child: Text('暂无日志')),
            )
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                itemCount: visible.length,
                itemBuilder: (ctx, i) {
                  // 倒序：最新在前
                  final e = visible[visible.length - 1 - i];
                  return _entryTile(e);
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _filterBar(AppLog log) {
    final labels = const ['全部', '警告及以上', '仅错误'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            ChoiceChip(
              label: Text(labels[i]),
              selected: _filter == i,
              onSelected: (_) => setState(() => _filter = i),
            ),
            const SizedBox(width: 8),
          ],
          const Spacer(),
          Text(
            '共 ${log.count} 条 · 错误 ${log.errorCount} · 警告 ${log.warnCount}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _entryTile(LogEntry e) {
    final scheme = Theme.of(context).colorScheme;
    final Color? color = switch (e.level) {
      LogLevel.error => scheme.error,
      LogLevel.warn => Colors.orange.shade700,
      LogLevel.debug => scheme.outline,
      LogLevel.info => null,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SelectableText(
        e.line,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          height: 1.35,
          color: color,
        ),
      ),
    );
  }
}
