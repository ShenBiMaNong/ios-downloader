# 视频下载器（Flutter）

内置浏览器 + 视频识别下载 + 本地视频库的个人自用 App（iOS 优先，可顺带出 Android）。

## 功能（MVP 分期）

| 阶段 | 内容 | 状态 |
|---|---|---|
| MVP-0 | GitHub Actions 云端 macOS 出未签名 IPA + 签名装机链路 | ✅ 真机验收通过（可安装） |
| MVP-1 | 内置浏览器（webview_flutter）+ JS 视频嗅探 + mp4 直链下载 + 本地库播放 | ✅ 真机验收通过（可下载视频） |
| MVP-2 | HLS(m3u8) 离线缓存（AVAssetDownloadTask 原生桥接） | 已实现（待真机验证） |
| MVP-3 | m3u8 转 mp4（ffmpeg_kit_flutter_new_min 预编译库，本地分片下载 + `-c copy` 无损转封装） | 已实现（待真机验证） |
| MVP-4 | 分享导入：剪贴板链接交接（iOS 免费账号）+ 视频文件接收（Android 直收系统分享；iOS 经「用 App 打开」收文件）→ 落盘 Documents/Share 并入库 | 剪贴板链路✅；Android 分享接收✅；iOS 文件接收✅（待真机验证）；分享扩展 target 待激活（staged/） |
| M4.5 | 广告过滤（JS 层拦截广告域名 + 隐藏广告元素，浏览器菜单开关） | ✅ 已实现 |
| M4.6 | 跳转拦截（非用户点击的自动跳转先询问，广告跳转识别 + 禁用开关，浏览器菜单/设置页） | ✅ 已实现 |
| MVP-5 | 浏览器扩展：书签（星标收藏/管理）+ 历史记录（自动记录/管理） | ✅ 已实现 |
| MVP-6 | 资源库：下载与视频库合并，按名称/大小/创建时间×正/倒序（默认创建倒序），下载显示进度/网速/预计剩余 | ✅ 已实现 |
| M6.5 | 资源库文件夹：新建/重命名/删除文件夹，视频可移动到文件夹（虚拟分组，改元数据不搬文件）；内置「分享」文件夹收纳分享导入的视频；「全部」视图按文件夹分组，组内按所选排序 | ✅ 已实现 |
| M6.6 | 资源库宫格/列表切换：宫格卡片显示封面状态（下载进度环/失败/类型图标）、标题与摘要，卡片点按播放、封面快捷按钮（取消/继续/本地转 MP4）、更多菜单（播放/移动/删除）；切换偏好持久化 | ✅ 已实现 |
| M6.7 | 视频重命名：列表/宫格「更多」菜单统一入口（点按条目即播放、无独立播放按钮，所有操作收进菜单），同步改名磁盘文件与元数据（原生 HLS 缓存仅改标题） | ✅ 已实现 |
| M6.8 | 下载重名自动避让：mp4 直链 / m3u8 转 mp4 / m3u8 分片包 / 分享导入，同名时自动追加 ` (2)` 序号，不再覆盖旧文件 | ✅ 已实现 |

## 架构

- 内置浏览器：`webview_flutter`（iOS 底层 WKWebView），页面加载时注入 [assets/sniffer.js](assets/sniffer.js)（钩住 fetch/XHR + 扫描 `<video>` + MutationObserver），嗅探到的视频 URL 经 JS Channel 回传 Dart；再注入 [assets/video_marker.js](assets/video_marker.js) 把可下载视频**直接标在页面上**（蓝色虚线描边 + 右上角角标，蓝=直链 / 紫=HLS），点角标展开页内操作卡（下载 / HLS 缓存 m3u8 / 转 MP4 / 复制链接 / 忽略），动作经 `videoAction` 通道回传 Dart。
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
