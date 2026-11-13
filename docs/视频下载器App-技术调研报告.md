# 视频下载器 App（iOS）技术调研报告

> 调研时间：2026-11 ｜ 开发环境约束：Windows 开发机 + GitHub Actions 云端 macOS 构建 + 免费 Personal Team 账号 + 私有仓库
> 关键结论均附官方文档 / GitHub / pub.dev 出处；无法验证处已标注「未能验证」。

---

## 1. 项目需求拆解

| 需求 | 对应技术组件 |
|---|---|
| 内置浏览器，可访问网站 | WKWebView（原生）或 webview_flutter（Flutter） |
| 识别网页中的视频 | JS 注入嗅探（fetch/XHR/video 元素钩子） |
| 视频缓存到本地 | AVAssetDownloadTask（HLS）或 URLSession（mp4 直链）或手动 m3u8 + ffmpeg |
| 本地查看（播放列表） | AVPlayer / video_player + 沙盒文件管理 |
| 其他 App 分享视频到本 App | iOS Share Extension（分享扩展） |

---

## 2. 调研结论速览（TL;DR）

1. **浏览器内视频识别：可行**。WKWebView 无法用原生 API 拦截 http/https 请求，**唯一可行路线是 JS 注入嗅探**（见 §3）。Flutter 与原生能力对等，两边同一套工作量。
2. **下载与缓存：可行，分三类场景**。HLS（VOD）走 Apple 原生 `AVAssetDownloadTask`；直链 mp4 走普通 URLSession；需要"合并成单个 mp4 文件"的 HLS 走手动分片下载 + ffmpeg 转封装（见 §4）。
3. **⚠️ 分享扩展：标准路线被免费账号卡死**。App Groups（扩展与主 App 共享数据的唯一官方方式）**需要付费 Apple Developer Program**，免费 Personal Team 用不了。免费账号只能走"剪贴板交接"降级方案（见 §5）。
4. **框架选型**：Flutter 被迫写的原生代码 = Share Extension（两方案都逃不掉）+ 一个 AVAssetDownloadTask 桥接（约 200-400 行 Swift）；原生 Swift 无桥接税但整包手写。Windows 约束对两方案公平（见 §6）。

---

## 3. 难点一：内置浏览器里的视频识别（WKWebView）

### 3.1 结论：无法原生拦截请求，只能 JS 注入

- `WKURLSchemeHandler`（iOS 11+）按 Apple 文档定义只能处理 **WebKit 不处理的自定义 scheme**（如 `app://`），http/https 属于 WebKit 自己处理的 scheme，不能注册。
  [WKURLSchemeHandler | Apple](https://developer.apple.com/documentation/webkit/wkurlschemehandler)
- `NSURLProtocol` 在 WKWebView 下**失效**：WKWebView 的请求/渲染在独立子进程完成，App 进程注册的 NSURLProtocol 根本看不到请求（SO 高票回答，作者为 Apple 工程师）。
  [SO #24208229](https://stackoverflow.com/questions/24208229/wkwebview-and-nsurlprotocol-not-working)
- `decidePolicyForNavigationAction` 只能看到页面级导航，**看不到 `<video>`、fetch、XHR、HLS 分片等子资源**。
- 私有 API（`registerSchemeForCustomProtocol`）可以做到但**不能上架**，本项目为个人 sideload，仍不建议。

### 3.2 推荐方案：JS 注入嗅探（四路并取）

注入 `WKUserScript`（`atDocumentStart` + `forMainFrameOnly: false` 覆盖跨域 iframe，iOS 14+ 用命名 `WKContentWorld` 隔离），四路抓取：

1. **扫描已有 `<video>` / `<source>` 元素**（`currentSrc || src`）；
2. **MutationObserver** 监听动态插入的视频元素；
3. **钩住 `fetch` 和 `XMLHttpRequest`**（很多播放器用它取 m3u8）；
4. **兜底轮询**（每 2 秒，防改 src 不触发事件）。

命中规则：`/\.(mp4|m3u8|mov|webm|ts)([?#]|$)/i`，去重后经 `WKScriptMessageHandler` 回传原生。

**JS 侧关键点**：`blob:` URL（MSE 流）不是可下载直链，只能降级提示"该视频不支持离线下载"；m3u8 与 mp4 分流转交不同下载器。

### 3.3 HLS 与直链 mp4 识别差异

| 维度 | 直链 mp4 | HLS (m3u8) |
|---|---|---|
| `video.src` | 直接是 `https://…/a.mp4`，一读即得 | 可能是 `https://…/index.m3u8`（可抓），也可能是 `blob:`（MSE，抓不到） |
| 分片（.ts） | 无 | 由媒体栈进程内自取，JS/原生都看不到 → 只能抓 m3u8 清单后原生解析下载 |
| 下载方式 | 一个 Range 请求 | 拉 master → 选 media playlist → 解析 `#EXTINF` 并发下载分片 |
| 加密 | 一般无 | 常见 AES-128（`#EXT-X-KEY`），需取 key 解密 |
| 反爬 | 偶见签名 URL | 常需 Referer / UA / Cookie |

### 3.4 可参考的开源实现（已逐一核实存在）

- **cliqx**（iOS 17+ WKWebView 浏览器，`WKContentWorld` 注入 + 全屏 + AVPlayer，架构文档最完整）→ 嗅探层参考
  https://github.com/SaiSamardh7/cliqx
- **YSMooxx/WKWebViewCaptureURL**（Swift 小 demo：video.src 轮询 + 消息回传）
  https://github.com/YSMooxx/WKWebViewCaptureURL
- **AappEEEE/M3U8Grab**（嗅探在系统层，App 内做 AES-128 解密 / TS 合并 / 断点续传）
  https://github.com/AappEEEE/M3U8Grab
- 下载层参考：**AriaM3U8Downloader**（Swift 6，并发/断点/AES-128）https://github.com/moxcomic/AriaM3U8Downloader ｜ **HLSDownloader** https://github.com/qi-shun-wang/HLSDownloader

> ⚠️ GitHub 上**不存在**"WKWebView 嗅探 + 下载"一体的成品级开源项目（搜索结果为 0），需自研组合：cliqx 式嗅探层 + AriaM3U8Downloader 式下载层。

---

## 4. 难点二：视频下载与本地缓存

### 4.1 三选一的决策矩阵

| 场景 | 推荐方案 | 理由 |
|---|---|---|
| HLS（VOD）离线播放 | **AVAssetDownloadTask** | Apple 原生通道，系统级后台下载/断点/存储策略；也支持 FairPlay DRM（需服务端配合） |
| 直链 mp4 | **URLSession 直接下载**到 Documents | 简单直接，无需 ffmpeg |
| HLS 需"合并成单个 mp4 文件"（导出/分享） | **手动下载分片 + ffmpeg remux**（`-c copy` 无损转封装） | AVAssetDownloadTask 产物是系统私有结构，无法导出为单文件 |
| 只想"边播边缓存、断网续播" | VIMediaCache / KTVHTTPCache（AVPlayer 代理缓存） | 零 ffmpeg 依赖，但 HLS 支持程度有限 |

### 4.2 AVAssetDownloadTask 要点（Apple 原生，iOS 9+，新 API 需 iOS 15+）

- 只支持 **HLS（VOD）**，直播流无法保存；不支持直链 mp4；
- 下载位置由系统决定，delegate 回调 `willDownloadTo` 给本地 URL——**必须保存，下次启动用它重建离线 AVURLAsset**；不要手动移动这些文件；
- 离线播放两种官方方式：复用原 AVURLAsset 建 AVPlayerItem（自动读缓存），或用本地 URL 重建 `AVURLAsset`；
- 后台下载依赖 background session，用户强杀 App 会取消下载。
- 文档：[AVAssetDownloadTask](https://developer.apple.com/documentation/avfoundation/avassetdownloadtask)、[Offline playback and storage](https://developer.apple.com/documentation/avfoundation/offline-playback-and-storage)、[官方示例](https://developer.apple.com/documentation/avfoundation/using-avfoundation-to-play-and-persist-http-live-streams)

### 4.3 ffmpeg 2025 年现状（已核实）

- **ffmpeg-kit 已退役**：仓库 archived、Releases 二进制全部下架、官方站点声明 "FFmpegKit has been officially retired"；pub.dev 的 `ffmpeg_kit_flutter` 标记 discontinued（最后 6.0.3，2023-09）。
  https://arthenica.github.io/ffmpeg-kit/ ｜ https://github.com/arthenica/ffmpeg-kit
- 官方续作 **FFmpegKitNext**：活跃但 **仅源码分发**（需 Nix/MSYS2 自建）。
  https://github.com/arthenica/ffmpeg-kit-next
- 现成替代：pub.dev 的 `ffmpeg_kit_flutter_new`（4.6.8，近期更新）、`ffmpeg_kit_extended_flutter`（1.0.0）；自编译 xcframework（可行但复杂）；SwiftFFmpeg（SPM 封装，需自备库）。
- **对本项目缓解**：本功能集不强依赖 ffmpeg——HLS 走 AVAssetDownloadTask，mp4 直链走 URLSession，ffmpeg 只在"合并单文件/转码"时需要，可后置。

### 4.4 本地存储与播放

- 存储结构建议：`Documents/Downloads/<videoId>/final.mp4` + 元数据 JSON；下载中间产物（.ts、改写 m3u8）放 tmp/Caches，完成后删除；
- 清理策略：按容量/时间 LRU，用 `volumeAvailableCapacityForImportantUsageKey` 检查空间；
- 播放：原生 AVPlayer；Flutter 用官方 `video_player`（底层即 AVPlayer）2.14.1，本地文件 `VideoPlayerController.file`；备选 media_kit（libmpv）。

---

## 5. 难点三：分享扩展（⚠️ 账号限制关键结论）

### 5.1 结论

> **标准路线（App Groups 共享容器）需要付费 Apple Developer Program（约 $99/年 ≈ 688 元/年），免费 Personal Team 账号用不了。**
> 免费账号下功能**可做，但只能走降级方案**：扩展解析链接 → 写剪贴板 → 用户打开主 App → 主 App 读取并下载。

**依据（Apple 官方文档原文）**：
- "The platform, and **whether you're a member of the Apple Developer Program**, may limit the capabilities available to your app."——能力可用性直接由是否为付费 Program 成员决定。
  [Adding capabilities to your app](https://developer.apple.com/documentation/xcode/adding-capabilities-to-your-app)
- App Group 需在开发者账户注册："Xcode retrieves any existing groups from your developer account… You need to register app groups for iOS…"——免费 Personal Team 无此注册通道。
  [Configuring app groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)
- 扩展与主 App"没有直接通信"、互不可访问对方容器，唯一官方共享方式是 App Groups。
  [App Extension Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html)

### 5.2 免费账号下的替代方案

| 方案 | 可行性 | 限制 |
|---|---|---|
| **剪贴板交接（推荐）** | ✅ 可行，无需任何 entitlement | iOS 14+ 跨 App 读剪贴板弹系统提示；适合传 URL/文本；需用户打开主 App |
| 扩展内直接发网络请求 | ⚠️ 部分可行 | 前台下载可以但**文件存扩展自己的容器，主 App 读不到**；后台下载强制要求共享容器 |
| openURL 拉起主 App | ❌ 官方不支持 | Apple 文档明确仅 Today/Message 扩展支持；付费账号也不支持，可能影响审核 |

**免费账号推荐工作流**：Share Extension 接收链接（`public.url`）→ 扩展内跟随重定向解析 → 结果写剪贴板 → 用户打开主 App → 主 App 读剪贴板 → 解析 + 下载 + 入库。下载/播放/列表完全不受账号限制。

> 若要"分享 → 自动入库"的完整体验，长期建议升级付费账号（688 元/年），走 App Groups 标准路线。另外付费账号也是将来上架 App Store 的前提。

### 5.3 各平台分享链接形态

| 平台 | 分享形态 | 解析路径 | 参考实现 |
|---|---|---|---|
| 抖音 | `v.douyin.com/xxx` 短链 | 跟随重定向 → 页面内嵌 JSON 提取无水印 playAddr（非官方接口，易变） | [Douyin_TikTok_Download_API](https://github.com/Evil0ctal/Douyin_TikTok_Download_API)（21.4k★） |
| 快手 | `v.kuaishou.com/xxx` 短链 | 重定向 → 解析页面数据 | [KS-Downloader](https://github.com/JoeanAmier/KS-Downloader)、[res-downloader](https://github.com/putyy/res-downloader)（21.3k★） |
| B 站 | 视频页 URL / `b23.tv` 短链 | BV 号 → `api.bilibili.com` 取流，需 Referer + WBI 签名/Cookie | [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)（20.1k★，已归档但最全） |
| Safari 网页 | 网页 URL | 自行抓取页内 `<video>`/m3u8；可用 `ExtensionPreprocessingJS` 拿页面内容 | — |
| YouTube | `youtu.be/<ID>` 短链 | 重定向 → innertube 接口 + 签名解密（高难度） | [yt-dlp](https://github.com/yt-dlp/yt-dlp)（207k★） |

> 通用要点：URLSession 默认自动跟随重定向；抖音/快手等对请求头敏感，带移动端 Safari UA + Referer；所有"无水印"接口均为逆向产物，建议**服务端代理解析**避免把易碎逻辑塞进客户端。

---

## 6. 难点四：框架选型（Flutter vs 原生 Swift）

### 6.1 webview_flutter 能力核实（iOS 底层即 WKWebView，iOS 13+）

- ✅ `runJavaScript` / `runJavaScriptReturningResult`（= evaluateJavaScript）、`addJavaScriptChannel`（= WKScriptMessageHandler）、`NavigationDelegate`（导航代理）；
- ❌ **无请求拦截 API**（flutter/flutter#27896 自 2019 年 open，正文明确 iOS 无 per-webview 拦截机制）——与原生 WKWebView 能力对等，视频识别两边都走 JS 注入，工作量相同。
  [webview_flutter](https://pub.dev/packages/webview_flutter)

### 6.2 各功能所需原生代码量

| 功能 | Flutter | 原生 Swift |
|---|---|---|
| 浏览器（WKWebView） | 0（webview_flutter） | 直接写 |
| JS 注入 + 视频识别 | 0 原生（纯 Dart） | 直接写 |
| HLS 离线下载 | ~200-400 行 Swift 桥接（AVAssetDownloadTask channel） | 直接写 |
| Share Extension | **必须写原生 target**（两方案相同） | 直接写 |
| App Group 读共享 | 0（receive_sharing_intent 插件） | 直接写 |
| 本地列表 + 播放 | 0（path_provider + video_player） | 直接写 |

### 6.3 结论

- **iOS-only + Swift 熟练 → 原生 Swift 摩擦更小**（本功能集 4 项里 3 项直接摸 AVFoundation/WebKit）；
- **看重 UI 开发速度 / 未来要 Android / 团队 Dart 向 → Flutter 完全可行**，被迫的原生面仅为"Share Extension（两边都逃不掉）+ 一个下载桥接"，且有官方文档与成熟先例；
- **Windows 约束对两方案公平**：都靠 GitHub Actions macOS runner 云构建；Share Extension target、App Groups、签名等 Xcode 工程级操作**无法在 Windows GUI 完成**——两边都需要一次性在 Mac 上生成工程配置（或手改 `project.pbxproj`）后提交进仓库，CI 只做构建。Flutter 的 CI 文档反而更充分（`flutter build ipa` 可无头执行）。

---

## 7. 推荐技术架构（Flutter 路线示意）

```
┌─ 分享入口 ─────────────────────────────┐
│ Share Extension (原生Swift target)      │
│ 接收 URL → 重定向解析 → 写剪贴板        │
└──────────────┬─────────────────────────┘
               ▼ 打开主App读剪贴板
┌─ 主 App（Flutter）─────────────────────┐
│ ① 内置浏览器  webview_flutter           │
│    + JS注入嗅探(纯Dart) → 发现视频URL    │
│ ② 下载器                               │
│    mp4直链 → Dio/URLSession            │
│    HLS     → AVAssetDownloadTask桥接    │
│              (Swift Method/EventChannel)│
│ ③ 本地库                               │
│    Documents/Downloads/<id>/ + 元数据  │
│    video_player 播放列表查看            │
└────────────────────────────────────────┘
```

---

## 8. 免费账号 + Windows 下的可行产品形态（降级版）

| 功能 | 免费账号可行形态 |
|---|---|
| 内置浏览器 + 视频识别 | ✅ 完整（与账号无关） |
| 下载 + 本地缓存 + 播放 | ✅ 完整 |
| 分享扩展 | ⚠️ 降级：扩展解析 → 剪贴板 → 打开主 App 导入；无 App Groups 自动入库 |
| 安装方式 | 未签名 IPA（CI 产出）→ Windows 端 Sideloadly/爱思助手 用 Apple ID 签名 → 7 天有效期，到期重签 |
| 分享扩展随 sideload 安装的兼容性 | ❓ **未能验证**，需真机实测（sideload 工具对扩展 target 的支持程度不一） |

---

## 9. 风险与合规

- **版权/服务条款**：抖音/快手/B 站/YouTube 的"去水印"下载普遍违反其服务条款；对 DRM（FairPlay/Widevine）内容手动抓流合并可能违法。建议定位为**个人自用工具**，界面明示"仅用于个人学习/备份，请勿传播"；
- **App Store**：视频下载器类 App 审核风险高，大概率被拒——本项目走个人 sideload 路线，天然规避审核，但也不要尝试上架；
- **技术易碎性**：各平台解析接口均为逆向产物、随时变更，建议解析逻辑服务端化；
- **不要用私有 API**（保持 sideload 也尽量干净，减少签名/安装问题）。

---

## 10. 开发路线建议（MVP 分期）

| 阶段 | 内容 | 产出 |
|---|---|---|
| **MVP-0 管线打通** | 最小 Demo App + GitHub Actions workflow 出未签名 IPA + Sideloadly 签名安装验证 | 跑通"代码 → IPA → 装机"全链路 |
| **MVP-1 核心功能** | 内置浏览器 + JS 嗅探 + mp4 直链下载 + 本地列表播放 | 可用的"浏览器下载器" |
| **MVP-2 HLS** | AVAssetDownloadTask 桥接 + m3u8 下载与离线播放 | 覆盖主流视频站 |
| **MVP-3 分享入口** | Share Extension（免费账号降级：剪贴板交接） | 其他 App 分享 → 导入 |
| **MVP-4 打磨** | 下载管理（暂停/断点/进度）、缓存清理、元数据、缩略图 | 完整产品 |
| 可选升级 | 付费账号（App Groups 自动入库、7 天限制解除依赖） | 完整"分享即入库"体验 |

> 说明：是否升级付费账号不影响前三个 MVP；付费账号主要解锁分享扩展标准路线与更自由的签名。

---

## 11. 未能验证清单（如实标注）

1. 免费 Personal Team "不能注册 App Group"的 Apple 官方单句表述（有官方"能力受 Program 成员资格限制"依据链，无单句引文）；
2. 各平台解析接口（抖音 playAddr、B 站 WBI、YouTube innertube）当前实时可用性；
3. Sideloadly/爱思助手 对带 Share Extension 的 App 的签名安装兼容性；
4. AVAssetDownloadTask 产物 `.movpkg` 用 video_player.file 直接播放的可行性（AVPlayer 理论可播，需真机验证）；
5. KTVHTTPCache / VIMediaCache 对 m3u8 分片的完整支持程度（README 主打 mp4 渐进式）；
6. ffmpeg-kit "2025 年 1 月停更"的具体日期（退役、归档、二进制下架均已核实）；
7. FFmpegKitNext 是否已有可直接依赖的 Flutter pub 包（官方声明 source-only）；
8. GitHub Actions 各 macOS runner 镜像当前具体 Xcode 版本。

---

## 12. 主要参考资料

- [WKURLSchemeHandler | Apple](https://developer.apple.com/documentation/webkit/wkurlschemehandler)
- [SO: WKWebView and NSURLProtocol not working](https://stackoverflow.com/questions/24208229/wkwebview-and-nsurlprotocol-not-working)
- [AVAssetDownloadTask | Apple](https://developer.apple.com/documentation/avfoundation/avassetdownloadtask)
- [Offline playback and storage | Apple](https://developer.apple.com/documentation/avfoundation/offline-playback-and-storage)
- [Adding capabilities to your app | Apple](https://developer.apple.com/documentation/xcode/adding-capabilities-to-your-app)
- [Configuring app groups | Apple](https://developer.apple.com/documentation/xcode/configuring-app-groups)
- [App Extension Programming Guide | Apple](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html)
- [Flutter: Adding iOS app extensions](https://docs.flutter.dev/platform-integration/ios/app-extensions)
- [receive_sharing_intent](https://pub.dev/packages/receive_sharing_intent)
- [ffmpeg-kit 官方退役声明](https://arthenica.github.io/ffmpeg-kit/) ｜ [FFmpegKitNext](https://github.com/arthenica/ffmpeg-kit-next)
- [cliqx](https://github.com/SaiSamardh7/cliqx) ｜ [AriaM3U8Downloader](https://github.com/moxcomic/AriaM3U8Downloader) ｜ [Douyin_TikTok_Download_API](https://github.com/Evil0ctal/Douyin_TikTok_Download_API) ｜ [yt-dlp](https://github.com/yt-dlp/yt-dlp)
