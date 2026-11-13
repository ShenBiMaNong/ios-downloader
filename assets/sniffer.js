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
  // 550/350：容器属性（data-url 之类）里声明的播放源。
  // 【不变式】属性证据永远低于 S_OK —— 只要有任何真实请求证据，就必须让位于它。
  // 但必须高于 S_GUESS —— 它是播放器实例自己持有的配置，不是正则从脚本里捞出来的噪声。
  // S_ATTR_PLAY 专指「这个属性就挂在正在用 blob: 播放的那个播放器身上」，
  // 是 DPlayer/Plyr/ArtPlayer 这类「MSE + data-url」组合的结构性证据：
  // 元件拿不到地址（src 是 blob），属性却是它自己的配置，等价于「正在播的就是它」。
  var S_ATTR_PLAY = 550;
  var S_ATTR = 350;     // 页面上有 data-url，但附近没有 blob 播放器（可能是备用线路/广告位）
  var S_WEAK = 500;     // 弱锚定：视频确实在放，但这条候选只是猜测，没有请求证据
  var S_PERF = 400;     // 资源时间线显示成功传输（拿不到状态码）
  var S_GUESS = 100;    // 静态脚本 / 无任何结果证据的猜测
  var S_DEAD = -1;      // 明确失败（4xx/5xx/网络错误/响应体不是清单）

  // 签名 URL 的本地过期判定（容差 180s：设备时钟可能偏，服务端也未必真校验）
  var EXP_TOL = 180;
  var EXP_SOON = 300;   // 距过期不到 5 分钟 → UI 提示尽快用

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

  // ── URL 归一 ──────────────────────────────────────────────────────────
  // 真实站点里地址有好几种「看起来一样、实际不能用」的写法：
  //   · 内联 <script> 里的 JS 字符串 → 斜杠被转义成 \/ 、& 被写成 \u0026
  //   · 属性里是相对路径 /hls/x.m3u8 或协议相对 //cdn/x.m3u8
  //   · 服务端模板渲进 HTML → &amp;（DOM 取属性时已解码，但脚本里不会）
  // 转义没还原会让 query 参数错位，请求直接 403/404，比「找不到」更难排查。
  function unesc(s) {
    return String(s || '')
      .replace(/\\u0026/gi, '&')
      .replace(/\\u003d/gi, '=')
      .replace(/\\u002f/gi, '/')
      .replace(/\\\//g, '/')
      .replace(/&amp;/gi, '&')
      .replace(/&#x26;|&#38;/gi, '&')
      .replace(/&#x2f;|&#47;/gi, '/');
  }

  function absUrl(v) {
    var s = unesc(v).trim();
    if (!s) return '';
    if (/^https?:\/\//i.test(s)) return s;
    try {
      if (s.indexOf('//') === 0) return (location.protocol || 'https:') + s;
      if (s.charAt(0) === '/') {
        // 绝对路径：补上当前页的 origin（data-url 里常见 /hls/x.m3u8 这种写法）
        return location.protocol + '//' + location.host + s;
      }
    } catch (e) { return ''; }
    return ''; // ./ ../ 这类相对路径不做解析：误伤面大于收益
  }

  // ── 签名 URL 的过期时间 ───────────────────────────────────────────────
  // 覆盖常见的几套 CDN 鉴权参数（本例是阿里云/又拍系 A 型：auth_key=时间戳-随机-uid-md5）：
  //   阿里云 A 型  : ?auth_key=<unix>-<rand>-<uid>-<md5>
  //   通用         : ?expires= / ?expire= / ?deadline= / ?et= / ?e=
  //   腾讯云 CDN   : ?wsTime=<hex unix>
  //   S3 预签名    : ?X-Amz-Date=...&X-Amz-Expires=<秒>
  // 拿不到就返回 0，不猜。
  function parseExp(u) {
    try {
      var s = String(u);
      var qi = s.indexOf('?');
      if (qi < 0) return 0;
      s = s.slice(qi + 1).split('#')[0];
      var kv = Object.create(null);
      var ps = s.split('&');
      for (var i = 0; i < ps.length; i++) {
        var eq = ps[i].indexOf('=');
        if (eq <= 0) continue;
        var k = ps[i].slice(0, eq);
        try { k = decodeURIComponent(k); } catch (e) {}
        kv[k.toLowerCase()] = ps[i].slice(eq + 1);
      }
      var t = 0;
      if (kv.auth_key) {
        // 第一段即过期时间戳，其余段（随机串/uid/md5）都用不上
        t = parseInt(String(kv.auth_key).split('-')[0], 10) || 0;
      }
      if (!t && kv.expires) t = parseInt(kv.expires, 10) || 0;
      if (!t && kv.expire) t = parseInt(kv.expire, 10) || 0;
      if (!t && kv.deadline) t = parseInt(kv.deadline, 10) || 0;
      if (!t && kv.et) t = parseInt(kv.et, 10) || 0;
      if (!t && kv.e && /^\d{10,13}$/.test(kv.e)) t = parseInt(kv.e, 10) || 0;
      if (!t && kv.wstime) t = parseInt(kv.wstime, 16) || 0;
      if (!t && kv['x-amz-expires'] && kv['x-amz-date']) {
        var m = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/.exec(kv['x-amz-date']);
        if (m) {
          var d = Date.parse(m[1] + '-' + m[2] + '-' + m[3] + 'T' + m[4] + ':' + m[5] + ':' + m[6] + 'Z');
          if (d) t = Math.floor(d / 1000) + (parseInt(kv['x-amz-expires'], 10) || 0);
        }
      }
      if (!t || !isFinite(t)) return 0;
      if (t > 1e12) t = Math.floor(t / 1000); // 毫秒时间戳
      if (t < 1e9) return 0;                  // 明显不是时间戳（比如 uid）
      return t;
    } catch (e) { return 0; }
  }

  // 过期只作为「排序与推荐」的排除条件，不改 st ——
  // 属性扫描每 2s 会重新 offer 一次，写进 st 会被反复翻案（offer 里 guess 能把 dead 复活）。
  function staleOf(r) {
    if (!r || !r.exp) return 0;
    return Date.now() > (r.exp + EXP_TOL) * 1000 ? 1 : 0;
  }
  function soonOf(r) {
    if (!r || !r.exp || staleOf(r)) return 0;
    return Date.now() > (r.exp - EXP_SOON) * 1000 ? 1 : 0;
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
      u = absUrl(u);
      if (!u) return;
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
          posted: 0,
          exp: parseExp(u)
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
      // 属性证据的「现在性」由 DOM 决定：值还挂在元素上就说明它此刻仍然有效，
      // 每轮扫描都要刷新时间戳，否则 30s 后会被 pickForPlayback 的时效窗口排除掉。
      if (src === 'attr' && state === 'guess') r.ts = Date.now();
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
      var a = arr[i];
      if (a.st === 'dead') continue;
      if (staleOf(a)) continue; // 签名已过期，除非它确实是唯一候选，否则不推荐
      return {
        url: a.u, kind: a.k, score: a.sc, state: a.st,
        src: a.src, exp: a.exp, soon: soonOf(a)
      };
    }
    // 全军覆没：优先报「过期」——它比「确认失效」更有救（刷新页面就能换签名）
    for (var j = 0; j < arr.length; j++) {
      if (staleOf(arr[j])) {
        return {
          url: arr[j].u, kind: arr[j].k, score: arr[j].sc, state: 'dead',
          src: arr[j].src, exp: arr[j].exp, why: 'expired'
        };
      }
    }
    if (arr.length) {
      return {
        url: arr[0].u, kind: arr[0].k, score: arr[0].sc, state: 'dead',
        src: arr[0].src, exp: arr[0].exp, why: 'dead'
      };
    }
    return null;
  }

  function listOf(kind) {
    var out = [];
    var guesses = 0;
    var arr = ranked(kind);
    for (var i = 0; i < arr.length && out.length < 6; i++) {
      var r = arr[i];
      // 脚本里扫出来、从没被请求过的纯猜测最多列 4 条：打开卡片时会现场校验
      // （见 I 段），列出来才能让用户看见「哪几条不能用」，而不是只藏掉两条；
      // dead 是实测结论，必须保留 —— 用户需要看到「为什么这条不能用」；
      // 过期同理：要让用户知道「这条本来是对的，只是签名失效了」。
      if (r.st === 'guess' && r.sc <= S_GUESS) {
        if (guesses >= 4) continue;
        guesses++;
      }
      out.push({
        url: r.u, kind: r.k, score: r.sc, state: r.st,
        src: r.src, soon: soonOf(r), expired: staleOf(r),
        // HTTP 状态码（主动校验或拦截时拿到的），0 = 没拿到。marker 里显示成「· 403」
        code: r.code || 0
      });
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

  // 文档卸载 / iframe 导航期间 document 可能已不可用，但定时器与 MutationObserver 还在跑
  function docOk() {
    try { return typeof document !== 'undefined' && !!document && !!document.querySelectorAll; }
    catch (e) { return false; }
  }

  function collect() {
    if (!docOk()) return;
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

  // ── B2. 播放器容器属性：data-url / data-src / data-m3u8 … ─────────────
  // 有的站点把真地址写在播放器容器的 data-* 上（DPlayer 系站点最典型）：
  //   <div class="dplayer" data-url="https://…/x.m3u8?auth_key=…">
  //     <video src="blob:https://site/uuid">      ← 元素永远拿不到真地址
  // 这时属性就是**唯一**入口：MSE 的 src 是内存句柄，而属性是播放器实例自己的配置。
  //
  // 与「静态脚本解析」的区别（分数差 3.5 倍的原因）：
  //   · 脚本里是**站点所有线路的清单**，包括从来没人点过的；
  //   · 属性是**这个播放器此刻选中的那条**，通常已经请求过或即将请求。
  // 所以属性给 S_ATTR，若旁边就蹲着 blob 播放器（结构性绑定）给 S_ATTR_PLAY。
  // 也顺手覆盖「清单在 Web Worker 里拉、fetch 钩子完全失效」的场景 —— 那时静态脚本
  // 只能给 guess，属性却能指出正在用的那条。
  var ATTR_SEL = '[data-url],[data-src],[data-m3u8],[data-hls],[data-mpd],[data-video],' +
    '[data-video-url],[data-play-url],[data-playurl],[data-source],[data-stream],[data-file]';
  var ATTR_URL_RE = /https?:\/\/[^"'<>\s]+?\.(?:m3u8|mp4|mpd|mov|webm|mkv|flv|m4v|ts)(?:[?#][^"'<>\s]*)?/ig;
  var ATTR_REL_RE = /^[^"'<>\s]{2,300}\.(?:m3u8|mp4|mpd)(?:[?#][^"'<>\s]*)?$/i;

  function isBlobVideo(v) {
    try {
      var s = v.currentSrc || (v.getAttribute && v.getAttribute('src')) || v.src || '';
      return /^blob:/i.test(s);
    } catch (e) { return false; }
  }

  // 属性所在元素是否「当前正被 blob: 播放器使用」
  function nearBlobVideo(el) {
    try {
      if (el.tagName === 'VIDEO') return isBlobVideo(el);
      var vs = el.querySelectorAll('video');
      for (var i = 0; i < vs.length; i++) if (isBlobVideo(vs[i])) return true;
      // 属性挂在 video 的兄弟包装层（如 .player > .dplayer-video-wrap 与 .data-bar）上时
      // 往后代找不到，再看一眼父容器
      var p = el.parentNode;
      if (p && p.querySelectorAll) {
        var pv = p.querySelectorAll('video');
        for (var j = 0; j < pv.length; j++) if (isBlobVideo(pv[j])) return true;
      }
      return false;
    } catch (e) { return false; }
  }

  function attrScan() {
    if (!docOk()) return;
    try {
      var els = document.querySelectorAll(ATTR_SEL);
      for (var i = 0; i < els.length; i++) {
        var el = els[i];
        if (el.tagName === 'IMG') continue; // data-src 的懒加载图片，纯噪声
        if (!el.attributes || !el.attributes.length) continue;
        for (var a = 0; a < el.attributes.length; a++) {
          var at = el.attributes[a];
          if (!at || !at.value || at.name.indexOf('data-') !== 0) continue;
          if (at.value.length > 2000) continue; // 塞整段 base64 的属性不看
          var raw = unesc(at.value);
          var play = -1; // 懒算：同一个元素只判一次
          var hit = 0;
          var m;
          ATTR_URL_RE.lastIndex = 0;
          while ((m = ATTR_URL_RE.exec(raw))) {
            if (play < 0) play = nearBlobVideo(el) ? 1 : 0;
            offer(m[0], play ? S_ATTR_PLAY : S_ATTR, 'guess', 'attr');
            if (++hit > 4) break;
          }
          if (hit) continue;
          // 纯相对路径 /hls/x.m3u8：上面那条要求 http 开头，这里补一刀
          var rel = ATTR_REL_RE.exec(raw.trim());
          if (rel) {
            var ab = absUrl(rel[0]);
            if (ab) {
              if (play < 0) play = nearBlobVideo(el) ? 1 : 0;
              offer(ab, play ? S_ATTR_PLAY : S_ATTR, 'guess', 'attr');
            }
          }
        }
      }
    } catch (e) {}
  }

  // ── B. 静态脚本解析：页面还没发起请求就能看到候选地址 ─────────────────
  // 注意：这里只给最低分（guess）。多线路站点会把所有线路都写在这里，
  // 到底哪条能用在 v1 里没法判断 —— 这正是「嗅探到不可访问那条」的主要来源。
  var SCRIPT_URL_RE =
    /https?:\\?\/\\?\/[^"'<>\s]+?\.(mp4|m3u8|mov|webm|mkv|flv|f4v|m4v|ts|m2ts|mts|mpg|mpeg|avi|wmv|asf|3gp|3g2|ogv|ogm|rm|rmvb|mpd)([?#][^"'<>\s]*)?/ig;
  var _lastScriptCount = -1;

  function scanScripts() {
    if (!docOk()) return;
    try {
      var ss = document.querySelectorAll('script');
      if (ss.length === _lastScriptCount) return; // 脚本没变就不重复扫
      _lastScriptCount = ss.length;
      for (var i = 0; i < ss.length; i++) {
        var txt = ss[i].textContent || '';
        var m;
        SCRIPT_URL_RE.lastIndex = 0;
        while ((m = SCRIPT_URL_RE.exec(txt))) {
          // 不再就地 replace：offer 里的 absUrl 会统一还原 \/ 、&amp; 、\u0026；
          // 漏还原会让 query 错位（本例的 auth_key 就是四段用 - 连的签名串）
          offer(m[0], S_GUESS, 'guess', 'script');
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
  //
  // 【为什么还要时长】站点常见形态：主视频 + 预加载的下一集 + 预卷广告，
  // 三条 m3u8 都是 200、都是合法清单、分数全是 S_OK_BODY，谁也压不住谁，
  // 于是「最近一次请求」决胜 —— 而最近的往往是刚预取的那一集。结果是：嗅探列表
  // 看着好几条都能通，点下载拿到的却是别的视频。清单的 Σ#EXTINF 与页面
  // video.duration 对得上，才是「这条就是正在播的那个」的内容级证据。
  function playlistDur(t) {
    if (!t) return 0;
    var re = /#EXTINF:\s*([0-9]+(?:\.[0-9]+)?)/g;
    var m, sum = 0, n = 0;
    while ((m = re.exec(t))) {
      sum += parseFloat(m[1]) || 0;
      if (++n > 20000) break; // 防巨型清单拖慢主线程
    }
    // master 清单没有 #EXTINF → 0（未知），不能当成「不匹配」
    return n > 0 ? Math.round(sum * 10) / 10 : 0;
  }

  // 时长比对容差：±3% 且至少 ±2s（广告前后插片、取整误差都能过）
  function durMatch(a, b) {
    if (!(a > 0) || !(b > 0)) return false;
    return Math.abs(a - b) <= Math.max(2, b * 0.03);
  }

  function pickForPlayback(wantDur) {
    var now = Date.now();
    var bestU = '', bestS = -1;
    var fallbackU = '', fallbackS = -1;
    var hasDur = 0;
    for (var u in cands) {
      var r = cands[u];
      if (r.st === 'dead') continue;
      if (r.k !== 'hls' && r.k !== 'dash') continue;
      if (now - r.ts > 30000) continue; // 半分钟前的证据不算数
      if (r.dur > 0) hasDur++;
      if (durMatch(r.dur, wantDur)) {
        if (r.sc > bestS) { bestS = r.sc; bestU = u; }
      } else if (r.sc > fallbackS) {
        fallbackS = r.sc; fallbackU = u;
      }
    }
    if (bestU) return bestU;
    // 有候选报得出时长、但没一条对得上 → 说明正在播的那条还没被抓到。
    // 这时绝不能拿「最近请求的那条」凑数：那正是下到别的视频的来源。
    if (hasDur > 0 && wantDur > 0) return '';
    return fallbackU;
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
        var want = (v.duration && isFinite(v.duration)) ? v.duration : 0;
        var p = pickForPlayback(want);
        if (!p) return;
        if (cands[p] && cands[p].sc >= S_OK) offer(p, S_PLAY, 'ok', 'play');
        else offer(p, S_WEAK, 'guess', 'play');
      }
    } catch (e) {}
  }

  // 轮询兜底：有些播放器不派发 play/playing 到 document（或用 video.play() 静默起播）
  function checkPlaying() {
    if (!docOk()) return;
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
  // RAW_FETCH：未被包装的原始 fetch。主动校验（见 I 段）用它 —— 走包装版会把
  // 「跨域无 CORS 头的探测失败」记成 dead，而那不是链接坏，是浏览器不给读。
  var RAW_FETCH = window.__vdlRawFetch || window.fetch;
  if (window.fetch && !window.__vdlFetchHooked) {
    window.__vdlFetchHooked = 1;
    var origFetch = window.fetch;
    window.__vdlRawFetch = origFetch;
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
                  t = String(t || '');
                  var head = t.slice(0, 64);
                  if (/^\uFEFF?\s*#EXTM3U/.test(head)) {
                    // 顺带记下清单总时长：master 清单没有 #EXTINF → 0（未知）
                    var d = playlistDur(t.slice(0, 512 * 1024));
                    var au = absUrl(u);
                    if (d > 0 && au && cands[au]) cands[au].dur = d;
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
            var full = '';
            if (!rt || rt === 'text') {
              try { full = String(xhr.responseText || '').slice(0, 512 * 1024); } catch (e) {}
            }
            var txt = full.slice(0, 64);
            // 内容级确认优先
            if (/^\uFEFF?\s*#EXTM3U/.test(txt)) {
              offer(url, S_OK_BODY, 'ok', 'xhr', 'hls');
              var d = playlistDur(full);
              var au = absUrl(url);
              if (d > 0 && au && cands[au]) cands[au].dur = d;
              return;
            }
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

  // ── I. 主动校验：给「页面自己从没请求过」的候选补一次实测 ───────────────
  // 拦截只能看到「已经发生的请求」：fetch/XHR/资源时间线上有它的，状态码、
  // Content-Type、响应体内容全都拿得到（F/G/D 段已经在做）。
  // 但脚本里抄出来、容器属性里挂着的备用线路，页面可能一次都不请求 —— 没有请求
  // 就没有状态码，只能永远停在「?」。想过滤掉这些，唯一办法是打开卡片时现场探一次。
  //
  // 判死的门槛故意抬高：探测失败 ≠ 链接坏。跨域 CDN 不给 CORS 头时 fetch 必 reject，
  // 证书错、断连也是 reject —— 这些只记「不确定」，保持 guess。只有拿到 4xx/5xx、
  // 或「200 但内容根本不是清单」才判 dead（后者是内容级确定性结论）。
  var PROBED = Object.create(null);
  var PROBE_TTL = 20000; // 同一条候选 20s 内不重复探测

  // 单条探测：fetch + 视频直链只读前 1KB（Range）。
  // 为什么不用 <video> 当探针：媒体元素的 error 语义不可靠 —— 404 和「编解码不认」
  // 都报 MEDIA_ERR_SRC_NOT_SUPPORTED，Chromium 里连 m3u8 也永远拿不到元数据。
  // 拿它判死会把「其实能下」的 mkv / HLS 线路误杀。宁可不判，也不能判错。
  //
  // 判定口径（刻意保守）：
  //   404/410/5xx、2xx 但内容不是清单、2xx+text/html  → dead（确定性结论）
  //   401/403、fetch 被拒（无 CORS 头/证书/断连）      → unknown（探测失败 ≠ 链接坏）
  function probeOne(u) {
    var k = kindOf(u);
    PROBED[u] = Date.now();
    var unknown = { url: u, state: 'unknown', code: 0, via: 'fetch' };
    var f = RAW_FETCH;
    if (!f) return Promise.resolve(unknown);
    var opts = {
      method: 'GET',
      // omit：跨域 CDN 回 Access-Control-Allow-Origin:* 时带 credentials 会被直接拒；
      // 而视频鉴权几乎都在 URL 签名里，不靠 cookie
      credentials: 'omit',
      cache: 'no-store',
      mode: 'cors'
    };
    // 清单是文本、整份很小；视频直链只取头部 1KB，绝不能整片下载
    if (k !== 'hls' && k !== 'dash') opts.headers = { Range: 'bytes=0-1023' };
    var p;
    try { p = f.call(window, u, opts); } catch (e) { return Promise.resolve(unknown); }
    if (!p || !p.then) return Promise.resolve(unknown);
    return p.then(function (resp) {
      if (!resp) return unknown;
      var code = resp.status || 0;
      var ct = '';
      try { ct = (resp.headers && resp.headers.get && resp.headers.get('content-type')) || ''; } catch (e) {}
      var fk = PLAYLIST_MIME.test(ct) ? 'hls' : (DASH_MIME.test(ct) ? 'dash' : k);
      if (code === 401 || code === 403) return { url: u, state: 'unknown', code: code, via: 'fetch' };
      if (code >= 400) return { url: u, state: 'dead', code: code, via: 'fetch' };
      // 视频直链：2xx/206 + 非 HTML 就够，不必读内容
      if (k !== 'hls' && k !== 'dash' && !PLAYLIST_MIME.test(ct) && !DASH_MIME.test(ct)) {
        if (!ct || MIME_RE.test(ct) || /octet-stream/i.test(ct)) {
          return { url: u, state: 'ok', code: code, via: 'fetch', fk: fk };
        }
        // 2xx 但 Content-Type 是 text/html → 又一枚「假可用」
        return { url: u, state: 'dead', code: code, via: 'fetch', fk: fk, body: 1 };
      }
      if (!resp.text) return { url: u, state: 'ok', code: code, via: 'fetch', fk: fk };
      return resp.text().then(function (t) {
        var head = String(t || '').slice(0, 512);
        if (k === 'dash') {
          if (/<MPD[\s>]/i.test(head)) return { url: u, state: 'ok', code: code, via: 'fetch', fk: 'dash', body: 1 };
          if (head.length > 8) return { url: u, state: 'dead', code: code, via: 'fetch', fk: 'dash', body: 1 };
          return { url: u, state: 'ok', code: code, via: 'fetch', fk: 'dash' };
        }
        if (/^\uFEFF?\s*#EXTM3U/.test(head)) {
          return { url: u, state: 'ok', code: code, via: 'fetch', fk: 'hls', body: 1 };
        }
        // 200 + HTML 错误页 / JSON 提示：站点最常见的「假可用线路」
        if (head.length > 8) return { url: u, state: 'dead', code: code, via: 'fetch', fk: 'hls', body: 1 };
        return { url: u, state: 'ok', code: code, via: 'fetch', fk: 'hls' };
      }, function () {
        // 读不到内容（CORS 下的不透明响应等）→ 按状态码认可，不算内容级确认
        return { url: u, state: 'ok', code: code, via: 'fetch', fk: fk };
      });
    }, function () {
      // fetch 被拒（CORS/证书/断连）→ 不确定
      return unknown;
    });
  }

  // 批量校验：最多 4 条、两路并发。done 每出结果回调一次，
  // marker 用它把「?」逐行改成 ✓/✗（不整卡重绘，滚动位置和点击目标都不会跳）
  function verify(list, done) {
    var now = Date.now();
    var todo = [];
    for (var i = 0; i < (list || []).length; i++) {
      var u = list[i];
      var r = cands[u];
      if (!r) continue;
      if (r.st === 'ok' && r.sc >= S_OK) continue; // 已有实测成功证据，不必再探
      if (PROBED[u] && now - PROBED[u] < PROBE_TTL) continue;
      todo.push(u);
    }
    var limit = Math.min(todo.length, 4);
    var idx = 0;
    var live = 0;
    function run() {
      while (live < 2 && idx < limit) {
        var u = todo[idx++];
        live++;
        probeOne(u).then(function (res) {
          try {
            var r = cands[res.url];
            if (r) {
              if (res.state === 'ok') {
                // 读到内容并确认是清单 → 与站点自己的实测同权重；
                // 只拿到状态码/类型 → 次一档（可能仍是一张 HTML 错误页）
                if (res.body) offer(res.url, S_OK_BODY, 'ok', 'probe', res.fk);
                else offer(res.url, S_OK_MIME, 'ok', 'probe', res.fk);
              } else if (res.state === 'dead') {
                // hard：4xx/5xx 或内容不符，是确定性结论，可以推翻状态码级的 ok
                offer(res.url, S_DEAD, 'dead', 'probe', res.fk, true);
              }
              r.code = res.code || 0;
              r.probed = Date.now();
            }
            if (done) { try { done(res); } catch (e) {} }
          } catch (e) {}
          live--;
          run();
        }, function () {
          live--;
          run();
        });
      }
      // 整批探完（含一条都没探的情况）：done(null) 是「收工」信号，
      // marker 靠它把表头从「校验中…」改回「点选切换」
      if (idx >= limit && live === 0) {
        if (done) { try { done(null); } catch (e) {} }
      }
    }
    run();
  }

  if (window.__vdlSniffInstalled) return;
  window.__vdlSniffInstalled = true;

  // ── 对外 API（video_marker.js 用）───────────────────────────────────
  window.__vdlSniff = {
    // v1 兼容：最近一条（跳过 dead 与已过期）
    getLatest: function (kind) {
      var arr = ranked(kind);
      for (var i = 0; i < arr.length; i++) {
        if (arr[i].st !== 'dead' && !staleOf(arr[i])) return arr[i].u;
      }
      return '';
    },
    // 推荐一条可直接用的（v2 主入口，marker 用这个）
    getBest: function (kind) {
      var b = best(kind);
      return b ? b.url : '';
    },
    // 带分数与状态的推荐项（含 src/exp/soon/why）
    best: best,
    // 全量候选（按分数降序，最多 8 条），供 marker 展示「线路」列表
    list: listOf,
    stateOf: stateOf,
    // 主动校验：marker 打开操作卡时对「未验证」候选调一次，结果回填进候选表，
    // 每出一条结果回调一次（UI 逐行改 ✓/✗）。详见 I 段。
    verify: verify,
    // 签名过期时间（unix 秒，0 = 没有可识别的时效参数），marker 用来提示
    expOf: function (u) {
      var r = cands[u];
      if (!r) return 0;
      if (r.exp === undefined) r.exp = parseExp(u);
      return r.exp || 0;
    },
    // 调试用
    dump: function () {
      return ranked('').map(function (r) {
        return {
          url: r.u, kind: r.k, score: r.sc, state: r.st, src: r.src,
          exp: r.exp || 0, soon: soonOf(r), expired: staleOf(r), code: r.code || 0
        };
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

  // 兜底轮询：元素扫描 + 容器属性 + 资源时间线 + 脚本解析 + 播放状态 + 迟到 iframe
  setInterval(function () {
    collect();
    attrScan();
    collectPerf();
    scanScripts();
    checkPlaying();
    if (window.__vdlSniffSource) {
      try { window.__vdlSniffPropagate(window.__vdlSniffSource); } catch (e) {}
    }
  }, 2000);

  collect();
  attrScan();
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
        attrScan();
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
