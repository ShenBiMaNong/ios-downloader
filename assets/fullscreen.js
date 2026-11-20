// 网页全屏兜底（iPhone / Android 的 WebView 都不支持 Fullscreen API）
//
// 现象：视频在网页里「原生播放」时，站点播放器自绘的全屏按钮点了没反应。
// 站点实现通常只有这么几种，iPhone 上全都会栽：
//   ① el.requestFullscreen()           ← iPhone WebKit 没有这个方法（或恒 reject）
//   ② el.webkitRequestFullscreen()     ← 同上；有的版本存在但直接失败
//   ③ video.webkitEnterFullscreen()    ← 存在，但视频未就绪 / 容器异常时静默无效
//
// 这里只在「原生 API 不可用」的环境接管（iPad / 桌面 WebKit 能用的不动）：
//   - 元素里能找到 <video> → 交给 iOS 原生播放器（真全屏、可横屏、系统控件）；
//   - 找不到（canvas / MSE 自绘）→ 退回 CSS 全屏（铺满 WebView，至少不是没反应）。
// 同时补齐 document.fullscreenElement / fullscreenEnabled 与 fullscreenchange 事件，
// 让页面的「进入/退出全屏」UI 状态能跟着走（页内角标也靠这个在原生全屏时隐藏）。
(function () {
  if (window.__vdlFullscreenInstalled) return;
  var EP = window.Element && window.Element.prototype;
  if (!EP) return;
  window.__vdlFullscreenInstalled = true;

  var DP = window.Document && window.Document.prototype;
  var VP = window.HTMLVideoElement && window.HTMLVideoElement.prototype;

  var stats = (window.__vdlFullscreenStats = {
    requests: 0,
    native: 0,
    css: 0,
    modified: false,
  });

  var nativeEnabled = false;
  try {
    nativeEnabled = !!(document.fullscreenEnabled || document.webkitFullscreenEnabled);
  } catch (e) {}
  var hasNativeApi =
    typeof EP.requestFullscreen === 'function' ||
    typeof EP.webkitRequestFullscreen === 'function';
  // 原生支持且启用：保持站点原有行为，一点都不碰
  if (nativeEnabled && hasNativeApi) return;
  stats.modified = true;

  var activeVideo = null; // 正在原生全屏播放的 video
  var cssEl = null; // CSS 全屏中的元素
  var cssSaved = null; // 元素原本的 style 属性（退出时原样还原）

  // 包装 webkitEnterFullscreen 之前先抓住原生实现：requestFullscreen 这条链
  // 直接调它，避免「本脚本的包装层」被调用两次（撞出两个 700ms 兜底定时器）
  var origWebkitEnter =
    VP && typeof VP.webkitEnterFullscreen === 'function'
      ? VP.webkitEnterFullscreen
      : null;

  function fire() {
    var names = ['fullscreenchange', 'webkitfullscreenchange'];
    for (var i = 0; i < names.length; i++) {
      try {
        var ev;
        try {
          ev = new Event(names[i], { bubbles: true });
        } catch (e2) {
          ev = document.createEvent('Event');
          ev.initEvent(names[i], true, false);
        }
        document.dispatchEvent(ev);
      } catch (e3) {}
    }
  }

  function findVideo(el) {
    try {
      if (!el) return null;
      if (el.tagName === 'VIDEO') return el;
      if (el.querySelector) return el.querySelector('video');
    } catch (e) {}
    return null;
  }

  // 全屏中的元素：原生视频全屏时把 video 报给页面，站点按钮据此切换成「退出全屏」
  function fsEl() {
    return activeVideo || cssEl || null;
  }

  function watch(v) {
    if (!v || v.__vdlFsWatched) return;
    try {
      v.__vdlFsWatched = true;
      v.addEventListener('webkitbeginfullscreen', function () {
        v.__vdlFsBeganAt = Date.now();
        activeVideo = v;
        fire();
      });
      v.addEventListener('webkitendfullscreen', function () {
        if (activeVideo === v) activeVideo = null;
        v.__vdlFsEndedAt = Date.now();
        fire();
      });
    } catch (e) {}
  }

  function cssRestore() {
    var el = cssEl;
    var saved = cssSaved;
    cssEl = null;
    cssSaved = null;
    if (!el) return false;
    try {
      if (saved === null) el.removeAttribute('style');
      else el.setAttribute('style', saved);
    } catch (e) {}
    return true;
  }

  function cssEnter(el) {
    if (!el || !el.style) return false;
    if (cssEl === el) {
      fire();
      return true;
    }
    cssRestore();
    try {
      cssSaved = el.getAttribute('style');
      cssEl = el;
      var s = el.style;
      var decl = {
        position: 'fixed',
        top: '0',
        left: '0',
        width: '100%',
        height: '100%',
        margin: '0',
        'z-index': '2147483647',
        background: '#000',
      };
      for (var k in decl) {
        if (decl.hasOwnProperty(k)) s.setProperty(k, decl[k], 'important');
      }
    } catch (e) {
      cssEl = null;
      cssSaved = null;
      return false;
    }
    stats.css++;
    fire();
    return true;
  }

  // 优先交给 iOS 原生播放器：真全屏（含状态栏/横屏），比 CSS 铺满更接近用户预期。
  // 失败的判据只有一个：700ms 后既没有 beginfullscreen、webkitDisplayingFullscreen 也还是 false。
  function nativeEnter(v, fallbackEl) {
    if (!v) return false;
    if (!origWebkitEnter && typeof v.webkitEnterFullscreen !== 'function') return false;
    watch(v);
    try {
      if (origWebkitEnter) origWebkitEnter.call(v);
      else v.webkitEnterFullscreen();
    } catch (e) {
      return false;
    }
    stats.native++;
    setTimeout(function () {
      var showing = false;
      try {
        showing = !!v.webkitDisplayingFullscreen;
      } catch (e) {}
      if (!showing && !v.__vdlFsBeganAt) cssEnter(fallbackEl || v);
    }, 700);
    return true;
  }

  function requestFs(el) {
    stats.requests++;
    var self = el || document.documentElement;
    var v = findVideo(self);
    if (v && nativeEnter(v, self)) return Promise.resolve();
    cssEnter(self);
    return Promise.resolve();
  }

  function exitFs() {
    if (activeVideo) {
      var v = activeVideo;
      activeVideo = null;
      v.__vdlFsEndedAt = 0;
      try {
        if (typeof v.webkitExitFullscreen === 'function') v.webkitExitFullscreen();
      } catch (e) {}
      // 退出事件一般由 webkitendfullscreen 带来（监听器里会 fire）；没等到就补一个，
      // 否则页面的「退出全屏」按钮会一直停在按下态
      setTimeout(function () {
        if (!v.__vdlFsEndedAt) fire();
      }, 300);
      return Promise.resolve();
    }
    if (cssRestore()) fire();
    return Promise.resolve();
  }

  function def(proto, name, value) {
    if (!proto) return false;
    try {
      Object.defineProperty(proto, name, {
        configurable: true,
        writable: true,
        value: value,
      });
      return true;
    } catch (e) {
      try {
        proto[name] = value;
        return true;
      } catch (e2) {
        return false;
      }
    }
  }

  function defGetter(proto, name, get) {
    if (!proto) return false;
    try {
      Object.defineProperty(proto, name, { configurable: true, get: get });
      return true;
    } catch (e) {
      return false;
    }
  }

  def(EP, 'requestFullscreen', function () {
    return requestFs(this);
  });
  def(EP, 'webkitRequestFullscreen', function () {
    return requestFs(this);
  });
  // 老前缀（大写 S）在部分站点/播放器里还在用
  def(EP, 'webkitRequestFullScreen', function () {
    return requestFs(this);
  });

  if (DP) {
    def(DP, 'exitFullscreen', function () {
      return exitFs();
    });
    def(DP, 'webkitExitFullscreen', function () {
      return exitFs();
    });
    def(DP, 'webkitCancelFullScreen', function () {
      return exitFs();
    });
    defGetter(DP, 'fullscreenElement', fsEl);
    defGetter(DP, 'webkitFullscreenElement', fsEl);
    defGetter(DP, 'webkitCurrentFullScreenElement', fsEl);
    defGetter(DP, 'fullscreenEnabled', function () {
      return true;
    });
    defGetter(DP, 'webkitFullscreenEnabled', function () {
      return true;
    });
  }

  // 直接调 webkitEnterFullscreen 的站点也兜一层：静默失败时退回 CSS 全屏，
  // 保证「点了全屏」至少有视觉反馈。
  if (origWebkitEnter) {
    def(VP, 'webkitEnterFullscreen', function () {
      var v = this;
      stats.requests++;
      watch(v);
      try {
        origWebkitEnter.call(v);
      } catch (e) {
        cssEnter(v);
        return;
      }
      setTimeout(function () {
        var showing = false;
        try {
          showing = !!v.webkitDisplayingFullscreen;
        } catch (e) {}
        if (!showing && !v.__vdlFsBeganAt) cssEnter(v);
      }, 700);
    });
  }
})();