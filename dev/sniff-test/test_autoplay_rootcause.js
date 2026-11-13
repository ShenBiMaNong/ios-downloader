// 「禁止自动播放」开关为什么「得重新开关一下才生效」——根因取证
// T1/T2：sessionStorage 只记「关」不记「开」→ 关过一次之后，每个新文档在
//        atDocumentStart 阶段都按「关」执行，直到 Dart 在 onPageFinished 补注入
// T3：跨域 iframe 拿不到 Dart 的 runJavaScript，只能吃 sessionStorage → 关闭开关对 iframe 无效
// T4：注入无串行化，旧值晚到会覆盖新值 → UI 与页面状态相反
const fs = require('fs');
const { JSDOM } = require('jsdom');

process.on('unhandledRejection', () => {});

const SCRIPT = fs.readFileSync(__dirname + '/../../assets/no_autoplay.js', 'utf8');
const PAGE = `<!doctype html><html><head><title>t</title></head>
<body><video id="v" src="https://cdn.example.com/v/1.mp4" autoplay></video></body></html>`;

function newDoc({ storage = null } = {}) {
  const dom = new JSDOM(PAGE, {
    url: 'https://site.example.com/play/1.html',
    runScripts: 'outside-only',
    pretendToBeVisual: true,
  });
  const w = dom.window;
  w.__origPlay = 0;
  w.HTMLMediaElement.prototype.play = function () {
    w.__origPlay++;
    return Promise.resolve();
  };
  if (storage !== null) w.sessionStorage.setItem('__vdlNoAutoplay', storage);
  // 模拟 iOS WKUserScript atDocumentStart：此时 Dart 还没注入过任何值
  w.eval(SCRIPT);
  return dom;
}

// 精确复刻 BrowserPage._injectNoAutoplay()
async function dartApply(w, on, hijack, delayMs = 0) {
  if (delayMs) await new Promise((r) => setTimeout(r, delayMs));
  if (on || hijack) {
    w.eval(`window.__vdlNoAutoplayEnabled=${on};`); // ← 关键：绕过 setter，不写 sessionStorage
    w.eval(SCRIPT);
  } else {
    w.eval('if (window.__vdlNoAutoplaySetEnabled) window.__vdlNoAutoplaySetEnabled(false);');
  }
  w.eval(
    `window.__vdlHijackEnabled=${hijack};if (window.__vdlNoAutoplaySetHijack) window.__vdlNoAutoplaySetHijack(${hijack});`
  );
}

async function tryPlay(w) {
  const v = w.document.getElementById('v');
  Object.defineProperty(v, 'paused', { value: true, writable: true, configurable: true });
  const before = w.__origPlay;
  let rejected = false;
  try {
    await v.play();
  } catch (e) {
    rejected = true;
  }
  return { blocked: rejected && w.__origPlay === before };
}

(async () => {
  // ── T1：关一次再开，sessionStorage 里留下什么 ──────────────────────
  console.log('【T1】关掉开关 → 再打开 → 看会话里记的是什么');
  {
    const dom = newDoc();
    const w = dom.window;
    await dartApply(w, true, false);
    w.eval('window.__vdlNoAutoplaySetEnabled(false)'); // 菜单关
    console.log('  关之后 __vdlNoAutoplay =', JSON.stringify(w.sessionStorage.getItem('__vdlNoAutoplay')));
    await dartApply(w, true, false); // 菜单再开
    const stored = w.sessionStorage.getItem('__vdlNoAutoplay');
    console.log('  再开之后 __vdlNoAutoplay =', JSON.stringify(stored));
    console.log(
      `  ${stored === '1' ? '✅' : '❌'} 期望 "1"（开），实际 ${JSON.stringify(stored)} —— 开关状态没有落到会话里`
    );
    w.close();
  }

  // ── T2：新文档 atDocumentStart 的默认行为 ─────────────────────────
  console.log('\n【T2】关过一次后再打开开关，然后打开一个新页面（新文档，Dart 还没注入）');
  {
    const dom = newDoc({ storage: '0' }); // 上一步留下的 "0"
    const w = dom.window;
    let r = await tryPlay(w);
    console.log(`  ${r.blocked ? '✅ 拦住' : '❌ 没拦住'} —— 开关是「开」，但新文档起手按会话里的 "0" 跑了`);
    await dartApply(w, true, false); // onPageFinished 才补上
    r = await tryPlay(w);
    console.log(`  ${r.blocked ? '✅ 补注入后拦住' : '❌ 补注入后仍不拦'}（这之后才恢复正常）`);
    w.close();
  }

  // ── T3：跨域 iframe（独立会话，Dart 的 runJavaScript 到达不了）──────
  console.log('\n【T3】跨域 iframe 播放器 + 用户把开关关掉');
  {
    const dom = newDoc({ storage: '0' }); // 主框架：用户关过 → "0"
    const main = dom.window;
    await dartApply(main, false, false); // 主框架关闭
    // 跨域 iframe 有自己独立的 sessionStorage，从未被写过
    const frameDom = newDoc(); // storage=null → 默认「开」
    const fw = frameDom.window;
    const r = await tryPlay(fw);
    console.log(`  ${r.blocked ? '❌ iframe 仍被拦（开关已关，但 iframe 不知道）' : '✅ iframe 放行'}`);
    main.close();
    frameDom.window.close();
  }

  // ── T4：并发注入，旧值晚到 ────────────────────────────────────────
  console.log('\n【T4】页面加载注入（旧值=开）与菜单点击（新值=关）并发，旧值晚到');
  try {
    const dom = newDoc();
    const w = dom.window;
    await dartApply(w, true, false);
    // 模拟：onPageFinished 的注入被 await 拖慢，用户这期间点了「关」
    const slow = dartApply(w, true, false, 60); // 旧值 true，晚到
    const fast = dartApply(w, false, false, 0); // 新值 false，先到
    await Promise.all([slow, fast]);
    const r = await tryPlay(w);
    console.log(
      `  ${r.blocked ? '❌ 最终仍在拦（UI 显示关）' : '✅ 最终放行（UI 显示关）'} —— 晚到的旧值把新值覆盖了`
    );
    console.log('  调试: enabled=' + w.__vdlNoAutoplayEnabled + ' installed=' + w.__vdlNoAutoplayInstalled);
    w.close();
  } catch (e) {
    console.log('  T4 异常: ' + (e && e.message));
  }
})().catch((e) => console.log('FATAL: ' + (e && e.stack)));
