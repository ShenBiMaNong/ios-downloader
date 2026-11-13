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
    '.vdl-btn.hl{color:#1d4ed8;font-weight:600;}';
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

  // blob:/MSE 无直链时，从嗅探器（sniffer.js 的 window.__vdlSniff）最近捕获的 URL 兜底
  function capturedFor(video) {
    try {
      var s = window.__vdlSniff;
      if (!s || !s.getLatest) return '';
      if (kindOf(srcOf(video)) !== 'mse') return '';
      var u = s.getLatest('hls');
      if (u) return u;
      u = s.getLatest('file');
      return u;
    } catch (e) { return ''; }
  }

  function infoOf(video) {
    var src = srcOf(video);
    var kind = kindOf(src);
    var captured = '';
    if (kind === 'mse') {
      captured = capturedFor(video);
      if (captured) { src = captured; kind = kindOf(captured); }
    }
    var t = (video.getAttribute && (video.getAttribute('title') || video.getAttribute('aria-label'))) || '';
    return {
      url: src,
      kind: kind,
      res: resOf(video),
      dur: fmtDur(video.duration),
      title: String(t || pageTitle()).slice(0, 80)
    };
  }

  function labelOf(info) {
    if (info.kind === 'hls') return info.dur ? 'HLS · ' + info.dur : 'HLS';
    if (info.kind === 'dash') return 'DASH';
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
      toggleCard(video, b);
    });
    document.body.appendChild(b);
    return b;
  }

  function place(badge, video) {
    var r = video.getBoundingClientRect();
    if (r.width < 10 || r.height < 10) { badge.style.display = 'none'; return; }
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
  function closeCard() {
    if (currentCard && currentCard.parentNode) {
      currentCard.parentNode.removeChild(currentCard);
    }
    currentCard = null;
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
    if (info.kind === 'hls') {
      // HLS：同时提供 m3u8 与 mp4 两种下载方式
      html += '<button class="vdl-btn hl" data-a="hls">缓存 m3u8（离线播放）</button>';
      html += '<button class="vdl-btn hl" data-a="convert">转 MP4</button>';
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
      while (t && t !== card && !(t.getAttribute && t.getAttribute('data-a'))) t = t.parentNode;
      var a = t && t.getAttribute ? t.getAttribute('data-a') : null;
      if (!a) return;
      e.preventDefault();
      e.stopPropagation();
      postAction({ action: a, url: info.url, title: info.title });
      closeCard();
      if (a === 'ignore') {
        if (video.__vdlBadge) {
          video.__vdlBadge.parentNode.removeChild(video.__vdlBadge);
          video.__vdlBadge = null;
        }
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
  }

  function update() {
    // 清理后（开关关闭）不再重建角标：click/play/观察器等残留监听可能仍会触发
    if (!window.__vdlMarkerInstalled) return;
    if (!document.body) return;
    var videos = document.querySelectorAll('video');
    for (var i = 0; i < videos.length; i++) {
      var v = videos[i];
      if (v.__vdlIgnored) continue;
      var badge = v.__vdlBadge;
      if (!badge) {
        var src = srcOf(v);
        if (!src) continue;
        if (kindOf(src) === 'other') continue;
        badge = makeBadge(v);
        v.__vdlBadge = badge;
        v.classList.add('vdl-video');
        (function (el, b) {
          el.addEventListener('loadedmetadata', function () { refreshBadge(b, el); });
          el.addEventListener('durationchange', function () { refreshBadge(b, el); });
          el.addEventListener('resize', function () { refreshBadge(b, el); });
        })(v, badge);
      }
      if (!v.isConnected) {
        if (badge.parentNode) badge.parentNode.removeChild(badge);
        v.__vdlBadge = null;
        continue;
      }
      refreshBadge(badge, v);
      place(badge, v);
    }
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
    if (srcObserver) { try { srcObserver.disconnect(); } catch (e) {} }
    var st = document.getElementById('vdl-style');
    if (st && st.parentNode) st.parentNode.removeChild(st);
    var el = document.querySelectorAll('.vdl-badge, .vdl-card');
    for (var i = 0; i < el.length; i++) if (el[i].parentNode) el[i].parentNode.removeChild(el[i]);
    var vs = document.querySelectorAll('video.vdl-video');
    for (var j = 0; j < vs.length; j++) vs[j].classList.remove('vdl-video');
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
