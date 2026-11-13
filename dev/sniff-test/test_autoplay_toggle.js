// 「禁止自动播放 / 点播放即接管」开关热切换测试
// 目标：复现「浏览器菜单里关掉/打开开关，需要再点一次才生效」的问题
// 做法：用 jsdom 精确复刻 Dart 侧 _injectNoAutoplay() 的调用序列
const fs = require('fs');
const { JSDOM } = require('jsdom');

process.on('unhandledRejection', () => {});

const SCRIPT = fs.readFileSync(__dirname + '/../../assets/no_autoplay.js', 'utf8');
const PAGE = `<!doctype html><html><head><title>t</title></head>
<body><video id="v" src="https://cdn.example.com/v/1.mp4" autoplay></video></body></html>`;

function makeDom({ storedNoAutoplay = null, injectAtStart = true } = {}) {
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
  if (storedNoAutoplay !== null) {
    w.sessionStorage.setItem('__vdlNoAutoplay', storedNoAutoplay ? '1' : '0');
  }
  // 模拟 iOS WKUserScript atDocumentStart：此时 Dart 还没注入开关值
  if (injectAtStart) w.eval(SCRIPT);
  return dom;
}

// 精确复刻 BrowserPage._injectNoAutoplay()
function dartApply(w, on, hijack) {
  if (on || hijack) {
    w.eval(`window.__vdlNoAutoplayEnabled=${on};`);
    w.eval(SCRIPT);
  } else {
    w.eval(
      'if (window.__vdlNoAutoplaySetEnabled) window.__vdlNoAutoplaySetEnabled(false);'
    );
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
  return { played: w.__origPlay > before, rejected };
}

let fail = 0;
function check(label, got, want) {
  const ok = got === want;
  if (!ok) fail++;
  console.log(`  ${ok ? '✅' : '❌'} ${label}: 实际=${got} 期望=${want}`);
  return ok;
}

(async () => {
  console.log('\n【场景 1】页面加载时开关=开（iOS atDocumentStart 已装脚本）');
  {
    const dom = makeDom({ injectAtStart: true });
    const w = dom.window;
    dartApply(w, true, false);
    let r = await tryPlay(w);
    check('初始开着 → 自动播被拦', r.rejected && !r.played, true);

    console.log(' -- 菜单关掉开关（on=false）--');
    dartApply(w, false, false);
    r = await tryPlay(w);
    check('关掉后立刻放行', r.played, true);

    console.log(' -- 再打开（on=true）--');
    dartApply(w, true, false);
    r = await tryPlay(w);
    check('打开后立刻拦截', r.rejected && !r.played, true);
    console.log('  调试: installed=' + w.__vdlNoAutoplayInstalled + ' enabled=' + w.__vdlNoAutoplayEnabled);
    w.close();
  }

  console.log('\n【场景 2】页面加载时开关=关（脚本未注入，Android / 老页面）');
  {
    const dom = makeDom({ injectAtStart: false });
    const w = dom.window;
    let r = await tryPlay(w);
    check('未注入 → 放行', r.played, true);
    dartApply(w, true, false);
    r = await tryPlay(w);
    check('打开后立刻拦截', r.rejected && !r.played, true);
    w.close();
  }

  console.log('\n【场景 3】iOS atDocumentStart + sessionStorage 记住「关」，页面加载后 Dart 注入 开');
  {
    const dom = makeDom({ injectAtStart: true, storedNoAutoplay: false });
    const w = dom.window;
    let r = await tryPlay(w);
    check('document start 阶段按 sessionStorage 放行', r.played, true);
    dartApply(w, true, false);
    r = await tryPlay(w);
    check('Dart 注入后立刻拦截', r.rejected && !r.played, true);
    w.close();
  }

  console.log('\n【场景 4】反复开关 4 次（开→关→开→关）');
  {
    const dom = makeDom({ injectAtStart: true });
    const w = dom.window;
    const seq = [true, false, true, false];
    for (const on of seq) {
      dartApply(w, on, false);
      const r = await tryPlay(w);
      check(`on=${on} → ${on ? '拦截' : '放行'}`, on ? r.rejected && !r.played : r.played, true);
    }
    w.close();
  }

  console.log('\n【场景 5】「点播放即接管」开着时关掉「禁止自动播放」');
  {
    const dom = makeDom({ injectAtStart: true });
    const w = dom.window;
    dartApply(w, true, true);
    let r = await tryPlay(w);
    check('两开关都开 → 拦截', r.rejected && !r.played, true);
    dartApply(w, false, true); // 只关自动播放拦截
    r = await tryPlay(w);
    check('关掉拦截后放行', r.played, true);
    dartApply(w, true, true);
    r = await tryPlay(w);
    check('再打开 → 拦截', r.rejected && !r.played, true);
    console.log('  调试: installed=' + w.__vdlNoAutoplayInstalled);
    w.close();
  }

  console.log('\n【场景 6】开关关掉后，页面里已有的 <video autoplay> 属性回归');
  {
    const dom = makeDom({ injectAtStart: true });
    const w = dom.window;
    dartApply(w, true, false);
    const v = w.document.getElementById('v');
    const attrWhileOn = v.hasAttribute('autoplay');
    dartApply(w, false, false);
    // 站点在开关关掉后重新设 autoplay 属性
    v.setAttribute('autoplay', '');
    await new Promise((r) => setTimeout(r, 50));
    const attrAfterOff = v.hasAttribute('autoplay');
    check('开时 autoplay 属性被摘掉', attrWhileOn, false);
    check('关掉后站点重设 autoplay 属性应保留', attrAfterOff, true);
    w.close();
  }

  console.log('\n结论：' + (fail === 0 ? '全部通过' : fail + ' 项未通过'));
  process.exit(fail === 0 ? 0 : 1);
})();
