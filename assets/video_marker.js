// 页面视频标记（方案A v2）：嗅探到的 <video> 加描边 + 右上角角标
// 支持的视频类型：
//  直链：mp4/mov/webm/mkv/flv/f4v/m4v/ts/m2ts/mts/mpg/avi/wmv/asf/3gp/ogv/rm/rmvb（蓝）
//  HLS：m3u8（紫）  DASH：mpd（青）  MSE/blob：无直链时用嗅探器最近捕获的 URL 兜底（灰）
// 标记不限于主框架：同源 iframe 内的播放器也会被注入标记（跨域 iframe 受浏览器限制）
// 操作经 videoAction 通道回传 Dart（下载 / 缓存m3u8 / 转MP4 / 复制 / 忽略）
(function () {
  function propagate(src) {
    // src == null → 通知子框架清理（开关关闭）；否则把标记脚本扩散到同源 iframe
    try {
      var off = (src === null || src === undefined);
      var frames = document.querySelectorAll('iframe');
      for (var i = 0; i < frames.length; i++) {
        var f = frames[i];
        var w = f.contentWindow;
        if (!w) continue;
        try {
          if (off) {
            if (w.__vdlMarkerInstalled && w.__vdlCleanup) w.__vdlCleanup();
            continue;
          }
          if (w.__vdlMarkerInstalled) continue;
          if (!f.contentDocument) continue; // 跨域 → 抛异常跳过
          w.__vdlMarkerSource = src;
          w.eval(src);
        } catch (e) {}
      }
    } catch (e) {}
  }

  if (window.__vdlMarkerInstalled) return;
  // 开关：iOS 全帧 user script 里由 Dart 在脚本前写入 window.__vdlMarkEnabled。
  // 关掉时连 iframe 帧也不启动（否则关掉开关后跨域播放器帧里还会冒角标）。
  if (window.__vdlMarkEnabled === false) return;
  // 这里**不能**再因为 `!document.documentElement` 就 return：iOS 的 WKUserScript 是
  // atDocumentStart + 全帧注入，那个时刻 <html>/<head> 常常还没创建，而 user script 对每个
  // 文档只执行一次 —— return 掉就等于这个文档（以及每个跨域 iframe 播放器帧）永远没有角标。
  // 这正是「视频已经播起来了、角标一个都不出」的根因。样式表改为轮询补挂（见 mountStyle）。
  window.__vdlMarkerInstalled = true;
  window.__vdlMarkerPropagate = propagate;

  var EXT_RE = /\.(mp4|m3u8|mov|webm|mkv|flv|f4v|m4v|ts|m2ts|mts|mpg|mpeg|avi|wmv|asf|3gp|3g2|ogv|ogm|rm|rmvb|mpd)([?#]|$)/i;
  var MIME_RE = /^video\/|x-mpegurl|vnd\.apple\.mpegurl|dash\+xml|mp2t/i;
  var ACT_CH = 'videoAction';
  var FMTS = {
    mp4: 'MP4', m3u8: 'HLS', mpd: 'DASH', ts: 'TS', m2ts: 'M2TS', mts: 'M2TS',
    mkv: 'MKV', flv: 'FLV', f4v: 'F4V', m4v: 'M4V', mov: 'MOV', webm: 'WEBM',
    mpg: 'MPEG', mpeg: 'MPEG', avi: 'AVI', wmv: 'WMV', asf: 'ASF',
    '3gp': '3GP', ogv: 'OGV', rm: 'RMVB', rmvb: 'RMVB'
  };

  var style = document.createElement('style');
  style.id = 'vdl-style';
  style.textContent =
    '.vdl-video{outline:2px dashed rgba(59,130,246,.75)!important;outline-offset:3px;}' +
    '.vdl-badge{position:fixed;z-index:2147483647;background:rgba(15,23,42,.94);color:#fff;' +
    'font:12px/1 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;' +
    'padding:5px 9px;border-radius:13px;cursor:pointer;box-shadow:0 2px 8px rgba(0,0,0,.4);' +
    'display:flex;align-items:center;gap:5px;user-select:none;-webkit-user-select:none;' +
    'pointer-events:auto;transition:background .15s;}' +
    '.vdl-badge:hover{background:#1d4ed8;}' +
    '.vdl-badge.vdl-hls{background:rgba(88,28,135,.95);}' +
    '.vdl-badge.vdl-hls:hover{background:#6d28d9;}' +
    '.vdl-badge.vdl-dash{background:rgba(8,116,144,.95);}' +
    '.vdl-badge.vdl-dash:hover{background:#0e7490;}' +
    '.vdl-badge.vdl-mse{background:rgba(71,85,105,.95);}' +
    '.vdl-badge.vdl-mse:hover{background:#475569;}' +
    '.vdl-badge.vdl-done{background:#15803d;}' +
    '.vdl-ic{width:15px;height:15px;border-radius:50%;background:#3b82f6;color:#fff;' +
    'display:flex;align-items:center;justify-content:center;font-size:10px;font-weight:700;flex:none;}' +
    '.vdl-hls .vdl-ic{background:#7c3aed;}' +
    '.vdl-dash .vdl-ic{background:#0e7490;}' +
    '.vdl-mse .vdl-ic{background:#64748b;}' +
    '.vdl-tx{max-width:110px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}' +
    '.vdl-card{position:fixed;z-index:2147483647;width:252px;max-height:360px;overflow:auto;' +
    // overscroll-behavior:contain：卡片内滚到底后不要「链式」带动页面上滚，
    // 页面一滚 dismiss 逻辑就会把卡片关掉（旧版 iOS 不支持时另有 touch 手势兜底）
    'overscroll-behavior:contain;-webkit-overflow-scrolling:touch;' +
    'background:#fff;color:#0f172a;border-radius:12px;box-shadow:0 8px 28px rgba(0,0,0,.35);' +
    'font:13px/1.45 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;}' +
    '.vdl-card-h{padding:10px 12px;background:#f8fafc;border-bottom:1px solid #e2e8f0;}' +
    '.vdl-card-t{font-weight:600;margin-bottom:2px;max-height:38px;overflow:hidden;}' +
    '.vdl-card-m{color:#64748b;font-size:12px;}' +
    '.vdl-card-u{color:#94a3b8;font-size:11px;word-break:break-all;max-height:32px;overflow:hidden;margin-top:3px;}' +
    '.vdl-card-n{color:#94a3b8;font-size:12px;margin-top:3px;}' +
    '.vdl-btn{display:block;width:100%;text-align:left;padding:11px 12px;border:0;' +
    'border-top:1px solid #f1f5f9;background:#fff;color:#0f172a;font-size:13px;cursor:pointer;}' +
    '.vdl-btn:hover{background:#eff6ff;}' +
    '.vdl-btn.hl{color:#1d4ed8;font-weight:600;}' +
    // 多线路候选列表：站点把多条 m3u8 一起下发时，让用户能自己挑一条能用的
    '.vdl-lines{max-height:132px;overflow:auto;overscroll-behavior:contain;' +
    '-webkit-overflow-scrolling:touch;background:#f8fafc;border-top:1px solid #e2e8f0;}' +
    '.vdl-lines-h{padding:6px 12px 4px;color:#64748b;font-size:11px;}' +
    '.vdl-line{display:flex;align-items:center;gap:6px;width:100%;text-align:left;' +
    'padding:6px 12px;border:0;border-top:1px solid #eef2f7;background:transparent;' +
    'color:#0f172a;font-size:12px;cursor:pointer;}' +
    '.vdl-line:hover{background:#eff6ff;}' +
    '.vdl-line.on{background:#eff6ff;font-weight:600;}' +
    '.vdl-line.dead{color:#94a3b8;}' +
    '.vdl-lm{flex:none;font-weight:700;width:10px;}' +
    '.vdl-line.on .vdl-lm{color:#16a34a;}' +
    '.vdl-line.dead .vdl-lm{color:#dc2626;}' +
    '.vdl-warn{color:#b45309;background:#fffbeb;border-radius:6px;padding:6px 8px;margin-top:6px;}' +
    '.vdl-lu{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}';
  // 样式表挂载：atDocumentStart 时 head 甚至 documentElement 都可能还没创建。
  // 轮询补挂（10ms × 600 ≈ 6s）；挂不上期间角标仍然会创建（只是没样式），
  // 绝不能因为挂不上就 return —— 那会让整个文档没有角标。
  var styleTries = 0;
  function mountStyle() {
    if (style.parentNode) return;
    var host = document.head || document.documentElement;
    if (host) {
      try { host.appendChild(style); } catch (e) {}
    }
    if (style.parentNode) return;
    if (++styleTries > 600) return;
    setTimeout(mountStyle, 10);
  }
  mountStyle();

  // 角标/卡片的挂载点。用 documentElement 而不是 body：站点常给 body（或 #app 外壳）
  // 加 transform/filter（页面切换动画），那会让 position:fixed 相对它定位而跑到屏幕外；
  // 同时作为 html 的最后一个子节点，z-index 打平时也能压在站点浮层上（广告遮罩常用 2147483647）
  function hostOf() {
    return document.documentElement || document.body;
  }

  function postAction(payload) {
    try {
      var s = JSON.stringify(payload);
      var w = window.webkit;
      if (w && w.messageHandlers && w.messageHandlers[ACT_CH]) {
        w.messageHandlers[ACT_CH].postMessage(s); // iOS WKWebView（含 iframe）
      } else if (window[ACT_CH] && window[ACT_CH].postMessage) {
        window[ACT_CH].postMessage(s); // Android / 调试页
      }
    } catch (e) {}
  }

  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function fmtDur(d) {
    if (!isFinite(d) || d <= 0) return '';
    var s = Math.round(d);
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
    function p(n) { return (n < 10 ? '0' : '') + n; }
    return (h ? h + ':' : '') + p(m) + ':' + p(sec);
  }

  function resOf(video) {
    if (video.videoWidth && video.videoHeight) return video.videoWidth + '×' + video.videoHeight;
    var src = video.currentSrc || video.getAttribute('src') || video.src || '';
    var m = src.match(/(\d{3,4})[x×](\d{3,4})/);
    if (m) return m[1] + '×' + m[2];
    m = src.match(/(?:^|[\/_\-.])(\d{3,4})p/i);
    return m ? (m[1] + 'p') : '';
  }

  function kindOf(src) {
    if (/\.m3u8([?#]|$)/i.test(src)) return 'hls';
    if (/\.mpd([?#]|$)/i.test(src)) return 'dash';
    if (EXT_RE.test(src)) return 'file';
    if (/^blob:/i.test(src) || !src) return 'mse';
    return 'other';
  }

  function fmtOf(src) {
    var m = src.match(/\.([a-z0-9]{2,5})([?#]|$)/i);
    return (m && FMTS[m[1].toLowerCase()]) || '';
  }

  function pageTitle() {
    var og = document.querySelector('meta[property="og:title"]');
    return (og && og.content) ? og.content : (document.title || '');
  }

  // video 的 src：元素自身 → <source> 子元素（URL 或 type MIME 命中视频）
  function srcOf(video) {
    // 自绘播放器常见写法：video.srcObject = mediaSource（MSE 直挂对象）。
    // 这时 src / currentSrc 全是空串 —— 不认这一条就会被当成「没有地址」，
    // 旧版直接 continue 跳过，于是「视频明明在播、角标一个不出」。
    // 返回一个固定的伪 blob:，让下游走 MSE（靠嗅探池找 m3u8）这条路。
    if (video.srcObject) return 'blob:srcobject';
    var s = video.currentSrc ||
      (video.getAttribute && video.getAttribute('src')) || video.src || '';
    if (s) return s;
    var ss = video.querySelectorAll ? video.querySelectorAll('source') : [];
    for (var i = 0; i < ss.length; i++) {
      var t = ss[i].getAttribute && (ss[i].getAttribute('type') || '') || '';
      var u = ss[i].currentSrc || (ss[i].getAttribute && ss[i].getAttribute('src')) || '';
      if (!u) continue;
      if (EXT_RE.test(u) || MIME_RE.test(t)) return u;
    }
    return '';
  }

  // blob:/MSE 没有直链时，向嗅探器要「当前最可信」的候选（而不是「最近一条」）：
  // 站点逐个试探多条 m3u8 时，最近一条往往是失败的那条。
  // 返回整个对象（含 state/soon/why），卡片需要区分「未验证」「已过期」「确认失效」。
  function capturedFor(video) {
    try {
      var s = window.__vdlSniff;
      if (!s || !s.best) return null;
      // 元素地址缺失 / blob: / 非扩展名形式 → 三种情况都只能靠嗅探池；
      // 之前只放过 blob:，于是「懒赋 src 的播放器」在赋 src 之前一个角标都不出
      var k = kindOf(srcOf(video));
      if (k !== 'mse' && k !== 'other') return null;
      var b = s.best('hls') || s.best('dash') || s.best('file');
      if (b && b.url) return b;
      var u = s.getLatest ? (s.getLatest('hls') || s.getLatest('file')) : '';
      return u ? { url: u, kind: kindOf(u), state: s.stateOf ? s.stateOf(u) : '' } : null;
    } catch (e) { return null; }
  }

  function linesOf(kind) {
    try {
      var s = window.__vdlSniff;
      if (!s || !s.list) return [];
      return s.list(kind) || [];
    } catch (e) { return []; }
  }

  function stateOfUrl(u) {
    try {
      var s = window.__vdlSniff;
      if (!s || !s.stateOf) return '';
      return s.stateOf(u) || '';
    } catch (e) { return ''; }
  }

  function infoOf(video) {
    var src = srcOf(video);
    var kind = src ? kindOf(src) : '';
    var cap = null;
    // 用户手动选了线路（多条候选里挑一条）→ 以他选的为准
    var manual = video.__vdlLine || '';
    if (manual) {
      src = manual;
      kind = kindOf(manual);
      cap = { url: manual, kind: kind, state: stateOfUrl(manual) };
    } else if (!src || kind === 'mse' || kind === 'other') {
      // 元素拿不到地址（blob: / 懒赋 src / 不是扩展名形式）：地址只能来自嗅探器
      // （元素句柄 / 容器 data-url / 网络证据 / 分片目录）
      cap = capturedFor(video);
      if (cap) { src = cap.url; kind = kindOf(cap.url); }
    } else if (kind === 'hls' || kind === 'dash') {
      // 元素直链一般是浏览器正在播的（原生 HLS），最可信；
      // 但若它在候选表里被判死、而另有明确可用的候选，则改用可用的那条
      if (stateOfUrl(src) === 'dead') {
        var b = (window.__vdlSniff && window.__vdlSniff.best) ? window.__vdlSniff.best(kind) : null;
        if (b && b.url && b.state === 'ok') { src = b.url; kind = kindOf(b.url); cap = b; }
      }
    }
    // 既没有元素地址、嗅探也没捞到东西 → 中性「视频」角标（入口先有，等地址到了再升级）
    if (!src) kind = 'none';
    var t = (video.getAttribute && (video.getAttribute('title') || video.getAttribute('aria-label'))) || '';
    var lines = (kind === 'hls' || kind === 'dash' || kind === 'file') ? linesOf(kind) : [];
    return {
      url: src,
      kind: kind,
      res: resOf(video),
      dur: fmtDur(video.duration),
      title: String(t || pageTitle()).slice(0, 80),
      state: stateOfUrl(src),
      // 签名 URL 的时效：expired 表示本地已判定过期（服务端仍可能放行，但基本 403）
      why: (cap && cap.why) || '',
      soon: !!(cap && cap.soon),
      expired: !!(cap && cap.why === 'expired'),
      lines: lines
    };
  }

  function labelOf(info) {
    // ✓ = 已确认可用（2xx + 内容校验 或 正在播放）；? = 未验证；✗ = 已确认失效
    var mk = info.state === 'ok' ? ' ✓' : (info.state === 'dead' ? ' ✗' : ' ?');
    if (info.kind === 'none') return '视频'; // 还没拿到地址：入口先立着，别让用户以为「没识别到」
    if (info.kind === 'hls') return 'HLS' + mk + (info.dur ? ' · ' + info.dur : '');
    if (info.kind === 'dash') return 'DASH' + mk;
    if (info.kind === 'mse') return '流';
    var f = fmtOf(info.url);
    if (info.res) return (f ? f + ' ' : '') + info.res;
    return f || '视频';
  }

  function refreshBadge(badge, video) {
    var info = infoOf(video);
    var label = labelOf(info);
    var tx = badge.querySelector('.vdl-tx');
    if (tx && tx.textContent !== label) tx.textContent = label;
    var hasDone = badge.className.indexOf('vdl-done') >= 0;
    var cls = 'vdl-badge';
    if (info.kind === 'hls') cls += ' vdl-hls';
    else if (info.kind === 'dash') cls += ' vdl-dash';
    else if (info.kind === 'mse') cls += ' vdl-mse';
    if (hasDone) cls += ' vdl-done';
    if (badge.className !== cls) badge.className = cls;
  }

  function makeBadge(video) {
    var b = document.createElement('div');
    b.className = 'vdl-badge';
    b.innerHTML = '<span class="vdl-ic">⬇</span><span class="vdl-tx"></span>';
    b.addEventListener('click', function (e) {
      e.preventDefault();
      e.stopPropagation();
      // 再点同一个角标 = 收起（原来 closeCard 后又立即重建，看起来「点不掉」）
      if (currentCard && currentCardAnchor === b) {
        closeCard();
        return;
      }
      toggleCard(video, b);
    });
    // 挂到 documentElement（见 hostOf）：body 上有 transform 时，body 里的 fixed 元素
    // 会跟着 body 一起偏出屏幕；挂 html 上不受影响
    (hostOf() || document.body).appendChild(b);
    return b;
  }

  // 「主播放器」判据：没拿到地址的 <video> 只有够大才值得立角标（避免给广告位/小窗
  // 预览视频都挂一个）；阈值与接管的小窗判据一致（240×135）
  function isMainPlayer(video) {
    var r = null;
    try { r = video.getBoundingClientRect(); } catch (e) { return false; }
    return !!(r && r.width >= 240 && r.height >= 135);
  }

  // 已标记视频登记表。必需：video 从 DOM 移除后 querySelectorAll 就查不到它了，
  // 只遍历现存 <video> 会漏掉这类元素 —— 预览视频关掉后角标会永久留在页面上，
  // 而且再没有任何代码更新它的坐标（表现为「视频没了角标还在、位置卡死不动」）。
  var marked = [];

  // ── 视频元素收集：document + shadow root + 同源 iframe ─────────────────
  // 1) 自绘播放器把 <video> 塞进 shadow root，`document.querySelectorAll('video')` 一个都
  //    看不到 —— 现象就是「页面上视频在播、旁边没有角标」，而页面里随便一个广告 <video>
  //    反而有角标。atDocumentStart 就钩住 attachShadow，之后创建的 shadow root 全部登记
  //    （closed 模式拿不到，无法处理；主流播放器是 open）。
  // 2) 同源 iframe 里的播放器直接遍历；跨域帧由全帧注入的 marker 在自己的帧里处理。
  var shadowRoots = [];
  try {
    var EP = window.Element && window.Element.prototype;
    if (EP && EP.attachShadow && !EP.__vdlAttachShadowHooked) {
      var origAttachShadow = EP.attachShadow;
      EP.attachShadow = function () {
        var sr = origAttachShadow.apply(this, arguments);
        try {
          if (sr && sr.nodeType === 11 && shadowRoots.indexOf(sr) < 0) {
            shadowRoots.push(sr);
            // 播放器刚挂上 → 立刻重扫（0ms 抓住首帧，300ms 兜住后续插入）
            setTimeout(update, 0);
            setTimeout(update, 300);
          }
        } catch (e) {}
        return sr;
      };
      EP.__vdlAttachShadowHooked = true;
    }
  } catch (e) {}

  // hook 装得比播放器晚时（注入时机不确定）已经创建好的 shadow root 只能靠扫。
  // 5s 一次、只读属性，成本可忽略。
  var lastShadowSweep = 0;
  function sweepShadowRoots() {
    var now = Date.now ? Date.now() : new Date().getTime();
    if (now - lastShadowSweep < 5000) return;
    lastShadowSweep = now;
    var els;
    try { els = document.querySelectorAll('*'); } catch (e) { return; }
    for (var i = 0; i < els.length; i++) {
      var sr = null;
      try { sr = els[i].shadowRoot; } catch (e) {}
      if (sr && sr.nodeType === 11 && shadowRoots.indexOf(sr) < 0) shadowRoots.push(sr);
    }
  }

  function collectVideos() {
    var out = [];
    function take(root) {
      if (!root || !root.querySelectorAll) return;
      var vs;
      try { vs = root.querySelectorAll('video'); } catch (e) { return; }
      for (var i = 0; i < vs.length; i++) if (out.indexOf(vs[i]) < 0) out.push(vs[i]);
    }
    take(document);
    for (var i = 0; i < shadowRoots.length; i++) take(shadowRoots[i]);
    var fs;
    try { fs = document.querySelectorAll('iframe'); } catch (e) { fs = []; }
    for (var j = 0; j < fs.length; j++) {
      try { take(fs[j].contentDocument); } catch (e) {}
    }
    return out;
  }

  // 元素在本帧视口里的矩形。视频在同源 iframe 里时，getBoundingClientRect 给的是
  // 该 iframe 自己的坐标系，必须逐级加上各层 frameElement 的偏移，否则角标会画在
  // 左上角/错位（用户看到的就是「角标位置莫名其妙」）。跨域帧拿不到 frameElement，
  // 返回 null —— 那个帧里的视频由它自己的 marker 画。
  function rectOf(video) {
    var r;
    try { r = video.getBoundingClientRect(); } catch (e) { return null; }
    var out = {
      left: r.left, top: r.top, width: r.width, height: r.height,
      right: r.right, bottom: r.bottom
    };
    var w = null;
    try { w = video.ownerDocument && video.ownerDocument.defaultView; } catch (e) {}
    var guard = 0;
    while (w && w !== window && guard++ < 8) {
      var fe = null;
      try { fe = w.frameElement; } catch (e) {}
      if (!fe) return null;
      var fr;
      try { fr = fe.getBoundingClientRect(); } catch (e) { return null; }
      out.left += fr.left; out.top += fr.top;
      out.right += fr.left; out.bottom += fr.top;
      w = (fe.ownerDocument && fe.ownerDocument.defaultView) || null;
    }
    return out;
  }

  function place(badge, video) {
    var r = rectOf(video);
    // 尺寸为 0 / 移出视口 / 被祖先 display:none 藏起来 → 不显示角标
    if (
      !r || r.width < 10 || r.height < 10 ||
      r.bottom <= 0 || r.top >= window.innerHeight ||
      r.right <= 0 || r.left >= window.innerWidth
    ) {
      badge.style.display = 'none';
      return;
    }
    badge.style.display = '';
    var bw = badge.offsetWidth || 64;
    var left = r.left + r.width - bw - 6;
    if (left < 4) left = 4;
    var top = r.top - 12;
    if (top < 4) top = 4;
    badge.style.left = left + 'px';
    badge.style.top = top + 'px';
  }

  var currentCard = null;
  var currentCardAnchor = null;
  // 卡片对应的视频 + 打开时是否已经有地址：没有地址的卡片（占位态）在嗅探拿到地址后
  // 要自动重绘一次，否则用户会一直看着「尚未捕获」的空卡片
  var currentCardVideo = null;
  var currentCardHasUrl = false;
  var cardDismissBound = false;
  // 手势是否「起手在卡片内」：卡片内滑动被带动页面时不应该关掉卡片
  var cardGesture = 0;

  // 点卡片外部 / 页面滚动 → 关闭操作卡（否则弹层只能靠再次点角标或选中某项关掉）
  function onDocClick(e) {
    if (!currentCard) return;
    var t = e.target;
    if (currentCard === t || currentCard.contains(t)) return;
    if (currentCardAnchor &&
        (currentCardAnchor === t || currentCardAnchor.contains(t))) return;
    closeCard();
  }

  function onScrollClose(e) {
    if (!currentCard) return;
    // 滚动事件在 window 上以捕获方式监听，卡片自身、卡片里的候选列表滚动同样会经过这里。
    // 这两种都不是「页面在滚」，一律放过 —— 否则用户想翻候选列表，一滑就把卡片关掉了。
    var t = e && (e.target || e.srcElement);
    if (t && t.nodeType === 1 && (t === currentCard || currentCard.contains(t))) return;
    // 旧版 iOS 不支持 overscroll-behavior：卡片内起手的滑动仍可能链式带动页面，
    // 手势期间（touchend 后短暂保留）不算离开
    if (cardGesture) return;
    closeCard();
  }

  function closeCard() {
    if (currentCard && currentCard.parentNode) {
      currentCard.parentNode.removeChild(currentCard);
    }
    currentCard = null;
    currentCardAnchor = null;
    currentCardVideo = null;
    currentCardHasUrl = false;
    cardGesture = 0;
    if (cardDismissBound) {
      cardDismissBound = false;
      document.removeEventListener('click', onDocClick, true);
      window.removeEventListener('scroll', onScrollClose, true);
    }
  }

  // 打开卡片后再挂「点外部关闭」：此刻正在派发这次 click，
  // 同步挂监听会在事件冒泡到 document 时立刻把卡片自己关掉 → 延到事件结束后
  function bindDismiss() {
    setTimeout(function () {
      if (!currentCard || cardDismissBound) return;
      cardDismissBound = true;
      document.addEventListener('click', onDocClick, true);
      window.addEventListener('scroll', onScrollClose, true);
    }, 0);
  }

  // 清理「视频已从 DOM 移除」的角标（悬停预览、播放器销毁等场景）
  function sweepDetached() {
    for (var i = marked.length - 1; i >= 0; i--) {
      var m = marked[i];
      if (m.v && m.v.isConnected) continue;
      if (m.b && m.b.parentNode) m.b.parentNode.removeChild(m.b);
      if (m.v) m.v.__vdlBadge = null;
      // 操作卡挂在被移除的角标上 → 一并关掉，否则弹层会浮在原地
      if (currentCardAnchor && currentCardAnchor === m.b) closeCard();
      marked.splice(i, 1);
    }
  }

  // 主动注销某个视频的标记（「忽略此条」），并从登记表摘掉，
  // 否则 rAF 会对一个已脱离文档的角标反复设样式、循环永不停
  function unmark(video) {
    for (var i = marked.length - 1; i >= 0; i--) {
      if (marked[i].v !== video) continue;
      var b = marked[i].b;
      if (b && b.parentNode) b.parentNode.removeChild(b);
      marked.splice(i, 1);
    }
    video.__vdlBadge = null;
  }

  function positionAll() {
    for (var i = 0; i < marked.length; i++) {
      var m = marked[i];
      if (m.v && m.v.isConnected) place(m.b, m.v);
    }
  }

  // 角标跟随：CSS 动画/浮层滑入不会触发 scroll/resize，单靠 1s 轮询会「卡住不跟」。
  // 有标记时用 rAF 逐帧（节流到 ~15fps）对齐坐标；无标记时自动停下。
  var rafId = 0;
  var lastPosAt = 0;
  function tick(ts) {
    rafId = 0;
    if (!window.__vdlMarkerInstalled) return;
    if (!lastPosAt || ts - lastPosAt > 66) {
      lastPosAt = ts;
      sweepDetached();
      positionAll();
    }
    if (marked.length && window.requestAnimationFrame) {
      rafId = window.requestAnimationFrame(tick);
    }
  }
  function kick() {
    if (!rafId && window.requestAnimationFrame) {
      rafId = window.requestAnimationFrame(tick);
    }
  }

  // 候选 URL 的短显示：host / 末段文件名
  function shortUrl(u) {
    try {
      var m = String(u).match(/^https?:\/\/([^\/?#]+)([^?#]*)/i);
      if (!m) return String(u).slice(0, 46);
      var seg = String(m[2] || '').split('/').filter(Boolean);
      var tail = seg.length ? seg[seg.length - 1] : '';
      var text = m[1] + (tail ? ' / ' + tail : '');
      return text.length > 46 ? text.slice(0, 45) + '…' : text;
    } catch (e) { return String(u).slice(0, 46); }
  }

  // ── 候选可用性：打开卡片时对「页面从没请求过」的线路补一次实测 ──────────
  // 候选表里的 guess 是「脚本/属性里抄出来的地址」，页面自己一次都没请求过，
  // 所以永远停在「?」—— 用户只能点下去才知道是 404。这里让嗅探器现场探一次。
  function markLine(card, url, state, code) {
    var btns = card.querySelectorAll('.vdl-line');
    for (var i = 0; i < btns.length; i++) {
      var b = btns[i];
      if (b.getAttribute('data-line') !== url) continue;
      var m = b.querySelector('.vdl-lm');
      if (m) m.textContent = state === 'ok' ? '✓' : (state === 'dead' ? '✗' : '?');
      // className 不整体重写：'.on' 是当前选中项，重建会丢
      if (state === 'dead') b.classList.add('dead');
      else b.classList.remove('dead');
      if (code) {
        b.title = 'HTTP ' + code;
        var tail = b.querySelector('.vdl-lu');
        if (tail && state === 'dead' && tail.textContent.indexOf(String(code)) < 0) {
          tail.textContent = tail.textContent + ' · ' + code;
        }
      }
      return;
    }
  }

  function verifyCardLines(card, video, badge, info) {
    try {
      var s = window.__vdlSniff;
      if (!s || !s.verify || info.kind === 'mse' || info.kind === 'none') return;
      var need = [];
      function push(u) {
        if (!u || need.indexOf(u) >= 0) return;
        need.push(u);
      }
      // 当前这条也要进去：它同样可能只是「脚本里抄来的」，页面一次都没请求过
      if (info.state !== 'ok' && info.state !== 'dead') push(info.url);
      for (var i = 0; i < (info.lines || []).length; i++) {
        var it = info.lines[i];
        if (it.state === 'ok' || it.state === 'dead') continue; // 已有实测结论，不必再探
        push(it.url);
      }
      if (!need.length) return;
      var head = card.querySelector('.vdl-lines-h');
      var multi = !!(info.lines && info.lines.length > 1);
      var headText = multi ? '共 ' + info.lines.length + ' 条候选 · ' : '';
      if (head) head.textContent = headText + '校验中…';
      s.verify(need, function (res) {
        var alive = !!(card.parentNode && currentCard === card);
        if (!res) {
          // 整批探完（嗅探器的「收工」信号）：表头恢复，角标同步刷一次
          if (alive) {
            if (head) head.textContent = headText + '点选切换';
            refreshBadge(badge, video);
          }
          return;
        }
        if (!alive) return;
        markLine(card, res.url, res.state, res.code);
        refreshBadge(badge, video); // 角标上的 ? 同步翻成 ✓ / ✗
        // 当前这条被判死、而别处有实测可用的 → 自动切过去。
        // 这是「嗅探到的恰好是打不开那条」的兜底：用户不必自己一条条试。
        if (res.state === 'dead' && res.url === info.url) {
          var b = s.best ? s.best(info.kind) : null;
          if (b && b.url && b.url !== info.url && b.state === 'ok') {
            video.__vdlLine = b.url;
            toggleCard(video, badge);
          }
        }
      });
    } catch (e) {}
  }

  function toggleCard(video, badge) {
    closeCard();
    var info = infoOf(video);
    var card = document.createElement('div');
    card.className = 'vdl-card';
    var kindName = info.kind === 'hls' ? 'HLS' :
      info.kind === 'dash' ? 'DASH' :
      info.kind === 'mse' ? 'MSE' :
      (fmtOf(info.url) || '视频');
    var meta = kindName +
      (info.res ? ' · ' + info.res : '') +
      (info.dur ? ' · ' + info.dur : '');
    var html = '<div class="vdl-card-h">' +
      '<div class="vdl-card-t">' + esc(info.title || '视频') + '</div>' +
      '<div class="vdl-card-m">' + esc(meta) + '</div>';
    if (info.kind === 'mse') {
      html += '<div class="vdl-card-n">分段/加密流（blob:），未捕获到可下载直链，暂不支持离线下载。</div>';
    } else if (info.kind === 'none') {
      // 占位态：视频元素在、地址还没有（站点点播放才赋 src）。不说「没识别到」——
      // 嗅探器一到地址这张卡会自己重绘成可下载状态
      html += '<div class="vdl-card-n">尚未捕获可下载地址 · 点一下页面播放，1–2 秒后这里会自动出现下载项</div>';
    } else {
      html += '<div class="vdl-card-u">' + esc(info.url) + '</div>';
    }
    // 签名 URL 有时效（本例 auth_key 就是半小时级的）：过期后再下必然 403，
    // 与其让用户下到一半失败，不如提前说清「刷新页面重新嗅探」这条唯一出路
    if (info.expired) {
      html += '<div class="vdl-card-n vdl-warn">链接签名已过期 · 刷新页面并重新点一次播放，嗅探会拿到新地址</div>';
    } else if (info.soon) {
      html += '<div class="vdl-card-n vdl-warn">链接即将过期 · 请尽快开始下载</div>';
    }
    html += '</div>';
    // 多候选（多线路）时列出全部，标明可用/失效，允许手动切换：
    // 这一栏就是为了解决「嗅探到的恰好是打不开的那条」
    if (info.lines && info.lines.length > 1) {
      html += '<div class="vdl-lines"><div class="vdl-lines-h">共 ' +
        info.lines.length + ' 条候选 · 点选切换</div>';
      for (var li = 0; li < info.lines.length; li++) {
        var it = info.lines[li];
        var bad = it.state === 'dead' || it.expired;
        var mk = bad ? '✗' : (it.state === 'ok' ? '✓' : (it.soon ? '!' : '?'));
        var cls = 'vdl-line' +
          (it.url === info.url ? ' on' : '') +
          (bad ? ' dead' : '');
        var tail = it.expired ? ' · 已过期' : (it.soon ? ' · 快过期' : '');
        if (bad && it.code) tail = ' · ' + it.code;
        html += '<button class="' + cls + '" data-line="' + esc(it.url) + '">' +
          '<span class="vdl-lm">' + mk + '</span>' +
          '<span class="vdl-lu">' + esc(shortUrl(it.url) + tail) + '</span></button>';
      }
      html += '</div>';
    }
    if (info.kind === 'hls') {
      // HLS 三种产物，别混为一谈：
      //  package → 自己下 .ts 分片包存 Downloads，可离线、可随时「本地转 MP4」
      //  convert → 转成单个 mp4（中间分片用完即删）。iOS 上分片由原生 background
      //            URLSession 代跑，锁屏 / 切 App 继续下载，齐备后回前台 -c copy
      //            合成；非 iOS 没有系统级后台传输，这条就是前台下完直接出片。
      //            入口对用户只有一个，不要再并列一个「后台下载」按钮。
      //  hls     → 系统 AVAssetDownloadTask 的 .movpkg，只能 AVFoundation 播，不能导出
      html += '<button class="vdl-btn hl" data-a="convert">直接转 MP4（锁屏继续下载）</button>';
      html += '<button class="vdl-btn" data-a="package">下载 m3u8 分片（可转 MP4）</button>';
      html += '<button class="vdl-btn" data-a="hls">系统离线缓存（仅播放，不可导出）</button>';
    } else if (info.kind === 'dash') {
      html += '<div class="vdl-card-n" style="padding:10px 12px;">DASH 流（.mpd）暂不支持离线下载，可复制清单链接自行处理。</div>';
    } else if (info.kind === 'file' || info.kind === 'other') {
      // 直链（含不带扩展名的播放地址，如 /play?id=1）：立即播放（边播边缓存）+ 下载
      html += '<button class="vdl-btn hl" data-a="play">立即播放（边播边缓存）</button>';
      html += '<button class="vdl-btn hl" data-a="mp4">下载视频</button>';
    }
    // MSE 且未兜底到直链 / 还没地址：无可复制的东西
    if (info.kind !== 'mse' && info.url) {
      html += '<button class="vdl-btn" data-a="copy">复制链接</button>';
    }
    html += '<button class="vdl-btn" data-a="ignore">忽略此条</button>';
    card.innerHTML = html;
    card.addEventListener('click', function (e) {
      var t = e.target;
      // 先看是不是「切线路」——它没有 data-a，别落到下面的动作分支里
      var lt = t;
      while (lt && lt !== card && !(lt.getAttribute && lt.getAttribute('data-line'))) lt = lt.parentNode;
      if (lt && lt !== card && lt.getAttribute) {
        e.preventDefault();
        e.stopPropagation();
        video.__vdlLine = lt.getAttribute('data-line') || '';
        toggleCard(video, badge); // 重绘卡片，让下面的动作按钮作用于新选的线路
        return;
      }
      while (t && t !== card && !(t.getAttribute && t.getAttribute('data-a'))) t = t.parentNode;
      var a = t && t.getAttribute ? t.getAttribute('data-a') : null;
      if (!a) return;
      e.preventDefault();
      e.stopPropagation();
      postAction({
        action: a,
        url: info.url,
        title: info.title,
        // 当前帧地址：本例这种「页面在 A 域、清单在 B 域」的站点很常见，
        // 跨域 iframe 播放器用主框架地址做 Referer 会被 CDN 判 403
        referer: location.href,
        // 页面视频的真实时长（秒）。这是「这条 m3u8 到底是不是页面上正在播的那个
        // 视频」唯一可靠的外部标尺：候选池里多条清单都能 200、都是合法清单、
        // 分数打平，靠请求时间决胜就会选到预加载的下一集 / 广告片。
        // Dart 侧拉到清单后算 Σ#EXTINF 与它比对，对不上就不下、并说明原因。
        duration: (video && video.duration && isFinite(video.duration))
          ? Math.round(video.duration * 10) / 10 : 0
      });
      closeCard();
      if (a === 'ignore') {
        unmark(video);
        video.classList.remove('vdl-video');
        video.__vdlIgnored = true;
      } else {
        badge.className = 'vdl-badge vdl-done';
        badge.querySelector('.vdl-tx').textContent = a === 'copy' ? '已复制' : '已加入';
        setTimeout(function () { refreshBadge(badge, video); }, 1800);
      }
    });
    (hostOf() || document.body).appendChild(card);
    var br = badge.getBoundingClientRect();
    var cw = card.offsetWidth || 252;
    var ch = card.offsetHeight || 240;
    var left = br.left - cw + br.width;
    if (left < 6) left = 6;
    if (left + cw > window.innerWidth - 6) left = Math.max(6, window.innerWidth - cw - 6);
    var top = br.top + 28;
    if (top + ch > window.innerHeight - 6) top = Math.max(6, window.innerHeight - ch - 6);
    card.style.left = left + 'px';
    card.style.top = top + 'px';
    currentCard = card;
    currentCardAnchor = badge;
    currentCardVideo = video;
    currentCardHasUrl = !!info.url;
    bindDismiss();

    // 卡片内起手的手势：内部没有可滚动的容器时直接吃掉（不带动页面滚），
    // 有可滚动的（候选列表）交给浏览器滚，靠 overscroll-behavior 阻断链式滚动。
    // 原生弹层的体感就是这样：在弹层上滑，弹层不动、底下的页面也不动。
    card.addEventListener('touchstart', function () {
      cardGesture = 1;
    }, { passive: true });
    card.addEventListener('touchend', function () {
      setTimeout(function () { cardGesture = 0; }, 300);
    }, { passive: true });
    card.addEventListener('touchmove', function (e) {
      var t = e.target;
      while (t && t !== card.parentNode) {
        if (t.nodeType === 1) {
          var oy = '';
          try { oy = getComputedStyle(t).overflowY; } catch (er) {}
          if ((oy === 'auto' || oy === 'scroll') && t.scrollHeight > t.clientHeight + 1) return;
        }
        t = t.parentNode;
      }
      if (e.cancelable) e.preventDefault();
    }, { passive: false });

    // 打开即校验：把「? 未验证」的候选探成 ✓ / ✗（详见 verifyCardLines）
    verifyCardLines(card, video, badge, info);
  }

  function update() {
    // 清理后（开关关闭）不再重建角标：click/play/观察器等残留监听可能仍会触发
    if (!window.__vdlMarkerInstalled) return;
    // iframe 导航中 / 文档卸载后 document 可能已经不可用（定时器还在跑）
    if (typeof document === 'undefined' || !document || !document.body) return;
    // 先摘掉已从 DOM 移除的角标（它们不会出现在下面的收集结果里）
    sweepDetached();
    sweepShadowRoots();
    var videos = collectVideos();
    // 自愈：一个跟踪中的角标都没有、页面里却有 <video> —— 说明之前的创建流程中断过
    // （badge 建了一半、挂载点错位、__vdlBadge 残留指向已 detached 的元素）。
    // 残留引用会让下面 `if (!badge)` 走不进去，永远不再重建；而「开关关→开」的
    // cleanup 恰好会清残留 —— 这就是「刷新后没角标、关了又开就有了」的机制。
    if (!marked.length) {
      for (var pi = 0; pi < videos.length; pi++) {
        if (videos[pi].__vdlBadge) videos[pi].__vdlBadge = null;
      }
    }
    for (var i = 0; i < videos.length; i++) {
      var v = videos[i];
      if (v.__vdlIgnored) continue;
      // 第一次发现「视频真的在播」→ 补报一次现场诊断。
      // 用户报的问题就发生在这个时刻，2.5s 的 boot 那次通常还没点播放，数据没用。
      if (!diagPlayPosted) {
        var isPlaying = false;
        try { isPlaying = !v.paused; } catch (e9) {}
        if (isPlaying) { diagPlayPosted = true; reportDiag('playing'); }
      }
      // 换集/换源：src 变了说明是新一条，之前手动选的线路作废
      var curSrc = srcOf(v);
      if (curSrc !== v.__vdlSeenSrc) {
        v.__vdlSeenSrc = curSrc;
        v.__vdlLine = '';
      }
      var badge = v.__vdlBadge;
      if (!badge) {
        var src = srcOf(v);
        var k0 = src ? kindOf(src) : '';
        // 没有元素地址（懒赋 src / 只挂了 poster）时，只要嗅探器已经拿到候选（容器
        // data-url、网络证据、分片目录）就该立刻出角标 —— 旧版这里 `if (!src) continue`，
        // 于是「刷新后视频明明在旁边、角标不出来，点一下页面才冒出来」，正是本次的 bug
        var cap0 = (!src || k0 === 'mse' || k0 === 'other') ? capturedFor(v) : null;
        // 两边都没有：只有「主播放器」级别的 <video> 才立一个中性角标（避免给广告位、
        // 小窗预览视频满屏挂角标）
        if (!src && !cap0 && !isMainPlayer(v)) continue;
        badge = makeBadge(v);
        v.__vdlBadge = badge;
        v.classList.add('vdl-video');
        marked.push({ v: v, b: badge });
        (function (el, b) {
          el.addEventListener('loadedmetadata', function () { refreshBadge(b, el); });
          el.addEventListener('durationchange', function () { refreshBadge(b, el); });
          el.addEventListener('resize', function () { refreshBadge(b, el); });
          // 起播 = 嗅探器拿到最硬证据的时刻，角标要从「?」翻成「✓」
          el.addEventListener('playing', function () {
            refreshBadge(b, el);
            // 清单/分片的判定可能比 playing 略晚到，补刷两次
            setTimeout(function () { refreshBadge(b, el); }, 400);
            setTimeout(function () { refreshBadge(b, el); }, 1500);
          });
        })(v, badge);
      }
      refreshBadge(badge, v);
      place(badge, v);
      // 卡片停在「尚未捕获地址」的占位态时，一旦嗅探到地址就原地重绘，
      // 不用让用户把卡片关掉再点一次
      if (currentCard && currentCardVideo === v && !currentCardHasUrl && infoOf(v).url) {
        toggleCard(v, badge);
      }
    }
    // 有待跟随的角标 → 开启逐帧对齐（脱离文档的会在 tick/sweep 里被摘掉）
    if (marked.length) kick();
  }

  window.addEventListener('scroll', update, true);
  window.addEventListener('resize', update);
  var timer = window.setInterval(function () {
    // 迟到的同源 iframe（懒加载/后注入）
    if (window.__vdlMarkerSource) {
      try { window.__vdlMarkerPropagate(window.__vdlMarkerSource); } catch (e) {}
    }
    update();
  }, 1000);

  // 懒加载站点：点击播放后才挂 src / 创建播放器 → 即时刷新 + 扩散
  function onQuick() {
    setTimeout(function () {
      update();
      if (window.__vdlMarkerSource) {
        try { window.__vdlMarkerPropagate(window.__vdlMarkerSource); } catch (e) {}
      }
    }, 60);
  }
  document.addEventListener('click', onQuick, true);
  document.addEventListener('play', onQuick, true);
  document.addEventListener('playing', onQuick, true);
  // 媒体事件不冒泡，但**捕获阶段**能收到（document 在最外层）。
  // loadeddata/canplay 是「播放器已经拿到数据、地址该有了」的最早信号 ——
  // 只靠 click/play 的话，站点「自动起播」或「静音预加载」场景会一直等到 1s 轮询。
  document.addEventListener('loadstart', onQuick, true);
  document.addEventListener('loadeddata', onQuick, true);
  document.addEventListener('canplay', onQuick, true);

  // <video>/<source> 的 src 属性变化（点击播放后赋值）→ 即时出角标。
  // 观察 document 本身而不是 documentElement：atDocumentStart 时 <html> 可能还没创建，
  // 观察 documentElement 会抛（被 catch 吞掉后只剩 1s 轮询，反应迟钝）。
  var srcObserver = null;
  try {
    srcObserver = new MutationObserver(function () { update(); });
    srcObserver.observe(document, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['src', 'poster']
    });
  } catch (e) {}

  // 全屏播放时隐藏标记
  function fsEvt() {
    var fs = !!(document.fullscreenElement || document.webkitFullscreenElement);
    var el = document.querySelectorAll('.vdl-badge, .vdl-card');
    for (var i = 0; i < el.length; i++) el[i].style.display = fs ? 'none' : '';
  }
  document.addEventListener('fullscreenchange', fsEvt);
  document.addEventListener('webkitfullscreenchange', fsEvt);

  // ── 现场诊断（每个文档最多两条，进 App 日志）───────────────────────────
  // 用户反馈「视频在播、角标不出」时，靠这条日志一次分辨到底是哪种情况：
  //   ① videos=0 但 frames>0 / shadow>0 → 视频在别的帧或 shadow root 里
  //   ② videos>0 playing>0 但 badged=0 → 建角标条件被卡住
  //   ③ badged>0 shown=0 → 坐标算出来在视口外（rectOf 换算/祖先隐藏）
  //   ④ badged>0 covered>0 → 建了但被站点浮层盖住（要上 top-layer）
  //   ⑤ nativefs>0 → iOS 原生全屏播放，HTML 角标物理上不可能可见
  var diagBootPosted = false;
  var diagPlayPosted = false;
  function reportDiag(tag) {
    try {
      if (!window.__vdlMarkerInstalled) return;
      var vs = collectVideos();
      var big = 0, shown = 0, covered = 0, playing = 0, srcobj = 0, nativefs = 0;
      for (var i = 0; i < vs.length; i++) {
        if (isMainPlayer(vs[i])) big++;
        try {
          if (!vs[i].paused) playing++;
          if (vs[i].srcObject) srcobj++;
          if (vs[i].webkitDisplayingFullscreen) nativefs++;
        } catch (e3) {}
        var b = vs[i].__vdlBadge;
        if (!b || b.style.display === 'none') continue;
        shown++;
        try {
          if (typeof document.elementFromPoint !== 'function') continue;
          var r = b.getBoundingClientRect();
          var hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
          if (hit && hit !== b && !b.contains(hit)) covered++;
        } catch (e2) {}
      }
      var frames = 0;
      try { frames = document.querySelectorAll('iframe').length; } catch (e4) {}
      postAction({
        action: 'markerDiag',
        url: '',
        tag: tag,
        frame: (window === window.top) ? 'top' : 'sub',
        videos: vs.length,
        dom: (function () { try { return document.querySelectorAll('video').length; } catch (e5) { return 0; } })(),
        shadow: shadowRoots.length,
        frames: frames,
        playing: playing,
        srcobj: srcobj,
        nativefs: nativefs,
        big: big,
        badged: marked.length,
        shown: shown,
        covered: covered,
        href: location.href
      });
    } catch (e) {}
  }
  window.setTimeout(function () { diagBootPosted = true; reportDiag('boot'); }, 2500);

  window.__vdlCleanup = function () {
    window.clearInterval(timer);
    window.removeEventListener('scroll', update, true);
    window.removeEventListener('resize', update);
    document.removeEventListener('click', onQuick, true);
    document.removeEventListener('play', onQuick, true);
    // 操作卡若正开着，连它挂的「点外部关闭」监听一起摘掉
    closeCard();
    if (srcObserver) { try { srcObserver.disconnect(); } catch (e) {} }
    var st = document.getElementById('vdl-style');
    if (st && st.parentNode) st.parentNode.removeChild(st);
    if (rafId && window.cancelAnimationFrame) window.cancelAnimationFrame(rafId);
    rafId = 0;
    marked.length = 0;
    var el = document.querySelectorAll('.vdl-badge, .vdl-card');
    for (var i = 0; i < el.length; i++) if (el[i].parentNode) el[i].parentNode.removeChild(el[i]);
    var vs = document.querySelectorAll('video.vdl-video');
    for (var j = 0; j < vs.length; j++) vs[j].classList.remove('vdl-video');
    // 元素上残留的 __vdlBadge 必须清掉：否则重新打开标记开关后，
    // update() 会认为角标已存在而不再创建，页面就再也不出角标了
    var all = document.querySelectorAll('video');
    for (var k = 0; k < all.length; k++) {
      all[k].__vdlBadge = null;
      all[k].__vdlLine = '';
      all[k].__vdlSeenSrc = undefined;
    }
    window.__vdlMarkerInstalled = false;
    window.__vdlMarkerSource = null;
    // 通知子框架一起清理（开关关闭）
    try { window.__vdlMarkerPropagate(null); } catch (e) {}
  };

  update();

  // 首次注入后立即扩散（源码由 Dart 侧注入时传入 window.__vdlMarkerSource）
  if (window.__vdlMarkerSource) {
    try { window.__vdlMarkerPropagate(window.__vdlMarkerSource); } catch (e) {}
  }
})();
