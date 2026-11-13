# 嗅探判定 / 播放接管 回归测试（jsdom）

两个测试，都跑在 jsdom 里，不参与 App 构建：

- `test_ab.js`：验证 `assets/sniffer.js` 在「站点多线路试探」场景下能否挑出**真正能用**的那条 m3u8，并与 `baseline/sniffer_v1.js`（冻结的 v1）做 A-B 对照。
- `test_hijack.js`：验证 `assets/no_autoplay.js` 的「点播放即接管」——该接管时接管，该放行时必须放行（不能出现「点了没反应」）。

## 跑法

```bash
cd dev/sniff-test
npm install        # 只装 jsdom
npm test           # 两个都跑；也可单独 node test_ab.js / node test_hijack.js
```

退出码 0 = 全部通过。

## 覆盖的场景

| 场景 | 输入 | 期望 |
|---|---|---|
| A 多线路试探 | 4 条候选：1 条 200+`#EXTM3U`、1 条 404、1 条 200+HTML 错误页、1 条网络错误 | v1 选到坏链（复现问题），v2 选到可用那条 |
| A' 标记层 | 同上，注入 `video_marker.js` | 角标显示 `HLS ✓`，线路列表 4 条且 `✓/✗` 标注正确，选中项可手动切换并重绘 |
| B 清单走 Worker | 清单请求不经主线程（拿不到），只有播放后的分片 URL 出现在资源时间线 | 靠分片目录前缀匹配定位到 `/hls/c/` 那条 |
| C 原生 HLS | `video.currentSrc` 直接是 m3u8（iOS WKWebView 路径） | 直接认元素 src，不被脚本里的其他候选干扰 |

另外 A 里对同一页面连续注入两次 `sniffer.js`，验证幂等（Dart 在
`onPageStarted` + `onPageFinished` 各注入一次，不会重复包装 fetch/XHR）。

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

## 改动嗅探逻辑时

先跑这个测试再上真机。`baseline/sniffer_v1.js` 是**冻结**的对照样本，不要更新它 ——
它是用来证明「新版确实比旧版选得准」的基准。
