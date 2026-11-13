import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../models/library_item.dart';
import '../services/download_manager.dart';
import '../services/hls_manager.dart';
import '../services/m3u8_convert.dart';
import 'player_page.dart';

/// 资源库：下载任务 + 已保存视频 合并视图，支持多字段排序
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  SortField _field = SortField.created;
  bool _desc = true;
  List<Map<String, dynamic>> _saved = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final saved = await DownloadManager.instance.scanSaved();
    if (!mounted) return;
    setState(() {
      _saved = saved;
      _loading = false;
    });
  }

  List<LibraryItem> _buildItems() {
    final items = <LibraryItem>[];

    // 进行中/内存中的任务
    for (final t in DownloadManager.instance.tasks) {
      final active = t.status == DownloadStatus.queued ||
          t.status == DownloadStatus.downloading;
      final done = t.status == DownloadStatus.done;
      final failed = t.status == DownloadStatus.failed;
      items.add(LibraryItem(
        id: t.id,
        title: t.title,
        size: done ? _fileSize(t.localPath) : 0,
        created: t.startedAt,
        kind: 'mp4',
        active: active,
        failed: failed,
        progress: t.progress,
        speedText: active ? formatSpeed(t.speed) : null,
        etaText: active ? formatEta(t.eta) : null,
        localPath: t.localPath,
        url: t.url,
        error: t.error,
      ));
    }
    for (final t in HlsManager.instance.tasks) {
      items.add(LibraryItem(
        id: t.taskId,
        title: t.title,
        size: 0,
        created: t.startedAt,
        kind: 'm3u8',
        active: !t.done && !t.failed,
        failed: t.failed,
        progress: t.progress,
        etaText: t.done || t.failed ? null : formatEta(t.eta),
        hlsTaskId: t.taskId,
        url: t.url,
      ));
    }
    for (final t in ConvertManager.instance.tasks) {
      final active = !t.done && !t.failed;
      items.add(LibraryItem(
        id: t.id,
        title: t.title,
        size: t.done ? _fileSize(t.localPath) : 0,
        created: t.startedAt,
        kind: 'convert',
        active: active,
        failed: t.failed,
        progress: t.progress,
        speedText: active && t.progress < 1 ? formatSpeed(t.speed) : null,
        etaText: active && t.progress < 1 ? formatEta(t.eta) : null,
        localPath: t.localPath,
        url: t.url,
        error: t.error,
        doneSegments: t.doneSegments,
        totalSegments: t.totalSegments,
      ));
    }

    // 已持久化的完成项（去重）
    for (final m in _saved) {
      final id = (m['id'] as String?) ?? '';
      if (items.any((i) => i.id == id)) continue;
      final kind = (m['kind'] as String?) ?? 'other';
      final isHls = (m['hls'] as bool?) ?? false;
      final path = (m['localPath'] as String?) ?? '';
      final savedAt =
          DateTime.tryParse((m['savedAt'] as String?) ?? '') ?? DateTime.now();
      items.add(LibraryItem(
        id: id,
        title: (m['title'] as String?) ?? '未命名',
        size: isHls ? 0 : _fileSize(path),
        created: savedAt,
        kind: isHls ? 'm3u8' : kind,
        active: false,
        failed: false,
        progress: 1,
        localPath: path,
        hlsTaskId: isHls ? id : null,
        url: (m['url'] as String?) ?? '',
      ));
    }

    return LibraryItem.sort(items, _field, _desc);
  }

  int _fileSize(String? path) {
    if (path == null || path.isEmpty) return 0;
    try {
      final f = File(path);
      return f.existsSync() ? f.lengthSync() : 0;
    } catch (_) {
      return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final merged = Listenable.merge(
        [DownloadManager.instance, HlsManager.instance, ConvertManager.instance]);
    return ListenableBuilder(
      listenable: merged,
      builder: (context, _) {
        final items = _buildItems();
        return Scaffold(
          appBar: AppBar(
            title: const Text('资源库'),
            actions: [
              IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
            ],
          ),
          body: Column(
            children: [
              _sortBar(),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : items.isEmpty
                        ? const Center(child: Text('暂无内容，去浏览器里找找视频吧'))
                        : RefreshIndicator(
                            onRefresh: _refresh,
                            child: ListView.builder(
                              itemCount: items.length,
                              itemBuilder: (context, i) =>
                                  _tile(context, items[i]),
                            ),
                          ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _sortBar() {
    final labels = {
      SortField.name: '名称',
      SortField.size: '大小',
      SortField.created: '创建时间',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(
        children: [
          PopupMenuButton<SortField>(
            initialValue: _field,
            icon: const Icon(Icons.sort),
            tooltip: '排序字段',
            onSelected: (f) => setState(() => _field = f),
            itemBuilder: (ctx) => [
              for (final f in SortField.values)
                PopupMenuItem(
                  value: f,
                  child: Row(
                    children: [
                      Icon(
                        f == _field
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(labels[f]!),
                    ],
                  ),
                ),
            ],
          ),
          Text('排序：${labels[_field]}', style: Theme.of(context).textTheme.bodyMedium),
          const Spacer(),
          IconButton(
            tooltip: _desc ? '倒序' : '正序',
            icon: Icon(_desc ? Icons.arrow_downward : Icons.arrow_upward),
            onPressed: () => setState(() => _desc = !_desc),
          ),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, LibraryItem it) {
    return ListTile(
      leading: _leadingIcon(it),
      title: Text(it.sortName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_subtitle(it), style: const TextStyle(fontSize: 12)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (it.active && it.kind != 'convert')
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '取消',
              onPressed: () {
                if (it.kind == 'mp4') {
                  DownloadManager.instance.cancel(it.id);
                } else if (it.kind == 'm3u8') {
                  HlsManager.instance.cancel(it.hlsTaskId ?? it.id);
                }
              },
            ),
          if (!it.active && !it.failed)
            IconButton(
              icon: const Icon(Icons.play_circle_outline),
              tooltip: '播放',
              onPressed: () => _play(it),
            ),
          if (!it.active)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
              onPressed: () async {
                if (it.kind == 'mp4') {
                  await DownloadManager.instance.delete(it.id, it.localPath ?? '');
                } else if (it.kind == 'm3u8') {
                  await DownloadManager.instance.delete(it.id, '');
                } else {
                  await DownloadManager.instance.delete(it.id, it.localPath ?? '');
                }
                await _refresh();
              },
            ),
        ],
      ),
      onTap: () {
        if (!it.active && !it.failed) _play(it);
      },
    );
  }

  void _play(LibraryItem it) {
    if (it.kind == 'm3u8') {
      HlsManager.instance.play(it.hlsTaskId ?? it.id);
      return;
    }
    if (it.localPath == null || it.localPath!.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(path: it.localPath!, title: it.sortName),
      ),
    );
  }

  Widget _leadingIcon(LibraryItem it) {
    if (it.failed) return const Icon(Icons.error, color: Colors.red);
    if (it.active) {
      if (it.kind == 'convert') {
        return const Icon(Icons.transform, color: Colors.teal);
      }
      return const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    switch (it.kind) {
      case 'm3u8':
        return const Icon(Icons.stream, color: Colors.orange);
      default:
        return const Icon(Icons.movie, color: Colors.blue);
    }
  }

  String _subtitle(LibraryItem it) {
    if (it.failed) return it.error ?? '失败';
    if (it.active) {
      final pct = '${(it.progress * 100).toStringAsFixed(0)}%';
      if (it.kind == 'convert') {
        final seg = it.progress >= 1
            ? '转封装中…'
            : '分片 ${it.doneSegments}/${it.totalSegments}';
        return [seg, it.speedText, it.etaText].whereType<String>().join(' · ');
      }
      return [pct, it.speedText, it.etaText].whereType<String>().join(' · ');
    }
    final date = it.created.toLocal().toString().substring(0, 10);
    if (it.kind == 'm3u8') return 'HLS 离线缓存 · $date';
    return '${formatBytes(it.size)} · $date';
  }
}
