import 'package:dio/dio.dart';

/// MP4 faststart 探测：判断 moov（元数据）是否位于文件头部。
/// 「边下边播」的硬性前提：moov 在 mdat（或 moof 分片）之前；
/// moov 在尾部的普通 mp4 在下载完成前无法被播放器解析。
///
/// 判定原理：按 box 链解析文件头（size 4B 大端 + fourcc 4B）：
/// `ftyp → (free/wide) → moov → mdat`；moov 出现在 mdat 前即 faststart；
/// fMP4 则 moov/mvex 在前、moof+mdat 分片在后。
const _ua =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 '
    'Safari/604.1';

/// 从文件头部字节流判定 faststart：
/// - true：在头部窗口内先看到 moov（且未先出现 mdat/moof）→ 可边下边播
/// - false：先看到 mdat/moof 而未见 moov → moov 在尾部，部分下载不可解析
/// - null：窗口内无法判定（数据不足 / 畸形 box）
bool? faststartFromHead(List<int> head) {
  var off = 0;
  final n = head.length;
  var sawMoov = false;
  while (off + 8 <= n) {
    final size = (head[off] << 24) |
        (head[off + 1] << 16) |
        (head[off + 2] << 8) |
        head[off + 3];
    final type = String.fromCharCodes(head, off + 4, off + 8);
    if (type == 'moov') {
      sawMoov = true;
    } else if (type == 'mdat' || type == 'moof') {
      // 先见媒体数据/分片而未见 moov → 元数据在尾部
      return sawMoov ? true : false;
    }
    // size==1 表示 64 位 largesize、size==0 表示延伸至文件尾：头部场景不再深入
    if (size < 8 || size == 1) return sawMoov ? true : null;
    if (size == 0) return sawMoov ? true : null;
    off += size;
    if (off > n) break;
  }
  // 窗口耗尽：已见 moov 视为 faststart（ftyp+moov 通常占头几十字节）；否则无法判定
  return sawMoov ? true : null;
}

/// 网络探测：Range 读源文件头 8KB 判断 faststart。
/// 探测失败返回 null（由调用方降级为网络直连播放）。
Future<bool?> probeFaststart(String url, {String? referer}) async {
  try {
    final resp = await Dio().get<List<int>>(
      url,
      options: Options(
        responseType: ResponseType.bytes,
        headers: {
          'User-Agent': _ua,
          if (referer != null && referer.isNotEmpty) 'Referer': referer,
          'Range': 'bytes=0-8191',
        },
        receiveTimeout: const Duration(seconds: 10),
      ),
    );
    final body = resp.data;
    if (body == null || body.isEmpty) return null;
    final head = body.length > 8192 ? body.sublist(0, 8192) : body;
    return faststartFromHead(head);
  } catch (_) {
    return null;
  }
}
