// 广告过滤（尽力而为）：
// ① 拦截已知广告域名的 fetch/XHR 请求（只匹配主机名，避免误伤正常 URL）
// ② 隐藏常见广告元素（iframe/class/id 特征）
// 注：WKWebView 无法在原生层拦截 http/https，此脚本是可行方案；误杀时可在浏览器菜单关闭。
(function () {
  if (window.__vdAdBlockLoaded) return;
  window.__vdAdBlockLoaded = true;

  var AD_HOST =
    /(^|[./_-])(ads?|adserver|advertising|adsrv|adnxs|adservice|doubleclick|googlesyndication|googleadservices|amazon-adsystem|taboola|outbrain|mgid|zedo|popads|propellerads|criteo|rubiconproject|onetag|smartadserver|moatads|scorecardresearch|imrworldwide)([./_-]|$)/i;

  function hostOf(u) {
    try {
      var s = String(u || '').replace(/^[a-z]+:\/\//i, '');
      return s.split(/[/?#]/)[0];
    } catch (e) {
      return '';
    }
  }

  function isAdUrl(u) {
    return AD_HOST.test(hostOf(u));
  }

  // 拦截 fetch
  var origFetch = window.fetch;
  if (origFetch) {
    window.fetch = function (input) {
      var u = (typeof input === 'string') ? input : (input && input.url) || '';
      if (isAdUrl(u)) {
        return Promise.reject(new Error('blocked by adblock'));
      }
      return origFetch.apply(this, arguments);
    };
  }

  // 拦截 XHR
  var origOpen = XMLHttpRequest.prototype.open;
  var origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (m, u) {
    this.__vdBlocked = isAdUrl(u);
    return origOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function () {
    if (this.__vdBlocked) return;
    return origSend.apply(this, arguments);
  };

  // 隐藏常见广告元素（display:none，保守选择器）
  var SEL =
    'iframe[src*="ad"], iframe[id*="google_ads"], ins.adsbygoogle, ' +
    '.ad-banner, [class*="ad-banner"], [class*="advert"]:not([class*="advertorial"]), ' +
    '[id*="ad-container"], [data-ad-zone], [data-ad-slot], [data-ad-client]';

  function hide() {
    try {
      document.querySelectorAll(SEL).forEach(function (el) {
        el.style.display = 'none';
      });
    } catch (e) {}
  }

  hide();
  try {
    var mo = new MutationObserver(hide);
    mo.observe(document.documentElement, { childList: true, subtree: true });
  } catch (e) {}
  setInterval(hide, 3000);
})();
