import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/video_info.dart';

class ConvertTask {
  final String id;
  final String url;
  final String title;
  double progress = 0; // 0~1（分片下载阶段）
  bool done = false;
  bool failed = false;
  String? error;
  String? localPath;

  ConvertTask({
    required this.id,
    required this.url,
    required this.title,
  });
}

/// m3u8 → mp4（MVP-3）：
/// 拉 master/media 清单 → 解析分片 → Dio 并发下载 → ffmpeg -c copy 无损转封装
class ConvertManager extends ChangeNotifier {
  static final ConvertManager instance = ConvertManager._();

  ConvertManager._() {
    _dio = Dio(BaseOptions(
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
        'Referer': 'https://www.bilibili.com/',
      },
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
    ));
  }

  late final Dio _dio;
  final List<ConvertTask> tasks = [];
  final Set<String> _active = {};

  Future<void> convert(VideoInfo v) async {
    if (_active.contains(v.url)) return;
    _active.add(v.url);
    final task = ConvertTask(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      url: v.url,
      title: v.pageTitle.isNotEmpty ? v.pageTitle : 'HLS视频',
    );
    tasks.add(task);
    notifyListeners();

    Directory? work;
    try {
      final tmpRoot = await getTemporaryDirectory();
      work = await Directory(p.join(tmpRoot.path, 'm3u8_${task.id}')).create(recursive: true);

      // 1) 拉取清单（master → media）
      final playlistText = await _fetchText(v.url);
      final mediaUrl = _selectMediaPlaylist(v.url, playlistText);
      final mediaText = await _fetchText(mediaUrl);

      // 2) 解析分片 + 密钥
      final segs = _parseSegments(mediaUrl, mediaText);
      if (segs.isEmpty) throw Exception('清单中没有可下载的分片');

      // 3) 并发下载分片（批 4 个）
      final urls = segs.map((s) => s.url).toList();
      final names = segs.map((s) => s.name).toList();
      var done = 0;
      for (var i = 0; i < urls.length; i += 4) {
        final batch = <Future<void>>[];
        for (var j = i; j < urls.length && j < i + 4; j++) {
          batch.add(_downloadTo(urls[j], p.join(work.path, names[j])));
        }
        await Future.wait(batch);
        done += batch.length;
        task.progress = done / urls.length;
        notifyListeners();
      }

      // 4) 生成本地清单
      final localPlaylist = p.join(work.path, 'local.m3u8');
      _writeLocalPlaylist(localPlaylist, mediaText, names);
      final outMp4 = p.join(work.path, 'out.mp4');

      // 5) ffmpeg 无损转封装
      final session = await FFmpegKit.execute(
        '-y -i "$localPlaylist" -c copy -movflags +faststart "$outMp4"',
      );
      final rc = await session.getReturnCode();
      if (!ReturnCode.isSuccess(rc)) throw Exception('ffmpeg 转封装失败');

      final f = File(outMp4);
      if (!await f.exists() || await f.length() == 0) throw Exception('输出文件为空');

      // 6) 移动到下载目录并写元数据
      final docs = await getApplicationDocumentsDirectory();
      final dl = Directory(p.join(docs.path, 'Downloads'));
      await dl.create(recursive: true);
      final safe = '${_safeName(task.title)}.mp4';
      final target = p.join(dl.path, safe);
      await f.copy(target);
      task.localPath = target;
      task.done = true;
      task.progress = 1;
      final meta = {
        'id': task.id,
        'url': v.url,
        'title': task.title,
        'kind': 'mp4',
        'localPath': target,
        'savedAt': DateTime.now().toIso8601String(),
      };
      await File(p.join(dl.path, '${task.id}.json')).writeAsString(jsonEncode(meta));
    } catch (e) {
      task.failed = true;
      task.error = e.toString();
    } finally {
      _active.remove(v.url);
      if (work != null && work.existsSync()) {
        try {
          await work.delete(recursive: true);
        } catch (_) {}
      }
      notifyListeners();
    }
  }

  Future<String> _fetchText(String url) async {
    final resp = await _dio.get<String>(url, options: Options(
      responseType: ResponseType.plain,
      headers: {'Accept': '*/*'},
    ));
    return resp.data ?? '';
  }

  Future<void> _downloadTo(String url, String path) async {
    await _dio.download(url, path);
    final f = File(path);
    if (!await f.exists() || await f.length() == 0) {
      throw Exception('分片下载失败: $url');
    }
  }

  /// master 清单选最高码率 media playlist；若本身就是 media 清单则原样返回
  String _selectMediaPlaylist(String baseUrl, String text) {
    if (!text.contains('#EXT-X-STREAM-INF')) return baseUrl;
    final lines = text.split('\n');
    Uri? best;
    var bestBandwidth = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('#EXT-X-STREAM-INF')) {
        final bw = RegExp(r'BANDWIDTH=(\d+)').firstMatch(lines[i]);
        if (bw != null && int.tryParse(bw.group(1)!)! > bestBandwidth) {
          bestBandwidth = int.parse(bw.group(1)!);
          best = Uri.parse(baseUrl).resolve(lines[i + 1].trim());
        }
      }
    }
    if (best == null) throw Exception('未找到 media playlist');
    return best.toString();
  }

  List<({String url, String name})> _parseSegments(String playlistUrl, String text) {
    final base = Uri.parse(playlistUrl);
    final result = <({String url, String name})>[];
    final lines = text.split('\n');
    for (final line in lines) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      final abs = base.resolve(t).toString();
      final name = 'seg_${result.length}.ts';
      result.add((url: abs, name: name));
    }
    return result;
  }

  void _writeLocalPlaylist(String path, String mediaText, List<String> names) {
    final lines = mediaText.split('\n');
    final buf = StringBuffer('#EXTM3U\n');
    var segIndex = 0;
    for (final line in lines) {
      final t = line.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('#')) {
        // 跳过密钥/清单级指令（本地分片不加密），保留 EXTINF
        if (t.startsWith('#EXT-X-KEY')) continue;
        if (t.startsWith('#EXT-X-MAP')) continue;
        buf.writeln(t);
      } else {
        buf.writeln(names[segIndex]);
        segIndex++;
      }
    }
    File(path).writeAsStringSync(buf.toString());
  }

  String _safeName(String raw) {
    var s = raw.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    if (s.length > 80) s = s.substring(0, 80);
    return s.isEmpty ? 'video_${DateTime.now().millisecondsSinceEpoch}' : s;
  }
}
