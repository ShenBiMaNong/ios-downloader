import 'package:flutter_test/flutter_test.dart';
import 'package:video_downloader/services/ad_detect.dart';

void main() {
  group('isAdHost', () {
    test('识别常见广告域名', () {
      expect(isAdHost('https://ad.doubleclick.net/path?x=1'), isTrue);
      expect(isAdHost('https://ads.example.com/banner'), isTrue);
      expect(isAdHost('https://googlesyndication.com/x'), isTrue);
      expect(isAdHost('http://popads.net'), isTrue);
    });

    test('不误伤正常域名', () {
      expect(isAdHost('https://www.bilibili.com/video/BV1xx411c7mD'), isFalse);
      expect(isAdHost('https://example.com/page'), isFalse);
      expect(isAdHost('https://myads.example.com/x'), isFalse);
      expect(isAdHost('https://adsense.google.com/x'), isFalse);
      expect(isAdHost(''), isFalse);
    });
  });
}
