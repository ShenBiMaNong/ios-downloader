// 「嗅探诊断」回归测试（jsdom）
//
// 现场反馈：视频嗅探/角标「有时显示有时不显示」，没有规律。于是加了三条诊断通路：
//   1) __vdlSniff.diag()      —— 钩子是否还在、注入方式/代次、候选池统计、事件时间线
//   2) __vdlMarkerDiag()      —— 每个 <video> 为什么有/没有角标（badged/hidden/skipped/unbadged）
//   3) markerDiag 上报        —— 面板关着时也能从系统日志看到现场快照
//
// 本测试锁定的就是「诊断本身别再骗人」：
//   D1 嗅探快照：版本/注入元信息/钩子标记/统计/fetch 与 XHR 两条通路/候选状态/事件
//   D2 站点覆盖 window.fetch 后，快照必须报 fetchHooked=false（否则面板会说“一切正常”）
//   D3 角标开关关闭：脚本 early-return，但仍要留一个能解释自己的最小快照
//   D4 角标状态：badged / skipped:no-src-small / hidden:offscreen / hidden:zero-size 逐个可辨
//   D5 markerDiag 上报带上了 items（原因串）与候选统计，关掉面板也能回看
//
// 跑法：cd dev/sniff-test && node test_diag.js
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

const snifferJs = fs.readFileSync(__dirname + '/../../assets/sniffer.js', 'utf8');
const markerJs = fs.readFileSync(__dirname + '/../../assets/video_marker.js', 'utf8');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const HLS = 'https://cdn1.example.com/hls/a/index.m3u8?auth_key=1-2-3';
const DEAD = 'https://cdn1.example.com/hls/dead.m3u8';

// 模拟一个成功清单响应（fetch 通路会 clone 后读内容定性）
function okManifest(u) {
  return {
    ok: true,
    status: 200,
    url: String(u),
    headers: {
      get: (k) => (String(k).toLowerCase() === 'content-type' ? 'application/vnd.apple.mpegurl' : ''),
    },
    clone() { return this; },
    text() { return Promise.resolve('#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:10,\nseg1.ts\n'); },
  };
}

function baseDom(html, url) {
  const dom = new JSDOM(html, {
    url: url || 'https://www.moviesite.example.com/play/12345.html',
    runScripts: 'outside-only',
    pretendToBeVisual: true,
    virtualConsole: quietVC(),
  });
  const w = dom.window;
  w.performance.getEntriesByType = () => [];
  w.fetch = (u) => {
    const s = String(u);
    if (s.indexOf('dead') >= 0) {
      return Promise.resolve({ ok: false, status: 404, url: s, headers: { get: () => '' } });
    }
    return Promise.resolve(okManifest(s));
  };
  return { dom, w };
}

// ── D1 + D2. 嗅探快照 & 钩子被站点覆盖的可检测性 ──────────────────────────
async function runSnifferDiag() {
  const { w } = baseDom('<!doctype html><html><head><title>诊断页</title></head><body>无视频</body></html>');
  w.__vdlSniffVia = 'early'; // 模拟 WKUserScript 早注入
  w.eval(snifferJs);
  const d0 = w.__vdlSniff.diag();

  await w.fetch(HLS);
  await w.fetch(DEAD);
  await sleep(60); // 等 clone().text() 落定
  // 晚到的 Dart 兜底注入：同一文档再执行一次 → 只更新注入元信息，不得清空统计/事件
  w.__vdlSniffVia = 'dart';
  w.eval(snifferJs);
  const d1 = w.__vdlSniff.diag();

  // 站点在注入后重新赋值 fetch（真实站点常见）→ 钩子应被识别为丢失
  w.fetch = function () { return Promise.resolve({ ok: true, status: 200 }); };
  const d2 = w.__vdlSniff.diag();

  w.close();
  return { d0, d1, d2 };
}

// ── D3. 角标开关关闭：最小快照 ───────────────────────────────────────────
async function runMarkerDisabled() {
  const { dom, w } = baseDom(
    '<!doctype html><html><body><video id="a" src="' + HLS + '"></video></body></html>'
  );
  w.__vdlMarkEnabled = false;
  w.eval(markerJs);
  await sleep(1200);
  const hasFn = typeof w.__vdlMarkerDiag === 'function';
  const d = hasFn ? w.__vdlMarkerDiag() : null;
  const badges = w.document.querySelectorAll('.vdl-badge').length;
  w.close();
  return { hasFn, d, badges };
}

// ── D4 + D5. 四种角标状态 + 上报字段 ────────────────────────────────────
async function runMarkerStates() {
  const html = `<!doctype html><html><head><title>状态页</title></head><body>
    <video id="a" src="${HLS}"></video>
    <video id="b"></video>
    <video id="c" src="https://cdn2.example.com/hls/c/index.m3u8"></video>
    <video id="d" src="https://cdn2.example.com/hls/d/index.m3u8"></video>
  </body></html>`;
  const { dom, w } = baseDom(html);
  const rects = {
    // 正常大播放器 → badged
    a: { left: 0, top: 0, width: 1280, height: 720 },
    // 无地址的小窗 → 刻意跳过（不是 bug）
    b: { left: 0, top: 100, width: 160, height: 90 },
    // 大播放器但在视口外 → 角标建了但 place() 隐藏
    c: { left: 0, top: 5000, width: 1280, height: 720 },
    // 尺寸为 0 → 隐藏原因是 zero-size（和 offscreen 区分开）
    d: { left: 0, top: 10, width: 0, height: 0 },
  };
  for (const id of Object.keys(rects)) {
    const v = w.document.getElementById(id);
    const r = rects[id];
    Object.defineProperty(v, 'getBoundingClientRect', {
      value: () => ({
        left: r.left, top: r.top, width: r.width, height: r.height,
        right: r.left + r.width, bottom: r.top + r.height,
      }),
    });
    Object.defineProperty(v, 'paused', { value: true, writable: true, configurable: true });
  }
  const posts = [];
  w.videoAction = { postMessage: (s) => { try { posts.push(JSON.parse(s)); } catch (e) {} } };

  w.__vdlMarkVia = 'early'; // 模拟 WKUserScript 早注入
  w.eval(markerJs);
  await sleep(1300); // 等一次 1s 轮询
  const d = w.__vdlMarkerDiag();
  const badges = w.document.querySelectorAll('.vdl-badge').length;
  await sleep(1400); // 等 2.5s 的 boot 上报
  const diagPost = posts.find((p) => p.action === 'markerDiag') || null;
  w.close();
  return { d, badges, diagPost };
}

(async () => {
  const s = await runSnifferDiag();
  console.log('===== D1. 嗅探快照（__vdlSniff.diag） =====');
  console.log('版本/注入  :', s.d0.v, '| via=' + JSON.stringify(s.d0.via),
    '| injects=' + s.d0.injects, /^sniff-/.test(s.d0.v) ? '✅' : '❌');
  console.log('来源区分   :', '安装=' + JSON.stringify(s.d1.via),
    '最近=' + JSON.stringify(s.d1.lastVia),
    s.d1.via === 'early' && s.d1.lastVia === 'dart' && s.d1.injects === 2
      ? '✅ 兜底补注入不冒领安装来源' : '❌');
  console.log('文档时间点 :', 'readyState=' + JSON.stringify(s.d0.readyState),
    '| hook.readyState=' + JSON.stringify(s.d0.hook && s.d0.hook.readyState),
    s.d0.hook && /^(loading|interactive|complete)$/.test(s.d0.hook.readyState || '') ? '✅' : '❌');
  console.log('钩子标记   :', 'fetch=' + s.d1.fetchHooked, 'xhr=' + s.d1.xhrHooked,
    'rawFetchKept=' + s.d1.rawFetchKept,
    s.d1.fetchHooked && s.d1.xhrHooked ? '✅' : '❌');
  console.log('统计       :', JSON.stringify(s.d1.stats),
    s.d1.stats.fetch >= 2 && s.d1.stats.xhr === 0 ? '✅' : '❌');
  console.log('候选统计   :', JSON.stringify(s.d1.counts),
    s.d1.counts.ok >= 1 && s.d1.counts.dead >= 1 ? '✅' : '❌');
  const evTypes = new Set((s.d1.events || []).map((e) => e.ev));
  console.log('事件类型   :', [...evTypes].join(','),
    evTypes.has('new') && evTypes.has('ok') && evTypes.has('dead') ? '✅' : '❌');

  console.log('===== D2. 站点覆盖 fetch 后钩子丢失可被看见 =====');
  console.log('fetchHooked:', s.d2.fetchHooked,
    s.d2.fetchHooked === false ? '✅ 面板会标「钩子丢失」' : '❌ 仍报正常，诊断会骗人');

  const m = await runMarkerDisabled();
  console.log('===== D3. 角标开关关闭 → 最小快照 =====');
  console.log('有 diag 函数:', m.hasFn, m.hasFn ? '✅' : '❌');
  console.log('快照       :', m.d
    ? `installed=${m.d.installed} enabled=${m.d.enabled} videos=${m.d.videos} items=${(m.d.items || []).length} ✅`
    : '❌ 没有快照，分不清「关了」和「没注入」');
  console.log('角标数量   :', m.badges, m.badges === 0 ? '✅' : '❌ 开关关了还在画角标');

  const st = await runMarkerStates();
  console.log('===== D4. 每个 video 的状态可辨 =====');
  console.log('角标数量   :', st.badges, st.badges === 3 ? '✅' : '❌ 应为 3（b 刻意跳过）');
  console.log('汇总       :', `videos=${st.d.videos} marked=${st.d.marked} shown=${st.d.shown} hidden=${st.d.hidden}`,
    st.d.videos === 4 && st.d.marked === 3 && st.d.shown === 1 && st.d.hidden === 2 ? '✅' : '❌');
  console.log('注入来源   :', 'via=' + JSON.stringify(st.d.via),
    st.d.via === 'early' ? '✅' : '❌');
  const states = (st.d.items || []).map((i) => i.state);
  console.log('逐条状态   :', JSON.stringify(states),
    JSON.stringify(states) === JSON.stringify([
      'badged', 'skipped:no-src-small', 'hidden:offscreen', 'hidden:zero-size',
    ]) ? '✅' : '❌');
  const mevTypes = (st.d.events || []).map((e) => e.ev + (e.x ? ':' + e.x : ''));
  console.log('事件       :', mevTypes.slice(-8).join(' | '),
    mevTypes.some((x) => x === 'skip:no-src-small') &&
    mevTypes.some((x) => x === 'hide:offscreen') &&
    mevTypes.some((x) => x === 'hide:zero-size') ? '✅' : '❌');

  console.log('===== D5. markerDiag 上报（面板关着也能回看） =====');
  console.log('上报       :', st.diagPost
    ? `frame=${st.diagPost.frame} badged=${st.diagPost.badged} hidden=${st.diagPost.hidden} items=${JSON.stringify(st.diagPost.items)} ✅`
    : '❌ 没收到 markerDiag');
  console.log('字段齐全   :',
    st.diagPost &&
    Object.prototype.hasOwnProperty.call(st.diagPost, 'cands') &&
    Object.prototype.hasOwnProperty.call(st.diagPost, 'hooks') &&
    Object.prototype.hasOwnProperty.call(st.diagPost, 'injects')
      ? `cands=${st.diagPost.cands} hooks=${JSON.stringify(st.diagPost.hooks)} injects=${st.diagPost.injects} ✅`
      : '❌ 上报缺字段');

  const okAll =
    /^sniff-/.test(s.d0.v) && s.d0.injects >= 1 &&
    s.d1.via === 'early' && s.d1.lastVia === 'dart' && s.d1.injects === 2 &&
    /^(loading|interactive|complete)$/.test((s.d0.hook && s.d0.hook.readyState) || '') &&
    s.d1.fetchHooked && s.d1.xhrHooked &&
    s.d1.stats.fetch >= 2 &&
    s.d1.counts.ok >= 1 && s.d1.counts.dead >= 1 &&
    evTypes.has('new') && evTypes.has('ok') && evTypes.has('dead') &&
    s.d2.fetchHooked === false &&
    m.hasFn && m.d && m.d.installed === false && m.d.enabled === false && m.badges === 0 &&
    st.badges === 3 && st.d.videos === 4 && st.d.marked === 3 && st.d.via === 'early' &&
    JSON.stringify(states) === JSON.stringify([
      'badged', 'skipped:no-src-small', 'hidden:offscreen', 'hidden:zero-size',
    ]) &&
    !!st.diagPost && typeof st.diagPost.items === 'string' &&
    /skipped:no-src-small/.test(st.diagPost.items);
  console.log('\n结论：' + (okAll ? '全部通过' : '存在未通过项，需复查'));
  process.exit(okAll ? 0 : 1);
})();
