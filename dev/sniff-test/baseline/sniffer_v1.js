// 视频嗅探脚本：注入到内置浏览器的每个页面（iOS 另注册为 WKUserScript 全帧注入，含跨域 iframe）
// 识别尽可能多的视频类型：
// ① <video>/<source> 扫描（含 <source type> MIME 兜底、video 无 src 时读子元素）
// ② MutationObserver（childList + src 属性变化）
// ③ fetch 钩子 + 响应 Content-Type 兜底（无扩展名的签名 URL）
// ④ XHR 钩子 + Content-Type 兜底
// ⑤ 静态脚本解析：扫描 <script> 文本里的视频地址（点击前即可识别）
// ⑥ Performance API 资源时间线：被动收集已请求资源（兜底站点缓存原始 fetch 引用的漏网）
// ⑦ 兜底轮询 + 点击后即时重扫 + 同源 iframe 扩散
// 噪声治理：.ts/.m4s 分片与字幕（vtt/srt/ttml…）不作为独立视频上报（元素直链除外）
// 暴露 window.__vdlSniff 注册表，供 video_marker.js 对 blob:/MSE 流做直链兜底
(function () {
  var CHANNEL = 'videoFound';
  var MAX = 60;

  var HLS_EXT = /\.m3u8([?#]|$)/i;
  var DASH_EXT = /\.mpd([?#]|$)/i;
  var FILE_EXT = /\.(mp4|mov|webm|mkv|flv|f4v|m4v|ts|m2ts|mts|mpg|mpeg|avi|wmv|asf|3gp|3g2|ogv|ogm|rm|rmvb)([?#]|$)/i;
  var VIDEO_EXT = /\.(mp4|m3u8|mov|webm|mkv|flv|f4v|m4v|ts|m2ts|mts|mpg|mpeg|avi|wmv|asf|3gp|3g2|ogv|ogm|rm|rmvb|mpd)([?#]|$)/i;
  // 分片/字幕噪声：只在作为 <video>/<source> 元素直链时接受
  var SEG_NOISE = /\.(ts|m4s|vtt|srt|ttml|dfxp|webvtt)([?#]|$)/i;
  // 响应头 MIME 兜底：视频 MIME 或 HLS/DASH 清单 MIME
  var MIME_RE = /^video\/|application\/(x-mpegurl|vnd\.apple\.mpegurl|dash\+xml|mp2t)/i;

  var seen = {};
  var reg = { items: [], max: 40 };

  function kindOf(u) {
    if (HLS_EXT.test(u)) return 'hls';
    if (DASH_EXT.test(u)) return 'dash';
    if (FILE_EXT.test(u)) return 'file';
    return 'other';
  }

  function post(u, fromElement, forcedKind) {
    try {
      u = String(u || '').trim();
      if (!u || seen[u] || reg.items.length >= MAX) return;
      if (!/^https?:/i.test(u)) return;
      // 分片/字幕噪声：网络层钩到的 .ts/.m4s/.vtt…一律不上报（元素直链除外），
      // MIME 兜底路径同样受此限制，避免 HLS 分片刷屏
      if (SEG_NOISE.test(u) && !fromElement) return;
      var k = forcedKind;
      if (!k) {
        if (!VIDEO_EXT.test(u)) return;
        k = kindOf(u);
      }
      seen[u] = 1;
      reg.items.push({ url: u, kind: k, ts: Date.now() });
      if (reg.items.length > reg.max) reg.items.shift();
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

  // 响应 Content-Type 兜底：URL 不带视频扩展名但服务端声明了视频 MIME
  function postByType(u, ct) {
    try {
      if (!u || seen[u]) return;
      if (!/^https?:/i.test(u)) return;
      var k = null;
      if (/x-mpegurl|vnd\.apple\.mpegurl/i.test(ct)) k = 'hls';
      else if (/dash\+xml/i.test(ct)) k = 'dash';
      else if (/^video\//i.test(ct) || /mp2t/i.test(ct)) k = 'file';
      if (k) post(u, false, k);
    } catch (e) {}
  }

  function srcOfMedia(el) {
    // video/source 元素：src/currentSrc；video 无 src 时读 <source> 子元素
    var s = el.currentSrc || el.getAttribute('src') || el.src || '';
    if (s) return s;
    if (el.tagName === 'SOURCE') return '';
    var ss = el.querySelectorAll ? el.querySelectorAll('source') : [];
    for (var i = 0; i < ss.length; i++) {
      var t = ss[i].getAttribute && (ss[i].getAttribute('type') || '') || '';
      var u = ss[i].currentSrc || (ss[i].getAttribute && ss[i].getAttribute('src')) || '';
      if (!u) continue;
      if (VIDEO_EXT.test(u) || MIME_RE.test(t)) return u;
    }
    return '';
  }

  function collect() {
    document.querySelectorAll('video, source').forEach(function (v) {
      post(srcOfMedia(v), true);
    });
  }

  // ── A. 静态脚本解析：很多影视站把真实视频地址嵌在 <script> 配置里
  //（如 var player_x={"url":"https:\/\/cdn…/index.m3u8"}、window.__INITIAL_STATE__），
  // 页面还没发起请求就能识别 → 点击前即可入列表。
  var SCRIPT_URL_RE =
    /https?:\\?\/\\?\/[^"'<>\s]+?\.(mp4|m3u8|mov|webm|mkv|flv|f4v|m4v|ts|m2ts|mts|mpg|mpeg|avi|wmv|asf|3gp|3g2|ogv|ogm|rm|rmvb|mpd)([?#][^"'<>\s]*)?/ig;
  var _lastScriptCount = -1;

  function scanScripts() {
    try {
      var ss = document.querySelectorAll('script');
      if (ss.length === _lastScriptCount) return; // 脚本没变就不重复扫
      _lastScriptCount = ss.length;
      for (var i = 0; i < ss.length; i++) {
        var txt = ss[i].textContent || '';
        var m;
        SCRIPT_URL_RE.lastIndex = 0;
        while ((m = SCRIPT_URL_RE.exec(txt))) {
          post(m[0].replace(/\\\//g, '/'), true);
        }
      }
    } catch (e) {}
  }

  // ── B. Performance API 资源时间线：被动收集所有已请求资源。
  // 站点若在脚本求值时缓存了原始 fetch 引用，钩子会被绕过；资源时间线不受影响，
  // 且请求在注入前发生的也能补到（iOS 文档加载即开始记录）。
  var _perfCursor = 0;

  function collectPerf() {
    try {
      if (!window.performance || !performance.getEntriesByType) return;
      if (performance.setResourceTimingBufferSize) {
        try { performance.setResourceTimingBufferSize(1000); } catch (e) {}
      }
      var res = performance.getEntriesByType('resource');
      for (var i = _perfCursor; i < res.length; i++) {
        var r = res[i];
        if (r && r.name) post(r.name, false);
      }
      _perfCursor = res.length;
    } catch (e) {}
  }

  try {
    var mo = new MutationObserver(collect);
    // 观察 document 本身：documentStart 注入时 documentElement 可能尚未就绪
    // childList 覆盖动态插入的 <video>；attributes 覆盖点击播放后才赋值的 src
    mo.observe(document, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['src']
    });
  } catch (e) {}

  // 钩住 fetch：很多播放器/站点用 fetch 取 m3u8 / mp4；响应头 MIME 兜底
  if (window.fetch) {
    var origFetch = window.fetch;
    window.fetch = function (input, init) {
      var u = (typeof input === 'string') ? input : (input && input.url) || '';
      post(u);
      var p;
      try {
        p = origFetch.apply(this, arguments);
        if (p && p.then) {
          p.then(function (resp) {
            try {
              if (!resp || !resp.ok) return;
              var ct = (resp.headers && resp.headers.get) ?
                resp.headers.get('content-type') : '';
              postByType(u, ct);
            } catch (e) {}
          });
        }
      } catch (e) { p = origFetch.apply(this, arguments); }
      return p;
    };
  }

  // 钩住 XMLHttpRequest
  var origOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (m, u) {
    post(u);
    var xhr = this;
    try {
      var origOn = xhr.onreadystatechange;
      xhr.onreadystatechange = function () {
        try {
          if (xhr.readyState === 4) {
            var ct = xhr.getResponseHeader('Content-Type') || '';
            postByType(u, ct);
          }
        } catch (e) {}
        if (origOn) return origOn.apply(this, arguments);
      };
    } catch (e) {}
    return origOpen.apply(this, arguments);
  };

  // 同源 iframe 扩散：把嗅探脚本注入到每个同源子框架（跨域 iframe 受浏览器限制，跳过）
  function propagate(src) {
    try {
      var frames = document.querySelectorAll('iframe');
      for (var i = 0; i < frames.length; i++) {
        var f = frames[i];
        var w = f.contentWindow;
        if (!w) continue;
        try {
          if (w.__vdlSniffInstalled) continue;
          if (!f.contentDocument) continue; // 跨域 → 抛异常跳过
          w.__vdlSniffSource = src;
          w.eval(src);
        } catch (e) {}
      }
    } catch (e) {}
  }
  window.__vdlSniffPropagate = propagate;

  if (window.__vdlSniffInstalled) return;
  window.__vdlSniffInstalled = true;

  // 暴露注册表：video_marker.js 用它给 blob:/MSE 流找最近捕获的直链
  window.__vdlSniff = {
    getLatest: function (wantKind) {
      for (var i = reg.items.length - 1; i >= 0; i--) {
        var it = reg.items[i];
        if (!wantKind || it.kind === wantKind) return it.url;
      }
      return '';
    }
  };

  // 兜底轮询（一些站点改 src 但不触发事件）+ 资源时间线 + 脚本解析 + 迟到的 iframe
  setInterval(function () {
    collect();
    collectPerf();
    scanScripts();
    if (window.__vdlSniffSource) {
      try { window.__vdlSniffPropagate(window.__vdlSniffSource); } catch (e) {}
    }
  }, 2000);
  collect();
  collectPerf();
  scanScripts();

  // 懒加载站点：点击播放后才创建播放器/发起媒体请求 → 点击后立即重扫 + 扩散，
  // 把「点击 → 识别」的延迟从最长 2s 压到毫秒级（播放器 src 赋值由属性观察覆盖）
  document.addEventListener('click', function () {
    setTimeout(function () {
      collect();
      collectPerf();
      scanScripts();
      if (window.__vdlSniffSource) {
        try { window.__vdlSniffPropagate(window.__vdlSniffSource); } catch (e) {}
      }
    }, 60);
  }, true);

  // 首次注入后立即扩散（源码由 Dart 侧注入时传入 window.__vdlSniffSource）
  if (window.__vdlSniffSource) {
    try { window.__vdlSniffPropagate(window.__vdlSniffSource); } catch (e) {}
  }
})();
