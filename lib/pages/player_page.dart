import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import '../models/playable_item.dart';
import '../services/app_log.dart';
import '../services/playback_progress.dart';
import '../services/player_settings.dart';
import 'settings_page.dart';

/// 本地视频播放页：播放列表 + 手势控制（点按暂停、双击快进快退、按住加速）
/// 支持本地文件 / 网络源（边播边缓存本地代理 URL、直连 URL），
/// 网络源自动记忆播放进度，下次打开时从上次位置恢复。
class PlayerPage extends StatefulWidget {
  final List<PlayableItem> playlist;
  final int initialIndex;

  const PlayerPage({super.key, required this.playlist, this.initialIndex = 0});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late VideoPlayerController _controller;
  late int _index;
  bool _initFailed = false;
  bool _completionHandled = false;
  bool _errorReported = false;

  // 进度记忆状态
  Timer? _saveTimer;
  String? _progressKey;
  bool _fallbackUsed = false;

  // 手势状态
  bool? _holdLeft; // true=按住左半边快退，false=按住右半边快进，null=未按住
  Timer? _holdTimer;
  bool _holdWasPlaying = false;
  double? _doubleTapDx;

  @override
  void initState() {
    super.initState();
    PlayerSettings.instance.ensureLoaded();
    if (widget.playlist.isEmpty) {
      // 空列表兜底（正常流程不会发生）
      _initFailed = true;
      _controller = VideoPlayerController.file(File(''));
      return;
    }
    _index = widget.initialIndex.clamp(0, widget.playlist.length - 1);
    _load();
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _saveTimer?.cancel();
    _saveProgressNow();
    _controller.dispose();
    super.dispose();
  }

  void _load() {
    _completionHandled = false;
    _errorReported = false;
    final item = widget.playlist[_index];
    // 主源：playUrl（缓存代理）→ url（直连）；兜底后改用 fallbackUrl
    final play = _fallbackUsed
        ? (item.fallbackUrl ?? item.playUrl ?? item.url)
        : (item.playUrl ?? item.url);
    if (play != null && play.isNotEmpty) {
      _controller = VideoPlayerController.networkUrl(
        Uri.parse(play),
        httpHeaders: item.httpHeaders ?? const {},
      );
    } else {
      _controller = VideoPlayerController.file(File(item.path ?? ''));
    }
    _progressKey = item.url ?? item.path;
    _controller.addListener(_onValueChanged);
    _controller.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
      _restoreProgress();
      _controller.play();
      _startSaveTimer();
    }).catchError((Object e, StackTrace st) {
      AppLog.instance.error(
        'player',
        '视频初始化失败: ${item.path ?? item.url}',
        e,
        st,
      );
      if (!_fallbackUsed &&
          item.fallbackUrl != null &&
          item.fallbackUrl!.isNotEmpty) {
        // 主源（如本地缓存代理）起播失败 → 直连原始 URL 兜底一次
        _fallbackUsed = true;
        _controller.removeListener(_onValueChanged);
        _controller.dispose();
        setState(() {});
        _load();
        return;
      }
      if (mounted) setState(() => _initFailed = true);
    });
  }

  /// 播放到底：按设置「重播当前 / 播放下一个（按播放顺序）」处理
  void _onValueChanged() {
    if (_controller.value.hasError && !_errorReported) {
      _errorReported = true;
      AppLog.instance.error(
        'player',
        '播放出错: ${widget.playlist[_index].path ?? widget.playlist[_index].url}: '
            '${_controller.value.errorDescription ?? '未知错误'}',
      );
    }
    if (!_controller.value.isInitialized) return;
    if (_controller.value.isCompleted) {
      if (!_completionHandled) {
        _completionHandled = true;
        // 播完：清除进度记忆，下次从头播
        final key = _progressKey;
        if (key != null && key.isNotEmpty) {
          PlaybackProgress.instance.clear(key);
        }
        _onComplete();
      }
    } else if (_completionHandled) {
      // 用户往回拖过末尾后又离开末尾，重新武装完成检测
      _completionHandled = false;
    }
  }

  // ---- 播放进度记忆 ----

  /// 打开时从上次位置恢复（网络源；本地文件也统一支持）
  void _restoreProgress() {
    final key = _progressKey;
    if (key == null || key.isEmpty) return;
    final saved = PlaybackProgress.instance.positionOf(key);
    if (saved == null || saved < 10) return;
    final d = _controller.value.duration;
    if (saved >= d.inSeconds - 5) {
      // 已近末尾 → 视为看完，从头播
      PlaybackProgress.instance.clear(key);
      return;
    }
    _controller.seekTo(Duration(seconds: saved));
  }

  void _startSaveTimer() {
    _saveTimer?.cancel();
    _saveTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _saveProgressNow());
  }

  /// 保存当前进度（退出/切歌/暂停/定时时调用；内部按秒落盘）
  void _saveProgressNow() {
    final key = _progressKey;
    if (key == null || key.isEmpty) return;
    if (!_controller.value.isInitialized) return;
    final pos = _controller.value.position.inSeconds;
    if (pos > 5) PlaybackProgress.instance.save(key, pos);
  }

  void _onComplete() {
    final s = PlayerSettings.instance;
    final shouldNext =
        s.onComplete == PlayCompleteAction.next && widget.playlist.length > 1;
    if (!shouldNext) {
      _controller.seekTo(Duration.zero);
      _controller.play();
      _completionHandled = false;
      return;
    }
    _goTo(nextPlaylistIndex(_index, widget.playlist.length, s.order));
  }

  void _goTo(int i) {
    _holdTimer?.cancel();
    _holdTimer = null;
    _holdLeft = null;
    _saveProgressNow();
    _controller.removeListener(_onValueChanged);
    _controller.dispose();
    setState(() {
      _index = i;
      _initFailed = false;
    });
    _load();
  }

  void _togglePlay() {
    if (!_controller.value.isInitialized) return;
    setState(() {
      _controller.value.isPlaying ? _controller.pause() : _controller.play();
    });
    if (!_controller.value.isPlaying) _saveProgressNow();
  }

  void _seekBy(Duration delta) {
    final v = _controller.value;
    if (!v.isInitialized) return;
    var target = v.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > v.duration) target = v.duration;
    _controller.seekTo(target);
  }

  void _seekByTap(double width) {
    final dx = _doubleTapDx;
    if (dx == null) return;
    final s = PlayerSettings.instance;
    _seekBy(Duration(seconds: dx < width / 2 ? -s.seekSeconds : s.seekSeconds));
  }

  void _startHold(bool left) {
    if (!_controller.value.isInitialized) return;
    _holdWasPlaying = _controller.value.isPlaying;
    _holdLeft = left;
    _controller.play();
    if (left) {
      // 按住左半边：按倍速持续快退
      final s = PlayerSettings.instance;
      _holdTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
        _seekBy(Duration(milliseconds: -(300 * s.holdSpeed).round()));
      });
    } else {
      // 按住右半边：加速播放
      _controller.setPlaybackSpeed(PlayerSettings.instance.holdSpeed);
    }
    setState(() {});
  }

  void _endHold() {
    if (_holdLeft == null) return;
    _holdTimer?.cancel();
    _holdTimer = null;
    _controller.setPlaybackSpeed(1.0);
    if (!_holdWasPlaying) _controller.pause();
    _holdLeft = null;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_currentTitle(), maxLines: 1, overflow: TextOverflow.ellipsis),
            if (widget.playlist.length > 1)
              Text(
                '${_index + 1} / ${widget.playlist.length}',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.white70),
              ),
          ],
        ),
      ),
      backgroundColor: Colors.black,
      body: _initFailed
          ? const Center(
              child: Text('播放失败（文件可能损坏或格式不支持）',
                  style: TextStyle(color: Colors.white)))
          : !_controller.value.isInitialized
              ? const Center(child: CircularProgressIndicator(color: Colors.white))
              : _player(),
    );
  }

  String _currentTitle() =>
      widget.playlist.isEmpty ? '' : widget.playlist[_index].title;

  Widget _player() {
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return GestureDetector(
                // 点击任意地方播放/暂停
                behavior: HitTestBehavior.opaque,
                onTap: _togglePlay,
                // 双击左/右半边：按设置秒数快退/快进
                onDoubleTapDown: (d) => _doubleTapDx = d.localPosition.dx,
                onDoubleTap: () => _seekByTap(width),
                // 按住左/右半边：加速快退/快进
                onLongPressStart: (d) =>
                    _startHold(d.localPosition.dx < width / 2),
                onLongPressEnd: (_) => _endHold(),
                onLongPressCancel: _endHold,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Center(
                      child: AspectRatio(
                        aspectRatio: _controller.value.aspectRatio,
                        child: VideoPlayer(_controller),
                      ),
                    ),
                    if (_holdLeft != null) _holdIndicator(),
                  ],
                ),
              );
            },
          ),
        ),
        _controls(),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _holdIndicator() {
    final isLeft = _holdLeft == true;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isLeft ? Icons.fast_rewind : Icons.fast_forward,
              color: Colors.white),
          const SizedBox(width: 8),
          Text(
            isLeft
                ? '按住快退 ×${_fmtSpeed(PlayerSettings.instance.holdSpeed)}'
                : '按住快进 ×${_fmtSpeed(PlayerSettings.instance.holdSpeed)}',
            style: const TextStyle(color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _controls() {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: _controller,
      builder: (context, v, _) {
        final s = PlayerSettings.instance;
        final canNavigate = widget.playlist.length > 1;
        return Column(
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.skip_previous, color: Colors.white),
                  tooltip: '上一个',
                  onPressed: canNavigate
                      ? () => _goTo(previousPlaylistIndex(
                          _index, widget.playlist.length, s.order))
                      : null,
                ),
                _seekButton(
                  forward: false,
                  seconds: s.seekSeconds,
                  onPressed: () =>
                      _seekBy(Duration(seconds: -s.seekSeconds)),
                ),
                Expanded(
                  child: VideoProgressIndicator(
                    _controller,
                    allowScrubbing: true,
                    colors: const VideoProgressColors(
                      playedColor: Colors.indigoAccent,
                      bufferedColor: Colors.white24,
                    ),
                  ),
                ),
                _seekButton(
                  forward: true,
                  seconds: s.seekSeconds,
                  onPressed: () => _seekBy(Duration(seconds: s.seekSeconds)),
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next, color: Colors.white),
                  tooltip: '下一个',
                  onPressed: canNavigate
                      ? () => _goTo(nextPlaylistIndex(
                          _index, widget.playlist.length, s.order))
                      : null,
                ),
              ],
            ),
            Row(
              children: [
                IconButton(
                  icon: Icon(
                    v.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                  ),
                  tooltip: '播放 / 暂停',
                  onPressed: _togglePlay,
                ),
                Text(
                  _fmt(v.position),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(width: 4),
                Text(
                  '/ ${_fmt(v.duration)}',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.settings, color: Colors.white),
                  tooltip: '播放设置',
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsPage(),
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _seekButton({
    required bool forward,
    required int seconds,
    required VoidCallback onPressed,
  }) {
    return TextButton(
      onPressed: onPressed,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            forward ? Icons.fast_forward : Icons.fast_rewind,
            color: Colors.white,
            size: 22,
          ),
          Text(
            '$seconds 秒',
            style: const TextStyle(color: Colors.white70, fontSize: 10),
          ),
        ],
      ),
    );
  }

  String _fmtSpeed(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    if (h > 0) return '${h.toString().padLeft(2, '0')}:$m:$s';
    return '$m:$s';
  }
}
