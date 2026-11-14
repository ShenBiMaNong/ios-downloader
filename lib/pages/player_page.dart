import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import '../models/playable_item.dart';
import '../services/app_log.dart';
import '../services/local_media_path.dart';
import '../services/playback_progress.dart';
import '../services/player_settings.dart';
import 'settings_page.dart';

/// 本地视频播放页：播放列表 + 手势控制
/// 点按暂停 / 双击左右半边快退快进 / 长按任意位置加速播放
/// 左右拖动：跟手快退快进（拖动中实时预览目标时间）
/// 上下拖动：上一个 / 下一个（带滑动入场动画）
/// 支持本地文件 / 网络源（边播边缓存本地代理 URL、直连 URL），
/// 网络源自动记忆播放进度，下次打开时从上次位置恢复。
class PlayerPage extends StatefulWidget {
  final List<PlayableItem> playlist;
  final int initialIndex;

  const PlayerPage({super.key, required this.playlist, this.initialIndex = 0});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with SingleTickerProviderStateMixin {
  late VideoPlayerController _controller;
  late int _index;
  bool _initFailed = false;
  bool _completionHandled = false;
  bool _errorReported = false;
  /// 本地文件起播前实测出的具体成因（null = 未检出 / 网络源，用通用文案）
  String? _failureHint;

  // 进度记忆状态
  Timer? _saveTimer;
  String? _progressKey;
  bool _fallbackUsed = false;

  // 手势状态
  bool _holding = false; // 长按加速中
  bool _holdWasPlaying = false;
  double? _doubleTapDx;

  // 左右拖动：快退 / 快进
  bool _hDragging = false;
  double _hDragDx = 0;
  Duration _hDragOrigin = Duration.zero;
  Duration _hDragTarget = Duration.zero;
  DateTime _lastLiveSeek = DateTime.fromMillisecondsSinceEpoch(0);

  // 底部进度条拖动（触控区比视觉轨道大得多）
  Duration? _scrubTarget;
  bool _scrubWasPlaying = false;
  DateTime _lastScrubSeek = DateTime.fromMillisecondsSinceEpoch(0);

  // 上下拖动：上一个 / 下一个
  bool _vDragging = false;
  double _vDragDy = 0;
  static const double _vSwipeThreshold = 72;

  // 切换视频的滑动入场动画（1 = 下一个从右侧滑入，-1 = 上一个从左侧滑入）
  late final AnimationController _slideCtrl;
  double _slideDir = 1;

  @override
  void initState() {
    super.initState();
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: 1, // 初始无动画（位移 0）
    );
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
    _saveTimer?.cancel();
    _slideCtrl.dispose();
    _saveProgressNow();
    _controller.dispose();
    super.dispose();
  }

  void _load() {
    _completionHandled = false;
    _errorReported = false;
    final item = widget.playlist[_index];
    final isLocal = (item.playUrl ?? item.url) == null;
    _failureHint =
        isLocal ? localIssueText(preflightLocalFile(item.path ?? '')) : null;
    if (isLocal && _failureHint != null) {
      // 播放器给的那句 OSStatus 不分成因，这里把实测到的判据一并留进日志，
      // 事后能从日志直接分清「路径失联」还是「字节不是 MP4」
      AppLog.instance.warn(
        'player',
        '本地文件预检不通过: ${item.path} → $_failureHint',
      );
    }
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
    _goTo(nextPlaylistIndex(_index, widget.playlist.length, s.order),
        slideDir: 1);
  }

  /// 切换到指定条目；[slideDir] 非空时播放滑动入场动画
  /// （1 = 下一个，从右侧滑入；-1 = 上一个，从左侧滑入）
  void _goTo(int i, {double? slideDir}) {
    _holding = false;
    _hDragging = false;
    _vDragging = false;
    _vDragDy = 0;
    _scrubTarget = null;
    _saveProgressNow();
    _controller.removeListener(_onValueChanged);
    _controller.dispose();
    setState(() {
      _index = i;
      _initFailed = false;
    });
    _load();
    if (slideDir != null) {
      _slideDir = slideDir;
      _slideCtrl.forward(from: 0);
    }
  }

  /// 上下滑动切歌：方向决定动画入场侧
  void _switchByGesture({required bool next}) {
    if (widget.playlist.length <= 1) return;
    final s = PlayerSettings.instance;
    final i = next
        ? nextPlaylistIndex(_index, widget.playlist.length, s.order)
        : previousPlaylistIndex(_index, widget.playlist.length, s.order);
    _goTo(i, slideDir: next ? 1 : -1);
  }

  bool get _canSwitch => widget.playlist.length > 1;

  // ---- 底部进度条：拖动 / 点按定位 ----

  Duration _ratioToDuration(Duration duration, double ratio) {
    final r = ratio.clamp(0.0, 1.0);
    return Duration(milliseconds: (duration.inMilliseconds * r).round());
  }

  /// 点进度条任意位置直接跳转
  void _scrubTap(double dx, double width) {
    final v = _controller.value;
    if (!v.isInitialized || v.duration <= Duration.zero || width <= 0) return;
    _controller.seekTo(_ratioToDuration(v.duration, dx / width));
  }

  void _scrubStart(double dx, double width) {
    final v = _controller.value;
    if (!v.isInitialized || v.duration <= Duration.zero || width <= 0) return;
    // 拖动期间先暂停，松手后恢复到原来的播放状态，避免画面边拖边跑
    _scrubWasPlaying = v.isPlaying;
    if (_scrubWasPlaying) _controller.pause();
    _scrubTarget = _ratioToDuration(v.duration, dx / width);
    _lastScrubSeek = DateTime.now();
    _controller.seekTo(_scrubTarget!);
    setState(() {});
  }

  void _scrubUpdate(double dx, double width) {
    final v = _controller.value;
    if (_scrubTarget == null ||
        !v.isInitialized ||
        v.duration <= Duration.zero ||
        width <= 0) {
      return;
    }
    final target = _ratioToDuration(v.duration, dx / width);
    _scrubTarget = target;
    setState(() {});
    // 跟手 seek：节流 100ms，兼顾画面预览与解码开销
    final now = DateTime.now();
    if (now.difference(_lastScrubSeek).inMilliseconds >= 100) {
      _lastScrubSeek = now;
      _controller.seekTo(target);
    }
  }

  void _scrubEnd() {
    final target = _scrubTarget;
    if (target == null) return;
    _scrubTarget = null;
    _controller.seekTo(target);
    if (_scrubWasPlaying) _controller.play();
    _scrubWasPlaying = false;
    setState(() {});
  }

  // ---- 左右拖动：快退 / 快进 ----

  void _hDragStart() {
    final v = _controller.value;
    if (!v.isInitialized) return;
    _hDragging = true;
    _hDragDx = 0;
    _hDragOrigin = v.position;
    _hDragTarget = v.position;
    setState(() {});
  }

  void _hDragUpdate(double dx, double width) {
    if (!_hDragging) return;
    final v = _controller.value;
    if (!v.isInitialized || v.duration <= Duration.zero) return;
    _hDragDx += dx;
    // 横向滑满一屏 ≈ 视频总时长的 1/4（上限 180 秒）：既跟手又不会一划到底
    final spanMs = math.min(v.duration.inMilliseconds / 4, 180000).toDouble();
    final deltaMs = (_hDragDx / (width <= 0 ? 1 : width) * spanMs).round();
    var target = _hDragOrigin + Duration(milliseconds: deltaMs);
    if (target < Duration.zero) target = Duration.zero;
    if (target > v.duration) target = v.duration;
    _hDragTarget = target;
    setState(() {});
    // 跟手 seek：节流 120ms，太密集解码器来不及出帧（画面会卡住不更新）
    final now = DateTime.now();
    if (now.difference(_lastLiveSeek).inMilliseconds >= 120) {
      _lastLiveSeek = now;
      _controller.seekTo(target);
    }
  }

  void _hDragEnd() {
    if (!_hDragging) return;
    _hDragging = false;
    _controller.seekTo(_hDragTarget);
    setState(() {});
  }

  void _hDragCancel() {
    if (!_hDragging) return;
    _hDragging = false;
    _controller.seekTo(_hDragTarget);
    setState(() {});
  }

  // ---- 上下拖动：上一个 / 下一个 ----

  void _vDragStart() {
    _vDragging = true;
    _vDragDy = 0;
    setState(() {});
  }

  void _vDragUpdate(double dy) {
    if (!_vDragging) return;
    // 到头了（只有一个视频 / 上拉却没有下一个）→ 位移衰减，给出「拉不动」的手感
    final atEdge = !_canSwitch;
    _vDragDy += atEdge ? dy * 0.3 : dy;
    _vDragDy = _vDragDy.clamp(-120.0, 120.0).toDouble();
    setState(() {});
  }

  void _vDragEnd() {
    if (!_vDragging) return;
    final dy = _vDragDy;
    _vDragging = false;
    _vDragDy = 0;
    setState(() {});
    if (dy <= -_vSwipeThreshold) {
      _switchByGesture(next: true); // 上划 = 下一个
    } else if (dy >= _vSwipeThreshold) {
      _switchByGesture(next: false); // 下划 = 上一个
    }
  }

  void _vDragCancel() {
    if (!_vDragging) return;
    _vDragging = false;
    _vDragDy = 0;
    setState(() {});
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

  /// 长按任意位置：按倍速加速播放，松开恢复
  void _startHold() {
    if (!_controller.value.isInitialized) return;
    _holdWasPlaying = _controller.value.isPlaying;
    _holding = true;
    _controller.play();
    _controller.setPlaybackSpeed(PlayerSettings.instance.holdSpeed);
    setState(() {});
  }

  void _endHold() {
    if (!_holding) return;
    _controller.setPlaybackSpeed(1.0);
    if (!_holdWasPlaying) _controller.pause();
    _holding = false;
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
      // 切歌滑动入场：整块内容（含加载中）从滑动方向滑入并淡入，
      // 让「上/下切歌」有明确的位移反馈，而不是硬切
      body: AnimatedBuilder(
        animation: _slideCtrl,
        builder: (context, child) {
          final t =
              Curves.easeOutCubic.transform(_slideCtrl.value.clamp(0.0, 1.0).toDouble());
          return Transform.translate(
            offset: Offset(_slideDir * (1 - t) * 44, 0),
            child: Opacity(opacity: 0.35 + 0.65 * t, child: child),
          );
        },
        child: _body(),
      ),
    );
  }

  Widget _body() {
    if (_initFailed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            _failureHint ?? '播放失败（文件可能损坏或格式不支持）',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
    }
    if (!_controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    return _player();
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
                // 长按任意位置：加速播放
                onLongPressStart: (_) => _startHold(),
                onLongPressEnd: (_) => _endHold(),
                onLongPressCancel: _endHold,
                // 左右拖动：跟手快退 / 快进
                onHorizontalDragStart: (_) => _hDragStart(),
                onHorizontalDragUpdate: (d) => _hDragUpdate(d.delta.dx, width),
                onHorizontalDragEnd: (_) => _hDragEnd(),
                onHorizontalDragCancel: _hDragCancel,
                // 上下拖动：上一个 / 下一个
                onVerticalDragStart: (_) => _vDragStart(),
                onVerticalDragUpdate: (d) => _vDragUpdate(d.delta.dy),
                onVerticalDragEnd: (_) => _vDragEnd(),
                onVerticalDragCancel: _vDragCancel,
                child: ClipRect(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // 上下拖动时画面跟手位移（切歌的横向滑入在页面级统一做）
                      Transform.translate(
                        offset: Offset(0, _vDragDy * 0.35),
                        child: Center(
                          child: AspectRatio(
                            aspectRatio: _controller.value.aspectRatio,
                            child: VideoPlayer(_controller),
                          ),
                        ),
                      ),
                      if (_hDragging) _seekIndicator(),
                      if (_vDragging) _switchIndicator(),
                      if (_holding) _holdIndicator(),
                    ],
                  ),
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

  /// 左右拖动时的目标时间预览（拖动中实时跟随）
  Widget _seekIndicator() {
    final total = _controller.value.duration;
    final target = _hDragTarget;
    final delta = target - _hDragOrigin;
    final forward = delta.inMilliseconds >= 0;
    final arrow = forward ? Icons.fast_forward : Icons.fast_rewind;
    final sign = forward ? '+' : '-';
    return _overlayPill(
      children: [
        Icon(arrow, color: Colors.white, size: 20),
        const SizedBox(width: 8),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$sign${delta.inSeconds.abs()}s',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '${_fmt(target)} / ${_fmt(total)}',
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ],
        ),
      ],
    );
  }

  /// 上下拖动时的切换提示（上划=下一个，下划=上一个）
  Widget _switchIndicator() {
    final up = _vDragDy <= 0;
    final label = !_canSwitch
        ? '仅一个视频'
        : up
            ? '下一个'
            : '上一个';
    return _overlayPill(
      children: [
        Icon(
          up ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
          color: Colors.white,
          size: 22,
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _overlayPill({required List<Widget> children}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  Widget _holdIndicator() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.fast_forward, color: Colors.white),
          const SizedBox(width: 8),
          Text(
            '按住快进 ×${_fmtSpeed(PlayerSettings.instance.holdSpeed)}',
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
        final scrubbing = _scrubTarget != null;
        final shown = _scrubTarget ?? v.position;
        return Column(
          children: [
            // 进度条单独占一行：左右只剩快退快进按钮，把可拖动宽度尽量放大
            Row(
              children: [
                _seekButton(
                  forward: false,
                  seconds: s.seekSeconds,
                  onPressed: () =>
                      _seekBy(Duration(seconds: -s.seekSeconds)),
                ),
                Expanded(child: _seekbar(v)),
                _seekButton(
                  forward: true,
                  seconds: s.seekSeconds,
                  onPressed: () => _seekBy(Duration(seconds: s.seekSeconds)),
                ),
              ],
            ),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.skip_previous, color: Colors.white),
                  tooltip: '上一个',
                  onPressed: canNavigate
                      ? () => _goTo(
                            previousPlaylistIndex(
                                _index, widget.playlist.length, s.order),
                            slideDir: -1,
                          )
                      : null,
                ),
                IconButton(
                  icon: Icon(
                    v.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                  ),
                  tooltip: '播放 / 暂停',
                  onPressed: _togglePlay,
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next, color: Colors.white),
                  tooltip: '下一个',
                  onPressed: canNavigate
                      ? () => _goTo(
                            nextPlaylistIndex(
                                _index, widget.playlist.length, s.order),
                            slideDir: 1,
                          )
                      : null,
                ),
                const SizedBox(width: 2),
                Text(
                  _fmt(shown),
                  style: TextStyle(
                    color: scrubbing ? Colors.indigoAccent : Colors.white70,
                    fontSize: 12,
                    fontWeight:
                        scrubbing ? FontWeight.w600 : FontWeight.normal,
                  ),
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

  /// 加大可操作性的进度条：40 高的触控区 + 加粗轨道 + 常显滑块，
  /// 点按任意位置跳转，横向拖动跟手预览
  Widget _seekbar(VideoPlayerValue v) {
    final totalMs = v.duration.inMilliseconds;
    final shown = _scrubTarget ?? v.position;
    final progress = totalMs > 0
        ? (shown.inMilliseconds / totalMs).clamp(0.0, 1.0).toDouble()
        : 0.0;
    var buffered = 0.0;
    if (totalMs > 0) {
      for (final r in v.buffered) {
        final end = r.end.inMilliseconds / totalMs;
        if (end > buffered) buffered = end;
      }
    }
    if (buffered < progress) buffered = progress;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _scrubTap(d.localPosition.dx, width),
          onHorizontalDragStart: (d) =>
              _scrubStart(d.localPosition.dx, width),
          onHorizontalDragUpdate: (d) =>
              _scrubUpdate(d.localPosition.dx, width),
          onHorizontalDragEnd: (_) => _scrubEnd(),
          onHorizontalDragCancel: _scrubEnd,
          child: SizedBox(
            height: 40,
            child: CustomPaint(
              painter: _SeekBarPainter(
                progress: progress,
                buffered: buffered.clamp(0.0, 1.0).toDouble(),
                scrubbing: _scrubTarget != null,
              ),
            ),
          ),
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

/// 底部进度条：加粗轨道 + 常显圆形滑块，拖动时整体再放大一档。
/// 触控高度由外层 SizedBox 提供（40），两端留出滑块半径的余量避免被裁切
class _SeekBarPainter extends CustomPainter {
  _SeekBarPainter({
    required this.progress,
    required this.buffered,
    required this.scrubbing,
  });

  final double progress;
  final double buffered;
  final bool scrubbing;

  static const double _thumbInset = 8;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final trackHeight = scrubbing ? 7.0 : 5.0;
    final left = _thumbInset;
    final right = size.width - _thumbInset;
    if (right <= left) return;
    final width = right - left;
    final radius = Radius.circular(trackHeight / 2);

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left, cy - trackHeight / 2, width, trackHeight),
        radius,
      ),
      Paint()..color = Colors.white24,
    );
    if (buffered > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
              left, cy - trackHeight / 2, width * buffered, trackHeight),
          radius,
        ),
        Paint()..color = Colors.white38,
      );
    }
    if (progress > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
              left, cy - trackHeight / 2, width * progress, trackHeight),
          radius,
        ),
        Paint()..color = Colors.indigoAccent,
      );
    }

    final thumbX = left + width * progress;
    final thumbR = scrubbing ? 8.5 : 6.5;
    canvas.drawCircle(
      Offset(thumbX, cy),
      thumbR + 2,
      Paint()..color = Colors.black38,
    );
    canvas.drawCircle(
      Offset(thumbX, cy),
      thumbR,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_SeekBarPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.buffered != buffered ||
      oldDelegate.scrubbing != scrubbing;
}
