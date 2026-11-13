import 'package:flutter/material.dart';

import '../services/download_manager.dart';

/// 下载任务列表页
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: DownloadManager.instance,
      builder: (context, _) {
        final tasks = DownloadManager.instance.tasks;
        return Scaffold(
          appBar: AppBar(title: const Text('下载')),
          body: tasks.isEmpty
              ? const Center(child: Text('暂无下载任务'))
              : ListView.builder(
                  itemCount: tasks.length,
                  itemBuilder: (context, i) {
                    final t = tasks[i];
                    return ListTile(
                      leading: _statusIcon(t),
                      title: Text(
                        t.title.isNotEmpty ? t.title : t.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: t.status == DownloadStatus.downloading
                          ? LinearProgressIndicator(value: t.progress)
                          : Text(t.error ?? t.status.name),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (t.status == DownloadStatus.downloading)
                            IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () => DownloadManager.instance.cancel(t.id),
                            ),
                          if (t.status == DownloadStatus.done ||
                              t.status == DownloadStatus.failed)
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () =>
                                  DownloadManager.instance.delete(t.id, t.localPath ?? ''),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        );
      },
    );
  }

  Widget _statusIcon(DownloadTask t) {
    switch (t.status) {
      case DownloadStatus.done:
        return const Icon(Icons.check_circle, color: Colors.green);
      case DownloadStatus.failed:
        return const Icon(Icons.error, color: Colors.red);
      case DownloadStatus.queued:
      case DownloadStatus.downloading:
        return const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
    }
  }
}
