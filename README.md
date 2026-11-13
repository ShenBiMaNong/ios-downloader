# 视频下载器（Flutter）

内置浏览器 + 视频识别下载 + 本地视频库的个人自用 App（iOS 优先，可顺带出 Android）。

## 功能（MVP 分期）

| 阶段 | 内容 | 状态 |
|---|---|---|
| MVP-0 | GitHub Actions 云端 macOS 出未签名 IPA + 签名装机链路 | 进行中 |
| MVP-1 | 内置浏览器（webview_flutter）+ JS 视频嗅探 + mp4 直链下载 + 本地库播放 | 进行中（当前代码） |
| MVP-2 | HLS(m3u8) 离线缓存（AVAssetDownloadTask 原生桥接） | 已实现（待真机验证） |
| MVP-3 | m3u8 转 mp4（ffmpeg_kit_flutter_new_min 预编译库，本地分片下载 + `-c copy` 无损转封装） | 已实现（待真机验证） |
| MVP-4 | 分享扩展（免费账号降级：剪贴板交接） | 待做 |
| M4.5 | 广告过滤（WKContentRuleList 桥接） | 可选 |
| M5 | 下载管理打磨（暂停/断点/缩略图/清理） | 可选 |

## 架构

- 内置浏览器：`webview_flutter`（iOS 底层 WKWebView），页面加载时注入 [assets/sniffer.js](assets/sniffer.js)（钩住 fetch/XHR + 扫描 `<video>` + MutationObserver），嗅探到的视频 URL 经 JS Channel 回传 Dart。
- 下载：mp4 直链走 Dio（带移动端 UA），存到 `Documents/Downloads/`，元数据存 `<id>.json`。
- 本地库：path_provider 扫描元数据 + video_player 播放。

## 构建 & 安装（Windows 开发机）

1. 推送到 GitHub 私有仓库，Actions 自动在 macOS runner 上执行 `flutter build ipa --no-codesign`，产物为**未签名 IPA**（artifact: `video-downloader-unsigned-ipa`）。
2. 下载 IPA 后，用 **Sideloadly**（Windows）或 **爱思助手** 以你的 Apple ID 签名并安装到 iPhone。
3. ⚠️ 免费 Personal Team 签名的 App **7 天过期**，到期重新签名安装即可。

> 私有仓库分钟账：免费 2000 分钟/月，macOS 按 10 倍消耗 ≈ 200 分钟/月，一次构建约 20-40 分钟，每月约 5-10 次构建。

## 本地开发

```bash
flutter pub get
flutter run -d windows   # Windows 桌面调试 UI（浏览器功能在桌面端受限，iOS/Android 为主）
flutter analyze
flutter build apk       # 顺带出 Android 包
```

## 已知限制 / 待办

- HLS(m3u8) 与 `blob:`(MSE) 视频暂不支持下载（MVP-2 接入 AVAssetDownloadTask；blob: 无解，降级提示）。
- 分享扩展依赖付费账号的 App Groups 才能走标准路线，免费账号用剪贴板降级方案（MVP-4）。
- 各平台（抖音/快手/B站/YouTube）分享链接解析为逆向接口，易变，建议后续服务端化。

## 合规声明

仅用于个人学习、备份与测试，请勿传播或用于商业用途；尊重各平台服务条款与版权。
