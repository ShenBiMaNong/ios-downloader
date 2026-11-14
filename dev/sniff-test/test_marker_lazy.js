// 角标「什么时候该出来」的回归测试（jsdom）
//
// 现场反馈：刷新页面后视频旁边没有角标；点一下页面（比如点到广告）角标才冒出来，
// 之后就一直在，直到再次刷新。
// 代码级原因：update() 的建角标条件里 `if (!src) continue` —— 站点只在点播放那一刻
// 才给 <video> 赋 src（或只挂 poster），赋 src 之前一个角标都不建；点击之所以「有效」，
// 是因为点完站点赋了 src / 或点了播放让嗅探器拿到达地址。
//
// 本测试锁定三件事：
//   P1 懒赋 src，但容器上已经有 data-url（嗅探器拿得到）→ **不点任何东西**就该出角标
//   P2 什么都没有 → 主播放器仍立一个中性「视频」角标；地址一到，卡片自动变成可下载
//   P3 小窗/广告位尺寸的 <video> 不给角标（别满屏角标）
//   P4 不带扩展名的播放地址（/play?id=1）也要有角标和下载项
//
// 跑法：cd dev/sniff-test && node test_marker_lazy.js
const fs = require('fs');
const { JSDOM, VirtualConsole } = require('jsdom');

function quietVC() {
  const vc = new VirtualConsole();
  vc.on('jsdomError', (e) => {
    const m = String((e && (e.detail || e.message)) || e);
    if (/Cannot read properties of undefined \(reading '(querySelectorAll|body|documentElement)'\)/.test(m)) return;
    if (/Not implemented: HTMLMediaElement/.test(m)) return;
    console.error('jsdomError:', m);
  });
  return vc;
}
process.on('unhandledRejection', () => {});

const HLS = 'https://cdn1.example.com/hls/a/index.m3u8?auth_key=1794592540-1016-0-abc';

const snifferJs = fs.readFileSync(__dirname + '/../../assets/sniffer.js', 'utf8');
const markerJs = fs.readFileSync(__dirname + '/../../assets/video_marker.js', 'utf8');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 页面骨架：player 容器上带 data-url（DPlayer 系站点把真地址写在这里），video 先不给 src
function page(opts) {
  const inner = opts.attr
    ? `<div class="dplayer" data-url="${opts.attr}"><video id="v"></video></div>`
    : `<video id="v"${opts.src ? ` src="${opts.src}"` : ''}></video>`;
  return `<!doctype html><html><head><title>测试播放页</title></head>
<body><div id="wrap">${inner}</div><div id="blank" style="height:60px">空白</div></body></html>`;
}

function makeDom(opts) {
  const dom = new JSDOM(page(opts), {
    url: 'https://www.moviesite.example.com/play/12345.html',
    runScripts: 'outside-only',
    pretendToBeVisual: true,
    virtualConsole: quietVC(),
  });
  const w = dom.window;
  w.performance.getEntriesByType = () => [];
  // 网络一律 reject：模拟「页面自己一次都没请求过」（地址只在 DOM 属性里）
  w.fetch = () => Promise.reject(new TypeError('Load failed'));
  // 捕获 Dart 侧的上报（诊断 / 动作）
  const posts = [];
  w.videoAction = { postMessage: (s) => { try { posts.push(JSON.parse(s)); } catch (e) {} } };

  const v = w.document.getElementById('v');
  const size = opts.size || { width: 1280, height: 720 };
  Object.defineProperty(v, 'getBoundingClientRect', {
    value: () => ({
      left: size.left || 0, top: size.top || 0,
      width: size.width, height: size.height,
      right: (size.left || 0) + size.width, bottom: (size.top || 0) + size.height,
    }),
  });
  Object.defineProperty(v, 'paused', { value: true, writable: true, configurable: true });
  Object.defineProperty(v, 'currentTime', { value: 0, writable: true, configurable: true });
  Object.defineProperty(v, 'duration', { value: 2712, writable: true, configurable: true });
  return { dom, w, v, posts };
}

async function boot(opts) {
  const ctx = makeDom(opts);
  ctx.w.eval(snifferJs);
  ctx.w.eval(markerJs);
  return ctx;
}

const badgeLabel = (w) => {
  const b = w.document.querySelector('.vdl-badge .vdl-tx');
  return b ? b.textContent : '';
};
const cardText = (w) => {
  const c = w.document.querySelector('.vdl-card');
  return c ? c.textContent : '';
};

// ── P1. 懒赋 src + 容器 data-url → 不点击也出角标 ─────────────────────────
async function runLazyWithAttr() {
  const { dom, w, posts } = await boot({ attr: HLS });
  await sleep(1300); // 只等 marker 的 1s 轮询，全程模拟「用户什么都没点」
  const n = w.document.querySelectorAll('.vdl-badge').length;
  const label = badgeLabel(w);
  await sleep(1400); // 等诊断上报（2.5s）
  const diag = posts.find((p) => p.action === 'markerDiag') || null;
  w.close();
  return { n, label, diag };
}

// ── P2. 什么都没有 → 中性角标；地址到了卡片自动升级 ──────────────────────
async function runPlaceholderUpgrade() {
  const { dom, w, v } = await boot({});
  await sleep(1300);
  const n = w.document.querySelectorAll('.vdl-badge').length;
  const label = badgeLabel(w);

  // 点角标 → 卡片应是「尚未捕获地址」的占位态
  const badge = w.document.querySelector('.vdl-badge');
  badge.dispatchEvent(new w.MouseEvent('click', { bubbles: true }));
  await sleep(50);
  const hint = cardText(w);

  // 模拟用户点了播放：站点此刻才赋 src（blob: + MSE 播放器是更常见的形态，这里用直链 m3u8）
  v.setAttribute('src', HLS);
  await sleep(1300);
  const cardAfter = cardText(w);
  const labelAfter = badgeLabel(w);
  w.close();
  return { n, label, hint, cardAfter, labelAfter };
}

// ── P3. 小窗 / 广告位尺寸 → 不给角标 ────────────────────────────────────
async function runTiny() {
  const { dom, w } = await boot({ size: { width: 160, height: 90 } });
  await sleep(1300);
  const n = w.document.querySelectorAll('.vdl-badge').length;
  w.close();
  return { n };
}

// ── P4. 不带扩展名的播放地址 → 角标 + 下载项 ────────────────────────────
async function runOpaqueUrl() {
  const { dom, w } = await boot({ src: 'https://cdn3.example.com/v/play?id=9527' });
  await sleep(1300);
  const n = w.document.querySelectorAll('.vdl-badge').length;
  const label = badgeLabel(w);
  const badge = w.document.querySelector('.vdl-badge');
  if (badge) badge.dispatchEvent(new w.MouseEvent('click', { bubbles: true }));
  await sleep(50);
  const card = cardText(w);
  w.close();
  return { n, label, card };
}

(async () => {
  const P1 = await runLazyWithAttr();
  console.log('===== P1. 懒赋 src + data-url：不点击也出角标 =====');
  console.log('角标数量   :', P1.n, P1.n >= 1 ? '✅' : '❌ 说明仍然要等用户点击');
  console.log('角标文案   :', JSON.stringify(P1.label), /HLS/.test(P1.label) ? '✅' : '❌');
  console.log('诊断上报   :', P1.diag
    ? `帧=${P1.diag.frame} 视频=${P1.diag.videos} 大=${P1.diag.big} 角标=${P1.diag.badged} 可见=${P1.diag.shown} 被遮挡=${P1.diag.covered} ✅`
    : '❌ 没收到 markerDiag');

  const P2 = await runPlaceholderUpgrade();
  console.log('===== P2. 无地址占位角标 → 地址到了自动升级 =====');
  console.log('角标数量   :', P2.n, P2.n >= 1 ? '✅' : '❌');
  console.log('角标文案   :', JSON.stringify(P2.label), P2.label === '视频' ? '✅ 中性' : '❌');
  console.log('占位卡片   :', JSON.stringify(P2.hint.slice(0, 40)),
    /尚未捕获/.test(P2.hint) ? '✅' : '❌');
  console.log('赋 src 后  :', /直接转 MP4/.test(P2.cardAfter) ? '✅ 卡片自动出现下载项' : '❌ 仍是占位',
    '| 角标=' + JSON.stringify(P2.labelAfter));

  const P3 = await runTiny();
  console.log('===== P3. 小窗尺寸不给角标 =====');
  console.log('角标数量   :', P3.n, P3.n === 0 ? '✅' : '❌ 小视频被误标');

  const P4 = await runOpaqueUrl();
  console.log('===== P4. 无扩展名播放地址 =====');
  console.log('角标数量   :', P4.n, P4.n >= 1 ? '✅' : '❌');
  console.log('角标文案   :', JSON.stringify(P4.label), P4.label === '视频' ? '✅' : '❌');
  console.log('卡片有下载 :', /下载视频/.test(P4.card) ? '✅' : '❌');

  const okAll =
    P1.n >= 1 && /HLS/.test(P1.label) && !!P1.diag &&
    P1.diag.videos >= 1 && P1.diag.badged >= 1 && P1.diag.frame === 'top' &&
    P2.n >= 1 && P2.label === '视频' && /尚未捕获/.test(P2.hint) &&
    /直接转 MP4/.test(P2.cardAfter) &&
    P3.n === 0 &&
    P4.n >= 1 && P4.label === '视频' && /下载视频/.test(P4.card);
  console.log('\n结论：' + (okAll ? '全部通过' : '存在未通过项，需复查'));
  process.exit(okAll ? 0 : 1);
})();
