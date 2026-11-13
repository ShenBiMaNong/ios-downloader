import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

/// 本地视频播放页
class PlayerPage extends StatefulWidget {
  final String path;
  final String title;

  const PlayerPage({super.key, required this.path, required this.title});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late VideoPlayerController _controller;
  bool _initFailed = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.path));
    _controller.initialize().then((_) {
      if (mounted) setState(() {});
      _controller.play();
    }).catchError((e) {
      if (mounted) setState(() => _initFailed = true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      backgroundColor: Colors.black,
      body: Center(
        child: _initFailed
            ? const Text('播放失败（文件可能损坏或格式不支持）', style: TextStyle(color: Colors.white))
            : _controller.value.isInitialized
                ? _player()
                : const CircularProgressIndicator(color: Colors.white),
      ),
    );
  }

  Widget _player() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AspectRatio(
          aspectRatio: _controller.value.aspectRatio,
          child: VideoPlayer(_controller),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            IconButton(
              icon: Icon(
                _controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
              ),
              onPressed: () {
                setState(() {
                  _controller.value.isPlaying ? _controller.pause() : _controller.play();
                });
              },
            ),
            Expanded(
              child: VideoProgressIndicator(_controller, allowScrubbing: true),
            ),
            Text(
              _fmt(_controller.value.position),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ],
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
