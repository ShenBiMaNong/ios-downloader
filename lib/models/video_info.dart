/// 从浏览器嗅探到的视频信息
class VideoInfo {
  final String url;
  final String frameUrl;
  final String pageTitle;

  /// 页内上报的「当前帧地址」，用作防盗链 Referer。
  ///
  /// 必须与嗅探到 URL 的那个 frame 一致：跨域 iframe 播放器拿主框架地址当
  /// Referer 会被 CDN 判 403。空串表示未知，调用方回退到 [frameUrl]。
  final String referer;

  /// 页面播放器报告的视频时长（秒）。0 = 未知。
  ///
  /// 这是判断「拿到的这条清单是不是页面上正在播的那个视频」的外部标尺：
  /// 站点常有主视频 + 预加载下一集 + 预卷广告，几条 m3u8 都是合法清单，
  /// 只看 URL/状态码分不出来，只有 Σ#EXTINF 与它比对才能识别。
  final double duration;

  /// m3u8 / mpd / mp4（直链文件：mp4/mkv/flv/ts…均视为可直接下载） / other
  final String kind;

  VideoInfo({
    required this.url,
    required this.frameUrl,
    required this.pageTitle,
    this.referer = '',
    this.duration = 0,
  }) : kind = _kindOf(url);

  /// 实际可用的 Referer：帧地址优先，其次主框架地址
  String get effectiveReferer =>
      referer.isNotEmpty ? referer : (frameUrl.isNotEmpty ? frameUrl : '');

  static String _kindOf(String url) {
    final u = url.toLowerCase();
    if (u.contains('.m3u8')) return 'm3u8';
    if (u.contains('.mpd')) return 'mpd';
    if (RegExp(r'\.(mp4|mov|webm|mkv|flv|f4v|m4v|ts|m2ts|mts|mpg|mpeg|avi|wmv|asf|3gp|3g2|ogv|ogm|rm|rmvb)([?#]|$)')
        .hasMatch(u)) {
      return 'mp4';
    }
    return 'other';
  }

  bool get isMp4 => kind == 'mp4';
  bool get isHls => kind == 'm3u8';

  Map<String, dynamic> toJson() => {
        'url': url,
        'frame': frameUrl,
        'title': pageTitle,
        'referer': referer,
        'duration': duration,
      };

  factory VideoInfo.fromJson(Map<String, dynamic> j) => VideoInfo(
        url: j['url'] as String,
        frameUrl: (j['frame'] as String?) ?? '',
        pageTitle: (j['title'] as String?) ?? '',
        referer: (j['referer'] as String?) ?? '',
        duration: (j['duration'] as num?)?.toDouble() ?? 0,
      );
}
