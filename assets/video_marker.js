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
    '.vdl-badge{position:fixed;z-index:2147483000;background:rgba(15,23,42,.94);color:#fff;' +
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
    '.vdl-card{position:fixed;z-index:2147483001;width:252px;max-height:360px;overflow:auto;' +
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
    '.vdl-lines{max-height:132px;overflow:auto;background:#f8fafc;border-top:1px solid #e2e8f0;}' +
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
    '.vdl-lu{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}';
  (document.head || document.documentElement).appendChild(style);

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
  function bestOf(kind) {
    try {
      var s = window.__vdlSniff;
      if (!s || !s.best) return null;
      return s.best(kind) || null;
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

  function capturedFor(video) {
    try {
      var s = window.__vdlSniff;
      if (!s) return '';
      if (kindOf(srcOf(video)) !== 'mse') return '';
      var b = s.best ? s.best('hls') : null;
      if (!b) b = s.best ? s.best('dash') : null;
      if (!b) b = s.best ? s.best('file') : null;
      if (b && b.url) return b.url;
      return s.getLatest ? (s.getLatest('hls') || s.getLatest('file')) : '';
    } catch (e) { return ''; }
  }

  function infoOf(video) {
    var src = srcOf(video);
    var kind = kindOf(src);
    var captured = '';
    // 用户手动选了线路（多条候选里挑一条）→ 以他选的为准
    var manual = video.__vdlLine || '';
    if (manual) {
      src = manual;
      kind = kindOf(manual);
      captured = 'manual';
    } else if (kind === 'mse') {
      captured = capturedFor(video);
      if (captured) { src = captured; kind = kindOf(captured); }
    } else if (kind === 'hls' || kind === 'dash') {
      // 元素直链一般是浏览器正在播的（原生 HLS），最可信；
      // 但若它在候选表里被判死、而另有明确可用的候选，则改用可用的那条
      if (stateOfUrl(src) === 'dead') {
        var b = bestOf(kind);
        if (b && b.url && b.state === 'ok') { src = b.url; kind = kindOf(b.url); }
      }
    }
    var t = (video.getAttribute && (video.getAttribute('title') || video.getAttribute('aria-label'))) || '';
    var lines = (kind === 'hls' || kind === 'dash' || kind === 'file') ? linesOf(kind) : [];
    return {
      url: src,
      kind: kind,
      res: resOf(video),
      dur: fmtDur(video.duration),
      title: String(t || pageTitle()).slice(0, 80),
      state: stateOfUrl(src),
      lines: lines
    };
  }

  function labelOf(info) {
    // ✓ = 已确认可用（2xx + 内容校验 或 正在播放）；? = 未验证；✗ = 已确认失效
    var mk = info.state === 'ok' ? ' ✓' : (info.state === 'dead' ? ' ✗' : ' ?');
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
    document.body.appendChild(b);
    return b;
  }

  // 已标记视频登记表。必需：video 从 DOM 移除后 querySelectorAll 就查不到它了，
  // 只遍历现存 <video> 会漏掉这类元素 —— 预览视频关掉后角标会永久留在页面上，
  // 而且再没有任何代码更新它的坐标（表现为「视频没了角标还在、位置卡死不动」）。
  var marked = [];

  function place(badge, video) {
    var r = video.getBoundingClientRect();
    // 尺寸为 0 / 移出视口 / 被祖先 display:none 藏起来 → 不显示角标
    if (
      r.width < 10 || r.height < 10 ||
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
  var cardDismissBound = false;

  // 点卡片外部 / 页面滚动 → 关闭操作卡（否则弹层只能靠再次点角标或选中某项关掉）
  function onDocClick(e) {
    if (!currentCard) return;
    var t = e.target;
    if (currentCard === t || currentCard.contains(t)) return;
    if (currentCardAnchor &&
        (currentCardAnchor === t || currentCardAnchor.contains(t))) return;
    closeCard();
  }

  function onScrollClose() {
    if (currentCard) closeCard();
  }

  function closeCard() {
    if (currentCard && currentCard.parentNode) {
      currentCard.parentNode.removeChild(currentCard);
    }
    currentCard = null;
    currentCardAnchor = null;
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
    } else {
      html += '<div class="vdl-card-u">' + esc(info.url) + '</div>';
    }
    html += '</div>';
    // 多候选（多线路）时列出全部，标明可用/失效，允许手动切换：
    // 这一栏就是为了解决「嗅探到的恰好是打不开的那条」
    if (info.lines && info.lines.length > 1) {
      html += '<div class="vdl-lines"><div class="vdl-lines-h">共 ' +
        info.lines.length + ' 条候选 · 点选切换</div>';
      for (var li = 0; li < info.lines.length; li++) {
        var it = info.lines[li];
        var mk = it.state === 'ok' ? '✓' : (it.state === 'dead' ? '✗' : '?');
        var cls = 'vdl-line' +
          (it.url === info.url ? ' on' : '') +
          (it.state === 'dead' ? ' dead' : '');
        html += '<button class="' + cls + '" data-line="' + esc(it.url) + '">' +
          '<span class="vdl-lm">' + mk + '</span>' +
          '<span class="vdl-lu">' + esc(shortUrl(it.url)) + '</span></button>';
      }
      html += '</div>';
    }
    if (info.kind === 'hls') {
      // HLS 四种产物，别混为一谈：
      //  bg      → 原生 background URLSession 下分片（锁屏/切 App 继续），回前台自动转 mp4
      //  package → 自己下 .ts 分片包存 Downloads，可离线、可随时「本地转 MP4」
      //  convert → 下分片后直接 ffmpeg 转封装成单个 mp4（中间分片用完即删）
      //  hls     → 系统 AVAssetDownloadTask 的 .movpkg，只能 AVFoundation 播，不能导出
      html += '<button class="vdl-btn hl" data-a="bg">后台下载并转 MP4（锁屏可继续）</button>';
      html += '<button class="vdl-btn" data-a="package">下载 m3u8 分片（可转 MP4）</button>';
      html += '<button class="vdl-btn hl" data-a="convert">直接转 MP4（单文件）</button>';
      html += '<button class="vdl-btn" data-a="hls">系统离线缓存（仅播放，不可导出）</button>';
    } else if (info.kind === 'dash') {
      html += '<div class="vdl-card-n" style="padding:10px 12px;">DASH 流（.mpd）暂不支持离线下载，可复制清单链接自行处理。</div>';
    } else if (info.kind === 'file') {
      // 直链：立即播放（边播边缓存）+ 下载
      html += '<button class="vdl-btn hl" data-a="play">立即播放（边播边缓存）</button>';
      html += '<button class="vdl-btn hl" data-a="mp4">下载视频</button>';
    }
    // MSE 且未兜底到直链：无可下载操作
    if (info.kind !== 'mse') {
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
      postAction({ action: a, url: info.url, title: info.title });
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
    document.body.appendChild(card);
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
    bindDismiss();
  }

  function update() {
    // 清理后（开关关闭）不再重建角标：click/play/观察器等残留监听可能仍会触发
    if (!window.__vdlMarkerInstalled) return;
    if (!document.body) return;
    // 先摘掉已从 DOM 移除的角标（它们不会出现在下面的 querySelectorAll 结果里）
    sweepDetached();
    var videos = document.querySelectorAll('video');
    for (var i = 0; i < videos.length; i++) {
      var v = videos[i];
      if (v.__vdlIgnored) continue;
      // 换集/换源：src 变了说明是新一条，之前手动选的线路作废
      var curSrc = srcOf(v);
      if (curSrc !== v.__vdlSeenSrc) {
        v.__vdlSeenSrc = curSrc;
        v.__vdlLine = '';
      }
      var badge = v.__vdlBadge;
      if (!badge) {
        var src = srcOf(v);
        if (!src) continue;
        if (kindOf(src) === 'other') continue;
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

  // <video>/<source> 的 src 属性变化（点击播放后赋值）→ 即时出角标
  var srcObserver = null;
  try {
    srcObserver = new MutationObserver(function () { update(); });
    srcObserver.observe(document.documentElement, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['src']
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
