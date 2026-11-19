// 网页全屏兜底（fullscreen.js）行为测试
// 语义：iPhone/Android WebView 没有 Fullscreen API —— 站点播放器调 requestFullscreen
// 必须仍有结果：容器里有 <video> 优先走 iOS 原生全屏；没有就 CSS 铺满。
// 同时要补齐 document.fullscreenElement / fullscreenEnabled / fullscreenchange。
const fs = require('fs');
const { JSDOM } = require('jsdom');

process.on('unhandledRejection', () => {});

const SRC = fs.readFileSync(__dirname + '/../../assets/fullscreen.js', 'utf8');

const PAGE = `<!doctype html><html><head><title>全屏测试页</title></head>
<body><div id="player" style="color:red"><video id="v"></video></div>
<div id="plain" style="padding:1px">无视频容器</div></body></html>`;

function makeDom(opts) {
  const o = opts || {};
  const dom = new JSDOM(PAGE, {
    url: 'https://www.example.com/watch/1',
    runScripts: 'outside-only',
    pretendToBeVisual: true,
  });
  const w = dom.window;
  // jsdom 没有媒体全屏实现：按 iOS 的真实行为打桩（进入/退出各派一个事件）
  w.HTMLVideoElement.prototype.webkitEnterFullscreen = function () {
    if (o.silentEnter) return; // 真机上常见的「不抛错、也不进全屏」
    this.__entered = (this.__entered || 0) + 1;
    this.webkitDisplayingFullscreen = true;
    this.__vdlTestBegan = true;
    this.dispatchEvent(new w.Event('webkitbeginfullscreen'));
  };
  w.HTMLVideoElement.prototype.webkitExitFullscreen = function () {
    this.__exited = (this.__exited || 0) + 1;
    this.webkitDisplayingFullscreen = false;
    this.dispatchEvent(new w.Event('webkitendfullscreen'));
  };
  w.__fsEvents = 0;
  w.document.addEventListener('fullscreenchange', () => {
    w.__fsEvents++;
  });
  return dom;
}

async function scenario(name, fn, want, opts) {
  const dom = makeDom(opts);
  const w = dom.window;
  // 必须在 eval 之前装桩：脚本会抓住原生 webkitEnterFullscreen 再包一层，
  // eval 之后再改实例属性只会遮蔽包装层，测不到兜底逻辑
  w.eval(SRC);
  let got;
  try {
    got = await fn(w);
  } catch (e) {
    got = 'ERR:' + (e && e.message);
  }
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(
    (ok ? '✅' : '❌') + ' ' + name,
    '| 结果=' + JSON.stringify(got),
    ok ? '' : '| 期望=' + JSON.stringify(want)
  );
  w.close();
  return ok ? 0 : 1;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  let fail = 0;

  fail += await scenario(
    '① 补齐 API：requestFullscreen / exitFullscreen / fullscreenEnabled',
    (w) => ({
      req: typeof w.document.getElementById('player').requestFullscreen,
      webkitReq: typeof w.document.getElementById('player').webkitRequestFullscreen,
      exit: typeof w.document.exitFullscreen,
      enabled: w.document.fullscreenEnabled,
      element: w.document.fullscreenElement,
    }),
    {
      req: 'function',
      webkitReq: 'function',
      exit: 'function',
      enabled: true,
      element: null,
    }
  );

  fail += await scenario(
    '② 容器全屏：优先交给 video 原生全屏，fullscreenElement = video',
    async (w) => {
      const v = w.document.getElementById('v');
      const p = w.document.getElementById('player');
      await p.requestFullscreen();
      return {
        entered: v.__entered || 0,
        fsEl: w.document.fullscreenElement === v,
        webkitFsEl: w.document.webkitFullscreenElement === v,
        events: w.__fsEvents,
        // 走原生全屏时不能给容器套 CSS
        pos: p.style.position || '',
      };
    },
    { entered: 1, fsEl: true, webkitFsEl: true, events: 1, pos: '' }
  );

  fail += await scenario(
    '③ exitFullscreen：退出原生全屏，状态清空',
    async (w) => {
      const v = w.document.getElementById('v');
      const p = w.document.getElementById('player');
      await p.requestFullscreen();
      await w.document.exitFullscreen();
      return {
        exited: v.__exited || 0,
        fsEl: w.document.fullscreenElement,
        events: w.__fsEvents,
      };
    },
    { exited: 1, fsEl: null, events: 2 }
  );

  fail += await scenario(
    '④ 容器里没有 video：CSS 铺满，退出后原 style 还原',
    async (w) => {
      const d = w.document.getElementById('plain');
      await d.requestFullscreen();
      const entered = {
        pos: d.style.position,
        w: d.style.width,
        h: d.style.height,
        z: d.style.zIndex,
        fsEl: w.document.fullscreenElement === d,
        events: w.__fsEvents,
      };
      await w.document.exitFullscreen();
      return {
        entered,
        after: d.getAttribute('style'),
        fsEl: w.document.fullscreenElement,
        events: w.__fsEvents,
      };
    },
    {
      entered: {
        pos: 'fixed',
        w: '100%',
        h: '100%',
        z: '2147483647',
        fsEl: true,
        events: 1,
      },
      after: 'padding:1px',
      fsEl: null,
      events: 2,
    }
  );

  fail += await scenario(
    '⑤ 直接对 video 调 webkitRequestFullscreen 也走原生全屏',
    async (w) => {
      const v = w.document.getElementById('v');
      await v.webkitRequestFullscreen();
      return { entered: v.__entered || 0, fsEl: w.document.fullscreenElement === v };
    },
    { entered: 1, fsEl: true }
  );

  fail += await scenario(
    '⑥ webkitEnterFullscreen 静默失败 → 700ms 后 CSS 兜底，点全屏不白点',
    async (w) => {
      const v = w.document.getElementById('v');
      const p = w.document.getElementById('player');
      await p.requestFullscreen();
      await sleep(850);
      return {
        pos: p.style.position,
        fsEl: w.document.fullscreenElement === p,
        entered: v.__entered || 0,
      };
    },
    { pos: 'fixed', fsEl: true, entered: 0 },
    { silentEnter: true }
  );

  fail += await scenario(
    '⑦ 脚本幂等：重复注入不会把 requestFullscreen 再包一层',
    async (w) => {
      const before = w.Element.prototype.requestFullscreen;
      w.eval(SRC);
      const v = w.document.getElementById('v');
      await w.document.getElementById('player').requestFullscreen();
      return {
        same: w.Element.prototype.requestFullscreen === before,
        entered: v.__entered || 0,
      };
    },
    { same: true, entered: 1 }
  );

  if (fail) {
    console.log(`\n${fail} 个场景失败`);
    process.exit(1);
  }
  console.log('\n全部通过');
})();