import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../models/library_item.dart';
import '../models/playable_item.dart';
import '../services/app_settings.dart';
import '../services/download_manager.dart';
import '../services/files_bridge.dart';
import '../services/hls_manager.dart';
import '../services/library_folders.dart';
import '../services/m3u8_convert.dart';
import '../services/playback_cacher.dart';
import '../services/share_import.dart';
import 'player_page.dart';
import 'settings_page.dart';

/// 资源库：下载任务 + 已保存视频 合并视图，支持多字段排序 + 文件夹分组
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

  /// 当前浏览的文件夹（'' = 全部）
  String _folder = '';

  @override
  void initState() {
    super.initState();
    LibraryFolders.instance.ensureLoaded();
    // 分享导入完成后重新扫描（启动时已导入的场景由 initState 的 _refresh 覆盖）
    LibraryRefresh.instance.addListener(_onLibraryRefresh);
    _refresh();
  }

  @override
  void dispose() {
    LibraryRefresh.instance.removeListener(_onLibraryRefresh);
    super.dispose();
  }

  void _onLibraryRefresh() => _refresh();

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final saved = await DownloadManager.instance.scanSaved();
    if (!mounted) return;
    setState(() {
      _saved = saved;
      _loading = false;
    });
  }

  /// 导入本地 m3u8（iOS 系统文件夹选择器）→ 直接转 mp4
  Future<void> _importLocalM3u8() async {
    final path = await FilesBridge.pickFolder();
    if (!mounted) return;
    if (path == null || path.isEmpty) {
      _toast('未选择文件夹（选择包含 .m3u8 与分片的文件夹）');
      return;
    }
    ConvertManager.instance.convertLocal(path);
    _toast('已开始本地 m3u8 → mp4 转换，进度见列表');
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  List<LibraryItem> _buildItems() {
    final items = <LibraryItem>[];

    // 已保存条目的 id → 文件夹（供「进行中/内存中」任务显示最新归属）
    final folderById = <String, String>{};
    for (final m in _saved) {
      folderById[(m['id'] as String?) ?? ''] = (m['folder'] as String?) ?? '';
    }

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
        resumable: t.canResume,
        folder: folderById[t.id] ?? '',
      ));
    }
    // 「边播边缓存」任务（本地 HTTP 代理，缓存完成即入库）
    for (final t in PlaybackCacher.instance.tasks) {
      final active = !t.done && !t.failed;
      items.add(LibraryItem(
        id: t.id,
        title: t.title,
        size: t.done ? _fileSize(t.localPath) : 0,
        created: t.startedAt,
        kind: 'mp4',
        active: active,
        failed: t.failed,
        progress: t.progress,
        localPath: t.localPath,
        url: t.url,
        error: t.error,
        folder: '',
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
        error: t.error,
        resumable: t.resumable,
        folder: folderById[t.taskId] ?? '',
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
        resumable: t.resumable,
        folder: folderById[t.id] ?? '',
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
        folder: (m['folder'] as String?) ?? '',
      ));
    }

    // 排序（文件夹过滤/分组在 build 里按当前视图处理）
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
    final merged = Listenable.merge([
      DownloadManager.instance,
      HlsManager.instance,
      ConvertManager.instance,
      PlaybackCacher.instance,
      AppSettings.instance,
    ]);
    return ListenableBuilder(
      listenable: merged,
      builder: (context, _) {
        final grid =
            AppSettings.instance.libraryViewMode == LibraryViewMode.grid;
        final items = _buildItems();
        // 「全部」按文件夹分组（未分组在前，组内按当前排序）；文件夹视图平铺
        final sections = _folder.isEmpty
            ? LibraryItem.groupSections(
                items,
                [
                  LibraryFolders.reservedName,
                  for (final f in LibraryFolders.instance.folders) f.name,
                ],
                _field,
                _desc,
              )
            : [
                LibrarySection(
                  _folder,
                  LibraryItem.sort(
                      LibraryItem.filterByFolder(items, _folder), _field, _desc),
                ),
              ];
        return Scaffold(
          appBar: AppBar(
            title: const Text('资源库'),
            actions: [
              IconButton(
                icon: const Icon(Icons.folder_open),
                tooltip: '导入本地 m3u8 转 MP4',
                onPressed: _importLocalM3u8,
              ),
              IconButton(
                icon: Icon(grid ? Icons.view_list : Icons.grid_view),
                tooltip: grid ? '切换为列表视图' : '切换为宫格视图',
                onPressed: () => AppSettings.instance.setLibraryViewMode(
                    grid ? LibraryViewMode.list : LibraryViewMode.grid),
              ),
              IconButton(
                icon: const Icon(Icons.settings),
                tooltip: '设置',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
                ),
              ),
              IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
            ],
          ),
          body: Column(
            children: [
              _sortBar(),
              _folderBar(),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : items.isEmpty
                        ? const Center(
                            child: Text('暂无内容，去浏览器里找找视频吧'),
                          )
                        : sections.every((s) => s.items.isEmpty)
                            ? Center(
                                child: Text(_folder == LibraryFolders.reservedName
                                    ? '还没有分享进来的视频'
                                    : '此文件夹暂无视频'),
                              )
                            : RefreshIndicator(
                                onRefresh: _refresh,
                                child: grid
                                    ? _gridList(context, sections)
                                    : _listList(context, sections),
                              ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 分组标题：文件夹名 + 数量
  Widget _sectionHeader(String name, int count) {
    final outline = Theme.of(context).colorScheme.outline;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Row(
        children: [
          Icon(
            name.isEmpty ? Icons.folder_open : Icons.folder,
            size: 18,
            color: outline,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name.isEmpty ? '未分组' : name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(color: outline),
            ),
          ),
          Text(
            '$count',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: outline),
          ),
        ],
      ),
    );
  }

  /// 列表视图：逐条 ListTile
  Widget _listList(BuildContext context, List<LibrarySection> sections) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        for (final s in sections) ...[
          if (_folder.isEmpty) _sectionHeader(s.name, s.items.length),
          for (var i = 0; i < s.items.length; i++)
            _tile(context, s.items[i], i, s.items),
        ],
      ],
    );
  }

  /// 宫格视图：分组标题 + 每组的卡片网格
  Widget _gridList(BuildContext context, List<LibrarySection> sections) {
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        for (final s in sections) ...[
          if (_folder.isEmpty)
            SliverToBoxAdapter(child: _sectionHeader(s.name, s.items.length)),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 280,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.0,
              ),
              delegate: SliverChildBuilderDelegate(
                (c, i) => _gridCard(context, s.items[i], i, s.items),
                childCount: s.items.length,
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 宫格卡片：封面（状态/进度/快捷操作）+ 标题 + 摘要 + 更多菜单
  Widget _gridCard(BuildContext context, LibraryItem it, int index,
      List<LibraryItem> all) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final playable = !it.active && !it.failed;
    final m3u8Pkg = it.kind == 'm3u8' &&
        it.hlsTaskId == null &&
        it.localPath != null &&
        it.localPath!.isNotEmpty;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: playable ? () => _play(all, index) : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: _gridCover(it, index, all, scheme),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 4, 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Flexible(
                            child: Text(
                              it.sortName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Flexible(
                            child: Text(
                              _subtitle(it),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: scheme.outline),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (playable || m3u8Pkg)
                      PopupMenuButton<String>(
                        icon: Icon(Icons.more_vert, size: 20, color: scheme.outline),
                        tooltip: '更多操作',
                        onSelected: (v) => _itemAction(it, index, all, v),
                        itemBuilder: (ctx) => _moreMenuItems(it),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 更多操作菜单动作（宫格/列表共用；缓存播放/转换/重命名/移动/删除/取消/继续）
  void _itemAction(LibraryItem it, int index, List<LibraryItem> all, String v) {
    switch (v) {
      case 'cacheplay':
        // 下载中的 mp4：边播边缓存（缓存完成即入库，播放字节即下载字节）
        _playCaching(it);
      case 'hlsplay':
        // 下载中的 HLS：复用同一 AVURLAsset 边下边看（读已缓存分段）
        _playHlsCaching(it);
      case 'convert':
        ConvertManager.instance.convertLocal(it.localPath!);
        _toast('已开始本地 m3u8 → mp4 转换');
      case 'move':
        _moveSheet(it);
      case 'rename':
        _renameItem(it);
      case 'delete':
        _deleteItem(it);
      case 'cancel':
        if (it.id.startsWith(PlaybackCacher.idPrefix)) {
          PlaybackCacher.instance.cancel(it.id);
        } else if (it.kind == 'mp4') {
          DownloadManager.instance.cancel(it.id);
        } else {
          HlsManager.instance.cancel(it.hlsTaskId ?? it.id);
        }
      case 'resume':
        if (it.kind == 'convert') {
          ConvertManager.instance.retry(it.id);
        } else if (it.kind == 'm3u8') {
          HlsManager.instance.retry(it.hlsTaskId ?? it.id);
        } else {
          DownloadManager.instance.resume(it.id);
        }
    }
  }

  /// 更多操作菜单项（宫格/列表共用，按条目状态取）
  List<PopupMenuEntry<String>> _moreMenuItems(LibraryItem it) {
    final playable = !it.active && !it.failed;
    final m3u8Pkg = it.kind == 'm3u8' &&
        it.hlsTaskId == null &&
        it.localPath != null &&
        it.localPath!.isNotEmpty;
    // 点按即播放（列表/宫格均可），菜单里不再提供独立的「播放」项
    return [
      // 下载中：mp4 边播边缓存；HLS 边下边看
      if (it.active && it.kind == 'mp4')
        const PopupMenuItem(
            value: 'cacheplay', child: Text('边播边缓存（立即播放）')),
      if (it.active && it.kind == 'm3u8')
        const PopupMenuItem(value: 'hlsplay', child: Text('边下边看')),
      if (m3u8Pkg)
        const PopupMenuItem(value: 'convert', child: Text('本地转 MP4')),
      if (it.active && it.kind != 'convert')
        const PopupMenuItem(value: 'cancel', child: Text('取消')),
      if (it.failed && it.resumable)
        const PopupMenuItem(value: 'resume', child: Text('继续下载')),
      if (playable) const PopupMenuItem(value: 'rename', child: Text('重命名')),
      if (playable)
        const PopupMenuItem(value: 'move', child: Text('移动到文件夹')),
      if (!it.active)
        const PopupMenuItem(
          value: 'delete',
          child: Text('删除', style: TextStyle(color: Colors.red)),
        ),
    ];
  }

  /// 宫格封面：按状态着色 + 居中状态图标 + 右下角快捷操作
  Widget _gridCover(LibraryItem it, int index, List<LibraryItem> all,
      ColorScheme scheme) {
    Color? bg;
    Widget content;
    if (it.failed) {
      bg = scheme.errorContainer;
      content =
          Icon(Icons.error_outline, size: 40, color: scheme.onErrorContainer);
    } else if (it.active) {
      bg = scheme.primaryContainer;
      if (it.kind == 'convert') {
        content = Icon(Icons.transform, size: 36, color: scheme.onPrimaryContainer);
      } else {
        final pct = (it.progress * 100).clamp(0, 100);
        content = Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 46,
              height: 46,
              child: CircularProgressIndicator(
                value: it.progress.clamp(0.0, 1.0),
                strokeWidth: 3.5,
                color: scheme.primary,
              ),
            ),
            Text(
              '${pct.toStringAsFixed(0)}%',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
          ],
        );
      }
    } else {
      switch (it.kind) {
        case 'm3u8':
          bg = scheme.tertiaryContainer;
          content = Icon(Icons.stream, size: 38, color: scheme.onTertiaryContainer);
        case 'share':
          bg = scheme.secondaryContainer;
          content =
              Icon(Icons.ios_share, size: 38, color: scheme.onSecondaryContainer);
        default:
          bg = scheme.primaryContainer;
          content =
              Icon(Icons.movie, size: 38, color: scheme.onPrimaryContainer);
      }
    }
    final action = _coverAction(it, index, all);
    return Container(
      color: bg,
      child: Stack(
        children: [
          Positioned.fill(child: Center(child: content)),
          if (action != null)
            Positioned(right: 6, bottom: 6, child: action),
        ],
      ),
    );
  }

  /// 封面右下角快捷操作（取消/继续/本地转 MP4；已完成条目点按封面即播放）
  Widget? _coverAction(LibraryItem it, int index, List<LibraryItem> all) {
    if (it.active && it.kind != 'convert') {
      // 进行中：取消 + 边播边缓存（mp4）/ 边下边看（HLS）
      final cancel = _smallFab(Icons.close, '取消', () {
        if (it.id.startsWith(PlaybackCacher.idPrefix)) {
          PlaybackCacher.instance.cancel(it.id);
        } else if (it.kind == 'mp4') {
          DownloadManager.instance.cancel(it.id);
        } else {
          HlsManager.instance.cancel(it.hlsTaskId ?? it.id);
        }
      });
      final play = it.kind == 'mp4'
          ? _smallFab(Icons.play_circle_outline, '边播边缓存（立即播放）',
              () => _playCaching(it))
          : _smallFab(Icons.play_circle_outline, '边下边看',
              () => _playHlsCaching(it));
      return Row(mainAxisSize: MainAxisSize.min, children: [play, cancel]);
    }
    if (it.failed && it.resumable) {
      return _smallFab(Icons.play_arrow, '继续下载', () {
        if (it.kind == 'convert') {
          ConvertManager.instance.retry(it.id);
        } else if (it.kind == 'm3u8') {
          HlsManager.instance.retry(it.hlsTaskId ?? it.id);
        } else {
          DownloadManager.instance.resume(it.id);
        }
      });
    }
    if (it.kind == 'm3u8' &&
        it.hlsTaskId == null &&
        it.localPath != null &&
        it.localPath!.isNotEmpty) {
      return _smallFab(Icons.transform, '本地转 MP4', () {
        ConvertManager.instance.convertLocal(it.localPath!);
        _toast('已开始本地 m3u8 → mp4 转换');
      });
    }
    // 已完成条目：点按卡片即播放，无需播放按钮
    return null;
  }

  /// 封面上的小圆钮（半透明黑底白图标）
  Widget _smallFab(IconData icon, String tooltip, VoidCallback onPressed) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      shape: const CircleBorder(),
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 18, color: Colors.white),
          ),
        ),
      ),
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

  /// 文件夹横条：全部 / 内置「分享」/ 各文件夹（点击切换，长按重命名/删除）/ 新建
  Widget _folderBar() {
    return SizedBox(
      height: 48,
      child: ListenableBuilder(
        listenable: LibraryFolders.instance,
        builder: (context, _) {
          final folders = LibraryFolders.instance.folders;
          return ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  avatar: const Icon(Icons.folder_open, size: 18),
                  label: const Text('全部'),
                  selected: _folder.isEmpty,
                  onSelected: (_) => setState(() => _folder = ''),
                ),
              ),
              // 内置「分享」文件夹（分享导入的视频默认归入；不可重命名/删除）
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  avatar: const Icon(Icons.ios_share, size: 18),
                  label: const Text('分享'),
                  selected: _folder == LibraryFolders.reservedName,
                  onSelected: (_) =>
                      setState(() => _folder = LibraryFolders.reservedName),
                ),
              ),
              for (final f in folders)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onLongPress: () => _folderMenu(f.name),
                    child: FilterChip(
                      avatar: const Icon(Icons.folder, size: 18),
                      label: Text(f.name),
                      selected: _folder == f.name,
                      onSelected: (_) => setState(() => _folder = f.name),
                    ),
                  ),
                ),
              ActionChip(
                avatar: const Icon(Icons.create_new_folder, size: 18),
                label: const Text('新建'),
                onPressed: _createFolderDialog,
              ),
            ],
          );
        },
      ),
    );
  }

  /// 文件夹管理菜单（长按文件夹 chip）
  void _folderMenu(String name) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder),
              title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('重命名'),
              onTap: () {
                Navigator.pop(ctx);
                _renameFolderDialog(name);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('删除文件夹', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteFolder(name);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 新建文件夹；成功返回文件夹名，失败返回 null
  Future<String?> _createFolderDialog({bool selectAfterCreate = true}) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '文件夹名称'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return null;
    if (LibraryFolders.isReserved(name)) {
      _toast('「${LibraryFolders.reservedName}」是内置文件夹，请换个名称');
      return null;
    }
    final ok = await LibraryFolders.instance.create(name);
    if (!ok) {
      _toast('已存在同名文件夹');
      return null;
    }
    if (selectAfterCreate) setState(() => _folder = name);
    return name;
  }

  Future<void> _renameFolderDialog(String oldName) async {
    final ctrl = TextEditingController(text: oldName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名文件夹'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '新名称'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    if (LibraryFolders.isReserved(name)) {
      _toast('「${LibraryFolders.reservedName}」是内置文件夹，请换个名称');
      return;
    }
    final ok = await LibraryFolders.instance.rename(oldName, name);
    if (!ok) {
      _toast('名称无效或已存在同名文件夹');
      return;
    }
    if (_folder == oldName) setState(() => _folder = name);
    await _refresh();
  }

  Future<void> _deleteFolder(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除文件夹'),
        content: Text(
            '确定删除文件夹「$name」？其中的视频会移回「全部」，视频文件不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await LibraryFolders.instance.delete(name);
    if (_folder == name) setState(() => _folder = '');
    await _refresh();
  }

  /// 移动底部面板：全部 / 各文件夹 / 新建文件夹
  Future<void> _moveSheet(LibraryItem it) async {
    final folders = LibraryFolders.instance.folders;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '移动「${it.sortName}」到',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('全部（不分组）'),
              trailing: it.folder.isEmpty ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, ''),
            ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('分享（分享导入）'),
              trailing: it.folder == LibraryFolders.reservedName
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.pop(ctx, LibraryFolders.reservedName),
            ),
            for (final f in folders)
              ListTile(
                leading: const Icon(Icons.folder),
                title: Text(f.name),
                trailing: it.folder == f.name ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(ctx, f.name),
              ),
            ListTile(
              leading: const Icon(Icons.create_new_folder),
              title: const Text('新建文件夹…'),
              onTap: () => Navigator.pop(ctx, '__new__'),
            ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    if (picked == '__new__') {
      final name = await _createFolderDialog(selectAfterCreate: false);
      if (name == null) return;
      await DownloadManager.instance.setFolder(it.id, name);
      _toast('已移动到「$name」');
      await _refresh();
      return;
    }
    await DownloadManager.instance.setFolder(it.id, picked);
    _toast(picked.isEmpty ? '已移回「全部」' : '已移动到「$picked」');
    await _refresh();
  }

  Widget _tile(BuildContext context, LibraryItem it, int index,
      List<LibraryItem> all) {
    final more = _moreMenuItems(it);
    return ListTile(
      leading: _leadingIcon(it),
      title: Text(it.sortName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_subtitle(it), style: const TextStyle(fontSize: 12)),
      // 点按即播放，不留播放按钮；所有操作统一收进「更多」菜单
      trailing: more.isEmpty
          ? null
          : PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              tooltip: '更多操作',
              onSelected: (v) => _itemAction(it, index, all, v),
              itemBuilder: (ctx) => more,
            ),
      onTap: () {
        if (!it.active && !it.failed) _play(all, index);
      },
    );
  }

  /// 重命名视频（仅已完成条目）：同步更新磁盘文件名与元数据；
  /// 原生 HLS 缓存（无磁盘路径）仅改标题。
  Future<void> _renameItem(LibraryItem it) async {
    final ctrl = TextEditingController(text: it.sortName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名视频'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(hintText: '新名称'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) {
      if (name != null) _toast('名称不能为空');
      return;
    }
    final ok = await DownloadManager.instance.rename(it.id, name);
    if (!ok) {
      _toast('重命名失败，请稍后重试');
      return;
    }
    _toast('已重命名为「$name」');
    await _refresh();
  }

  /// 删除条目：按类型清理（convert / m3u8 离线任务 + 分片包 / mp4）
  Future<void> _deleteItem(LibraryItem it) async {
    if (it.kind == 'convert') {
      await ConvertManager.instance.delete(it.id);
    } else if (it.kind == 'm3u8') {
      // HLS 离线任务清理其 pending 记录；分片包删除其文件夹
      await HlsManager.instance.delete(it.hlsTaskId ?? it.id);
      await DownloadManager.instance.delete(it.id, it.localPath ?? '');
    } else {
      await DownloadManager.instance.delete(it.id, it.localPath ?? '');
    }
    await _refresh();
  }

  /// 播放：mp4 进入播放列表页（支持上/下一个、连播），m3u8 走原生离线播放
  void _play(List<LibraryItem> all, int index) {
    final it = all[index];
    if (it.kind == 'm3u8') {
      if (it.hlsTaskId == null) {
        _toast('m3u8 分片包请先「本地转 MP4」');
        return;
      }
      HlsManager.instance.play(it.hlsTaskId!);
      return;
    }
    if (it.localPath == null || it.localPath!.isEmpty) return;
    // 当前排序下的可播放 mp4 列表，保证「上一个 / 下一个」与列表顺序一致
    final playlist = <PlayableItem>[
      for (final x in all)
        if (x.kind != 'm3u8' && x.localPath != null && x.localPath!.isNotEmpty)
          PlayableItem(path: x.localPath!, title: x.sortName),
    ];
    var start = playlist.indexWhere((p) => p.path == it.localPath);
    if (start < 0) start = 0;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(playlist: playlist, initialIndex: start),
      ),
    );
  }

  /// 下载中的 mp4：边播边缓存（本地 HTTP 代理，缓存完成即入库；
  /// 非 faststart / 建流失败时自动降级为原始网络直连播放）
  Future<void> _playCaching(LibraryItem it) async {
    final item = await PlaybackCacher.instance
        .start(url: it.url ?? '', title: it.title);
    if (!mounted) return;
    if (item == null) {
      _toast('无法播放该视频（链接不可用）');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(playlist: [item], initialIndex: 0),
      ),
    );
  }

  /// 下载中的 HLS：边下边看（复用同一 AVURLAsset，读已缓存分段）
  void _playHlsCaching(LibraryItem it) {
    final taskId = it.hlsTaskId ?? it.id;
    if (taskId.isEmpty) {
      _toast('该任务暂不支持边下边看');
      return;
    }
    HlsManager.instance.play(taskId, whileDownloading: true);
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
      case 'share':
        return const Icon(Icons.ios_share, color: Colors.teal);
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
    if (it.kind == 'share') return '分享导入 · $date';
    if (it.kind == 'm3u8') return 'HLS 离线缓存 · $date';
    return '${formatBytes(it.size)} · $date';
  }
}
