// 「刷新后没角标、开关关→开就有」的回归测试（jsdom）
//
// 现场反馈（第 2 轮）：刷新视频页角标不出；把「视频标记」设置项关了又开，角标就出来了。
// 结论指向注入链路而非脚本逻辑：开关切换 = 页面已完全加载后 runJavaScript 注入（必成功），
// 刷新 = onPageStarted/onPageFinished 注入（导航竞态，可能打到旧文档或被丢弃）。
// 另外 iOS 全帧 WKUserScript 是 atDocumentStart 注入，那个时刻 <html>/<body>/<video>
// 全都还不存在 —— 旧版 marker 顶部 `if (!document.documentElement) return;` 会直接退出，
// 而 user script 对每个文档只执行一次，等于这个文档永远没有角标。
//
// 本测试锁定三件事：
//   E1 极早注入（文档几乎为空）→ 页面随后解析出 <video> → 角标必须自己长出来
//   E2 shadow root 内的 <video>（自绘播放器）→ document.querySelectorAll 看不到，也要出角标
//   E3 video.srcObject = MediaSource（src/currentSrc 都是空串）→ 不能被当成「没有地址」跳过
//   E4 同源 iframe 内的 <video> → 主帧收集到它，坐标换算到主帧视口
//
// 跑法：cd dev/sniff-test && node test_marker_early.js
const fs = require('fs');
const { JSDOM, VirtualConsole } = require('jsdom');

function quietVC() {
  const vc = new VirtualConsole();
  vc.on('jsdomError', (e) => {
    const m = String((e && (e.detail || e.message)) || e);
    if (/Not implemented: HTMLMediaElement/.test(m)) return;
    if (/Not implemented/.test(m)) return;
    console.error('jsdomError:', m);
  });
  return vc;
}
process.on('unhandledRejection', (e) => { console.error('UNHANDLED:', e); process.exit(1); });

const markerJs = fs.readFileSync(__dirname + '/../../assets/video_marker.js', 'utf8');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 极早期文档：只有 <html>，没有 body —— 对应 WKUserScript atDocumentStart 时刻
function makeDom() {
  const dom = new JSDOM('<!doctype html><html></html>', {
    url: 'https://m.example.com/play/9527.html',
    runScripts: 'outside-only',
    pretendToBeVisual: true,
    virtualConsole: quietVC(),
  });
  const w = dom.window;
  w.performance.getEntriesByType = () => [];
  w.fetch = () => Promise.reject(new TypeError('Load failed'));
  const posts = [];
  w.videoAction = { postMessage: (s) => { try { posts.push(JSON.parse(s)); } catch (e) {} } };
  // jsdom 会自动补全 <body>，手动去掉以复现 atDocumentStart（<body> 尚未创建）的真实时刻
  if (w.document.body) w.document.body.remove();
  return { dom, w, posts };
}

function bigVideo(w, opts) {
  const v = w.document.createElement('video');
  const size = (opts && opts.size) || { width: 1280, height: 720 };
  // configurable：F1 需要在「播放器布局出来」时重定义尺寸
  Object.defineProperty(v, 'getBoundingClientRect', {
    configurable: true,
    value: () => ({
      left: size.left || 0, top: size.top || 0,
      width: size.width, height: size.height,
      right: (size.left || 0) + size.width, bottom: (size.top || 0) + size.height,
    }),
  });
  Object.defineProperty(v, 'paused', { value: false, writable: true, configurable: true });
  Object.defineProperty(v, 'currentTime', { value: 3, writable: true, configurable: true });
  Object.defineProperty(v, 'duration', { value: 2712, writable: true, configurable: true });
  return v;
}

const badgeLabel = (root) => {
  const b = root.querySelector('.vdl-badge .vdl-tx');
  return b ? b.textContent : '';
};

// ── E1. 极早注入：body/video 都还没有 → 页面解析出来后角标自动出现 ─────────
async function runEarlyInject() {
  const { w, posts } = makeDom();
  // 关键时刻：documentElement 存在但 body 不存在（atDocumentStart）
  w.eval(markerJs); // ← 旧版在这里直接 return，角标永远不来
  if (w.document.body) throw new Error('测试前提变了：body 应该还不存在');
  await sleep(30); // 模拟解析器继续跑
  const body = w.document.createElement('body');
  w.document.documentElement.appendChild(body);
  const v = bigVideo(w);
  v.setAttribute('src', 'https://cdn.example.com/hls/a/index.m3u8');
  body.appendChild(v);
  await sleep(1500);
  const n = w.document.querySelectorAll('.vdl-badge').length;
  const label = badgeLabel(w.document);
  await sleep(1400); // 等 playing 诊断
  const diag = posts.filter((p) => p.action === 'markerDiag').pop() || null;
  w.close();
  return { n, label, diag };
}

// ── E2. shadow root 内的 <video> ─────────────────────────────────────────
async function runShadow() {
  const { w } = makeDom();
  const body = w.document.createElement('body');
  w.document.documentElement.appendChild(body);
  const host = w.document.createElement('div');
  body.appendChild(host);
  // 先注入再建 shadow（钩子才有用）；再补一个「先建 shadow 后注入」的对照行
  w.eval(markerJs);
  const sr = host.attachShadow({ mode: 'open' });
  const v = bigVideo(w);
  v.setAttribute('src', 'https://cdn.example.com/hls/s/index.m3u8');
  sr.appendChild(v);
  // 主文档里故意放一个小广告 video（站点常有），防止「有角标就算过」的假阳性
  const ad = bigVideo(w, { size: { width: 120, height: 80 } });
  ad.setAttribute('src', 'https://ads.example.com/ad.mp4');
  body.appendChild(ad);
  await sleep(1500);
  // 角标按设计挂在本帧 documentElement 上（shadow root 内只放 video），
  // 所以查主文档：shadow 里的大 video 一个 + 主文档小广告一个（有地址就标，宁多勿漏）
  const nDoc = w.document.querySelectorAll('.vdl-badge').length;
  const labels = Array.from(w.document.querySelectorAll('.vdl-badge .vdl-tx')).map((e) => e.textContent);
  w.close();
  return { nDoc, labels };
}

// ── E3. video.srcObject = MediaSource（src/currentSrc 全是空串）──────────
async function runSrcObject() {
  const { w } = makeDom();
  const body = w.document.createElement('body');
  w.document.documentElement.appendChild(body);
  w.eval(markerJs);
  const v = bigVideo(w);
  v.srcObject = { fake: 'MediaSource' };
  body.appendChild(v);
  await sleep(1500);
  const n = w.document.querySelectorAll('.vdl-badge').length;
  const label = badgeLabel(w.document);
  w.close();
  return { n, label };
}

// ── E4. 同源 iframe 内的 <video>：主帧收集 + 坐标换算 ─────────────────────
async function runSameOriginIframe() {
  const { w } = makeDom();
  const body = w.document.createElement('body');
  w.document.documentElement.appendChild(body);
  w.eval(markerJs);
  const iframe = w.document.createElement('iframe');
  Object.defineProperty(iframe, 'getBoundingClientRect', {
    value: () => ({ left: 40, top: 60, width: 800, height: 450, right: 840, bottom: 510 }),
  });
  body.appendChild(iframe);
  // jsdom 的 iframe 没有真实 contentDocument，手动塞一个同源文档
  const inner = new JSDOM('<video id="iv"></video>', {
    url: 'https://m.example.com/player.html', runScripts: 'outside-only', pretendToBeVisual: true,
    virtualConsole: quietVC(),
  });
  Object.defineProperty(iframe, 'contentDocument', { value: inner.window.document, configurable: true });
  Object.defineProperty(iframe, 'contentWindow', { value: inner.window, configurable: true });
  // jsdom 不实现 frameElement，真机上同源 iframe 靠它换算坐标 → mock 出来
  Object.defineProperty(inner.window, 'frameElement', { value: iframe, configurable: true });
  const iv = inner.window.document.getElementById('iv');
  Object.defineProperty(iv, 'getBoundingClientRect', {
    value: () => ({ left: 0, top: 0, width: 800, height: 450, right: 800, bottom: 450 }),
  });
  Object.defineProperty(iv, 'paused', { value: false, writable: true, configurable: true });
  Object.defineProperty(iv, 'duration', { value: 1200, writable: true, configurable: true });
  iv.setAttribute('src', 'https://cdn.example.com/hls/i/index.m3u8');
  await sleep(1500);
  const n = w.document.querySelectorAll('.vdl-badge').length;
  const badge = w.document.querySelector('.vdl-badge');
  // 角标应画在 iframe 偏移后的坐标上（video 右上角 = 40+800-角标宽, 60-12）
  const style = badge ? { left: badge.style.left, top: badge.style.top } : null;
  w.close();
  return { n, style };
}

// ── F1. __vdlBadge 残留自愈：指向已脱离文档的 badge 不再挡住重建 ──────────
async function runStaleBadgeHeal() {
  const { w } = makeDom();
  const body = w.document.createElement('body');
  w.document.documentElement.appendChild(body);
  w.eval(markerJs);
  // 先放一个「没有地址、尺寸小」的 video → 按规则不建角标，marked 保持为空
  const v = bigVideo(w, { size: { width: 160, height: 90 } });
  body.appendChild(v);
  await sleep(80);
  // 模拟上一轮创建流程中断留下的残留：指向一个已脱离文档的 badge
  const ghost = w.document.createElement('div');
  ghost.className = 'vdl-badge';
  v.__vdlBadge = ghost;
  // 播放器此刻才布局出来 + 点播放赋了 src（真实站点的常见时序）
  Object.defineProperty(v, 'getBoundingClientRect', {
    configurable: true,
    value: () => ({ left: 0, top: 0, width: 1280, height: 720, right: 1280, bottom: 720 }),
  });
  v.setAttribute('src', 'https://cdn.example.com/hls/heal/index.m3u8');
  await sleep(1500);
  const badges = w.document.querySelectorAll('.vdl-badge');
  const real = badges.length; // ghost 不在文档里，只数真实挂上的
  const detachedStill = (v.__vdlBadge === ghost); // 自愈应把残留换掉
  w.close();
  return { real, healed: !detachedStill };
}

// ── F2. 开关「关→开」：cleanup 后重新注入 → 角标必须重建 ─────────────────
async function runToggleRebuild() {
  const { w } = makeDom();
  const body = w.document.createElement('body');
  w.document.documentElement.appendChild(body);
  w.eval(markerJs);
  const v = bigVideo(w);
  v.setAttribute('src', 'https://cdn.example.com/hls/t/index.m3u8');
  body.appendChild(v);
  await sleep(1400);
  const before = w.document.querySelectorAll('.vdl-badge').length;
  w.eval('if (window.__vdlCleanup) window.__vdlCleanup();'); // 开关「关」
  await sleep(60);
  const afterOff = w.document.querySelectorAll('.vdl-badge').length;
  w.eval(markerJs); // 开关「开」= 重新注入
  await sleep(1400);
  const afterOn = w.document.querySelectorAll('.vdl-badge').length;
  w.close();
  return { before, afterOff, afterOn };
}

(async () => {
  try {
  const E1 = await runEarlyInject();
  console.log('===== E1. 极早注入（body 尚不存在）→ 页面解析后自动出角标 =====');
  console.log('角标数量 :', E1.n, E1.n >= 1 ? '✅' : '❌ 刷新后没角标 = 这条没修好');
  console.log('角标文案 :', JSON.stringify(E1.label), /HLS/.test(E1.label) ? '✅' : '❌');
  console.log('诊断上报 :', E1.diag
    ? `tag=${E1.diag.tag} 视频=${E1.diag.videos} 播放中=${E1.diag.playing} 角标=${E1.diag.badged} ✅`
    : '❌ 无诊断');

  const E2 = await runShadow();
  console.log('===== E2. shadow root 内 <video> 也出角标 =====');
  console.log('角标总数 :', E2.nDoc, E2.nDoc >= 2 ? '✅（shadow 内视频 + 小视频都标到）' : '❌ 自绘播放器全漏');
  console.log('角标文案 :', JSON.stringify(E2.labels), E2.labels.some((l) => /HLS/.test(l)) ? '✅' : '❌');

  const E3 = await runSrcObject();
  console.log('===== E3. video.srcObject（src 为空串）=======');
  console.log('角标数量 :', E3.n, E3.n >= 1 ? '✅' : '❌ MSE 播放器全漏');
  console.log('角标文案 :', JSON.stringify(E3.label), /流/.test(E3.label) ? '✅ MSE' : '❌');

  const E4 = await runSameOriginIframe();
  console.log('===== E4. 同源 iframe 内 <video>：主帧收集 + 坐标换算 =====');
  console.log('角标数量 :', E4.n, E4.n >= 1 ? '✅' : '❌');
  console.log('角标位置 :', JSON.stringify(E4.style),
    (E4.style && E4.style.top === '48px') ? '✅（60-12=48，已换算 iframe 偏移）' : '❌ 位置没换算');

  const F1 = await runStaleBadgeHeal();
  console.log('===== F1. __vdlBadge 残留自愈（「刷新没角标」的机制）=====');
  console.log('真实角标 :', F1.real, F1.real >= 1 ? '✅ 残留没挡住重建' : '❌ 残留导致永远不建');
  console.log('残留已换 :', F1.healed ? '✅' : '❌ __vdlBadge 仍指向 detached 元素');

  const F2 = await runToggleRebuild();
  console.log('===== F2. 开关「关→开」重建角标（「关了又开就有了」的机制）=====');
  console.log('关之前 :', F2.before, F2.before >= 1 ? '✅' : '❌');
  console.log('关之后 :', F2.afterOff, F2.afterOff === 0 ? '✅ 清干净' : '❌ 没清掉');
  console.log('再打开 :', F2.afterOn, F2.afterOn >= 1 ? '✅ 重建成功' : '❌ 关→开后仍然没有');

  const okAll =
    E1.n >= 1 && /HLS/.test(E1.label) && !!E1.diag &&
    E2.nDoc >= 2 && E2.labels.some((l) => /HLS/.test(l)) &&
    E3.n >= 1 && /流/.test(E3.label) &&
    E4.n >= 1 && E4.style && E4.style.top === '48px' &&
    F1.real >= 1 && F1.healed &&
    F2.before >= 1 && F2.afterOff === 0 && F2.afterOn >= 1;
  console.log('\n结论：' + (okAll ? '全部通过' : '存在未通过项，需复查'));
  process.exit(okAll ? 0 : 1);
  } catch (e) { console.error('TEST CRASH:', e); process.exit(1); }
})();
