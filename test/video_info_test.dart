import 'package:flutter_test/flutter_test.dart';
import 'package:video_downloader/models/video_info.dart';

void main() {
  test('视频类型识别：mp4 / m3u8 / 带查询参数 / 其他', () {
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
  });
}
