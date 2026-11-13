import 'package:material_ui/material_ui.dart';

import '../services/download_manager.dart';
import '../services/hls_manager.dart';
import '../services/m3u8_convert.dart';

/// 下载任务列表页（mp4 直链 + HLS 离线 + m3u8 转 mp4）
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final merged = Listenable.merge(
        [DownloadManager.instance, HlsManager.instance, ConvertManager.instance]);
    return ListenableBuilder(
      listenable: merged,
      builder: (context, _) {
        final mp4 = DownloadManager.instance.tasks;
        final hls = HlsManager.instance.tasks;
        final converts = ConvertManager.instance.tasks;
        final empty = mp4.isEmpty && hls.isEmpty && converts.isEmpty;
        return Scaffold(
          appBar: AppBar(title: const Text('下载')),
          body: empty
              ? const Center(child: Text('暂无下载任务'))
              : ListView(
                  children: [
                    if (hls.isNotEmpty) ...[
                      const _SectionTitle('HLS 离线下载'),
                      ...hls.map((t) => _HlsTile(task: t)),
                    ],
                    if (converts.isNotEmpty) ...[
                      const _SectionTitle('m3u8 → mp4'),
                      ...converts.map((t) => _ConvertTile(task: t)),
                    ],
                    if (mp4.isNotEmpty) ...[
                      const _SectionTitle('mp4 直链'),
                      ...mp4.map((t) => _Mp4Tile(task: t)),
                    ],
                  ],
                ),
        );
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}

class _HlsTile extends StatelessWidget {
  final HlsTask task;
  const _HlsTile({required this.task});

  @override
  Widget build(BuildContext context) {
    final done = task.done;
    final failed = task.failed;
    return ListTile(
      leading: Icon(
        done ? Icons.check_circle : Icons.stream,
        color: done ? Colors.green : Colors.orange,
      ),
      title: Text(task.title.isNotEmpty ? task.title : task.url,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: failed
          ? const Text('下载失败', style: TextStyle(color: Colors.red))
          : LinearProgressIndicator(value: task.progress),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!done && !failed)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => HlsManager.instance.cancel(task.taskId),
            ),
          if (done)
            IconButton(
              icon: const Icon(Icons.play_circle_outline),
              tooltip: '离线播放',
              onPressed: () => HlsManager.instance.play(task.taskId),
            ),
        ],
      ),
    );
  }
}

class _ConvertTile extends StatelessWidget {
  final ConvertTask task;
  const _ConvertTile({required this.task});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        task.done
            ? Icons.check_circle
            : task.failed
                ? Icons.error
                : Icons.transform,
        color: task.done
            ? Colors.green
            : task.failed
                ? Colors.red
                : Colors.teal,
      ),
      title: Text(task.title.isNotEmpty ? task.title : task.url,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: task.failed
          ? Text(task.error ?? '转换失败', style: const TextStyle(color: Colors.red))
          : task.done
              ? const Text('已完成（本地库可播放）')
              : LinearProgressIndicator(value: task.progress),
    );
  }
}

class _Mp4Tile extends StatelessWidget {
  final DownloadTask task;
  const _Mp4Tile({required this.task});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _statusIcon(task),
      title: Text(
        task.title.isNotEmpty ? task.title : task.url,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: task.status == DownloadStatus.downloading
          ? LinearProgressIndicator(value: task.progress)
          : Text(task.error ?? task.status.name),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (task.status == DownloadStatus.downloading)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => DownloadManager.instance.cancel(task.id),
            ),
          if (task.status == DownloadStatus.done ||
              task.status == DownloadStatus.failed)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () =>
                  DownloadManager.instance.delete(task.id, task.localPath ?? ''),
            ),
        ],
      ),
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
