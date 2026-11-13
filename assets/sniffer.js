// 视频嗅探脚本 v2：候选池 + 证据分级 + 播放锚定
// 注入到内置浏览器的每个页面（iOS 另注册为 WKUserScript 全帧注入，含跨域 iframe）
//
// ── v1 的坑 ────────────────────────────────────────────────────────────
// 很多站点把多条线路（多个 m3u8）一起写进 <script> 配置里，或者逐个试探哪条能访问。
// v1 只要「看到过 URL」就上报，且对外取的是「最近捕获的那条」—— 而试探的最后一个
// 往往正是失败的那条，于是用户点下载拿到的是死链。
//
// ── v2 的思路：不判断「有没有出现过」，只判断「哪条真的在跑」 ──────────
//   ① 每条候选记一个可信度分数（不是布尔值），分数来自具体证据来源
//   ② 网络层死活判定：fetch/XHR 拿到 2xx 且响应体以 #EXTM3U 开头 → ok；
//      404/5xx/网络错误 → dead（dead 永远不会被选为首选）
//   ③ 播放锚定（最硬的证据）：<video> 真的播起来时，把正在用的那条拉到最高分
//      · 元素直链（原生 HLS / mp4）：currentSrc 就是正在播的，直接锚定
//      · MSE(blob:)：取「播放前最近一次成功请求的清单」；再用播放后新出现的分片 URL
//        与候选清单的目录前缀做匹配佐证（线路 a/b 的分片目录不同 → 能区分开）
//   ④ 静态脚本解析出来的 URL 只给最低分（guess），永远排在实测证据之后
//   ⑤ 对 marker 只暴露 getBest / best / list，由它挑「能用的那条」
//
// 噪声治理不变：.ts/.m4s 分片与字幕不作为独立视频上报（元素直链除外），
// 但分片 URL 会被记录下来用于 ③ 的目录前缀佐证。
(function () {
  var CHANNEL = 'videoFound';

  var HLS_EXT = /\.m3u8([?#]|$)/i;
  var DASH_EXT = /\.mpd([?#]|$)/i;
  var FILE_EXT = /\.(mp4|mov|webm|mkv|flv|f4v|m4v|ts|m2ts|mts|mpg|mpeg|avi|wmv|asf|3gp|3g2|ogv|ogm|rm|rmvb)([?#]|$)/i;
  var VIDEO_EXT = /\.(mp4|m3u8|mov|webm|mkv|flv|f4v|m4v|ts|m2ts|mts|mpg|mpeg|avi|wmv|asf|3gp|3g2|ogv|ogm|rm|rmvb|mpd)([?#]|$)/i;
  // 分片/字幕噪声：只在作为 <video>/<source> 元素直链时接受
  var SEG_NOISE = /\.(ts|m4s|vtt|srt|ttml|dfxp|webvtt)([?#]|$)/i;
  // 用于「分片目录佐证」的分片特征（HLS 的 ts / fMP4 的 m4s）
  var SEG_RE = /\.(ts|m4s)([?#]|$)/i;
  // 响应头 MIME 兜底：视频 MIME 或 HLS/DASH 清单 MIME
  var MIME_RE = /^video\/|application\/(x-mpegurl|vnd\.apple\.mpegurl|dash\+xml|mp2t)/i;
  var PLAYLIST_MIME = /x-mpegurl|vnd\.apple\.mpegurl/i;
  var DASH_MIME = /dash\+xml/i;

  // ── 证据强度（同一候选被多次观测时取最高分；ok 可以给 dead 翻案，反之不行）──
  var S_PLAY = 1000;    // 正在播放，且这条候选本身已有成功请求证据（强锚定，最硬）
  var S_ELEM = 900;     // <video>/<source> 的 currentSrc（浏览器已经解析出来了）
  var S_SEG = 850;      // 播放后出现的分片 URL 与之目录前缀匹配
  var S_OK_BODY = 800;  // 2xx 且响应体以 #EXTM3U 开头（内容级确认）
  var S_OK_MIME = 700;  // 2xx 且 Content-Type 是清单/视频
  var S_OK = 600;       // 2xx 但内容没读到（不透明响应 / 二进制）
  var S_WEAK = 500;     // 弱锚定：视频确实在放，但这条候选只是猜测，没有请求证据
  var S_PERF = 400;     // 资源时间线显示成功传输（拿不到状态码）
  var S_GUESS = 100;    // 静态脚本 / 无任何结果证据的猜测
  var S_DEAD = -1;      // 明确失败（4xx/5xx/网络错误/响应体不是清单）

  // url -> { u, k, sc, st, src, ts, play, posted }
  //   k  : hls | dash | file | other
  //   sc : 可信度分数
  //   st : ok | guess | dead
  //   ts : 最近一次有效证据时间
  var cands = Object.create(null);
  var urls = [];
  var MAX = 140;

  function kindOf(u) {
    if (HLS_EXT.test(u)) return 'hls';
    if (DASH_EXT.test(u)) return 'dash';
    if (FILE_EXT.test(u)) return 'file';
    return 'other';
  }

  // 目录前缀：https://a.com/x/y/index.m3u8 → https://a.com/x/y/
  function dirOf(u) {
    try {
      var s = String(u).split('#')[0].split('?')[0];
      var i = s.lastIndexOf('/');
      return i > 8 ? s.slice(0, i + 1) : '';
    } catch (e) { return ''; }
  }

  // ── 上报到 Dart / 调试页（保持 v1 的 videoFound 通道兼容，payload 增加分数与状态）──
  function post(r) {
    try {
      var payload = JSON.stringify({
        url: r.u,
        kind: r.k,
        score: r.sc,
        state: r.st,
        frame: location.href,
        page: document.title || ''
      });
      var w = window.webkit;
      if (w && w.messageHandlers && w.messageHandlers[CHANNEL]) {
        w.messageHandlers[CHANNEL].postMessage(payload); // iOS WKWebView
      } else if (window[CHANNEL] && window[CHANNEL].postMessage) {
        window[CHANNEL].postMessage(payload); // Android WebView 通道 / 调试页
      }
    } catch (e) {}
  }

  function prune() {
    var arr = urls.filter(function (u) { return !!cands[u]; });
    arr.sort(function (a, b) { return cands[a].sc - cands[b].sc; });
    var drop = arr.length - 100;
    for (var i = 0; i < drop && i < arr.length; i++) {
      var u = arr[i];
      // 活的和正在播的永不裁剪
      if (cands[u].st === 'ok' || cands[u].play) continue;
      delete cands[u];
    }
    urls = urls.filter(function (u) { return !!cands[u]; });
  }

  // 统一入口：给某个 URL 记一条证据
  //   score : 本次证据的强度
  //   state : 'ok' | 'dead' | 'guess'
  //   src   : 证据来源（element/fetch/xhr/perf/play/seg/script）
  //   fk    : 强制 kind（响应 MIME 已确定类型时用，URL 可能没有扩展名）
  //   hard  : 内容级证据（读到了响应体）。这类 dead 可以推翻状态码级的 ok ——
  //           「返回 200 但内容是一张 HTML 错误页」必须判死，否则假可用线路会排在前面
  function offer(u, score, state, src, fk, hard) {
    try {
      u = String(u || '').trim();
      if (!u || !/^https?:/i.test(u)) return;
      if (SEG_NOISE.test(u) && src !== 'element') return;

      var isVideoExt = VIDEO_EXT.test(u);
      // 扩展名不像视频的 URL：只有拿到成功证据（MIME 兜底）才收录，避免把接口 JSON 混进来
      if (!isVideoExt && state !== 'ok') return;

      var r = cands[u];
      if (!r) {
        r = cands[u] = {
          u: u,
          k: fk || kindOf(u),
          sc: isVideoExt ? S_GUESS : S_OK_MIME,
          st: 'guess',
          src: src || '',
          ts: Date.now(),
          play: 0,
          posted: 0
        };
        urls.push(u);
        if (urls.length > MAX) prune();
        r.posted = 1;
        post(r);
      } else if (fk && r.k === 'other') {
        r.k = fk;
      }

      var upd = false;
      if (state === 'dead') {
        // 普通 dead（一次请求失败）不推翻已有 ok/播放证据 —— 站点可能只是该次被限流；
        // 但内容级 dead（hard，读到了响应体且不是清单）是确定性结论，必须推翻状态码级的 ok。
        // 唯一例外：正在播放的源永远不被判死。
        if (!r.play && (hard || r.st !== 'ok')) {
          if (r.st !== 'dead') { r.st = 'dead'; upd = true; }
          r.sc = S_DEAD;
        }
      } else {
        if (r.st === 'dead') { r.st = 'ok'; upd = true; }
        else if (state === 'ok' && r.st !== 'ok') { r.st = 'ok'; upd = true; }
        if (score > r.sc) { r.sc = score; upd = true; }
        // 播放锚定：每次播放都要刷新时间戳（多条都锚定时按最近一次播放决胜）
        if (score >= S_PLAY) { r.play = 1; r.ts = Date.now(); }
      }

      if (upd) {
        r.ts = Date.now();
        if (src) r.src = src;
        // 升级成 ok 时补报一次（Dart 侧/调试页可据此刷新列表）
        if (r.st === 'ok' && !r.postedOk) { r.postedOk = 1; post(r); }
      }
    } catch (e) {}
  }

  function stateOf(u) {
    var r = cands[u];
    return r ? r.st : '';
  }

  // ── 候选排序：分数优先，同分取最近一次证据 ────────────────────────────
  function ranked(kind) {
    var out = [];
    for (var u in cands) {
      var r = cands[u];
      if (kind && r.k !== kind) continue;
      out.push(r);
    }
    out.sort(function (a, b) {
      if (b.sc !== a.sc) return b.sc - a.sc;
      return b.ts - a.ts;
    });
    return out;
  }

  // 最佳候选：优先非 dead；全是 dead 时兜底返回最高分那条（标 state=dead，让 UI 提示）
  function best(kind) {
    var arr = ranked(kind);
    for (var i = 0; i < arr.length; i++) {
      if (arr[i].st !== 'dead') {
        return { url: arr[i].u, kind: arr[i].k, score: arr[i].sc, state: arr[i].st };
      }
    }
    if (arr.length) {
      return { url: arr[0].u, kind: arr[0].k, score: arr[0].sc, state: 'dead' };
    }
    return null;
  }

  function listOf(kind) {
    var out = [];
    var guesses = 0;
    var arr = ranked(kind);
    for (var i = 0; i < arr.length && out.length < 6; i++) {
      var r = arr[i];
      // 脚本里扫出来、从没被请求过的纯猜测只留 2 条，避免刷屏；
      // dead 是实测结论，要保留 —— 用户需要看到「为什么这条不能用」
      if (r.st === 'guess' && r.sc <= S_GUESS) {
        if (guesses >= 2) continue;
        guesses++;
      }
      out.push({ url: r.u, kind: r.k, score: r.sc, state: r.st });
    }
    return out;
  }

  // ── 元素直链扫描 ──────────────────────────────────────────────────────
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
    var els = document.querySelectorAll('video, source');
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      // currentSrc = 浏览器真正选中的那个源，可作为「已解析」证据
      var cur = el.currentSrc || '';
      if (cur && /^https?:/i.test(cur)) {
        offer(cur, S_ELEM, 'ok', 'element');
        continue;
      }
      var s = srcOfMedia(el);
      if (s) offer(s, S_GUESS, 'guess', 'element');
    }
  }

  // ── B. 静态脚本解析：页面还没发起请求就能看到候选地址 ─────────────────
  // 注意：这里只给最低分（guess）。多线路站点会把所有线路都写在这里，
  // 到底哪条能用在 v1 里没法判断 —— 这正是「嗅探到不可访问那条」的主要来源。
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
          offer(m[0].replace(/\\\//g, '/'), S_GUESS, 'guess', 'script');
        }
      }
    } catch (e) {}
  }

  // ── C. 分片目录佐证：播放开始后持续有 .ts/.m4s 请求的，说明这条线路在跑 ──
  // 多线路站点线路 a/b 的清单目录不同（/hls/a/ 与 /hls/b/），分片 URL 一定以
  // 正在播放那条的目录为前缀 → 取「最长的匹配前缀」命中者加分，避免同域歧义。
  function corroborate(seg) {
    try {
      var hit = '', hitLen = 0;
      for (var u in cands) {
        var r = cands[u];
        if (r.k !== 'hls' && r.k !== 'dash') continue;
        var d = dirOf(u);
        if (!d || d.length <= hitLen) continue;
        if (seg.indexOf(d) === 0) { hit = u; hitLen = d.length; }
      }
      if (hit) offer(hit, S_SEG, 'ok', 'seg');
    } catch (e) {}
  }

  // ── D. Performance API 资源时间线：被动收集已请求资源 ─────────────────
  // 站点若在脚本求值时缓存了原始 fetch 引用，钩子会被绕过；资源时间线不受影响，
  // 且请求在注入前发生的也能补到（iOS 文档加载即开始记录）。
  // v2 的改进：能拿到状态码就看状态码（404 直接判死），
  // 拿不到就只看「是否真的传了字节」，不再把失败请求当成视频上报。
  var _perfCursor = 0;

  function collectPerf() {
    try {
      if (!window.performance || !performance.getEntriesByType) return;
      if (performance.setResourceTimingBufferSize) {
        try { performance.setResourceTimingBufferSize(2000); } catch (e) {}
      }
      var res = performance.getEntriesByType('resource');
      for (; _perfCursor < res.length; _perfCursor++) {
        var r = res[_perfCursor];
        if (!r || !r.name) continue;
        if (SEG_RE.test(r.name)) { corroborate(r.name); continue; }
        if (!/^https?:/i.test(r.name)) continue;
        if (!VIDEO_EXT.test(r.name)) continue;
        var st = r.responseStatus; // 新版 Chromium/Safari 才有，没有就是 undefined
        if (typeof st === 'number' && st >= 400) { offer(r.name, S_DEAD, 'dead', 'perf'); continue; }
        if (typeof st === 'number' && st >= 200 && st < 400) { offer(r.name, S_OK, 'ok', 'perf'); continue; }
        if (r.transferSize > 0 || r.decodedBodySize > 0) { offer(r.name, S_PERF, 'ok', 'perf'); continue; }
        // 拿不到任何结果信息 → 只能算猜测，不能当成「有视频」
        offer(r.name, S_GUESS, 'guess', 'perf');
      }
    } catch (e) {}
  }

  // ── E. 播放锚定：真正播起来的那一刻，确定正在用的是哪条 ────────────────
  // MSE(blob:) 场景拿不到清单 URL，只能靠「播放前最近一次成功的清单请求」推断；
  // 若有多条候选，优先已经拿到 ok 证据的那条，其次才是最近的猜测。
  function pickForPlayback() {
    var now = Date.now();
    var bestU = '', bestS = -1;
    for (var u in cands) {
      var r = cands[u];
      if (r.st === 'dead') continue;
      if (r.k !== 'hls' && r.k !== 'dash') continue;
      if (now - r.ts > 30000) continue; // 半分钟前的证据不算数
      if (r.sc > bestS) { bestS = r.sc; bestU = u; }
    }
    return bestU;
  }

  function anchorFrom(v) {
    try {
      if (!v || v.tagName !== 'VIDEO') return;
      // 广告/预览小窗（几百像素的宣传片）不参与锚定，避免把主播放源的分数顶掉
      var r = v.getBoundingClientRect ? v.getBoundingClientRect() : null;
      if (r && (r.width < 160 || r.height < 90)) return;

      var s = v.currentSrc || (v.getAttribute && v.getAttribute('src')) || v.src || '';
      if (s && /^https?:/i.test(s)) {
        // 元素直链 = 正在播的就是它（原生 HLS / mp4 直链）
        if (!SEG_NOISE.test(s)) offer(s, S_PLAY, 'ok', 'play');
        return;
      }
      if (!s || /^blob:/i.test(s)) {
        // MSE：从候选池里推断正在跑的那条。
        // 注意分两档：视频在放 ≠ 被锚定的这条就是它在用的那条。
        // 只有该候选本身已有成功请求证据才给强锚定；否则给弱锚定（S_WEAK），
        // 让后到的实测证据（分片目录匹配 / 成功的清单请求）能超过它。
        var p = pickForPlayback();
        if (!p) return;
        if (cands[p] && cands[p].sc >= S_OK) offer(p, S_PLAY, 'ok', 'play');
        else offer(p, S_WEAK, 'guess', 'play');
      }
    } catch (e) {}
  }

  // 轮询兜底：有些播放器不派发 play/playing 到 document（或用 video.play() 静默起播）
  function checkPlaying() {
    try {
      var vs = document.querySelectorAll('video');
      for (var i = 0; i < vs.length; i++) {
        var v = vs[i];
        if (v.paused || !(v.currentTime > 0.2)) continue;
        anchorFrom(v);
      }
    } catch (e) {}
  }

  // ── F. 钩住 fetch：拿到状态码/响应头/响应体前缀，判定死活 ──────────────
  // 幂等保护：Dart 在 onPageStarted 与 onPageFinished 各注入一次，没有这道闸
  // 就会把 fetch 包两层（每条请求记两遍、clone 两次）—— v1 就踩了这个坑。
  if (window.fetch && !window.__vdlFetchHooked) {
    window.__vdlFetchHooked = 1;
    var origFetch = window.fetch;
    window.fetch = function (input, init) {
      var u = (typeof input === 'string') ? input : (input && input.url) || '';
      var self = this, args = arguments;
      // 请求刚发出：还什么都不知道，只登记为猜测
      if (u) offer(u, S_GUESS, 'guess', 'fetch');
      var p;
      try {
        p = origFetch.apply(self, args);
      } catch (e) {
        if (u) offer(u, S_DEAD, 'dead', 'fetch'); // 同步抛错 = 请求没发出去
        throw e;
      }
      if (p && p.then) {
        p.then(function (resp) {
          try {
            if (!resp) return;
            if (!resp.ok) { offer(u, S_DEAD, 'dead', 'fetch'); return; } // 404/403/500 → 死链
            var ct = (resp.headers && resp.headers.get) ? (resp.headers.get('content-type') || '') : '';
            var fk = null;
            if (PLAYLIST_MIME.test(ct)) fk = 'hls';
            else if (DASH_MIME.test(ct)) fk = 'dash';
            else if (/^video\//i.test(ct) || /mp2t/i.test(ct)) fk = 'file';

            // 清单类（.m3u8 或清单 MIME）：先不判定，等读到内容再定性。
            // 「200 + HTML 错误页」是假可用线路的典型形态，只看状态码会被骗。
            if (HLS_EXT.test(u) || PLAYLIST_MIME.test(ct)) {
              // 直播会反复重载 media playlist：已确认过是清单的就不再重复拷响应体
              if (cands[u] && cands[u].sc >= S_OK_BODY) {
                offer(u, S_OK_BODY, 'ok', 'fetch', 'hls');
                return;
              }
              var c = resp.clone ? resp.clone() : null;
              if (c && c.text) {
                c.text().then(function (t) {
                  t = String(t || '').slice(0, 64);
                  if (/^\uFEFF?\s*#EXTM3U/.test(t)) {
                    offer(u, S_OK_BODY, 'ok', 'fetch', 'hls');
                  } else if (t.length > 8) {
                    // 内容不是清单 → 确定失效（hard：可推翻先前状态码级的 ok）
                    offer(u, S_DEAD, 'dead', 'fetch', 'hls', true);
                  } else {
                    // 读不到内容（不透明响应 / CORS）→ 按 MIME 认可，但分数不高
                    offer(u, S_OK_MIME, 'ok', 'fetch', 'hls');
                  }
                }, function () {
                  offer(u, S_OK, 'ok', 'fetch', 'hls');
                });
                return;
              }
            }
            offer(u, fk ? S_OK_MIME : S_OK, 'ok', 'fetch', fk || undefined);
          } catch (e) {}
        }, function () {
          // rejected = 网络层失败（DNS/CORS/断连）
          offer(u, S_DEAD, 'dead', 'fetch');
        });
      }
      return p;
    };
  }

  // ── G. 钩住 XMLHttpRequest ────────────────────────────────────────────
  // v1 包装 onreadystatechange 有个隐患：站点之后自己赋值 onreadystatechange 会把
  // 包装覆盖掉，嗅探就静默失效了。改用 addEventListener('loadend')，不可被覆盖。
  if (!window.__vdlXhrHooked) {
    window.__vdlXhrHooked = 1;
    var origOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (m, u) {
      var xhr = this;
      var url = String(u || '');
      if (url) offer(url, S_GUESS, 'guess', 'xhr');
      try {
        xhr.addEventListener('loadend', function () {
          try {
            if (!url) return;
            var st = xhr.status;
            // status 0 = 网络错误 / 被拦截；>=400 = 明确的失败
            if (st === 0 || st >= 400) { offer(url, S_DEAD, 'dead', 'xhr'); return; }

            var ct = xhr.getResponseHeader('Content-Type') || '';
            var rt = xhr.responseType;
            var txt = '';
            if (!rt || rt === 'text') {
              try { txt = String(xhr.responseText || '').slice(0, 64); } catch (e) {}
            }
            // 内容级确认优先
            if (/^\uFEFF?\s*#EXTM3U/.test(txt)) { offer(url, S_OK_BODY, 'ok', 'xhr', 'hls'); return; }
            // .m3u8 却返回别的内容（HTML 错误页 / JSON 提示）→ 假地址，内容级证据可推翻 ok
            if (HLS_EXT.test(url) && txt.length > 8 && txt.indexOf('#EXTM3U') < 0) {
              offer(url, S_DEAD, 'dead', 'xhr', 'hls', true);
              return;
            }
            var fk = null;
            if (PLAYLIST_MIME.test(ct)) fk = 'hls';
            else if (DASH_MIME.test(ct)) fk = 'dash';
            else if (/^video\//i.test(ct) || /mp2t/i.test(ct)) fk = 'file';
            offer(url, fk ? S_OK_MIME : S_OK, 'ok', 'xhr', fk || undefined);
          } catch (e) {}
        }, false);
      } catch (e) {}
      return origOpen.apply(this, arguments);
    };
  }

  // ── H. 同源 iframe 扩散 ───────────────────────────────────────────────
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

  // ── 对外 API（video_marker.js 用）───────────────────────────────────
  window.__vdlSniff = {
    // v1 兼容：最近一条（跳过 dead）
    getLatest: function (kind) {
      var arr = ranked(kind);
      for (var i = 0; i < arr.length; i++) {
        if (arr[i].st !== 'dead') return arr[i].u;
      }
      return '';
    },
    // 推荐一条可直接用的（v2 主入口，marker 用这个）
    getBest: function (kind) {
      var b = best(kind);
      return b ? b.url : '';
    },
    // 带分数与状态的推荐项
    best: best,
    // 全量候选（按分数降序，最多 8 条），供 marker 展示「线路」列表
    list: listOf,
    stateOf: stateOf,
    // 调试用
    dump: function () {
      return ranked('').map(function (r) {
        return { url: r.u, kind: r.k, score: r.sc, state: r.st, src: r.src };
      });
    }
  };

  // ── 事件挂载 ─────────────────────────────────────────────────────────
  // media 事件不冒泡，但捕获阶段仍会经过 document（addEventListener 第三参 true）。
  try {
    var mo = new MutationObserver(collect);
    mo.observe(document, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['src']
    });
  } catch (e) {}

  ['play', 'playing', 'loadedmetadata', 'canplay'].forEach(function (type) {
    document.addEventListener(type, function (e) {
      var v = e.target;
      if (v && v.tagName === 'VIDEO') anchorFrom(v);
    }, true);
  });

  // 兜底轮询：元素扫描 + 资源时间线 + 脚本解析 + 播放状态 + 迟到 iframe
  setInterval(function () {
    collect();
    collectPerf();
    scanScripts();
    checkPlaying();
    if (window.__vdlSniffSource) {
      try { window.__vdlSniffPropagate(window.__vdlSniffSource); } catch (e) {}
    }
  }, 2000);

  collect();
  collectPerf();
  scanScripts();

  // 懒加载站点：点了播放按钮才创建播放器/发请求（有的还要先过一道解析接口）。
  // 只扫一次 60ms 太早 —— 解析接口的那次往返还没回来。改成点击后的一串时间点各扫一次，
  // 把角标出现时间压到 2s 轮询之前；后续变化仍由 fetch/XHR 钩子实时接住。
  var CLICK_SCAN_DELAYS = [60, 400, 1200, 3000];
  document.addEventListener('click', function () {
    // forEach 给每次迭代独立闭包；用 for + var 会让所有定时器都读到循环结束后的 i
    CLICK_SCAN_DELAYS.forEach(function (delay) {
      setTimeout(function () {
        collect();
        collectPerf();
        scanScripts();
        if (window.__vdlSniffSource) {
          try { window.__vdlSniffPropagate(window.__vdlSniffSource); } catch (e) {}
        }
      }, delay);
    });
  }, true);

  // 首次注入后立即扩散（源码由 Dart 侧注入时传入 window.__vdlSniffSource）
  if (window.__vdlSniffSource) {
    try { window.__vdlSniffPropagate(window.__vdlSniffSource); } catch (e) {}
  }
})();
