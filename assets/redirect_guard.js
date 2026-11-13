// 跳转拦截脚本：拦截「非用户点击」的自动跳转（location 赋值 / assign / replace /
// window.location 赋值 / meta refresh / window.open('_self')），通过 JS Channel
// 回传 Dart 弹窗询问；Dart 允许后由 loadRequest 重新发起，拒绝则保持原页面。
// 用户点击/触摸后的短窗口期（GESTURE_MS）内发生的跳转视为用户主动，直接放行。
// 总开关由 Dart 侧控制（window.__vdRedirectGuardEnabled）。
(function () {
  if (window.__vdRedirectGuardLoaded) {
    window.__vdRedirectGuardEnabled = true;
    return;
  }
  window.__vdRedirectGuardLoaded = true;
  window.__vdRedirectGuardEnabled = true;

  var CHANNEL = 'redirectAttempt';
  var GESTURE_MS = 2000;

  // 记录最近一次用户交互（点击 / 触摸 / 按键），用于区分「用户主动」与「程序自动」
  var lastGesture = 0;
  ['pointerdown', 'touchend', 'click', 'keydown'].forEach(function (t) {
    try {
      document.addEventListener(t, function () { lastGesture = Date.now(); }, true);
    } catch (e) {}
  });

  function hasGesture() {
    return Date.now() - lastGesture < GESTURE_MS;
  }

  function post(url, kind) {
    try {
      if (!url || !/^https?:/i.test(url)) return;
      var payload = JSON.stringify({ url: url, kind: kind || 'location', from: location.href });
      var w = window.webkit;
      if (w && w.messageHandlers && w.messageHandlers[CHANNEL]) {
        w.messageHandlers[CHANNEL].postMessage(payload); // iOS WKWebView
      } else if (window[CHANNEL] && window[CHANNEL].postMessage) {
        window[CHANNEL].postMessage(payload); // Android WebView 通道
      }
    } catch (e) {}
  }

  // 是否需要拦截：开关开、非用户手势、http(s)、且不是「仅 hash 变化 / 相同 URL」
  function shouldIntercept(target) {
    if (!window.__vdRedirectGuardEnabled) return false;
    if (hasGesture()) return false;
    try {
      if (!/^https?:/i.test(target)) return false;
      var a = new URL(target, location.href);
      var cur = new URL(location.href);
      if (a.origin + a.pathname + a.search === cur.origin + cur.pathname + cur.search) {
        return false; // 仅 hash 变化，页面不卸载，放行
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  // ① location.href = url（含 location.hash 之外的整页跳转）
  try {
    var hrefDesc = Object.getOwnPropertyDescriptor(Location.prototype, 'href');
    if (hrefDesc && hrefDesc.set) {
      Object.defineProperty(Location.prototype, 'href', {
        configurable: true,
        get: hrefDesc.get,
        set: function (v) {
          var u = String(v || '');
          if (shouldIntercept(u)) { post(u, 'href'); return; }
          return hrefDesc.set.call(this, u);
        }
      });
    }
  } catch (e) {}

  // ② location.assign / location.replace
  ['assign', 'replace'].forEach(function (m) {
    try {
      var orig = Location.prototype[m];
      Location.prototype[m] = function (u) {
        var s = String(u || '');
        if (shouldIntercept(s)) { post(s, m); return; }
        return orig.apply(this, arguments);
      };
    } catch (e) {}
  });

  // ③ window.location = url（部分引擎不允许覆写则跳过，仍有 ①② 兜底）
  try {
    var winLoc = Object.getOwnPropertyDescriptor(Window.prototype, 'location') ||
      Object.getOwnPropertyDescriptor(window, 'location');
    if (winLoc && winLoc.set) {
      Object.defineProperty(Window.prototype, 'location', {
        configurable: true,
        get: winLoc.get,
        set: function (v) {
          var u = String(v || '');
          if (shouldIntercept(u)) { post(u, 'window'); return; }
          return winLoc.set.call(this, u);
        }
      });
    }
  } catch (e) {}

  // ④ window.open(url, '_self') 相当于整页跳转；其他 target 不拦截（webview 内基本打不开新窗）
  try {
    var origOpen = window.open;
    window.open = function (url, name) {
      if (String(name || '') === '_self' && shouldIntercept(String(url || ''))) {
        post(String(url || ''), 'open');
        return null;
      }
      return origOpen.apply(this, arguments);
    };
  } catch (e) {}

  // ⑤ meta refresh（<meta http-equiv="refresh" content="N;url=...">）：移除 meta 并询问
  function scanMeta() {
    try {
      document.querySelectorAll('meta[http-equiv="refresh"]').forEach(function (m) {
        if (m.getAttribute('data-vd-guarded')) return;
        var c = (m.getAttribute('content') || '').toLowerCase();
        var i = c.indexOf('url=');
        if (i < 0) return;
        var u = c.slice(i + 4).trim();
        m.setAttribute('data-vd-guarded', '1');
        if (shouldIntercept(u)) {
          m.remove();
          post(u, 'meta');
        }
      });
    } catch (e) {}
  }
  scanMeta();
  try {
    var mo = new MutationObserver(scanMeta);
    mo.observe(document.documentElement, { childList: true, subtree: true });
  } catch (e) {}
  setInterval(scanMeta, 1000);
})();
