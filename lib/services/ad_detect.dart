/// 广告域名判定：用于跳转拦截时识别「广告发起的跳转目标」。
/// 规则与 assets/adblock.js 中的 AD_HOST 保持一致（改任一处的正则需同步另一处）。
final RegExp adHostRe = RegExp(
  r'(^|[./_-])(ads?|adserver|advertising|adsrv|adnxs|adservice|doubleclick|googlesyndication|googleadservices|amazon-adsystem|taboola|outbrain|mgid|zedo|popads|propellerads|criteo|rubiconproject|onetag|smartadserver|moatads|scorecardresearch|imrworldwide)([./_-]|$)',
  caseSensitive: false,
);

/// 判断 URL 的主机名是否命中广告域名库
bool isAdHost(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  return adHostRe.hasMatch(host);
}
