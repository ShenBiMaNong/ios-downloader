// 视频自动播放拦截（默认为开，可在浏览器菜单 / 设置页关闭）
// 目标：页面自己开始的播放一律拦下 —— 打开网页不再自动出声、不再白跑流量；
//       用户真正点播放器（点播放按钮 / 点视频本身）时照常播放。
//
// 三层拦截，缺一层都会漏：
//  ① 覆盖 HTMLMediaElement.prototype.play —— 站点 JS 主动 play()（含 setTimeout 延迟调用）
//  ② 覆盖 autoplay 属性 setter —— 站点 new Video() 后设 autoplay = true
//  ③ MutationObserver + DOMContentLoaded 扫描 —— HTML 里直接写 <video autoplay>（属性在解析时生效，
//     不经过 ①②，只能等元素插入 DOM 时立刻摘掉 autoplay 并 pause；此时还没到 canplay，不会真的播出去）
//
// 放行判据（任一成立即视为「用户想看」）：
//  a) 开关关闭            window.__vdlNoAutoplayEnabled === false
//  b) 浏览器 transient activation   navigator.userActivation.isActive（Safari 15.4+）
//  c) 4 秒内刚点过这个播放器（点播放按钮时坐标通常落在 video 矩形/其覆盖控件上）
//  d) 800 毫秒内有过任意手势 —— 覆盖 a 判据缺失（旧 WebKit）时点击播放按钮的同步 play()
//
// 覆盖范围：iOS 上脚本注册为 WKUserScript（atDocumentStart + 全帧），含跨域 iframe 播放器；
// Android 走 onPageStarted 注入，只覆盖主框架（同源 iframe 内的播放器需另做扩散）。
(function () {
  if (window.__vdlNoAutoplayInstalled) return;
  var proto = window.HTMLMediaElement && window.HTMLMediaElement.prototype;
  if (!proto || typeof proto.play !== 'function') return;
  window.__vdlNoAutoplayInstalled = true;

  var origPlay = proto.play;
  var autoplayDesc = null;
  try {
    autoplayDesc = Object.getOwnPropertyDescriptor(proto, 'autoplay');
  } catch (e) {}

  var TAP_ALLOW_MS = 4000; // 点过播放器之后多长时间的 play 请求算用户意图
  var GESTURE_ALLOW_MS = 800; // 任意手势后极短时间内同步触发的 play 也算用户操作
  var TAP_SLOP = 60; // 播放按钮/控制条常压在 video 边缘之外，坐标判定外扩像素

  var CHANNEL = 'videoAction';
  var lastTapTs = 0;
  var lastTapEls = [];
  var lastGestureTs = 0;
  var blockedCount = 0;
  var reported = false;

  // sessionStorage 记住本会话的开关状态（per-origin）：atDocumentStart 阶段 Dart 还没机会注入
  // 开关值时，靠它避免「关掉开关后新开的页面又被拦一次」
  var defaultOn = true;
  try {
    if (window.sessionStorage && window.sessionStorage.getItem('__vdlNoAutoplay') === '0') {
      defaultOn = false;
    }
  } catch (e) {}
  if (typeof window.__vdlNoAutoplayEnabled !== 'boolean') {
    window.__vdlNoAutoplayEnabled = defaultOn;
  }

  function enabled() {
    return window.__vdlNoAutoplayEnabled !== false;
  }

  function activationActive() {
    try {
      var ua = navigator.userActivation;
      return !!(ua && ua.isActive);
    } catch (e) {
      return false;
    }
  }

  function isMedia(el) {
    return !!el && (el.tagName === 'VIDEO' || el.tagName === 'AUDIO');
  }

  function recentlyTapped(el) {
    if (!lastTapTs || Date.now() - lastTapTs > TAP_ALLOW_MS) return false;
    for (var i = 0; i < lastTapEls.length; i++) {
      if (lastTapEls[i] === el) return true;
    }
    return false;
  }

  function allowed(el) {
    if (!enabled()) return true;
    if (activationActive()) return true;
    if (recentlyTapped(el)) return true;
    if (lastGestureTs && Date.now() - lastGestureTs <= GESTURE_ALLOW_MS) return true;
    return false;
  }

  // 坐标命中：点击落在哪个 video/audio 上（含压在 video 上的控件层与外扩区域）
  function hitMediaAt(x, y) {
    var list;
    try {
      list = document.querySelectorAll('video,audio');
    } catch (e) {
      return null;
    }
    var n = Math.min(list.length, 24);
    for (var i = 0; i < n; i++) {
      var el = list[i];
      var r;
      try {
        r = el.getBoundingClientRect();
      } catch (e) {
        continue;
      }
      if (!r || r.width < 8 || r.height < 8) continue;
      if (
        x >= r.left - TAP_SLOP &&
        x <= r.right + TAP_SLOP &&
        y >= r.top - TAP_SLOP &&
        y <= r.bottom + TAP_SLOP
      ) {
        return el;
      }
    }
    return null;
  }

  function noteGesture(x, y, target) {
    lastGestureTs = Date.now();
    var el = null;
    var t = target;
    while (t && t !== document) {
      if (isMedia(t)) {
        el = t;
        break;
      }
      t = t.parentNode;
    }
    if (!el && typeof x === 'number' && typeof y === 'number') {
      el = hitMediaAt(x, y);
    }
    if (!el) return;
    lastTapTs = lastGestureTs;
    lastTapEls = [el].concat(lastTapEls).slice(0, 4);
  }

  function notifyOnce() {
    if (reported) return;
    reported = true;
    try {
      var payload = JSON.stringify({
        action: 'autoplayBlocked',
        url: String(location.href || ''),
        count: blockedCount,
      });
      var w = window.webkit;
      if (w && w.messageHandlers && w.messageHandlers[CHANNEL]) {
        w.messageHandlers[CHANNEL].postMessage(payload); // iOS WKWebView（含 iframe）
      } else if (window[CHANNEL] && window[CHANNEL].postMessage) {
        window[CHANNEL].postMessage(payload); // Android / 调试页
      }
    } catch (e) {}
  }

  function notAllowedError() {
    var msg = '播放被「禁止视频自动播放」拦截（可在浏览器菜单关闭）';
    try {
      return new DOMException(msg, 'NotAllowedError');
    } catch (e) {
      var err = new Error(msg);
      err.name = 'NotAllowedError';
      return err;
    }
  }

  function block(el) {
    blockedCount++;
    try {
      if (el && typeof el.pause === 'function' && !el.paused) el.pause();
    } catch (e) {}
    notifyOnce();
    try {
      var s = window.__vdlNoAutoplayStats || (window.__vdlNoAutoplayStats = { blocked: 0 });
      s.blocked = blockedCount;
    } catch (e) {}
  }

  // ① 站点 JS 调用 play()
  proto.play = function () {
    if (allowed(this)) return origPlay.apply(this, arguments);
    block(this);
    if (typeof Promise === 'undefined') return undefined;
    return Promise.reject(notAllowedError());
  };

  // ② 站点设置 autoplay 属性（无手势时吞掉，同时记住站点意图，避免再被 fixMedia 放回来）
  if (autoplayDesc && autoplayDesc.set) {
    try {
      Object.defineProperty(proto, 'autoplay', {
        configurable: true,
        enumerable: !!autoplayDesc.enumerable,
        get: function () {
          try {
            return autoplayDesc.get ? autoplayDesc.get.call(this) : false;
          } catch (e) {
            return false;
          }
        },
        set: function (v) {
          if (v && !allowed(this)) {
            try {
              this.__vdlAutoplayWanted = true;
            } catch (e) {}
            return;
          }
          autoplayDesc.set.call(this, v);
        },
      });
    } catch (e) {}
  }

  // ③ HTML 里写死的 autoplay：元素插入 DOM 时摘掉，必要时 pause
  function fixMedia(el) {
    if (!isMedia(el)) return;
    if (allowed(el)) return;
    var wants = false;
    try {
      wants = el.hasAttribute('autoplay') || el.autoplay === true || el.__vdlAutoplayWanted === true;
    } catch (e) {
      return;
    }
    if (!wants) return;
    try {
      el.removeAttribute('autoplay');
      el.autoplay = false;
      el.__vdlAutoplayWanted = false;
    } catch (e) {}
    try {
      if (!el.paused) block(el);
    } catch (e) {}
  }

  function scan(root) {
    try {
      var list = root.querySelectorAll ? root.querySelectorAll('video,audio') : [];
      var n = Math.min(list.length, 40);
      for (var i = 0; i < n; i++) fixMedia(list[i]);
    } catch (e) {}
  }

  function onMutations(muts) {
    for (var i = 0; i < muts.length; i++) {
      var m = muts[i];
      if (m.type === 'attributes') {
        fixMedia(m.target);
        continue;
      }
      var nodes = m.addedNodes;
      for (var j = 0; j < nodes.length; j++) {
        var n = nodes[j];
        if (!n || n.nodeType !== 1) continue;
        fixMedia(n);
        scan(n);
      }
    }
  }

  var observer = null;

  function startObserve() {
    var root = document.documentElement;
    if (!root) {
      setTimeout(startObserve, 10);
      return;
    }
    try {
      observer = new MutationObserver(onMutations);
      observer.observe(root, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['autoplay'],
      });
    } catch (e) {}
    scan(root);
  }

  startObserve();
  try {
    document.addEventListener(
      'DOMContentLoaded',
      function () {
        scan(document);
      },
      true
    );
    window.addEventListener(
      'load',
      function () {
        scan(document);
      },
      true
    );
  } catch (e) {}

  // 手势记录（capture 阶段，先于站点自己的监听拿到）
  try {
    document.addEventListener(
      'pointerdown',
      function (e) {
        noteGesture(e.clientX, e.clientY, e.target);
      },
      true
    );
    document.addEventListener(
      'touchstart',
      function (e) {
        var t = e.touches && e.touches[0];
        noteGesture(t ? t.clientX : undefined, t ? t.clientY : undefined, e.target);
      },
      true
    );
    document.addEventListener(
      'keydown',
      function () {
        lastGestureTs = Date.now();
      },
      true
    );
  } catch (e) {}

  // Dart 侧关掉开关时不必重新导航即可恢复原生行为
  window.__vdlNoAutoplayRestore = function () {
    try {
      if (proto.play === origPlay) return;
      proto.play = origPlay;
      if (autoplayDesc) Object.defineProperty(proto, 'autoplay', autoplayDesc);
      if (observer) observer.disconnect();
      window.__vdlNoAutoplayInstalled = false;
    } catch (e) {}
  };

  window.__vdlNoAutoplayStats = { blocked: 0 };
  window.__vdlNoAutoplaySetEnabled = function (on) {
    window.__vdlNoAutoplayEnabled = !!on;
    try {
      if (window.sessionStorage) {
        window.sessionStorage.setItem('__vdlNoAutoplay', on ? '1' : '0');
      }
    } catch (e) {}
    if (on) {
      // 重新开启时需要把被还原的原型方法再装回去 → 最省事的做法是让 Dart 侧重新注入本脚本
      return;
    }
    window.__vdlNoAutoplayRestore();
  };
})();
