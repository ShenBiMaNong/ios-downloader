// A-B 实测：同一页面（4 条线路候选、只有 1 条真能用），v1 与 v2 各选中哪条
// 场景还原：站点把 4 条线路写在 <script> 配置里，然后逐条试探可用性
//   L1 /hls/a/index.m3u8  → 200 + #EXTM3U        ✅ 唯一可用
//   L2 /hls/b/index.m3u8  → 404                  ❌
//   L3 /hls/c/index.m3u8  → 200 + text/html 错误页 ❌（假可用，最阴的一种）
//   L4 /hls/d/index.m3u8  → 网络错误 reject       ❌
const fs = require('fs');
const { JSDOM } = require('jsdom');

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

  const okAll = v1 !== A && best && best.url === A && marker.onLine === A &&
    seg.best && seg.best.url === C && nat.best && nat.best.url === nat.live;
  console.log('\n结论：' + (okAll ? '三项全部通过 —— 修复成立' : '存在未通过项，需复查'));
  process.exit(okAll ? 0 : 1);
})();
