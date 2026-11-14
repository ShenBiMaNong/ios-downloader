# 嗅探判定 / 播放接管 回归测试（jsdom）

八个测试（`npm test` 串联执行），都跑在 jsdom 里，不参与 App 构建：

- `test_ab.js`：验证 `assets/sniffer.js` 在「站点多线路试探」场景下能否挑出**真正能用**的那条 m3u8，并与 `baseline/sniffer_v1.js`（冻结的 v1）做 A-B 对照。
- `test_hijack.js`：验证 `assets/no_autoplay.js` 的「点播放即接管」——该接管时接管，该放行时必须放行（不能出现「点了没反应」）。
- `test_verify_card.js`：验证标记层的两件事——① 页面从没请求过的线路能否在打开操作卡时被现场校验（`?` → `✓/✗`）；② 弹层关闭规则（卡片内滚动不关、页面滚动才关）。
- `test_pick_dur.js`：验证「多条 m3u8 都能通、下载出来却是别的视频」——播放锚定必须同时满足 `Σ#EXTINF ≈ video.duration`，同分的预加载下一集/预卷广告不得被认成正在播的那条。
- `test_marker_lazy.js`：验证「角标什么时候该出来」——站点懒赋 `src`（点播放才给地址）时，只要嗅探器拿得到候选就必须**不点也出角标**；什么都没有时主播放器立中性角标，地址一到卡片自动升级；小窗尺寸不给角标。
- `test_marker_early.js`：验证「刷新后角标不出、开关关→开就有了」这条链路——极早注入（`<body>` 尚未创建）后页面解析出 `<video>` 必须自动出角标；shadow root 内的 `<video>`（自绘播放器）与 `video.srcObject`（`src` 全空）不能漏；同源 iframe 内的 `<video>` 由主帧收集且坐标要换算 iframe 偏移；`__vdlBadge` 残留（指向已脱离文档的 badge）不能挡住重建；`__vdlCleanup` 后重新注入必须重建角标。
- `test_swipe.js`：验证左右滑动手势（`browser_swipe.js`）——右滑=back、左滑=forward 且一次手势只发一条消息（脚本幂等）；输入框/contenteditable、文本选区、双指、慢速拖拽、纵向主导、位移不足、横向滚动容器未到边界一律不触发；触发后合成 click 被吞掉、正常点击不受影响。
- `test_diag.js`：验证**诊断本身不骗人**（对应 App 内「更多 → 嗅探诊断（当前页）」面板）——嗅探快照带版本/注入元信息/钩子标记/统计/事件；站点覆盖 `window.fetch` 后必须报 `fetchHooked=false`；角标开关关闭时仍留最小快照（能区分「关了」与「没注入」）；`badged` / `skipped:no-src-small` / `hidden:offscreen` / `hidden:zero-size` 四种状态逐个可辨；`markerDiag` 上报必须带原因串与候选统计。

## 跑法

```bash
cd dev/sniff-test
npm install        # 只装 jsdom
npm test           # 四个都跑；也可单独 node test_ab.js 等
```

退出码 0 = 全部通过。

## 覆盖的场景

| 场景 | 输入 | 期望 |
|---|---|---|
| A 多线路试探 | 4 条候选：1 条 200+`#EXTM3U`、1 条 404、1 条 200+HTML 错误页、1 条网络错误 | v1 选到坏链（复现问题），v2 选到可用那条 |
| A' 标记层 | 同上，注入 `video_marker.js` | 角标显示 `HLS ✓`，线路列表 4 条且 `✓/✗` 标注正确，选中项可手动切换并重绘 |
| B 清单走 Worker | 清单请求不经主线程（拿不到），只有播放后的分片 URL 出现在资源时间线 | 靠分片目录前缀匹配定位到 `/hls/c/` 那条 |
| C 原生 HLS | `video.currentSrc` 直接是 m3u8（iOS WKWebView 路径） | 直接认元素 src，不被脚本里的其他候选干扰 |
| D1 MSE + `data-url` | `video.src` 是 `blob:`，真地址只在父级 `.dplayer[data-url]`，**全程没有任何网络请求**（复刻 DPlayer 系站点） | 从属性拿到 m3u8，score 550 / `src=attr`；旧版这里是空的 |
| D2 签名过期 | 同上，但 `auth_key` 时间戳已过 | `best()` 不推荐它，`why=expired`（UI 提示刷新页面重新嗅探） |
| D3 属性旁没有播放器 | 只有一个孤立的 `data-url`（备用线路/广告位） | 只给 350，让位于任何实测证据 |
| D4 相对路径 / 转义 | `data-url="/hls/x.m3u8"`、脚本里 `\u0026` | 归一成绝对地址、转义还原成 `&`（否则 query 错位必 403） |
| D5 标记层（blob） | D1 页面 + `video_marker.js` | 角标变 `HLS ?`，卡片出下载动作，不再是「未捕获到可下载直链」 |
| E 主动校验 | 3 条线路只写在 `<script>` 里、页面从不请求；卡片打开后 `verify()` 现场探 | 200+`#EXTM3U` → ✓、404 → ✗（带状态码）、200+HTML → ✗；`best()` 落到可用那条 |
| G 探测被拒 | 候选 URL 的 fetch 直接 reject（无 CORS 头 / 断连） | 保持 `guess`，**不得判死**（探测失败 ≠ 链接坏） |
| F 弹层关闭 | 卡片内滚动 / 卡片内点击 / 页面滚动 / 点页面空白 | 前两者保持打开，后两者关闭 |
| H 时长锚定 | 预卷广告(30s)、下一集(2410s)、主视频(2712s) 三条都 200+合法清单，按「广告→下一集→主视频」顺序请求 | 只锚定主视频（2712s ≈ 页面 duration）；页面时长与三者都不符时不锚定任何一条 |
| P1 懒赋 src + `data-url` | `<video>` 没有 `src`，真地址只在 `.dplayer[data-url]`，全程**不点击** | 1s 轮询内就出角标 `HLS ?`（旧版 `if (!src) continue` → 永远不出） |
| P2 占位角标升级 | 无 `src`、无候选、主播放器尺寸 | 中立 `视频` 角标 + 「尚未捕获地址」卡片；赋 `src` 后卡片自动变成可下载（无需重开） |
| P3 小窗尺寸 | 160×90 | 不给角标（广告位/预览视频不挂） |
| P4 无扩展名地址 | `src=https://…/v/play?id=9527` | 出角标 + 卡片有「立即播放 / 下载视频 / 复制链接」 |

H 场景做过 A-B 对照：把时长比对去掉（等价改前逻辑）后，锚定对象变成**广告**、
`best('hls')` 返回广告 URL —— 这就是「列表里好几条都能通，下载出来却是别的视频」
的复现路径。

另外 A 里对同一页面连续注入两次 `sniffer.js`，验证幂等（Dart 在
`onPageStarted` + `onPageFinished` 各注入一次，不会重复包装 fetch/XHR）。

## 诊断面板（test_diag.js）

| 编号 | 输入 | 期望 |
|---|---|---|
| 诊1 | 正常注入后发 2 个 fetch（1 个 `#EXTM3U`、1 个 404） | 快照有版本/注入次数/`hook.readyState`；`fetchHooked`/`xhrHooked` 均为真；`stats.fetch=2`；候选 `ok=1`、`dead=1`；事件含 `new/ok/dead` |
| 诊2 | 注入后站点重新赋值 `window.fetch` | `fetchHooked=false`（面板据此标「钩子丢失」，而不是继续报正常） |
| 诊3 | `__vdlMarkEnabled=false` | 仍能调 `__vdlMarkerDiag()`，返回 `installed=false / enabled=false / videos=-1`，页面无角标 |
| 诊4 | 4 个 video：正常大播放器 / 160×90 无地址 / 视口外 / 0 尺寸 | 角标 3 个；状态依次为 `badged`、`skipped:no-src-small`、`hidden:offscreen`、`hidden:zero-size`；事件含对应 `skip`/`hide` |
| 诊5 | 同上，等 2.5s 的 boot 上报 | `markerDiag` 带 `items` 原因串、`cands/hooks/injects` 字段 |

## 接管场景（test_hijack.js）

| 场景 | 期望 |
|---|---|
| 接管开 + m3u8/mp4 直链 + 用户点击 | 接管，页面**不播**，回传 url + 当前帧 Referer |
| 接管开 + `blob:`(MSE) + 点击 | 不接管，页面自己播 |
| 接管开 + 无扩展名签名直链 + 点击 | 不接管，页面自己播（认不出来就别乱接管） |
| 接管关 + m3u8 + 点击 | 不接管，页面自己播 |
| 接管开 + m3u8 + 无人点击（自动播） | 不接管，且被「禁止自动播放」拦下 |
| 接管开 + 160×90 小窗广告 + 点击 | 不接管，页面自己播 |

最后两类是防误伤的关键：没有手势判据和尺寸判据，接管的就不只是用户想看的那个视频了。

## 开关热切换（test_autoplay_toggle.js / test_autoplay_rootcause.js）

针对「浏览器菜单里开关点了没反应、要再点一次才生效」的排查脚本，两个都只读
`assets/no_autoplay.js`，并精确复刻 `BrowserPage._injectNoAutoplay()` 的调用序列：

- `test_autoplay_toggle.js`：**行为基线** —— 同一文档内反复开关、开关与「点播放即接管」
  组合、`<video autoplay>` 属性回归，期望全部即时生效（当前通过）。
- `test_autoplay_rootcause.js`：**根因取证** —— 证明跨文档 / 跨域 iframe / 并发注入
  三种情况下开关会失真：
  | 编号 | 现象 |
  |---|---|
  | T1 | 关一次再开，`sessionStorage.__vdlNoAutoplay` 仍是 `"0"`（开值从不落盘） |
  | T2 | 新文档 atDocumentStart 按 `"0"` 执行 → 开关显示「开」但初期不拦 |
  | T3 | 跨域 iframe 有独立会话 → 关掉开关后 iframe 里的播放器仍被拦 |
  | T4 | 页面加载注入（旧值）与菜单点击（新值）并发时，晚到的旧值覆盖新值 |

## 改动嗅探逻辑时

先跑这个测试再上真机。`baseline/sniffer_v1.js` 是**冻结**的对照样本，不要更新它 ——
它是用来证明「新版确实比旧版选得准」的基准。
