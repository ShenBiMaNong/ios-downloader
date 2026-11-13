// 视频嗅探脚本：注入到内置浏览器的每个页面
// 四路抓取：① <video>/<source> 扫描 ② MutationObserver ③ fetch 钩子 ④ XHR 钩子 + 兜底轮询
(function () {
  var CHANNEL = 'videoFound';
  var seen = {};
  var VIDEO_RE = /\.(mp4|m3u8|mov|webm|ts)([?#]|$)/i;
  var MAX = 30;

  function post(u) {
    try {
      u = String(u || '').trim();
      if (!u || seen[u] || Object.keys(seen).length >= MAX) return;
      if (!/^https?:/i.test(u)) return;
      if (!VIDEO_RE.test(u)) return;
      seen[u] = 1;
      var payload = JSON.stringify({
        url: u,
        frame: location.href,
        page: document.title || ''
      });
      var w = window.webkit;
      if (w && w.messageHandlers && w.messageHandlers[CHANNEL]) {
        w.messageHandlers[CHANNEL].postMessage(payload); // iOS WKWebView
      } else if (window[CHANNEL] && window[CHANNEL].postMessage) {
        window[CHANNEL].postMessage(payload); // Android WebView 通道
      }
    } catch (e) {}
  }

  function collect() {
    document.querySelectorAll('video, source').forEach(function (v) {
      post(v.currentSrc || v.getAttribute('src') || v.src);
    });
  }

  try {
    var mo = new MutationObserver(collect);
    mo.observe(document.documentElement, { childList: true, subtree: true });
  } catch (e) {}

  // 钩住 fetch（很多播放器/站点用 fetch 取 m3u8）
  if (window.fetch) {
    var origFetch = window.fetch;
    window.fetch = function (input) {
      var u = (typeof input === 'string') ? input : (input && input.url) || '';
      post(u);
      return origFetch.apply(this, arguments);
    };
  }

  // 钩住 XMLHttpRequest
  var origOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (m, u) {
    post(u);
    return origOpen.apply(this, arguments);
  };

  // 兜底轮询（一些站点改 src 但不触发事件）
  setInterval(collect, 2000);
  collect();
})();
