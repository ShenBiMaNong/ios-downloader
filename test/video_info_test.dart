import 'package:flutter_test/flutter_test.dart';
import 'package:video_downloader/models/video_info.dart';

void main() {
  test('视频类型识别：mp4 / m3u8 / mpd / 更多直链格式 / 其他', () {
    expect(
      VideoInfo(url: 'https://a.com/v.mp4', frameUrl: '', pageTitle: '').kind,
      'mp4',
    );
    expect(
      VideoInfo(url: 'https://a.com/index.m3u8', frameUrl: '', pageTitle: '').kind,
      'm3u8',
    );
    expect(
      VideoInfo(url: 'https://a.com/v.mp4?token=1&x=2', frameUrl: '', pageTitle: '').kind,
      'mp4',
    );
    expect(
      VideoInfo(url: 'https://a.com/stream', frameUrl: '', pageTitle: '').kind,
      'other',
    );
    expect(
      VideoInfo(url: 'https://a.com/x.m3u8', frameUrl: '', pageTitle: '').isHls,
      true,
    );
    // 更多直链格式：mkv/flv/ts/m2ts/avi/wmv/ogv 等均按可直接下载处理
    expect(
      VideoInfo(url: 'https://a.com/movie.mkv', frameUrl: '', pageTitle: '').kind,
      'mp4',
    );
    expect(
      VideoInfo(url: 'https://a.com/live.flv?token=1', frameUrl: '', pageTitle: '').isMp4,
      true,
    );
    expect(
      VideoInfo(url: 'https://a.com/seg.ts', frameUrl: '', pageTitle: '').isMp4,
      true,
    );
    expect(
      VideoInfo(url: 'https://a.com/x.m2ts', frameUrl: '', pageTitle: '').isMp4,
      true,
    );
    // DASH 清单单独分类
    expect(
      VideoInfo(url: 'https://a.com/dash.mpd', frameUrl: '', pageTitle: '').kind,
      'mpd',
    );
  });
}
