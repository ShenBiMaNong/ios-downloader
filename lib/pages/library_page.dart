import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/download_manager.dart';
import 'player_page.dart';

/// 本地视频库
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final items = await DownloadManager.instance.scanSaved();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地视频库'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? const Center(child: Text('暂无已下载视频，去浏览器里找找吧'))
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView.builder(
                    itemCount: _items.length,
                    itemBuilder: (context, i) {
                      final m = _items[i];
                      final path = (m['localPath'] as String?) ?? '';
                      final title = (m['title'] as String?) ?? '未命名';
                      final kind = (m['kind'] as String?) ?? 'other';
                      return ListTile(
                        leading: Icon(
                          kind == 'm3u8' ? Icons.stream : Icons.movie,
                          color: kind == 'm3u8' ? Colors.orange : Colors.blue,
                        ),
                        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${_size(path)} · ${(m['savedAt'] as String? ?? '').substring(0, 10)}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            final id = (m['id'] as String?) ?? '';
                            await DownloadManager.instance.delete(id, path);
                            _refresh();
                          },
                        ),
                        onTap: () {
                          if (path.isEmpty) return;
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => PlayerPage(path: path, title: title),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
    );
  }

  String _size(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return '文件缺失';
      final kb = f.lengthSync() / 1024;
      if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
      final mb = kb / 1024;
      return '${mb.toStringAsFixed(1)} MB';
    } catch (_) {
      return '?';
    }
  }
}
