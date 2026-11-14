// 左右滑动手势（browser_swipe.js）行为测试
// 语义：右滑=后退(back)、左滑=前进(forward)；
// 防误触：输入框 / 文本选区 / 多点触控 / 慢速拖拽 / 纵向主导 / 位移不足 /
//        横向滚动容器未到边界 —— 一律不触发；触发后合成 click 必须被吞掉。
const fs = require('fs');
const { JSDOM } = require('jsdom');

process.on('unhandledRejection', () => {});

const SRC = fs.readFileSync(__dirname + '/../../assets/browser_swipe.js', 'utf8');

const PAGE = `<!doctype html><html><head><title>手势测试页</title></head>
<body><div id="t">内容</div></body></html>`;

function makeDom(html) {
  const dom = new JSDOM(html || PAGE, {
    url: 'https://www.example.com/page/1',
    runScripts: 'outside-only',
    pretendToBeVisual: true,
  });
  const w = dom.window;
  w.__msgs = [];
  w.browserGesture = { postMessage: (s) => w.__msgs.push(JSON.parse(s)) };
  return dom;
}

// 手势全程用假时钟推进，慢速拖拽场景把每步间隔拉大即可
function clock(w) {
  let now = 10000;
  w.Date.now = () => now;
  return {
    tick(ms) {
      now += ms;
    },
  };
}

function fireTouch(w, el, type, x, y, opts) {
  opts = opts || {};
  const p = { clientX: x, clientY: y };
  const ev = new w.Event(type, { bubbles: true, cancelable: true });
  const touches = opts.touches || (type === 'touchend' ? [] : [p]);
  Object.defineProperty(ev, 'touches', { value: touches });
  Object.defineProperty(ev, 'changedTouches', { value: opts.changed || [p] });
  el.dispatchEvent(ev);
  return ev;
}

// 一次完整滑动：start → 若干 move → end。返回松手后触发的方向（无则 null）
function swipe(w, el, x0, y0, x1, y1, opts) {
  opts = opts || {};
  const ck = clock(w);
  const steps = opts.steps || 3;
  fireTouch(w, el, 'touchstart', x0, y0, opts.startOpts);
  for (let i = 1; i <= steps; i++) {
    ck.tick(opts.stepMs || 10);
    const x = x0 + ((x1 - x0) * i) / steps;
    const y = y0 + ((y1 - y0) * i) / steps;
    fireTouch(w, el, 'touchmove', x, y);
  }
  ck.tick(opts.stepMs || 10);
  fireTouch(w, el, 'touchend', x1, y1, opts.endOpts);
  const dirs = w.__msgs.map((m) => m.direction);
  return dirs.length ? dirs[dirs.length - 1] : null;
}

function stubHScroll(el, scrollLeft, scrollWidth, clientWidth) {
  Object.defineProperty(el, 'scrollLeft', { value: scrollLeft, configurable: true });
  Object.defineProperty(el, 'scrollWidth', { value: scrollWidth, configurable: true });
  Object.defineProperty(el, 'clientWidth', { value: clientWidth, configurable: true });
}

function countOf(w) {
  return w.__msgs.length;
}

async function scenario(name, fn, want) {
  const dom = makeDom();
  const w = dom.window;
  w.eval(SRC);
  let got;
  try {
    got = await fn(w);
  } catch (e) {
    got = 'ERR:' + (e && e.message);
  }
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? '✅' : '❌') + ' ' + name, '| 结果=' + JSON.stringify(got),
    ok ? '' : '| 期望=' + JSON.stringify(want));
  w.close();
  return ok ? 0 : 1;
}

(async () => {
  let fail = 0;

  fail += await scenario(
    '① 右滑达标 → back（仅 1 条消息，双装脚本不重复触发）',
    (w) => {
      w.eval(SRC); // 幂等：再装一次不能双发
      swipe(w, w.document.getElementById('t'), 100, 300, 280, 312);
      return { dir: w.__msgs.map((m) => m.direction), n: countOf(w) };
    },
    { dir: ['back'], n: 1 }
  );

  fail += await scenario(
    '② 左滑达标 → forward',
    (w) => {
      swipe(w, w.document.getElementById('t'), 280, 300, 100, 312);
      return { dir: w.__msgs.map((m) => m.direction), n: countOf(w) };
    },
    { dir: ['forward'], n: 1 }
  );

  fail += await scenario(
    '③ 纵向滚动（dy 主导）→ 不触发',
    (w) => {
      swipe(w, w.document.getElementById('t'), 300, 100, 312, 320);
      return countOf(w);
    },
    0
  );

  fail += await scenario(
    '④ 位移不足（dx=40）→ 不触发',
    (w) => {
      swipe(w, w.document.getElementById('t'), 100, 300, 140, 305);
      return countOf(w);
    },
    0
  );

  fail += await scenario(
    '⑤ 起点在输入框 → 不触发',
    (w) => {
      const inp = w.document.createElement('input');
      w.document.body.appendChild(inp);
      swipe(w, inp, 100, 300, 280, 305);
      return countOf(w);
    },
    0
  );

  fail += await scenario(
    '⑤b 起点在 contenteditable → 不触发',
    (w) => {
      const div = w.document.createElement('div');
      div.setAttribute('contenteditable', 'true');
      w.document.body.appendChild(div);
      swipe(w, div, 100, 300, 280, 305);
      return countOf(w);
    },
    0
  );

  fail += await scenario(
    '⑥ 横向容器未到左边界（scrollLeft=100）右滑 → 让给页面，不触发',
    (w) => {
      const sc = w.document.createElement('div');
      const inner = w.document.createElement('div');
      sc.appendChild(inner);
      w.document.body.appendChild(sc);
      stubHScroll(sc, 100, 2000, 500);
      swipe(w, inner, 100, 300, 280, 305);
      return countOf(w);
    },
    0
  );

  fail += await scenario(
    '⑦ 横向容器到左边界（scrollLeft=0）右滑 → back；未到右边界左滑 → 不触发',
    (w) => {
      const sc = w.document.createElement('div');
      const inner = w.document.createElement('div');
      sc.appendChild(inner);
      w.document.body.appendChild(sc);
      stubHScroll(sc, 0, 2000, 500);
      swipe(w, inner, 100, 300, 280, 305); // 右滑 → back
      const n1 = countOf(w);
      swipe(w, inner, 280, 300, 100, 305); // 左滑：右边还有 1500 可滚 → 不触发
      return { first: w.__msgs.map((m) => m.direction), n1, n2: countOf(w) };
    },
    { first: ['back'], n1: 1, n2: 1 }
  );

  fail += await scenario(
    '⑦b 横向容器到右边界（scrollLeft=1500）左滑 → forward',
    (w) => {
      const sc = w.document.createElement('div');
      const inner = w.document.createElement('div');
      sc.appendChild(inner);
      w.document.body.appendChild(sc);
      stubHScroll(sc, 1500, 2000, 500);
      swipe(w, inner, 280, 300, 100, 305);
      return w.__msgs.map((m) => m.direction);
    },
    ['forward']
  );

  fail += await scenario(
    '⑧ 双指触控 → 不触发',
    (w) => {
      const p1 = { clientX: 100, clientY: 300 };
      const p2 = { clientX: 400, clientY: 300 };
      const ev = new w.Event('touchstart', { bubbles: true, cancelable: true });
      Object.defineProperty(ev, 'touches', { value: [p1, p2] });
      Object.defineProperty(ev, 'changedTouches', { value: [p1] });
      w.document.getElementById('t').dispatchEvent(ev);
      fireTouch(w, w.document.getElementById('t'), 'touchmove', 300, 305);
      fireTouch(w, w.document.getElementById('t'), 'touchend', 300, 305);
      return countOf(w);
    },
    0
  );

  fail += await scenario(
    '⑨ 慢速拖拽（每步 300ms，全程 >800ms）→ 不触发',
    (w) => {
      swipe(w, w.document.getElementById('t'), 100, 300, 280, 305, { stepMs: 300 });
      return countOf(w);
    },
    0
  );

  fail += await scenario(
    '⑩ 触发后合成 click 被吞掉；正常点击不受影响',
    (w) => {
      const el = w.document.getElementById('t');
      swipe(w, el, 100, 300, 280, 305); // back
      const c1 = new w.MouseEvent('click', { bubbles: true, cancelable: true });
      el.dispatchEvent(c1);
      // 推过 400ms 窗口后，click 恢复正常
      w.Date.now = () => 99999999;
      const c2 = new w.MouseEvent('click', { bubbles: true, cancelable: true });
      el.dispatchEvent(c2);
      return { swallowed: c1.defaultPrevented, normal: c2.defaultPrevented };
    },
    { swallowed: true, normal: false }
  );

  fail += await scenario(
    '⑪ 文本选区未折叠 → 不触发',
    (w) => {
      w.getSelection = () => ({ rangeCount: 1, isCollapsed: false });
      swipe(w, w.document.getElementById('t'), 100, 300, 280, 305);
      return countOf(w);
    },
    0
  );

  fail += await scenario(
    '⑫ __vdlSwipeEval 纯判定（测试钩子与事件路径同源）',
    (w) => {
      const el = w.document.getElementById('t');
      return {
        back: w.__vdlSwipeEval(160, 10, 30, el),
        forward: w.__vdlSwipeEval(-160, 10, 30, el),
        tooShort: w.__vdlSwipeEval(40, 0, 30, el),
        vertical: w.__vdlSwipeEval(10, 160, 30, el),
        slow: w.__vdlSwipeEval(160, 10, 900, el),
      };
    },
    { back: 'back', forward: 'forward', tooShort: null, vertical: null, slow: null }
  );

  fail += await scenario(
    '⑬ 消息体含 action=swipe 与 url',
    (w) => {
      swipe(w, w.document.getElementById('t'), 100, 300, 280, 305);
      return w.__msgs[0];
    },
    { action: 'swipe', direction: 'back', url: 'https://www.example.com/page/1' }
  );

  console.log('\n结论：' + (fail === 0 ? '全部通过（13/13）' : fail + ' 项未通过'));
  process.exit(fail === 0 ? 0 : 1);
})();
