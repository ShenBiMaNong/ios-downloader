# MVP-4 分享扩展（待激活）

> 更新：主 App 已实现另一条免费可行的**文件接收**路线（不依赖本扩展）：
> Android 直接收系统分享（ACTION_SEND video/*）；iOS 声明 CFBundleDocumentTypes，
> 经系统「用 App 打开 / 分享」收视频文件。两者都落盘 `Documents/Share/` 并入库
> （见 lib/services/share_import.dart + 原生 ShareBridge）。本扩展的价值收窄为
> 「在分享菜单里直接接管网页链接 → 剪贴板」的快捷入口，可继续暂缓。

本目录是 **Share Extension 的完整代码与配置，但尚未接入 Xcode 工程**（在 Windows 上无法用
Xcode GUI 加 target；手工改 `project.pbxproj` 风险高，等 MVP-0 流水线跑通后再激活，
避免把两个高风险改动叠进同一次 CI 构建）。

## 方案（免费账号，无 App Groups）

```
其他 App 分享链接
   → ShareViewController（本扩展）：接收 URL → 跟随重定向解析 → 写系统剪贴板
   → （尽力）videodl:// 唤起主 App；不生效则用户手动打开
   → 主 App 启动时检测剪贴板（lib/services/share_import.dart 已实现）
   → 导入面板：mp4 下载 / HLS 离线缓存 / m3u8 转 MP4 / 浏览器打开
```

## 激活步骤（在一台 Mac 上执行一次，或后续由 pbxproj 脚本完成）

1. Xcode 打开 `ios/Runner.xcworkspace` → File > New > Target > **Share Extension**（名 `ShareExtension`）；
2. 把本目录 `ShareViewController.swift` 内容替换生成的控制器；
3. 用本目录 `Info.plist` 覆盖扩展的 Info.plist；
4. 主 App `Info.plist` 已有 `videodl://` scheme（见 ios/Runner/Info.plist 的 CFBundleURLTypes）；
5. 两 target 均选同一免费 Personal Team 签名，Commit 整个 `ios/` 目录推回仓库，CI 构建验证。

> 注意：免费账号签名 7 天过期；扩展随主 App 一起 sideload 的兼容性需真机实测。
> 若以后升级付费账号（688 元/年），可加 App Groups 走「分享即自动入库」标准路线。

## 为什么暂缓激活

- Windows 无法操作 Xcode GUI；`project.pbxproj` 手工新增 target 极易出错；
- 私有仓库 macOS 分钟额度有限（约 5-10 次构建/月），应优先用于验证 MVP-0/1/2/3；
- 剪贴板导入链路已在主 App 内可用，分享扩展只是把它接到系统分享菜单，价值增量明确后再激活不迟。
