// A-B 实测：同一页面（4 条线路候选、只有 1 条真能用），v1 与 v2 各选中哪条
// 场景还原：站点把 4 条线路写在 <script> 配置里，然后逐条试探可用性
//   L1 /hls/a/index.m3u8  → 200 + #EXTM3U        ✅ 唯一可用
//   L2 /hls/b/index.m3u8  → 404                  ❌
//   L3 /hls/c/index.m3u8  → 200 + text/html 错误页 ❌（假可用，最阴的一种）
//   L4 /hls/d/index.m3u8  → 网络错误 reject       ❌
const fs = require('fs');
const { JSDOM, VirtualConsole } = require('jsdom');

// 窗口 close() 后残留的定时器 / MutationObserver 仍会回调一次，
// jsdom 把这些统一报成「Uncaught TypeError: ... undefined」。生产环境里 document
// 一直存在，这类噪音与用例无关 —— 单独屏蔽，其他脚本错误照常打印。
function quietVC() {
  const vc = new VirtualConsole();
  vc.on('jsdomError', (e) => {
    const m = String((e && (e.detail || e.message)) || e);
    if (/Cannot read properties of undefined \(reading '(querySelectorAll|body)'\)/.test(m)) return;
    console.error('jsdomError:', m);
  });
  return vc;
}

// v1 的 fetch 钩子只挂了成功回调，网络失败的 rejected promise 没人接（它自己的毛病，
// 在 WKWebView 里表现为一条 unhandled rejection）。测试里忽略它，别让它杀掉进程。
process.on('unhandledRejection', () => {});

const A = 'https://cdn1.example.com/hls/a/index.m3u8';
const B = 'https://cdn2.example.com/hls/b/index.m3u8';
const C = 'https://cdn3.example.com/hls/c/index.m3u8';
const D = 'https://cdn4.example.com/hls/d/index.m3u8';

const PAGE = `<!doctype html><html><head><title>测试播放页</title>
<script>var player_1={"url":"${A}"};var player_2={"url":"${B}"};
var player_3={"url":"${C}"};var player_4={"url":"${D}"};</script>
</head><body><video id="v" width="1280" height="720"></video></body></html>`;

const ROUTES = {
  [A]: { status: 200, ct: 'application/vnd.apple.mpegurl', body: '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n' },
  [B]: { status: 404, ct: 'text/plain', body: 'not found' },
  [C]: { status: 200, ct: 'text/html', body: '<html><body>线路维护中</body></html>' },
  [D]: null, // null = 网络层 reject
};

function fakeFetch(url, srcText) {
  const r = ROUTES[url];
  const mkResp = (spec) => ({
    ok: spec.status >= 200 && spec.status < 300,
    status: spec.status,
    headers: { get: (k) => (k.toLowerCase() === 'content-type' ? spec.ct : null) },
    clone() { return { text: () => Promise.resolve(spec.body) }; },
  });
  if (!r) return Promise.reject(new TypeError('Load failed')); // 断连 / 被拦
  return Promise.resolve(mkResp(r));
}

function makeDom() {
  const dom = new JSDOM(PAGE, {
    url: 'https://www.moviesite.example.com/play/12345.html',
    runScripts: 'outside-only',
    pretendToBeVisual: true,
    virtualConsole: quietVC(),
  });
  const w = dom.window;
  // 隔离环境：资源时间线不参与（用 fetch 钩子这条主路径验证）
  w.performance.getEntriesByType = () => [];
  w.fetch = (input) => fakeFetch(typeof input === 'string' ? input : input.url);
  return dom;
}

// 模拟站点：把播放器的 src 换成 blob:（MSE），然后逐条试探线路
function setupVideo(w) {
  const v = w.document.getElementById('v');
  Object.defineProperty(v, 'currentSrc', { value: 'blob:https://www.moviesite.example.com/9f1c', configurable: true });
  Object.defineProperty(v, 'paused', { value: true, writable: true, configurable: true });
  Object.defineProperty(v, 'currentTime', { value: 0, writable: true, configurable: true });
  Object.defineProperty(v, 'duration', { value: 2712, writable: true, configurable: true });
  Object.defineProperty(v, 'getBoundingClientRect', {
    value: () => ({ left: 0, top: 0, width: 1280, height: 720, right: 1280, bottom: 720 }),
  });
  return v;
}

async function probeAll(w) {
  // 逐条试探；全部失败的那条最后才返回 —— 这也是真实站点的常见顺序
  for (const u of [A, B, C, D]) {
    try { await w.fetch(u).then((r) => (r.ok ? r.clone().text() : null)); } catch (e) { /* 网络错误 */ }
    await new Promise((r) => setTimeout(r, 5));
  }
}

function startPlayback(w, v) {
  v.paused = false;
  v.currentTime = 3.2;
  // media 事件不冒泡，但会在捕获阶段经过 document
  v.dispatchEvent(new w.Event('play'));
  v.dispatchEvent(new w.Event('playing'));
}

async function runV1() {
  const dom = makeDom();
  const w = dom.window;
  const v = setupVideo(w);
  w.eval(fs.readFileSync(__dirname + '/baseline/sniffer_v1.js', 'utf8'));
  await probeAll(w);
  startPlayback(w, v);
  await new Promise((r) => setTimeout(r, 150));
  const got = w.__vdlSniff ? w.__vdlSniff.getLatest('hls') : '';
  w.close();
  return got;
}

async function runV2() {
  const dom = makeDom();
  const w = dom.window;
  const v = setupVideo(w);
  const js = fs.readFileSync(__dirname + '/../../assets/sniffer.js', 'utf8');
  w.eval(js);
  w.eval(js); // Dart 在 onPageStarted + onPageFinished 各注入一次 → 幂等性验证
  await probeAll(w);
  startPlayback(w, v);
  await new Promise((r) => setTimeout(r, 150));
  const best = w.__vdlSniff.best('hls');
  const dump = w.__vdlSniff.dump();
  w.close();
  return { best, dump };
}

// v2 + 标记层：验证角标文案与「线路」列表
async function runMarker() {
  const dom = makeDom();
  const w = dom.window;
  const v = setupVideo(w);
  w.eval(fs.readFileSync(__dirname + '/../../assets/sniffer.js', 'utf8'));
  await probeAll(w);
  startPlayback(w, v);
  w.eval(fs.readFileSync(__dirname + '/../../assets/video_marker.js', 'utf8'));
  await new Promise((r) => setTimeout(r, 1300)); // 等 marker 的 1s 轮询

  const badge = w.document.querySelector('.vdl-badge');
  const label = badge ? badge.querySelector('.vdl-tx').textContent : '(无角标)';
  let lines = [];
  let onLine = '';
  let switched = null;
  let actions = [];
  if (badge) {
    badge.dispatchEvent(new w.MouseEvent('click', { bubbles: true }));
    await new Promise((r) => setTimeout(r, 30));
    lines = [...w.document.querySelectorAll('.vdl-line')].map((b) => ({
      mark: b.querySelector('.vdl-lm').textContent,
      url: b.getAttribute('data-line'),
      on: b.className.indexOf(' on') >= 0,
    }));
    onLine = (lines.find((l) => l.on) || {}).url || '';
    actions = [...w.document.querySelectorAll('.vdl-btn')].map((b) => b.getAttribute('data-a'));

    // 点第 2 条（dead 那条）→ 卡片应重绘并把当前 URL 切过去
    if (lines.length > 1) {
      const btn = [...w.document.querySelectorAll('.vdl-line')][1];
      const target = btn.getAttribute('data-line');
      btn.dispatchEvent(new w.MouseEvent('click', { bubbles: true }));
      await new Promise((r) => setTimeout(r, 30));
      const nowOn = w.document.querySelector('.vdl-line.on');
      switched = {
        want: target,
        on: nowOn ? nowOn.getAttribute('data-line') : '',
        url: (w.document.querySelector('.vdl-card-u') || {}).textContent || '',
      };
    }
  }
  w.close();
  return { label, lines, onLine, actions, switched };
}

// 场景 B：hls.js 走 Web Worker 拉清单（JS 钩子拿不到清单请求），
// 只能靠播放后出现的分片 URL 与候选目录前缀匹配来定位
async function runSeg() {
  const dom = makeDom();
  const w = dom.window;
  const v = setupVideo(w);
  const entries = [];
  w.performance.getEntriesByType = () => entries.slice();
  w.performance.setResourceTimingBufferSize = () => {};
  w.eval(fs.readFileSync(__dirname + '/../../assets/sniffer.js', 'utf8'));
  startPlayback(w, v);
  await new Promise((r) => setTimeout(r, 300));
  // 播放起来之后才有分片请求（真实时序），且目录是 /hls/c/ → 指向 L3 那条线路
  entries.push({
    name: 'https://cdn3.example.com/hls/c/1000kb/hls/seg1.ts',
    transferSize: 81234, decodedBodySize: 81234, responseStatus: 200,
  });
  await new Promise((r) => setTimeout(r, 2300)); // 等 2s 轮询跑到
  const best = w.__vdlSniff.best('hls');
  const dump = w.__vdlSniff.dump();
  w.close();
  return { best, dump };
}

// 场景 C：原生 HLS（iOS WKWebView 直接播 m3u8，不是 MSE）
// 期望：直接认元素 currentSrc，即便脚本里还写着别的候选
async function runNative() {
  const dom = makeDom();
  const w = dom.window;
  const v = setupVideo(w);
  const live = 'https://live.example.com/stream/9988/index.m3u8';
  Object.defineProperty(v, 'currentSrc', { value: live, configurable: true });
  w.eval(fs.readFileSync(__dirname + '/../../assets/sniffer.js', 'utf8'));
  startPlayback(w, v);
  await new Promise((r) => setTimeout(r, 200));
  const best = w.__vdlSniff.best('hls');
  w.close();
  return { best, live };
}


// 场景 D：DPlayer 式「MSE + 容器 data-url」
// 复刻桌面真实样本：video.src 是 blob:，真地址在父级 .dplayer[data-url]，
// 全程没有任何可观测的网络请求（清单在 Worker 里拉 / 请求发生在注入之前）。
// 旧版本在这种页面上只能给「未捕获到可下载直链」，v2.1 应能从属性拿到并推荐。
const PAGE_D = (dataUrl, extraScript) => `<!doctype html><html><head><title>DPlayer 站</title>
${extraScript || ''}
</head><body>
<div class="player-container">
  <div class="dplayer" data-video="0000000003484ff9" data-url="${dataUrl}">
    <div class="dplayer-video-wrap">
      <video class="dplayer-video" preload="auto" src="blob:https://asd.example.cc/b9aaf0bf-71c0"></video>
    </div>
  </div>
</div>
</body></html>`;

// 真实样本的签名形态：auth_key=<过期unix>-<随机>-<uid>-<md5>
// 时间戳只算一次，D1 与 D5 必须比对同一个串（否则跨秒就假失败）
const LIVE_D = 'https://hls.example.cn/videos5/1e4f/1e4f.m3u8?auth_key=' +
  (Math.floor(Date.now() / 1000) + 3600) + '-1016784267ba7-0-eafaf252&v=2';

function makeDomD(html) {
  const dom = new JSDOM(html, {
    url: 'https://asd.example.cc/watch/3484',
    runScripts: 'outside-only',
    pretendToBeVisual: true,
    virtualConsole: quietVC(),
  });
  const w = dom.window;
  w.performance.getEntriesByType = () => [];
  w.fetch = () => Promise.reject(new TypeError('Load failed'));
  return dom;
}

function runSnifferOn(dom) {
  const w = dom.window;
  w.eval(fs.readFileSync(__dirname + '/../../assets/sniffer.js', 'utf8'));
  return w;
}

async function runAttrFuture() {
  const live = LIVE_D;
  const dom = makeDomD(PAGE_D(live.replace(/&/g, '&amp;')));
  const w = runSnifferOn(dom);
  await new Promise((r) => setTimeout(r, 60));
  const best = w.__vdlSniff.best('hls');
  const dump = w.__vdlSniff.dump();
  w.close();
  return { best, dump, live };
}

async function runAttrExpired() {
  const dead = 'https://hls.example.cn/videos5/1e4f/1e4f.m3u8?auth_key=' +
    (Math.floor(Date.now() / 1000) - 1000) + '-1016784267ba7-0-eafaf252&v=2';
  const dom = makeDomD(PAGE_D(dead.replace(/&/g, '&amp;')));
  const w = runSnifferOn(dom);
  await new Promise((r) => setTimeout(r, 60));
  const best = w.__vdlSniff.best('hls');
  const dump = w.__vdlSniff.dump();
  w.close();
  return { best, dump, dead };
}

// 属性旁没有 blob 播放器（备用线路/广告位）→ 只给 S_ATTR，不该压过任何实测证据
async function runAttrLoose() {
  const live = 'https://cdn.example.cn/backup/index.m3u8';
  const html = '<!doctype html><html><body>' +
    '<div class="spare" data-url="' + live + '"></div></body></html>';
  const dom = makeDomD(html);
  const w = runSnifferOn(dom);
  await new Promise((r) => setTimeout(r, 60));
  const best = w.__vdlSniff.best('hls');
  w.close();
  return { best, live };
}

// 相对路径 + 脚本里 \u0026 转义（真实站点两种都常见）
async function runAttrRelative() {
  const html = '<!doctype html><html><body>' +
    '<div class="dplayer" data-url="/hls/rel/index.m3u8?a=1&amp;b=2">' +
    '<video src="blob:https://asd.example.cc/aa11"></video></div>' +
    '<script>var cfg={"u":"https://cdn.example.cn/x/index.m3u8?a=1\\u0026auth_key=' +
    (Math.floor(Date.now() / 1000) + 600) + '-9-0-ff"};</script>' +
    '</body></html>';
  const dom = makeDomD(html);
  const w = runSnifferOn(dom);
  await new Promise((r) => setTimeout(r, 60));
  const dump = w.__vdlSniff.dump();
  w.close();
  return { dump };
}

// 标记层：blob 播放器 + data-url → 角标应给 HLS，卡片应出下载动作而不是「不支持」
async function runAttrMarker() {
  const live = LIVE_D;
  const dom = makeDomD(PAGE_D(live.replace(/&/g, '&amp;')));
  const w = runSnifferOn(dom);
  w.eval(fs.readFileSync(__dirname + '/../../assets/video_marker.js', 'utf8'));
  await new Promise((r) => setTimeout(r, 120));
  const badge = w.document.querySelector('.vdl-badge');
  const label = badge ? badge.querySelector('.vdl-tx').textContent : '(无角标)';
  let actions = [];
  let cardUrl = '';
  let notice = '';
  if (badge) {
    badge.dispatchEvent(new w.MouseEvent('click', { bubbles: true }));
    await new Promise((r) => setTimeout(r, 30));
    actions = [...w.document.querySelectorAll('.vdl-btn')].map((b) => b.getAttribute('data-a'));
    cardUrl = (w.document.querySelector('.vdl-card-u') || {}).textContent || '';
    const warn = w.document.querySelector('.vdl-warn');
    notice = warn ? warn.textContent : '';
  }
  w.close();
  return { label, actions, cardUrl, notice };
}


(async () => {
  const v1 = await runV1();
  const { best, dump } = await runV2();
  const marker = await runMarker();

  const short = (u) => (u || '').replace('https://', '').replace('/index.m3u8', '');
  const pass = (b) => (b ? '✅ 命中 L1（唯一可用）' : '❌ 未命中');

  console.log('===== 场景：4 条线路，仅 L1 可用 =====');
  console.log('v1 getLatest("hls") =', short(v1), v1 === A ? '✅' : '❌ 选到坏链接');
  console.log('v2 getBest("hls")   =', short(best && best.url), best && best.url === A ? '✅' : '❌');
  console.log('v2 判定明细：');
  for (const d of dump) {
    console.log('   ', short(d.url).padEnd(26), 'score=' + String(d.score).padStart(4), 'state=' + d.state.padEnd(5), 'src=' + d.src);
  }
  console.log('===== 标记层（video_marker.js）=====');
  console.log('角标文案 :', marker.label);
  console.log('线路列表 :', marker.lines.length, '条');
  for (const l of marker.lines) {
    console.log('   ', l.mark, short(l.url).padEnd(26), l.on ? '← 当前选中' : '');
  }
  console.log('当前选中 :', short(marker.onLine), marker.onLine === A ? '✅' : '❌');
  console.log('动作按钮 :', marker.actions.join(', '));
  const sw = marker.switched;
  console.log('切线路测试:', sw
    ? (sw.on === sw.want && sw.url === sw.want
      ? '✅ 选中项与卡片 URL 都已切到 ' + short(sw.want)
      : '❌ 未切换（on=' + short(sw.on) + ' url=' + short(sw.url) + '）')
    : '(无候选)');

  const seg = await runSeg();
  console.log('===== 场景 B：清单走 Worker 拿不到，靠分片目录佐证 =====');
  console.log('v2 getBest("hls") =', short(seg.best && seg.best.url),
    seg.best && seg.best.url === C ? '✅ 命中真正在播的 /hls/c/' : '❌');
  for (const d of seg.dump) {
    console.log('   ', short(d.url).padEnd(26), 'score=' + String(d.score).padStart(4), 'state=' + d.state.padEnd(5), 'src=' + d.src);
  }

  const nat = await runNative();
  console.log('===== 场景 C：原生 HLS（元素 currentSrc 即正在播的清单）=====');
  console.log('v2 getBest("hls") =', nat.best && nat.best.url.replace('https://', ''),
    nat.best && nat.best.url === nat.live ? '✅' : '❌');

  // ── 场景 D：MSE + 容器 data-url（复刻桌面 DPlayer 样本）──
  const d1 = await runAttrFuture();
  const d2 = await runAttrExpired();
  const d3 = await runAttrLoose();
  const d4 = await runAttrRelative();
  const d5 = await runAttrMarker();

  const d1ok = d1.best && d1.best.url === d1.live && d1.best.score === 550 && d1.best.src === 'attr';
  console.log('===== 场景 D1：blob 播放器 + 父级 data-url（无任何网络请求）=====');
  console.log('v2 getBest("hls") =', short(d1.best && d1.best.url),
    'score=' + (d1.best && d1.best.score), 'src=' + (d1.best && d1.best.src),
    d1ok ? '✅ 从属性拿到真地址（旧版这里是空的）' : '❌');
  for (const d of d1.dump) {
    console.log('   ', short(d.url).padEnd(30), 'score=' + String(d.score).padStart(4),
      'state=' + d.state.padEnd(5), 'src=' + d.src, 'exp=' + (d.exp || '-'));
  }

  const d2ok = d2.best && d2.best.why === 'expired';
  console.log('===== 场景 D2：同上但 auth_key 已过期 =====');
  console.log('v2 best() why =', d2.best && (d2.best.why || '(无)'),
    d2ok ? '✅ 不推荐已过期链接' : '❌ 仍把过期链接当可用');

  const d3ok = d3.best && d3.best.url === d3.live && d3.best.score === 350;
  console.log('===== 场景 D3：只有 data-url，旁边没有 blob 播放器 =====');
  console.log('score =', d3.best && d3.best.score,
    d3ok ? '✅ 350（低档，让位于任何实测证据）' : '❌');

  const d4rel = d4.dump.find((d) => d.url.indexOf('/hls/rel/index.m3u8') >= 0);
  const d4esc = d4.dump.find((d) => d.url.indexOf('auth_key') >= 0);
  const d4ok = !!d4rel && d4rel.url === 'https://asd.example.cc/hls/rel/index.m3u8?a=1&b=2' &&
    !!d4esc && d4esc.url.indexOf('\\u0026') < 0 && d4esc.url.indexOf('&amp;') < 0;
  console.log('===== 场景 D4：相对路径 / 脚本内 \\u0026 转义 =====');
  console.log('相对路径归一 =', d4rel ? d4rel.url : '(未找到)',
    d4rel && d4rel.url.indexOf('https://asd.example.cc/') === 0 ? '✅' : '❌');
  console.log('转义还原   =', d4esc ? d4esc.url : '(未找到)',
    d4esc && d4ok ? '✅' : '❌');

  const d5ok = d5.label.indexOf('HLS') === 0 && d5.actions.indexOf('bg') >= 0 &&
    d5.cardUrl === d1.live;
  console.log('===== 场景 D5：标记层（角标 + 卡片）=====');
  console.log('角标文案 :', d5.label, '| 动作 :', d5.actions.join(', '));
  console.log('卡片地址 :', d5.cardUrl ? d5.cardUrl.slice(0, 52) + '…' : '(空)',
    d5ok ? '✅ 不再是「未捕获到直链」' : '❌');

  const okAll = v1 !== A && best && best.url === A && marker.onLine === A &&
    seg.best && seg.best.url === C && nat.best && nat.best.url === nat.live &&
    d1ok && d2ok && d3ok && d4ok && d5ok;
  console.log('\n结论：' + (okAll ? '全部场景通过 —— 修复成立' : '存在未通过项，需复查'));
  process.exit(okAll ? 0 : 1);
})();
