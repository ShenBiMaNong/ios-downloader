// 「多条 m3u8 都能通，下载出来的却是别的视频」的回归测试（jsdom）
//
// 现场形态：主视频 + 预加载的下一集 + 预卷广告，三条清单都是 200、都是合法
// #EXTM3U，分数全是 S_OK_BODY，谁也压不住谁 —— 旧逻辑「最近一次请求的那条
// 就是正在播的」会把刚预取的广告/下一集锚成 S_PLAY，用户点下载就下错片。
//
// 本测试验证：锚定必须同时满足「清单 Σ#EXTINF ≈ 页面 video.duration」。
//
// 跑法：cd dev/sniff-test && node test_pick_dur.js
const fs = require('fs');
const { JSDOM, VirtualConsole } = require('jsdom');

function quietVC() {
  const vc = new VirtualConsole();
  vc.on('jsdomError', (e) => {
    const m = String((e && (e.detail || e.message)) || e);
    if (/Cannot read properties of undefined \(reading '(querySelectorAll|body)'\)/.test(m)) return;
    if (/Not implemented: HTMLMediaElement/.test(m)) return;
    console.error('jsdomError:', m);
  });
  return vc;
}
process.on('unhandledRejection', () => {});

const MAIN = 'https://cdn1.example.com/hls/main/index.m3u8'; // 2712s  ← 正在播
const NEXT = 'https://cdn1.example.com/hls/next/index.m3u8'; // 2410s  预加载的下一集
const AD = 'https://ad.example.com/hls/preroll/index.m3u8'; // 30s    预卷广告

// 生成一段总时长 = want 秒的合法 media 清单（每片 6s）
function playlist(want) {
  const n = Math.round(want / 6);
  let s = '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n';
  for (let i = 0; i < n; i++) s += '#EXTINF:6.0,\nseg_' + i + '.ts\n';
  return s + '#EXT-X-ENDLIST\n';
}

const ROUTES = {
  [MAIN]: playlist(2712),
  [NEXT]: playlist(2410),
  [AD]: playlist(30),
};

// 页面请求顺序 = 预卷广告 → 预加载的下一集 → 主视频。
// 这个顺序是有意的：旧逻辑「遍历候选取第一个最高分、同分不替换」会停在最先插入
// 的广告上，于是锚定到 AD —— 正是「列表里好几条都能通，下载出来的却是别的视频」。
// 只有把时长比对加进去，才能在三条同分候选里认出真正在播的那条。
const REQ_ORDER = [AD, NEXT, MAIN];
const PAGE = `<!doctype html><html><head><title>测试播放页</title></head>
<body><video id="v" width="1280" height="720"></video></body></html>`;

function fakeFetch(url) {
  const body = ROUTES[url];
  if (body == null) return Promise.reject(new TypeError('Load failed'));
  return Promise.resolve({
    ok: true,
    status: 200,
    headers: { get: (k) => (k.toLowerCase() === 'content-type' ? 'application/vnd.apple.mpegurl' : null) },
    text: () => Promise.resolve(body),
    clone() { return { text: () => Promise.resolve(body) }; },
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function makeDom(pageDur) {
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
  // MSE：src 是 blob，清单 URL 只能从候选池推断
  Object.defineProperty(v, 'currentSrc', { value: 'blob:https://www.moviesite.example.com/9f1c', configurable: true });
  Object.defineProperty(v, 'paused', { value: false, configurable: true });
  Object.defineProperty(v, 'currentTime', { value: 120, configurable: true });
  Object.defineProperty(v, 'duration', { value: pageDur, configurable: true });
  Object.defineProperty(v, 'getBoundingClientRect', {
    value: () => ({ left: 0, top: 0, width: 1280, height: 720, right: 1280, bottom: 720 }),
  });
  return { dom, w, v };
}

const scoreOf = (w, u) => {
  const d = w.__vdlSniff.dump().find((x) => x.url === u);
  return d ? d.score : -1;
};

// A. 时长能对上 → 必须锚定到主视频，而不是最后请求的广告
async function anchorByDuration() {
  const { dom, w } = makeDom(2712);
  w.eval(fs.readFileSync(__dirname + '/../../assets/sniffer.js', 'utf8'));
  for (const u of REQ_ORDER) await w.fetch(u);
  await sleep(2600); // 等播放锚定轮询（sniffer 兜底轮询 2s 一轮）
  const out = {
    main: scoreOf(w, MAIN),
    next: scoreOf(w, NEXT),
    ad: scoreOf(w, AD),
    best: (w.__vdlSniff.best('hls') || {}).url || '',
  };
  w.close();
  return out;
}

// B. 时长一条都对不上（页面 1800s）→ 不许锚定任何一条
async function noAnchorWhenNoneMatches() {
  const { dom, w } = makeDom(1800);
  w.eval(fs.readFileSync(__dirname + '/../../assets/sniffer.js', 'utf8'));
  for (const u of REQ_ORDER) await w.fetch(u);
  await sleep(2600);
  const out = {
    main: scoreOf(w, MAIN),
    next: scoreOf(w, NEXT),
    ad: scoreOf(w, AD),
  };
  w.close();
  return out;
}

(async () => {
  let fail = 0;
  const bad = (m) => { fail++; console.log('❌ ' + m); };
  const ok = (m) => console.log('✅ ' + m);

  console.log('===== A. 清单时长与页面一致 → 锚定主视频 =====');
  const A = await anchorByDuration();
  console.log(`   分数  main=${A.main}  next=${A.next}  ad=${A.ad}`);
  if (A.main >= 1000) ok('主视频拿到播放锚定（S_PLAY）');
  else bad(`主视频未锚定（score=${A.main}）`);
  if (A.ad < 1000) ok('广告没有被误锚成「正在播」');
  else bad('广告被误锚（score=' + A.ad + '）—— 正是「下到别的视频」的来源');
  if (A.best === MAIN) ok('best(hls) 返回主视频');
  else bad('best(hls) 返回了 ' + A.best);

  console.log('\n===== B. 时长全都不匹配 → 不锚定（宁可不标，也别标错） =====');
  const B = await noAnchorWhenNoneMatches();
  console.log(`   分数  main=${B.main}  next=${B.next}  ad=${B.ad}`);
  const anchored = [B.main, B.next, B.ad].filter((s) => s >= 1000);
  if (anchored.length === 0) ok('没有候选被误标为「正在播」');
  else bad(anchored.length + ' 条候选被误锚定');

  console.log('\n' + (fail ? `FAIL（${fail} 项）` : 'PASS'));
  process.exit(fail ? 1 : 0);
})();
