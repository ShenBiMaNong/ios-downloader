import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../models/library_item.dart';
import '../models/playable_item.dart';
import '../models/video_info.dart';
import '../services/app_settings.dart';
import '../services/download_manager.dart';
import '../services/files_bridge.dart';
import '../services/hls_manager.dart';
import '../services/library_folders.dart';
import '../services/m3u8_convert.dart';
import '../services/playback_cacher.dart';
import '../services/share_import.dart';
import '../services/thumbnailer.dart';
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
    try {
      final saved = await DownloadManager.instance.scanSaved();
      if (!mounted) return;
      setState(() {
        _saved = saved;
        _loading = false;
      });
    } catch (_) {
      // 扫描失败也要退出 loading，否则资源库会永久停在转圈上（列表中什么都看不到）
      if (!mounted) return;
      setState(() => _loading = false);
    }
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
    _toast('已开始转换');
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
        speed: active ? t.speed : 0,
        eta: active ? t.eta : null,
        bytesDone: active ? t.bytesDone : 0,
        bytesTotal: active ? t.bytesTotal : 0,
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
        speed: active ? t.speed : 0,
        eta: active ? t.eta : null,
        bytesDone: active ? t.bytesDone : 0,
        bytesTotal: active ? t.bytesTotal : 0,
        // http_cache_stream 只给比例，总量由「已缓存字节 / 比例」反推 → 估算值
        bytesEstimated: true,
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
        eta: t.done || t.failed ? null : t.eta,
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
        speed: active && t.progress < 1 ? t.speed : 0,
        eta: active && t.progress < 1 ? t.eta : null,
        localPath: t.localPath,
        url: t.url,
        error: t.error,
        doneSegments: t.doneSegments,
        totalSegments: t.totalSegments,
        bytesDone: t.bytes,
        bytesTotal: t.bytesTotal,
        bytesEstimated: t.bytesEstimated,
        resumable: t.resumable,
        failedSegments: t.failedSegments,
        canForceMerge: t.canForceMerge,
        folder: folderById[t.id] ?? '',
        stage: t.stage.isEmpty ? null : t.stage,
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

  /// 目录大小按路径缓存：m3u8 分片包可能有数百个分片，
  /// 不该在列表每次刷新时都重新 stat 一遍。
  final Map<String, int> _sizeCache = {};

  /// 已完成产物大小：mp4 直接取文件长度；m3u8 分片包是目录，递归累加。
  /// 系统 .movpkg 是 Apple 私有 bundle（元数据 hls=true），官方禁止遍历内部文件，
  /// 这类条目在 _saved 映射里直接置 0，不会走到这里。
  int _fileSize(String? path) {
    if (path == null || path.isEmpty) return 0;
    final cached = _sizeCache[path];
    if (cached != null) return cached;
    try {
      int total;
      final dir = Directory(path);
      if (dir.existsSync()) {
        total = _dirSize(dir);
      } else {
        final f = File(path);
        total = f.existsSync() ? f.lengthSync() : 0;
      }
      _sizeCache[path] = total;
      return total;
    } catch (_) {
      return 0;
    }
  }

  static int _dirSize(Directory dir) {
    var total = 0;
    try {
      for (final e in dir.listSync(followLinks: false)) {
        if (e is File) {
          total += e.lengthSync();
        } else if (e is Directory) {
          total += _dirSize(e);
        }
      }
    } catch (_) {}
    return total;
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
                            child: Text('暂无视频'),
                          )
                        : sections.every((s) => s.items.isEmpty)
                            ? Center(
                                child: Text(_folder == LibraryFolders.reservedName
                                    ? '暂无分享'
                                    : '此文件夹为空'),
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

  /// 卡片文字区高度：上下 padding 14 + 两行标题 40 + 间距 2 + 一行摘要 16
  /// 留 4px 余量，避免系统字体放大时 Column 溢出
  static const double _gridTextHeight = 76;

  /// 宫格视图：分组标题 + 每组的卡片网格
  ///
  /// 卡片高度按「16:9 封面 + 固定文字区」算（mainAxisExtent），
  /// 不再用 childAspectRatio —— 那个比例是按卡片宽度换算的，
  /// 窄屏两列时封面只占一半，卡片底部会留出一大片空白。
  Widget _gridList(BuildContext context, List<LibrarySection> sections) {
    const spacing = 12.0;
    const padH = 12.0;
    return LayoutBuilder(
      builder: (ctx, box) {
        final avail = box.maxWidth - padH * 2;
        var cols = (avail / 170).round();
        if (cols < 2) cols = 2;
        final itemW = (avail - spacing * (cols - 1)) / cols;
        // clamp 返回 num，必须显式转 double，否则 mainAxisExtent 类型不匹配
        final coverH = (itemW * 9 / 16).clamp(80.0, 320.0).toDouble();
        final extent = coverH + _gridTextHeight;
        return CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            for (final s in sections) ...[
              if (_folder.isEmpty)
                SliverToBoxAdapter(child: _sectionHeader(s.name, s.items.length)),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(padH, 4, padH, 16),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    mainAxisSpacing: spacing,
                    crossAxisSpacing: spacing,
                    mainAxisExtent: extent,
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
      },
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
        _toast('已开始转换');
      case 'move':
        _moveSheet(it);
      case 'rename':
        _renameItem(it);
      case 'delete':
        _deleteItem(it);
      case 'cancel':
        if (it.id.startsWith(PlaybackCacher.idPrefix)) {
          PlaybackCacher.instance.cancel(it.id);
        } else if (it.kind == 'convert') {
          // 原来 convert 类会误落到 HlsManager.cancel，点「取消」毫无反应；
          // 原生后台作业还要一并取消系统代跑的 task。
          ConvertManager.instance.cancel(it.id);
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
      case 'forcemerge':
        _confirmForceMerge(it);
      case 'detail':
        _showError(it);
      case 'reconvert':
        _reconvertHls(it);
    }
  }

  /// 已完成的系统 HLS 离线缓存（.movpkg 私有格式）无法导出为 mp4：
  /// 用元数据里保存的原始 m3u8 地址重新拉一遍分片并转封装。
  /// 代价是会重新下载一次分片，但产物是可分享/可导出的通用 mp4。
  void _reconvertHls(LibraryItem it) {
    final url = it.url ?? '';
    if (!url.startsWith('http')) {
      _toast('缺少原始 m3u8 地址');
      return;
    }
    ConvertManager.instance.convert(VideoInfo(
      url: url,
      frameUrl: '',
      pageTitle: it.sortName,
    ));
    _toast('已开始重新下载');
  }

  /// 「仍要合成」确认框：缺片出片是一次性决定，代价必须先说清
  Future<void> _confirmForceMerge(LibraryItem it) async {
    final missing = it.failedSegments;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('仍要合成？'),
        content: Text(
          missing > 0
              ? '缺少 $missing 个分片，合成后的视频会缺失对应片段（时长偏短、可能黑屏跳跃）。\n\n'
                  '注意：合成后本次下载即完成，已下分片会被清理，无法再续传补齐缺失部分。\n'
                  '加密流（AES-128）从缺失位置起可能解密失败。'
              : '将用已下载的分片合成视频。\n\n'
                  '注意：合成后本次下载即完成，无法再续传补片。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('仍要合成'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ConvertManager.instance.mergeAnyway(it.id);
    }
  }

  /// 完整错误详情（列表里只显示收敛后的单行摘要）
  void _showError(LibraryItem it) {
    final raw = (it.error ?? '').trim();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('失败原因'),
        content: SingleChildScrollView(
          child: SelectableText(
            raw.isEmpty ? '未知错误' : raw,
            style: const TextStyle(fontSize: 13),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
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
      // 系统 HLS 离线缓存（.movpkg）不能导出：用条目里保存的原始 m3u8 重新拉一遍
      if (it.kind == 'm3u8' &&
          it.hlsTaskId != null &&
          !it.active &&
          !it.failed &&
          (it.url ?? '').startsWith('http'))
        const PopupMenuItem(
            value: 'reconvert', child: Text('重新下载并转 MP4')),
      // 普通 convert 任务在跑的是 Dart 侧 ffmpeg，取消会留下不一致状态，故不开放；
      // 原生后台作业（stage != null）则由系统托管，必须能取消在途 task。
      if (it.active && (it.kind != 'convert' || it.stage != null))
        const PopupMenuItem(value: 'cancel', child: Text('取消')),
      if (it.failed && it.resumable)
        const PopupMenuItem(value: 'resume', child: Text('继续下载')),
      if (it.failed && it.kind == 'convert' && it.canForceMerge)
        PopupMenuItem(
            value: 'forcemerge',
            child: Text('仍要合成（缺 ${it.failedSegments} 片）')),
      if (it.failed)
        const PopupMenuItem(value: 'detail', child: Text('查看错误详情')),
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
      // 所有进行中条目统一显示进度环（原来 convert / 分片包只给一个静态图标，
      // 宫格视图里看不到任何进度）。progress 还是 0 时用不确定态转圈，
      // 避免系统 HLS 缓存（按媒体时长报进度、且酌情下载会择机启动）显示成卡住的 0%。
      final hasProgress = it.progress > 0;
      final pct = (it.progress * 100).clamp(0, 100);
      content = Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 46,
            height: 46,
            child: CircularProgressIndicator(
              value: hasProgress ? it.progress.clamp(0.0, 1.0) : null,
              strokeWidth: 3.5,
              color: scheme.primary,
            ),
          ),
          if (hasProgress)
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
    // 已完成条目（非进行中/失败）优先用真实画面抽帧作封面；
    // 抽帧失败或还在生成时，保持原来的纯色 + 图标封面，不出现白块。
    Widget base = Container(color: bg, child: Center(child: content));
    final src = _thumbSource(it);
    if (src != null) {
      base = FutureBuilder<String?>(
        future: Thumbnailer.get(
          key: it.id,
          path: src.path,
          taskId: src.taskId,
          url: src.url,
        ),
        builder: (ctx, snap) {
          final p = snap.data;
          if (p == null) {
            return Container(color: bg, child: Center(child: content));
          }
          return Image.file(
            File(p),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
            errorBuilder: (_, __, ___) =>
                Container(color: bg, child: Center(child: content)),
          );
        },
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        base,
        if (action != null)
          Positioned(right: 6, bottom: 6, child: action),
      ],
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
      final resume = _smallFab(Icons.play_arrow, '继续下载', () {
        if (it.kind == 'convert') {
          ConvertManager.instance.retry(it.id);
        } else if (it.kind == 'm3u8') {
          HlsManager.instance.retry(it.hlsTaskId ?? it.id);
        } else {
          DownloadManager.instance.resume(it.id);
        }
      });
      // 分片部分失败的 convert 任务：多给一个「仍要合成」入口
      if (it.kind == 'convert' && it.canForceMerge) {
        return Row(mainAxisSize: MainAxisSize.min, children: [
          _smallFab(Icons.merge_type, '仍要合成（缺 ${it.failedSegments} 片）',
              () => _confirmForceMerge(it)),
          resume,
        ]);
      }
      return resume;
    }
    // 失败但不可续传（如清单已丢）：只要工作目录里还有清单和分片，仍可强合
    if (it.failed && it.kind == 'convert' && it.canForceMerge) {
      return _smallFab(Icons.merge_type, '仍要合成（缺 ${it.failedSegments} 片）',
          () => _confirmForceMerge(it));
    }
    if (it.kind == 'm3u8' &&
        it.hlsTaskId == null &&
        it.localPath != null &&
        it.localPath!.isNotEmpty) {
      return _smallFab(Icons.transform, '本地转 MP4', () {
        ConvertManager.instance.convertLocal(it.localPath!);
        _toast('已开始转换');
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
                  // 保持文件夹图标可见：选中时不叠加对号（对号会盖住图标）
                  showCheckmark: false,
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
                  showCheckmark: false,
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
                      showCheckmark: false,
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
      leading: _leading(it),
      title: Text(it.sortName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        _subtitle(it),
        style: const TextStyle(fontSize: 12),
        // 错误信息必须限死单行：原始异常（DioException / ffmpeg 输出尾部）
        // 带换行且超长，直接渲染会把列表行高撑坏
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
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
    // 缩略图缓存随之失效（同 id 重新下载时不该复用旧画面）
    Thumbnailer.evict(it.id);
    // 边播边缓存完成项仍驻留 PlaybackCacher 内存列表：走 cancel 才能连同记录一起清理
    if (PlaybackCacher.instance.tasks.any((t) => t.id == it.id)) {
      await PlaybackCacher.instance.cancel(it.id);
    } else if (ConvertManager.instance.tasks.any((t) => t.id == it.id)) {
      // 转换产物（mp4 / m3u8 分片包）完成态任务仍驻留 ConvertManager 内存列表，
      // 只删磁盘文件会残留列表记录、点播放报「播放失败」
      await ConvertManager.instance.delete(it.id);
    } else {
      if (it.kind == 'm3u8' && it.hlsTaskId != null) {
        // HLS 离线任务清理其 pending 记录与内存任务
        await HlsManager.instance.delete(it.hlsTaskId!);
      }
      await DownloadManager.instance.delete(it.id, it.localPath ?? '');
    }
    await _refresh();
  }

  /// 播放：mp4 进入播放列表页（支持上/下一个、连播），m3u8 走原生离线播放
  void _play(List<LibraryItem> all, int index) {
    final it = all[index];
    if (it.kind == 'm3u8') {
      if (it.hlsTaskId == null) {
        _toast('请先转 MP4');
        return;
      }
      _playHls(it);
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
    _playHls(it, whileDownloading: true);
  }

  /// HLS 播放（离线 / 边下边看）：原生返回 false 时明确提示，
  /// 避免出现「点了按钮毫无反应」的情况
  Future<void> _playHls(LibraryItem it, {bool whileDownloading = false}) async {
    final taskId = it.hlsTaskId ?? it.id;
    if (taskId.isEmpty) {
      _toast('该任务暂不支持播放');
      return;
    }
    final ok = await HlsManager.instance
        .play(taskId, whileDownloading: whileDownloading);
    if (!mounted) return;
    if (!ok) {
      _toast(whileDownloading
          ? '任务不存在，请重新下载'
          : '缓存已失效');
    }
  }

  /// 列表左侧：能出图就用缩略图（56×40 圆角），否则回退到原来的状态图标
  Widget _leading(LibraryItem it) {
    final icon = _leadingIcon(it);
    final src = _thumbSource(it);
    if (src == null) return icon;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 56,
        height: 40,
        child: FutureBuilder<String?>(
          future: Thumbnailer.get(
            key: it.id,
            path: src.path,
            taskId: src.taskId,
            url: src.url,
          ),
          builder: (ctx, snap) {
            final p = snap.data;
            if (p == null) {
              // 还在抽帧 / 抽帧失败：保持原图标，不闪白块
              return ColoredBox(
                color: Colors.black.withValues(alpha: 0.04),
                child: Center(child: icon),
              );
            }
            return Image.file(
              File(p),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.low,
              errorBuilder: (_, __, ___) => ColoredBox(
                color: Colors.black.withValues(alpha: 0.04),
                child: Center(child: icon),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 缩略图源：本地文件 / HLS 离线任务 id / 原始地址（老条目兜底）。
  /// 进行中、失败条目不出图（保留原来的进度/错误封面）。
  ({String? path, String? taskId, String? url})? _thumbSource(LibraryItem it) {
    if (it.active || it.failed) return null;
    final raw = it.url ?? '';
    final remote = raw.startsWith('http') ? raw : null;
    final remoteOnly = remote == null ? null : (path: null, taskId: null, url: remote);
    if (it.kind == 'm3u8') {
      final tid = it.hlsTaskId;
      // 脏记录：旧桥接曾把本地路径当 taskId，这类原生查不到
      if (tid == null ||
          tid.isEmpty ||
          tid.contains('/') ||
          tid.contains(r'\')) {
        return remoteOnly;
      }
      return (path: null, taskId: tid, url: remote);
    }
    final p = it.localPath ?? '';
    if (p.isEmpty) return remoteOnly;
    return (path: p, taskId: null, url: null);
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
    if (it.failed) return _shortError(it.error);
    if (it.active) {
      // 合成阶段没有下行量，单独文案（否则会显示上一阶段的残留字节）
      switch (it.stage) {
        case 'ready':
          return '待合成';
        case 'remuxing':
          return '合成中';
      }
      // 系统 HLS 缓存在起步前不报进度，显示成 0% 会让人以为卡住
      if (it.kind == 'm3u8' && it.hlsTaskId != null && it.progress <= 0) {
        return '系统下载中';
      }
      // 所有下载链路统一口径：速度 → 已下/总量 → 剩余时长 → 已下分片/总分片
      final line = it.progressLine;
      return line.isEmpty ? '准备中' : line;
    }
    final date = it.created.toLocal().toString().substring(0, 10);
    if (it.kind == 'share') {
      final size = formatBytes(it.size);
      return size.isEmpty ? date : '$size · $date';
    }
    if (it.kind == 'm3u8') {
      // 系统 .movpkg 是私有 bundle，遍历不出大小
      if (it.hlsTaskId != null) return '系统缓存 · $date';
      final size = formatBytes(it.size);
      return size.isEmpty ? '分片包 · $date' : '$size · 分片包 · $date';
    }
    return '${formatBytes(it.size)} · $date';
  }

  /// 把异常文本收敛成一行短摘要：只留可读部分，完整内容走「查看错误详情」
  static String _shortError(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '失败';
    var s = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    s = s.replaceFirst(RegExp(r'^(Exception|DioException|Error)[:\s]+'), '');
    // 服务层文案常把「怎么处理」也写进去，列表行只留原因
    s = s.replaceFirst(RegExp(r'[，,]\s*(请|可)[^，,。]*$'), '');
    const max = 32;
    if (s.length > max) s = '${s.substring(0, max)}…';
    return s.isEmpty ? '失败' : s;
  }
}
