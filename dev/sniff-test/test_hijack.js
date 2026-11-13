// 「点播放即接管」(no_autoplay.js) 行为测试
// 核心要求：能拿到 http 直链 → 页面不播、交给 App；
//           拿不到（blob:/MSE、小窗广告、非用户点击）→ 必须原样放行，不能出现「点了没反应」
const fs = require('fs');
const { JSDOM } = require('jsdom');

process.on('unhandledRejection', () => {});

const PAGE = `<!doctype html><html><head><title>测试播放页</title></head>
<body><video id="v"></video></body></html>`;

function makeDom() {
  const dom = new JSDOM(PAGE, {
    url: 'https://www.moviesite.example.com/play/1.html',
    runScripts: 'outside-only',
    pretendToBeVisual: true,
  });
  const w = dom.window;
  // jsdom 的 play() 只是 not-implemented 桩，换成可观测的假实现
  w.__origPlay = 0;
  w.HTMLMediaElement.prototype.play = function () {
    w.__origPlay++;
    return Promise.resolve();
  };
  w.__actions = [];
  w.videoAction = { postMessage: (s) => w.__actions.push(JSON.parse(s)) };
  return dom;
}

function setupVideo(w, src, box) {
  const v = w.document.getElementById('v');
  if (src) v.setAttribute('src', src);
  Object.defineProperty(v, 'currentSrc', { value: src || '', configurable: true });
  Object.defineProperty(v, 'paused', { value: true, writable: true, configurable: true });
  const b = box || { left: 0, top: 0, width: 1280, height: 720, right: 1280, bottom: 720 };
  Object.defineProperty(v, 'getBoundingClientRect', { value: () => b });
  return v;
}

// 模拟用户点击播放器（脚本靠 pointerdown/touchstart 记录手势 + 坐标命中 video）
function tap(w, v) {
  v.dispatchEvent(new w.MouseEvent('pointerdown', { bubbles: true, clientX: 640, clientY: 360 }));
}

const HLS = 'https://cdn.example.com/hls/a/index.m3u8';
const MP4 = 'https://cdn.example.com/v/12345.mp4';
const BLOB = 'blob:https://www.moviesite.example.com/9f1c';
const SIGNED = 'https://cdn.example.com/v/abc?sign=x&exp=1';

async function scenario(name, opts) {
  const dom = makeDom();
  const w = dom.window;
  const v = setupVideo(w, opts.src, opts.box);
  w.eval(fs.readFileSync(__dirname + '/../../assets/no_autoplay.js', 'utf8'));
  w.__vdlHijackEnabled = opts.hijack === true; // 实时读取，注入后再开也生效
  if (opts.tap) tap(w, v);
  let err = '';
  try {
    await v.play();
  } catch (e) {
    err = e && e.name ? e.name : 'error';
  }
  const plays = w.__actions.filter((a) => a.action === 'play');
  const out = {
    name,
    hijacked: plays.length > 0,
    url: plays.length ? plays[0].url : '',
    referer: plays.length ? plays[0].referer : '',
    origPlay: w.__origPlay,
    err,
  };
  w.close();
  return out;
}

(async () => {
  const cases = [
    { name: '① 接管开 + m3u8 直链 + 用户点击', src: HLS, hijack: true, tap: true,
      want: { hijacked: true, origPlay: 0 } },
    { name: '② 接管开 + mp4 直链 + 用户点击', src: MP4, hijack: true, tap: true,
      want: { hijacked: true, origPlay: 0 } },
    { name: '③ 接管开 + blob:(MSE) + 用户点击', src: BLOB, hijack: true, tap: true,
      want: { hijacked: false, origPlay: 1 } },
    { name: '④ 接管开 + 无扩展名签名直链 + 点击', src: SIGNED, hijack: true, tap: true,
      want: { hijacked: false, origPlay: 1 } },
    { name: '⑤ 接管关 + m3u8 + 用户点击', src: HLS, hijack: false, tap: true,
      want: { hijacked: false, origPlay: 1 } },
    { name: '⑥ 接管开 + m3u8 + 无人点击(自动播)', src: HLS, hijack: true, tap: false,
      want: { hijacked: false, origPlay: 0 } },
    { name: '⑦ 接管开 + 160x90 小窗广告 + 点击', src: HLS, hijack: true, tap: true,
      box: { left: 0, top: 0, width: 160, height: 90, right: 160, bottom: 90 },
      want: { hijacked: false, origPlay: 1 } },
  ];

  let fail = 0;
  for (const c of cases) {
    const r = await scenario(c.name, c);
    const ok = r.hijacked === c.want.hijacked && r.origPlay === c.want.origPlay;
    if (!ok) fail++;
    console.log(
      (ok ? '✅' : '❌') + ' ' + c.name,
      '| 接管=' + r.hijacked,
      '| 页面播=' + r.origPlay,
      r.url ? '| ' + r.url.replace('https://', '') : '',
      r.err ? '| 站点收到=' + r.err : ''
    );
    if (c.name.indexOf('m3u8 直链') >= 0) {
      const refOk = r.referer === 'https://www.moviesite.example.com/play/1.html';
      console.log('   Referer 透传：', refOk ? '✅ ' + r.referer : '❌ "' + r.referer + '"');
      if (!refOk) fail++;
    }
  }
  console.log('\n结论：' + (fail === 0 ? '全部通过（7/7）' : fail + ' 项未通过'));
  process.exit(fail === 0 ? 0 : 1);
})();
