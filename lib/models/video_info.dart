/// 从浏览器嗅探到的视频信息
class VideoInfo {
  final String url;
  final String frameUrl;
  final String pageTitle;

  /// m3u8 / mpd / mp4（直链文件：mp4/mkv/flv/ts…均视为可直接下载） / other
  final String kind;

  VideoInfo({
    required this.url,
    required this.frameUrl,
    required this.pageTitle,
  }) : kind = _kindOf(url);

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
      };

  factory VideoInfo.fromJson(Map<String, dynamic> j) => VideoInfo(
        url: j['url'] as String,
        frameUrl: (j['frame'] as String?) ?? '',
        pageTitle: (j['title'] as String?) ?? '',
      );
}
