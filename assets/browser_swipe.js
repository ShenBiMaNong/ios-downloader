// 页面左右滑动手势导航（浏览器 WebView 区域内）：
//   右滑（dx>0）= 后退   左滑（dx<0）= 前进
// 与地址栏后退/前进按钮同语义，动作经 browserGesture 通道回传 Dart（goBack/goForward）。
//
// 为什么是 JS 注入而不是 Flutter GestureDetector：WebView 是原生平台视图
// （iOS WKWebView / Android WebView），触摸事件被原生视图消费，Flutter 手势
// 识别器大概率拿不到；页内 JS 监听反而可靠，且与其他脚本同走
// WKUserScript 全帧 atDocumentStart + onPageFinished 兜底的注入双路。
//
// 防误触规则（任一成立就不触发导航）：
//  a) 起点在输入框/文本域/下拉/contenteditable（那是调光标，不是翻页）
//  b) 页面有未折叠的文本选区（用户在选字）
//  c) 多点触控（捏合/旋转/双指手势）
//  d) 慢速拖拽（>800ms）—— 地图拖动、精确定位这类一慢一拖的动作
//  e) 纵向主导的滑动（页面纵向滚动让给页面）
//  f) 该方向上有「还能滚」的横向滚动容器（轮播/横滑列表未到边界时让给页面；
//     到边界后多滑一下才触发，与系统返回手势的边界语义一致）
//  g) 位移不足（<80px）或 touchcancel
//
// 触发后吞掉随后的合成 click（400ms 窗口），避免松手误触链接/按钮。
// 覆盖范围：iOS 注册为 WKUserScript（atDocumentStart + 全帧）；
// Android 走 onPageStarted/onPageFinished 注入，只覆盖主框架。
(function () {
  if (window.__vdlSwipeInstalled) return;
  window.__vdlSwipeInstalled = true;

  var CHANNEL = 'browserGesture';
  var MIN_DX = 80; // 触发导航的最小水平位移（px）
  var DOM_RATIO = 0.7; // 横向主导：|dy| ≤ |dx| × DOM_RATIO
  var LOCK_SLOP = 20; // 锁定为「横滑」的启动位移（锁定后吃掉 move 默认行为）
  var MAX_MS = 800; // 超过此时长视为慢速拖拽，不触发
  var EPS = 1; // 滚动边界容差（px）

  var tracking = null; // 当前手势 {x, y, t, target, locked, dead}
  var swallowClickUntil = 0;

  window.__vdlSwipeStats = { fired: 0 };

  function isEditable(t) {
    try {
      if (!t || t.nodeType !== 1) return false;
      if (t.closest) {
        var el = t.closest(
          'input,textarea,select,option,[contenteditable]:not([contenteditable="false"])'
        );
        if (el) return true;
      }
    } catch (e) {}
    return false;
  }

  function selectionActive() {
    try {
      var sel = window.getSelection && window.getSelection();
      if (sel && sel.rangeCount > 0 && !sel.isCollapsed) return true;
    } catch (e) {}
    return false;
  }

  // 触点祖先链上能水平滚动的容器（含页面自身）
  function hScrollers(target) {
    var out = [];
    try {
      var el = target && target.nodeType === 1 ? target : null;
      while (el && el.nodeType === 1) {
        if (el.scrollWidth > el.clientWidth + EPS) out.push(el);
        el = el.parentElement;
      }
      var se = document.scrollingElement || document.documentElement;
      if (se && out.indexOf(se) < 0 && se.scrollWidth > se.clientWidth + EPS) {
        out.push(se);
      }
    } catch (e) {}
    return out;
  }

  // 该方向的手势会不会被横向滚动容器吃掉：
  // 右滑(dx>0)内容右移（scrollLeft 变小）—— 只有 scrollLeft > 0 时才吃；
  // 左滑(dx<0)反之 —— 只有 scrollLeft < scrollWidth - clientWidth 时才吃。
  function consumedByScroll(target, dx) {
    var list = hScrollers(target);
    for (var i = 0; i < list.length; i++) {
      var el = list[i];
      try {
        var max = el.scrollWidth - el.clientWidth;
        if (dx > 0 ? el.scrollLeft > EPS : el.scrollLeft < max - EPS) return true;
      } catch (e) {}
    }
    return false;
  }

  // 纯判定：位移 / 主导方向 / 时长 / 输入态 / 选区 / 滚动边界全过才出方向。
  // 测试直接调这个（window.__vdlSwipeEval），事件路径也走同一份，避免两处判据跑偏。
  function evaluate(dx, dy, ms, target) {
    if (!(Math.abs(dx) >= MIN_DX)) return null;
    if (!(Math.abs(dy) <= Math.abs(dx) * DOM_RATIO)) return null;
    if (typeof ms === 'number' && ms > MAX_MS) return null;
    if (isEditable(target)) return null;
    if (selectionActive()) return null;
    if (consumedByScroll(target, dx)) return null;
    return dx > 0 ? 'back' : 'forward';
  }
  window.__vdlSwipeEval = evaluate;

  function post(dir) {
    try {
      var payload = JSON.stringify({
        action: 'swipe',
        direction: dir,
        url: String(location.href || ''),
      });
      var w = window.webkit;
      if (w && w.messageHandlers && w.messageHandlers[CHANNEL]) {
        w.messageHandlers[CHANNEL].postMessage(payload); // iOS WKWebView（含 iframe）
      } else if (window[CHANNEL] && window[CHANNEL].postMessage) {
        window[CHANNEL].postMessage(payload); // Android / 调试页
      }
    } catch (e) {}
  }

  function fire(dir) {
    window.__vdlSwipeStats.fired++;
    post(dir);
    // 松手后浏览器会补一个合成 click（落在松手点），刚翻完页很容易误触链接 → 吞掉
    swallowClickUntil = Date.now() + 400;
  }

  // 捕获阶段吞 click：只在手势刚触发后的窗口内生效，不影响正常点击
  try {
    document.addEventListener(
      'click',
      function (e) {
        if (Date.now() < swallowClickUntil) {
          try {
            e.preventDefault();
            e.stopPropagation();
          } catch (err) {}
        }
      },
      true
    );
  } catch (e) {}

  function point(e, which) {
    var list = which === 'end' ? e.changedTouches : e.touches;
    return list && list.length ? list[0] : null;
  }

  function onStart(e) {
    try {
      if (e.touches && e.touches.length > 1) {
        tracking = null; // 多点触控（捏合/双指）不参与
        return;
      }
      var p = point(e, 'start');
      if (!p) return;
      if (isEditable(e.target)) return;
      tracking = {
        x: p.clientX,
        y: p.clientY,
        t: Date.now(),
        target: e.target,
        locked: false,
        dead: false,
      };
    } catch (err) {}
  }

  function onMove(e) {
    if (!tracking || tracking.dead) return;
    try {
      var p = point(e, 'move');
      if (!p) return;
      var dx = p.clientX - tracking.x;
      var dy = p.clientY - tracking.y;
      if (!tracking.locked) {
        if (Math.abs(dx) > LOCK_SLOP && Math.abs(dx) > Math.abs(dy)) {
          tracking.locked = true;
        } else if (Math.abs(dy) > LOCK_SLOP) {
          tracking.dead = true; // 纵向滚动意图，让给页面
          return;
        }
      }
      if (tracking.locked) {
        try {
          e.preventDefault(); // 已认定横滑：吃掉默认滚动，避免页面跟着晃
        } catch (err) {}
      }
    } catch (err) {}
  }

  function onEnd(e) {
    if (!tracking) return;
    var tk = tracking;
    tracking = null;
    if (tk.dead) return;
    try {
      if (e.touches && e.touches.length > 0) return; // 还有手指没抬起，取消
      var p = point(e, 'end');
      if (!p) return;
      var dx = p.clientX - tk.x;
      var dy = p.clientY - tk.y;
      var ms = Date.now() - tk.t;
      var dir = evaluate(dx, dy, ms, tk.target);
      if (dir) fire(dir);
    } catch (err) {}
  }

  try {
    document.addEventListener('touchstart', onStart, true);
    document.addEventListener('touchmove', onMove, { capture: true, passive: false });
    document.addEventListener('touchend', onEnd, true);
    document.addEventListener(
      'touchcancel',
      function () {
        tracking = null;
      },
      true
    );
  } catch (e) {}
})();
