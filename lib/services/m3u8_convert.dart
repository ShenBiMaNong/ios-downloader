import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/video_info.dart';
import 'app_log.dart';
import 'background_task.dart';
import 'file_names.dart';

class ConvertTask {
  final String id;
  final String url; // 远程 URL；本地转换为本地 m3u8 / 文件夹路径
  String title; // 重命名后同步更新（完成项仍驻留内存列表）
  final DateTime startedAt;

  /// remote: 远程 m3u8 URL → mp4；local: 本地 m3u8 → mp4；package: 下载 m3u8 分片包
  final String mode;

  double progress = 0; // 0~1（分片下载阶段）
  double speed = 0; // 字节/秒（分片下载阶段）
  Duration? eta;
  int doneSegments = 0;
  int totalSegments = 0;
  bool done = false;
  bool failed = false;
  String? error;
  String? localPath;

  /// 工作目录；失败/中断时保留，供 retry() 续传
  String? workDir;

  ConvertTask({
    required this.id,
    required this.url,
    required this.title,
    required this.mode,
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now();

  bool get resumable => !done && workDir != null && workDir!.isNotEmpty;

  /// 中断时的持久化状态（供下次启动恢复续传）
  Map<String, dynamic> toPendingJson() => {
        'id': id,
        'url': url,
        'title': title,
        'mode': mode,
        'workDir': workDir,
        'startedAt': startedAt.toIso8601String(),
        'error': error,
      };

  factory ConvertTask.fromPendingJson(Map<String, dynamic> j) => ConvertTask(
        id: j['id'] as String,
        url: (j['url'] as String?) ?? '',
        title: (j['title'] as String?) ?? '',
        mode: (j['mode'] as String?) ?? 'remote',
        startedAt: DateTime.tryParse((j['startedAt'] as String?) ?? ''),
      )
        ..workDir = j['workDir'] as String?
        ..failed = true
        ..error = (j['error'] as String?) ?? '已暂停，可继续下载';
}

/// m3u8 → mp4（MVP-3）：
/// 拉 master/media 清单 → 解析分片与 AES-128 密钥 → 并发下载 → ffmpeg -c copy 无损转封装
/// 支持：远程 URL / 本地 m3u8 文件（文件夹）直接转换 / 下载 m3u8 分片包离线备用；
/// 加密分片（AES-128）由 ffmpeg 解封装时解密；失败保留分片可续传。
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
  bool _loaded = false;

  /// 启动时恢复未完成的转换任务（复用保留的分片工作目录）
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'Downloads'));
      if (!await dir.exists()) return;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.convert.json')) {
          try {
            final j = jsonDecode(await entity.readAsString());
            if (j is! Map<String, dynamic>) continue;
            final t = ConvertTask.fromPendingJson(j);
            if (tasks.any((x) => x.id == t.id)) continue;
            if (t.workDir == null || !Directory(t.workDir!).existsSync()) {
              // 分片缓存已丢失，无法续传，清理记录
              if (await entity.exists()) await entity.delete();
              continue;
            }
            tasks.insert(0, t);
          } catch (e, st) {
            AppLog.instance
                .warn('convert', '解析转换断点记录失败: ${entity.path}', e, st);
          }
        }
      }
      if (tasks.isNotEmpty) notifyListeners();
    } catch (e, st) {
      AppLog.instance.error('convert', '启动时恢复转换任务失败', e, st);
    }
  }

  // ---------- 入口 ----------

  /// 远程 m3u8 URL → mp4
  Future<void> convert(VideoInfo v) => _start(
        mode: 'remote',
        key: v.url,
        url: v.url,
        title: v.pageTitle.isNotEmpty ? v.pageTitle : 'HLS视频',
      );

  /// 下载 m3u8 分片包（含密钥）到 Downloads，可离线本地转 mp4
  Future<void> downloadM3u8(VideoInfo v) => _start(
        mode: 'package',
        key: v.url,
        url: v.url,
        title: v.pageTitle.isNotEmpty ? v.pageTitle : 'HLS视频',
      );

  /// 本地 m3u8 文件或包含 .m3u8 的文件夹 → mp4
  Future<void> convertLocal(String folderOrFile) {
    final name = p.basenameWithoutExtension(folderOrFile);
    return _start(
      mode: 'local',
      key: folderOrFile,
      url: folderOrFile,
      title: name.isEmpty ? '本地HLS' : name,
    );
  }

  /// 续传失败/中断的转换任务（复用保留的工作目录与分片）
  Future<void> retry(String id) async {
    ConvertTask? task;
    for (final t in tasks) {
      if (t.id == id) {
        task = t;
        break;
      }
    }
    if (task == null || task.done) return;
    if (task.workDir == null ||
        !Directory(task.workDir!).existsSync()) {
      task.failed = false;
      task.error = '分片缓存已失效，请重新发起转换';
      task.workDir = null;
      notifyListeners();
      return;
    }
    if (_active.contains(task.url)) return;
    _active.add(task.url);
    task.failed = false;
    task.error = null;
    task.progress = 0;
    task.doneSegments = 0;
    notifyListeners();
    await _run(task);
    _active.remove(task.url);
    notifyListeners();
  }

  Future<void> delete(String id) async {
    ConvertTask? t;
    for (final x in tasks) {
      if (x.id == id) {
        t = x;
        break;
      }
    }
    tasks.removeWhere((x) => x.id == id);
    try {
      if (t?.workDir != null && Directory(t!.workDir!).existsSync()) {
        await Directory(t.workDir!).delete(recursive: true);
      }
      final docs = await getApplicationDocumentsDirectory();
      final dl = Directory(p.join(docs.path, 'Downloads'));
      final meta = File(p.join(dl.path, '$id.json'));
      if (await meta.exists()) await meta.delete();
      if (t?.localPath != null) {
        final lp = t!.localPath!;
        final d = Directory(lp);
        if (await d.exists()) {
          await d.delete(recursive: true);
        } else {
          final f = File(lp);
          if (await f.exists()) await f.delete();
        }
      }
      await _removePendingById(id);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _savePending(ConvertTask t) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'Downloads'));
      await dir.create(recursive: true);
      await File(p.join(dir.path, '${t.id}.convert.json'))
          .writeAsString(jsonEncode(t.toPendingJson()));
    } catch (_) {}
  }

  Future<void> _clearPending(ConvertTask t) => _removePendingById(t.id);

  Future<void> _removePendingById(String id) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'Downloads'));
      final f = File(p.join(dir.path, '$id.convert.json'));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> _start({
    required String mode,
    required String key,
    required String url,
    required String title,
  }) async {
    if (_active.contains(key)) return;
    _active.add(key);
    final task = ConvertTask(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      url: url,
      title: title,
      mode: mode,
    );
    tasks.add(task);
    notifyListeners();
    await _savePending(task);
    await _run(task);
    _active.remove(key);
    notifyListeners();
  }

  Future<void> _run(ConvertTask task) async {
    final bg = await BackgroundTask.begin();
    try {
      Directory? work;
      if (task.workDir != null && Directory(task.workDir!).existsSync()) {
        work = Directory(task.workDir!);
      } else {
        final tmpRoot = await getTemporaryDirectory();
        work = await Directory(p.join(tmpRoot.path, 'm3u8_${task.id}'))
            .create(recursive: true);
        task.workDir = work.path;
      }
      // 工作目录确定后落盘，确保进程被杀后重启可恢复
      await _savePending(task);
      switch (task.mode) {
        case 'local':
          await _convertLocal(task, work);
          await _finishMp4(task, work);
          break;
        case 'package':
          await _downloadPackage(task, work);
          break;
        default:
          await _convertRemote(task, work);
          await _finishMp4(task, work);
          break;
      }
    } catch (e) {
      task.failed = true;
      task.error = e.toString();
      // 工作目录保留，供 retry() 续传；持久化以便重启后恢复
      await _savePending(task);
      AppLog.instance.error(
        'convert',
        'm3u8 ${task.mode} 失败: ${task.title}（${task.url}）',
        e,
      );
    } finally {
      await BackgroundTask.end(bg);
      notifyListeners();
    }
  }

  // ---------- 远程 m3u8 → mp4 ----------

  Future<void> _convertRemote(ConvertTask task, Directory work) async {
    // 1) 拉取清单（master → media）
    final playlistText = await _fetchText(task.url);
    final mediaUrl = _selectMediaPlaylist(task.url, playlistText);
    final mediaText = await _fetchText(mediaUrl);

    // 2) 解析分片 + 密钥（AES-128）
    final lines = _parsePlaylist(mediaUrl, mediaText);
    final segs = lines.where((l) => l.type == 'seg').toList();
    if (segs.isEmpty) throw Exception('清单中没有可下载的分片');
    task.totalSegments = segs.length;

    // 3) 密钥下载
    final keyLocal = await _fetchKeys(work, lines,
        referer: Uri.tryParse(mediaUrl)?.origin);

    // 4) 并发下载分片（跳过已存在的，断点续传）
    final urls = segs.map((s) => s.url!).toList();
    final names = segs.map((s) => s.name!).toList();
    await _downloadSegments(task, work, urls, names);

    // 5) 生成本地清单
    final localPlaylist = p.join(work.path, 'local.m3u8');
    _writeLocalPlaylist(localPlaylist, lines, keyLocal, names);

    // 6) ffmpeg 无损转封装（解密在解封装阶段由 ffmpeg 完成）
    await _remux(localPlaylist, p.join(work.path, 'out.mp4'));
  }

  // ---------- 本地 m3u8 → mp4 ----------

  Future<void> _convertLocal(ConvertTask task, Directory work) async {
    // 优先复用工作目录中已有的本地清单（重启恢复：原始文件夹可能已不可访问）
    final resumePlaylist = File(p.join(work.path, 'local.m3u8'));
    var text = '';
    var mediaDir = work.path;
    // 分片源目录：恢复时即工作目录自身；首次转换时为源 m3u8 所在目录
    Directory baseDir = Directory(work.path);
    if (await resumePlaylist.exists()) {
      text = await resumePlaylist.readAsString();
    } else {
      // 定位 m3u8：文件本身，或文件夹内第一个 .m3u8
      File? src;
      if (Directory(task.url).existsSync()) {
        src = _findM3u8(Directory(task.url));
      } else if (File(task.url).existsSync()) {
        src = File(task.url);
      }
      if (src == null) throw Exception('未找到 m3u8 文件: ${task.url}');
      baseDir = src.parent;

      text = await src.readAsString();
      // master 清单 → 选择最高码率 media 清单（本地变体），以其所在目录解析分片
      var mediaPath = src.path;
      if (text.contains('#EXT-X-STREAM-INF')) {
        final rel = _selectMediaPlaylistLocal(baseDir.path, text);
        mediaPath = rel;
        text = await File(rel).readAsString();
      }
      mediaDir = p.dirname(mediaPath);
    }

    final lines = _parsePlaylistLocal(mediaDir, text);
    final segs = lines.where((l) => l.type == 'seg').toList();
    if (segs.isEmpty) throw Exception('清单中没有可用的本地分片');
    task.totalSegments = segs.length;

    // 密钥：本地复制 / 远程下载
    final keyLocal = await _fetchKeys(work, lines,
        referer: Uri.tryParse(task.url)?.origin);

    // 复制分片（已存在的跳过）
    final names = segs.map((s) => s.name!).toList();
    await _copyLocalSegments(task, work, baseDir.path, segs, names);

    final localPlaylist = p.join(work.path, 'local.m3u8');
    _writeLocalPlaylist(localPlaylist, lines, keyLocal, names);

    await _remux(localPlaylist, p.join(work.path, 'out.mp4'));
  }

  // ---------- 下载 m3u8 分片包（离线备用，可再本地转 mp4） ----------

  Future<void> _downloadPackage(ConvertTask task, Directory work) async {
    final playlistText = await _fetchText(task.url);
    final mediaUrl = _selectMediaPlaylist(task.url, playlistText);
    final mediaText = await _fetchText(mediaUrl);

    final lines = _parsePlaylist(mediaUrl, mediaText);
    final segs = lines.where((l) => l.type == 'seg').toList();
    if (segs.isEmpty) throw Exception('清单中没有可下载的分片');
    task.totalSegments = segs.length;

    final keyLocal = await _fetchKeys(work, lines,
        referer: Uri.tryParse(mediaUrl)?.origin);

    final urls = segs.map((s) => s.url!).toList();
    final names = segs.map((s) => s.name!).toList();
    await _downloadSegments(task, work, urls, names);

    final localPlaylist = p.join(work.path, 'playlist.m3u8');
    _writeLocalPlaylist(localPlaylist, lines, keyLocal, names);

    // 整个工作目录 → Downloads/<标题>_m3u8/（重名时自动追加序号，不再覆盖旧包）
    final docs = await getApplicationDocumentsDirectory();
    final dl = Directory(p.join(docs.path, 'Downloads'));
    await dl.create(recursive: true);
    final folderName = uniqueFileName(dl, '${safeFileName(task.title)}_m3u8');
    final folder = Directory(p.join(dl.path, folderName));
    await _copyDir(work, folder);
    task.localPath = folder.path;
    task.done = true;
    task.progress = 1;
    final meta = {
      'id': task.id,
      'url': task.url,
      'title': task.title,
      'kind': 'm3u8',
      'localPath': folder.path,
      'm3u8Package': true,
      'folder': '',
      'savedAt': DateTime.now().toIso8601String(),
    };
    await File(p.join(dl.path, '${task.id}.json')).writeAsString(jsonEncode(meta));
    // 成功：清理工作目录与 pending 记录
    if (work.existsSync()) {
      try {
        await work.delete(recursive: true);
      } catch (_) {}
    }
    task.workDir = null;
    await _clearPending(task);
  }

  // ---------- 收尾（mp4 输出 → Downloads） ----------

  Future<void> _finishMp4(ConvertTask task, Directory work) async {
    final outMp4 = p.join(work.path, 'out.mp4');
    final f = File(outMp4);
    if (!await f.exists() || await f.length() == 0) throw Exception('输出文件为空');

    final docs = await getApplicationDocumentsDirectory();
    final dl = Directory(p.join(docs.path, 'Downloads'));
    await dl.create(recursive: true);
    // 与已存文件重名时自动追加序号，不再覆盖
    final safe = uniqueFileName(dl, '${safeFileName(task.title)}.mp4');
    final target = p.join(dl.path, safe);
    await f.copy(target);
    task.localPath = target;
    task.done = true;
    task.progress = 1;
    final meta = {
      'id': task.id,
      'url': task.url,
      'title': task.title,
      'kind': 'mp4',
      'localPath': target,
      'folder': '',
      'savedAt': DateTime.now().toIso8601String(),
    };
    await File(p.join(dl.path, '${task.id}.json')).writeAsString(jsonEncode(meta));
    // 成功：清理工作目录与 pending 记录
    if (work.existsSync()) {
      try {
        await work.delete(recursive: true);
      } catch (_) {}
    }
    task.workDir = null;
    await _clearPending(task);
  }

  // ---------- 网络/IO 基础 ----------

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

  /// 并发下载分片（批 4 个）；已存在且非空的分片跳过（续传）
  Future<void> _downloadSegments(
      ConvertTask task, Directory work, List<String> urls, List<String> names) async {
    // 统计已有分片（续传起点）
    var existing = 0;
    for (var i = 0; i < names.length; i++) {
      final f = File(p.join(work.path, names[i]));
      if (await f.exists() && await f.length() > 0) existing++;
    }
    var done = 0;
    var cumulative = 0;
    var lastBytes = 0;
    var lastTime = DateTime.now();
    for (var i = 0; i < urls.length; i += 4) {
      final batch = <Future<void>>[];
      for (var j = i; j < urls.length && j < i + 4; j++) {
        final f = File(p.join(work.path, names[j]));
        if (await f.exists() && await f.length() > 0) continue;
        batch.add(_downloadTo(urls[j], p.join(work.path, names[j])));
      }
      await Future.wait(batch);
      done += batch.length;
      task.doneSegments = existing + done;
      task.progress = urls.isEmpty ? 0 : (existing + done) / urls.length;
      var batchBytes = 0;
      for (var j = i; j < urls.length && j < i + 4; j++) {
        try {
          batchBytes += File(p.join(work.path, names[j])).lengthSync();
        } catch (_) {}
      }
      cumulative += batchBytes;
      final now = DateTime.now();
      final dtMs = now.difference(lastTime).inMilliseconds;
      if (dtMs >= 800) {
        final dBytes = cumulative - lastBytes;
        if (dBytes > 0 && dtMs > 0) {
          task.speed = dBytes / (dtMs / 1000.0);
          if (done > 0 && task.speed > 0) {
            final avg = cumulative / done;
            final remBytes = avg * (urls.length - existing - done);
            task.eta = Duration(seconds: (remBytes / task.speed).round());
          }
        }
        lastBytes = cumulative;
        lastTime = now;
      }
      notifyListeners();
    }
  }

  /// 复制本地分片到工作目录（已存在的跳过）
  Future<void> _copyLocalSegments(ConvertTask task, Directory work,
      String baseDir, List<_PlaylistEntry> segs, List<String> names) async {
    var existing = 0;
    for (var i = 0; i < names.length; i++) {
      final f = File(p.join(work.path, names[i]));
      if (await f.exists() && await f.length() > 0) existing++;
    }
    var done = 0;
    for (var i = 0; i < segs.length; i++) {
      final srcPath = segs[i].url!;
      final src = File(srcPath);
      if (!await src.exists()) {
        throw Exception('本地缺少分片文件: $srcPath');
      }
      final dst = p.join(work.path, names[i]);
      if (File(dst).existsSync() && File(dst).lengthSync() > 0) continue;
      await src.copy(dst);
      done++;
      task.doneSegments = existing + done;
      task.progress = segs.isEmpty ? 0 : (existing + done) / segs.length;
      notifyListeners();
    }
  }

  /// 下载/复制 AES-128 密钥到工作目录；返回 源地址 → 本地文件名 映射
  Future<Map<String, String>> _fetchKeys(Directory work,
      List<_PlaylistEntry> lines, {String? referer}) async {
    final map = <String, String>{};
    var i = 0;
    for (final e in lines.where((l) => l.type == 'key')) {
      final src = e.url!;
      if (map.containsKey(src)) continue;
      final localName = 'key_$i.bin';
      final localPath = p.join(work.path, localName);
      try {
        if (e.remote) {
          final resp = await _dio.get<List<int>>(src, options: Options(
            responseType: ResponseType.bytes,
            headers: {
              if (referer != null && referer.isNotEmpty) 'Referer': referer,
            },
          ));
          await File(localPath).writeAsBytes(resp.data ?? const [], flush: true);
        } else {
          final srcFile = File(src);
          if (!await srcFile.exists()) throw Exception('本地缺少密钥文件: $src');
          await srcFile.copy(localPath);
        }
        if (await File(localPath).length() == 0) {
          throw Exception('密钥文件为空: $src');
        }
      } catch (err) {
        throw Exception('获取 AES-128 密钥失败: $src ($err)');
      }
      map[src] = localName;
      i++;
    }
    return map;
  }

  Future<void> _remux(String playlist, String out) async {
    final session = await FFmpegKit.execute(
      '-y -i "$playlist" -c copy -movflags +faststart "$out"',
    );
    final rc = await session.getReturnCode();
    if (!ReturnCode.isSuccess(rc)) {
      // 详细报错：收集 ffmpeg 输出尾部，便于排查
      var tail = '';
      try {
        final so = await session.getOutput();
        final sl = await session.getLogs();
        tail = _lastLines('$so\n$sl', 8);
      } catch (_) {}
      AppLog.instance.error(
        'convert',
        'ffmpeg 转封装失败（$playlist）',
        tail.isEmpty ? null : tail,
      );
      throw Exception('ffmpeg 转封装失败${tail.isEmpty ? '' : '：$tail'}');
    }
    final f = File(out);
    if (!await f.exists() || await f.length() == 0) throw Exception('输出文件为空');
  }

  /// 取文本末尾 n 行（报错摘要）
  static String _lastLines(String text, int n) {
    final lines = text.trim().split('\n');
    if (lines.length <= n) return lines.join('\n');
    return lines.sublist(lines.length - n).join('\n');
  }

  // ---------- 清单解析 ----------

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

  /// 本地 master 清单 → 最高码率 media 清单相对路径
  String _selectMediaPlaylistLocal(String baseDir, String text) {
    final lines = text.split('\n');
    String? best;
    var bestBandwidth = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('#EXT-X-STREAM-INF')) {
        final bw = RegExp(r'BANDWIDTH=(\d+)').firstMatch(lines[i]);
        if (bw != null && int.tryParse(bw.group(1)!)! > bestBandwidth) {
          bestBandwidth = int.parse(bw.group(1)!);
          best = lines[i + 1].trim();
        }
      }
    }
    if (best == null) throw Exception('未找到本地 media playlist');
    return p.normalize(p.join(baseDir, best));
  }

  /// 解析远程 media 清单：分片 + AES-128 密钥位置（保持原始顺序）
  List<_PlaylistEntry> _parsePlaylist(String playlistUrl, String text) {
    final base = Uri.parse(playlistUrl);
    final result = <_PlaylistEntry>[];
    var segCount = 0;
    final lines = text.split('\n');
    for (final raw in lines) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('#EXT-X-KEY')) {
        final k = _parseKey(t);
        if (k.method == 'AES-128') {
          if (k.uri == null || k.uri!.isEmpty) continue;
          result.add(_PlaylistEntry.key(
            url: base.resolve(k.uri!).toString(),
            iv: k.iv,
            remote: true,
            raw: raw,
          ));
        } else if (k.method == 'NONE') {
          result.add(_PlaylistEntry.plain(raw)); // 保持位置（清除密钥状态）
        } else {
          throw Exception('暂不支持的加密方式: ${k.method}');
        }
        continue;
      }
      if (t.startsWith('#')) {
        result.add(_PlaylistEntry.plain(raw));
        continue;
      }
      final abs = base.resolve(t).toString();
      result.add(_PlaylistEntry.seg(
        url: abs,
        name: 'seg_$segCount.ts',
        remote: true,
        raw: raw,
      ));
      segCount++;
    }
    return result;
  }

  /// 解析本地 media 清单：分片为本地路径，密钥可为本地文件或远程 URL
  List<_PlaylistEntry> _parsePlaylistLocal(String baseDir, String text) {
    final result = <_PlaylistEntry>[];
    var segCount = 0;
    final lines = text.split('\n');
    for (final raw in lines) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('#EXT-X-KEY')) {
        final k = _parseKey(t);
        if (k.method == 'AES-128') {
          if (k.uri == null || k.uri!.isEmpty) continue;
          final isRemote = k.uri!.toLowerCase().startsWith('http');
          result.add(_PlaylistEntry.key(
            url: isRemote ? k.uri! : p.normalize(p.join(baseDir, k.uri!)),
            iv: k.iv,
            remote: isRemote,
            raw: raw,
          ));
        } else if (k.method == 'NONE') {
          result.add(_PlaylistEntry.plain(raw));
        } else {
          throw Exception('暂不支持的加密方式: ${k.method}');
        }
        continue;
      }
      if (t.startsWith('#')) {
        result.add(_PlaylistEntry.plain(raw));
        continue;
      }
      final local = p.normalize(p.join(baseDir, t));
      result.add(_PlaylistEntry.seg(
        url: local,
        name: 'seg_$segCount.ts',
        remote: false,
        raw: raw,
      ));
      segCount++;
    }
    return result;
  }

  /// 解析 #EXT-X-KEY 行 → (method, uri, iv)
  ({String method, String? uri, String? iv}) _parseKey(String line) {
    final m = RegExp(r'#EXT-X-KEY:(.+)').firstMatch(line);
    if (m == null) return (method: 'NONE', uri: null, iv: null);
    final attrs = <String, String>{};
    final re = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,"]*)');
    for (final mm in re.allMatches(m.group(1)!)) {
      var v = mm.group(2)!;
      if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
        v = v.substring(1, v.length - 1);
      }
      attrs[mm.group(1)!] = v;
    }
    return (
      method: attrs['METHOD'] ?? 'NONE',
      uri: attrs['URI'],
      iv: attrs['IV'],
    );
  }

  /// 生成本地清单：密钥行改写为本地密钥文件（保留 IV），分片行改写为本地文件名
  void _writeLocalPlaylist(String path, List<_PlaylistEntry> lines,
      Map<String, String> keyLocal, List<String> names) {
    final buf = StringBuffer('#EXTM3U\n');
    var segIndex = 0;
    for (final e in lines) {
      switch (e.type) {
        case 'seg':
          buf.writeln(names[segIndex]);
          segIndex++;
          break;
        case 'key':
          final local = keyLocal[e.url];
          if (local == null) continue;
          var line = '#EXT-X-KEY:METHOD=AES-128,URI="$local"';
          if (e.iv != null && e.iv!.isNotEmpty) line += ',IV=${e.iv}';
          buf.writeln(line);
          break;
        default:
          // 保留 EXTINF / MEDIA-SEQUENCE 等指令（默认 IV 依赖序列号）；跳过 MAP
          if (e.raw.trim().startsWith('#EXT-X-MAP')) continue;
          buf.writeln(e.raw);
          break;
      }
    }
    File(path).writeAsStringSync(buf.toString());
  }

  File? _findM3u8(Directory dir) {
    if (!dir.existsSync()) return null;
    for (final e in dir.listSync(followLinks: false)) {
      if (e is File && p.extension(e.path).toLowerCase() == '.m3u8') return e;
    }
    return null;
  }

  Future<void> _copyDir(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final e in from.list(followLinks: false)) {
      if (e is Directory) {
        await _copyDir(e, Directory(p.join(to.path, p.basename(e.path))));
      } else if (e is File) {
        await File(p.join(to.path, p.basename(e.path)))
            .writeAsBytes(await e.readAsBytes());
      }
    }
  }
}

/// 清单行：分片 / 密钥 / 其它指令（保持顺序）
class _PlaylistEntry {
  final String type; // seg | key | plain
  final String raw;
  final String? url; // seg: 下载地址（URI 或本地绝对路径）；key: 密钥源地址
  final bool remote; // url 是否为网络地址
  final String? name; // seg 文件名
  final String? iv; // key: 显式 IV

  _PlaylistEntry.seg({
    required this.url,
    required this.name,
    required this.remote,
    required this.raw,
  })  : type = 'seg',
        iv = null;

  _PlaylistEntry.key({
    required this.url,
    required this.iv,
    required this.remote,
    required this.raw,
  })  : type = 'key',
        name = null;

  _PlaylistEntry.plain(this.raw)
      : type = 'plain',
        url = null,
        remote = false,
        name = null,
        iv = null;
}
