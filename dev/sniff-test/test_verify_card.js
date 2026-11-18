// 标记层两件事的回归测试（jsdom）：
//   E. 候选可用性：页面从来没请求过的线路（脚本/属性里抄出来的 guess）能否在
//      打开操作卡时被现场探测，把「?」变成 ✓ / ✗，并把死链上的选中自动挪到可用那条
//   F. 弹层关闭：卡片内滚动（候选列表翻页）不能关掉卡片，页面滚动必须关掉
//
// 跑法：cd dev/sniff-test && node test_verify_card.js
const fs = require('fs');
const { JSDOM, VirtualConsole } = require('jsdom');

function quietVC() {
  const vc = new VirtualConsole();
  vc.on('jsdomError', (e) => {
    const m = String((e && (e.detail || e.message)) || e);
    if (/Cannot read properties of undefined \(reading '(querySelectorAll|body)'\)/.test(m)) return;
    // jsdom 没有媒体管线：探针元素的 load() 会走到这里，与用例无关
    if (/Not implemented: HTMLMediaElement/.test(m)) return;
    console.error('jsdomError:', m);
  });
  return vc;
}
process.on('unhandledRejection', () => {});

const A = 'https://cdn1.example.com/hls/a/index.m3u8'; // 200 + #EXTM3U  ✅
const B = 'https://cdn2.example.com/hls/b/index.m3u8'; // 404            ❌
const C = 'https://cdn3.example.com/hls/c/index.m3u8'; // 200 + HTML     ❌（假可用）

// 三条线路只写在 <script> 配置里，页面自己一次都不请求 —— 这正是「拦截拿不到状态」的场景
const PAGE = `<!doctype html><html><head><title>测试播放页</title>
<script>var cfg={"lines":["${A}","${B}","${C}"]};</script>
</head><body><video id="v" width="1280" height="720"></video>
<div id="blank" style="height:80px">空白</div></body></html>`;

const ROUTES = {
  [A]: { status: 200, ct: 'application/vnd.apple.mpegurl', body: '#EXTM3U\n#EXT-X-VERSION:3\n' },
  [B]: { status: 404, ct: 'text/plain', body: 'not found' },
  [C]: { status: 200, ct: 'text/html', body: '<html><body>线路维护中</body></html>' },
};

function fakeFetch(url) {
  const r = ROUTES[url];
  if (!r) return Promise.reject(new TypeError('Load failed'));
  return Promise.resolve({
    ok: r.status >= 200 && r.status < 300,
    status: r.status,
    headers: { get: (k) => (k.toLowerCase() === 'content-type' ? r.ct : null) },
    text: () => Promise.resolve(r.body),
    clone() { return { text: () => Promise.resolve(r.body) }; },
  });
}

function makeDom() {
  const dom = new JSDOM(PAGE, {
    url: 'https://www.moviesite.example.com/play/12345.html',
    runScripts: 'outside-only',
    pretendToBeVisual: true,
    virtualConsole: quietVC(),
  });
  const w = dom.window;
  w.performance.getEntriesByType = () => [];
  w.fetch = (input) => fakeFetch(typeof input === 'string' ? input : input.url);
  const v = w.document.getElementById('v');
  Object.defineProperty(v, 'currentSrc', { value: 'blob:https://www.moviesite.example.com/9f1c', configurable: true });
  Object.defineProperty(v, 'paused', { value: true, writable: true, configurable: true });
  Object.defineProperty(v, 'currentTime', { value: 0, writable: true, configurable: true });
  Object.defineProperty(v, 'duration', { value: 2712, writable: true, configurable: true });
  Object.defineProperty(v, 'getBoundingClientRect', {
    value: () => ({ left: 0, top: 0, width: 1280, height: 720, right: 1280, bottom: 720 }),
  });
  return { dom, w, v };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const short = (u) => (u || '').replace('https://', '').replace('/index.m3u8', '');
const cardCount = (w) => w.document.querySelectorAll('.vdl-card').length;

async function boot() {
  const { dom, w, v } = makeDom();
  w.eval(fs.readFileSync(__dirname + '/../../assets/sniffer.js', 'utf8'));
  w.eval(fs.readFileSync(__dirname + '/../../assets/video_marker.js', 'utf8'));
  await sleep(1200); // 等 marker 的 1s 轮询出角标
  const badge = w.document.querySelector('.vdl-badge');
  return { dom, w, v, badge };
}

// ── E. 未验证候选的主动校验 ─────────────────────────────────────────────
async function runVerify() {
  const { dom, w, badge } = await boot();
  const before = w.__vdlSniff.dump().map((d) => `${short(d.url)}:${d.state}`);
  if (!badge) { w.close(); return { before, error: '没有角标' }; }

  badge.dispatchEvent(new w.MouseEvent('click', { bubbles: true }));
  await sleep(30);
  const marksAtOpen = [...w.document.querySelectorAll('.vdl-line .vdl-lm')].map((m) => m.textContent).join('');
  const headAtOpen = (w.document.querySelector('.vdl-lines-h') || {}).textContent || '';

  await sleep(500); // 等探测结果回来
  const marksAfter = [...w.document.querySelectorAll('.vdl-line .vdl-lm')].map((m) => m.textContent).join('');
  const headAfter = (w.document.querySelector('.vdl-lines-h') || {}).textContent || '';
  const dump = w.__vdlSniff.dump();
  const stateOf = {};
  for (const d of dump) stateOf[short(d.url)] = d.state + '/' + (d.code || 0);
  const best = w.__vdlSniff.best('hls');
  const tails = [...w.document.querySelectorAll('.vdl-line .vdl-lu')].map((e) => e.textContent);
  const label = (w.document.querySelector('.vdl-badge .vdl-tx') || {}).textContent || '';
  w.close();
  return { before, marksAtOpen, marksAfter, headAtOpen, headAfter, stateOf, best, tails, label };
}

// ── F. 关闭规则 ────────────────────────────────────────────────────────
async function runDismiss() {
  const { dom, w, badge } = await boot();
  const out = {};
  const step = async (fn, wait = 30) => { fn(); await sleep(wait); };

  out.opened = 0;
  badge.dispatchEvent(new w.MouseEvent('click', { bubbles: true }));
  await sleep(30);
  out.opened = cardCount(w);

  // 卡片自身滚动 + 候选列表滚动 → 必须留着（用户要翻线路）
  await step(() => {
    const card = w.document.querySelector('.vdl-card');
    const lines = card.querySelector('.vdl-lines');
    card.dispatchEvent(new w.Event('scroll'));
    if (lines) lines.dispatchEvent(new w.Event('scroll'));
  });
  out.afterCardScroll = cardCount(w);

  // 卡片内点击 → 留着
  await step(() => w.document.querySelector('.vdl-card .vdl-card-h').click());
  out.afterCardClick = cardCount(w);

  // 页面滚动 → 关掉
  await step(() => w.document.dispatchEvent(new w.Event('scroll')));
  out.afterPageScroll = cardCount(w);

  // 点页面空白 → 关掉
  await step(() => w.document.getElementById('blank').click());
  out.afterBlankClick = cardCount(w);

  w.close();
  return out;
}

// ── G. 「探测失败 ≠ 死链」：reject（CORS/断连）必须留 guess，不能判死 ──
async function runAmbiguous() {
  const { dom, w } = makeDom();
  const u = 'https://cdn9.example.com/hls/z/index.m3u8'; // 不在 ROUTES 里 → fetch 必 reject
  w.document.head.insertAdjacentHTML('beforeend',
    '<script>var cfg2={"u":"' + u + '"};</script>');
  w.eval(fs.readFileSync(__dirname + '/../../assets/sniffer.js', 'utf8'));
  await sleep(60);
  const before = (w.__vdlSniff.dump().find((x) => x.url === u) || {}).state || '(未收录)';
  w.__vdlSniff.verify([u], () => {});
  await sleep(300);
  const d = w.__vdlSniff.dump().find((x) => x.url === u);
  w.close();
  return { before, state: d ? d.state : '(未收录)' };
}

(async () => {
  const E = await runVerify();
  console.log('===== E. 未验证候选 → 打开卡片现场校验 =====');
  console.log('打开前候选状态 :', E.before ? E.before.join('  ') : E.error);
  console.log('卡片行标记     :', E.marksAtOpen, '→', E.marksAfter, '(期望 ??? → ?✓✗ 或 ✓/✗ 组合)');
  console.log('表头           :', E.headAtOpen, '→', E.headAfter);
  console.log('探测后状态/码  :', E.stateOf);
  console.log('best("hls")    :', short(E.best && E.best.url), E.best && E.best.url === A ? '✅' : '❌');
  console.log('死链行尾注     :', E.tails.join(' | '));
  console.log('角标文案       :', E.label);

  const F = await runDismiss();
  console.log('===== F. 弹层关闭规则 =====');
  console.log('点角标         : card=' + F.opened, F.opened === 1 ? '✅' : '❌');
  console.log('卡片内滚动     : card=' + F.afterCardScroll, F.afterCardScroll === 1 ? '✅ 不关闭' : '❌ 被关掉了');
  console.log('卡片内点击     : card=' + F.afterCardClick, F.afterCardClick === 1 ? '✅' : '❌');
  console.log('页面滚动       : card=' + F.afterPageScroll, F.afterPageScroll === 0 ? '✅ 关闭' : '❌ 仍开着');
  console.log('点页面空白     : card=' + F.afterBlankClick, F.afterBlankClick === 0 ? '✅ 关闭' : '❌ 仍开着');

  const G = await runAmbiguous();
  console.log('===== G. 探测被拒（CORS/断连）不得判死 =====');
  console.log('探测前 state =', G.before, '→ 探测后 state =', G.state,
    G.state === 'guess' ? '✅ 保持未验证' : '❌ 被误判');

  const okAll =
    E.best && E.best.url === A &&
    E.stateOf[short(A)].indexOf('ok') === 0 &&
    E.stateOf[short(B)].indexOf('dead') === 0 &&
    E.stateOf[short(C)].indexOf('dead') === 0 &&
    E.marksAfter.indexOf('✓') >= 0 && E.marksAfter.indexOf('✗') >= 0 &&
    F.opened === 1 && F.afterCardScroll === 1 && F.afterCardClick === 1 &&
    F.afterPageScroll === 0 && F.afterBlankClick === 0 &&
    G.state === 'guess';
  console.log('\n结论：' + (okAll ? '全部通过' : '存在未通过项，需复查'));
  process.exit(okAll ? 0 : 1);
})();
