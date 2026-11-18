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

/// 本地字节是否为 ISO-BMFF（mp4/mov 系）容器：看头 8 字节的 box 类型。
///
/// 为什么需要它：AVFoundation 打不开文件时给的那句 OSStatus 不区分成因 ——
/// 「路径已经指不到这个文件」和「文件真的不是视频」在播放器眼里是同一个错。
/// 起播前先看一眼头部 box，才能把两种情况分成两条不同的提示，
/// 而不是统统写成「文件可能损坏」（用户据此去重下一个其实好好的文件）。
///
/// 只认头部第一个 box 的类型、不校验长度：够把 HTML 错误页（`<` 开头）、
/// zip 包这类非 mp4 产物挡掉，代价是极端情况下会放过畸形文件 —— 放过是对的，
/// 预检只负责说清已确定的成因，不该拦下本来能播的东西。
bool looksLikeMp4Head(List<int> head) {
  if (head.length < 8) return false;
  const magicBoxes = {
    'ftyp', // 绝大多数 mp4/mov 的开头
    'moov', // 少数工具直接以 moov 起头
    'mdat', // 丢了 ftyp 的流式产物仍是 ISO-BMFF 字节
    'free',
    'skip',
    'wide',
    'uuid',
    'jumb',
    'pnot',
  };
  final type = String.fromCharCodes(head.sublist(4, 8));
  if (magicBoxes.contains(type)) return true;
  // 头 4 字节全 0 是「box 长度未知/超大」的畸形写法，后面若跟着可打印
  // fourcc 也当 ISO-BMFF 处理（这类文件 AVFoundation 一般能读）
  final size = head[0] | head[1] | head[2] | head[3];
  return size == 0 && RegExp(r'^[a-zA-Z0-9]{4}$').hasMatch(type);
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
