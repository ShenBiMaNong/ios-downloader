# MVP-4 分享扩展方案（免费账号 · 剪贴板降级）

> 调研结论回顾（见《视频下载器App-技术调研报告.md》§5）：
> App Groups（扩展↔主 App 共享数据的唯一官方方式）需要**付费** Apple Developer Program；
> 免费 Personal Team 下 Share Extension 只能走「剪贴板交接」降级路线。

## 一、方案总览

```
抖音/快手/B站/网页/Safari 分享
        │ 系统分享菜单 → 我们的扩展
        ▼
ShareViewController（原生 Swift，staged/ 目录已备好）
  ① 接收 NSItemProvider 的 public.url
  ② URLSession 跟随重定向（抖音 v.douyin.com、快手 v.kuaishou.com、b23.tv 等）
  ③ 把解析后的 URL 写入系统剪贴板（无需任何 entitlement）
  ④ 尝试 videodl:// 唤起主 App（官方不保证，实测为准）
        │ 用户打开主 App（或已被唤起）
        ▼
主 App 启动时读剪贴板（lib/services/share_import.dart 已实现）
  → 导入面板：mp4 下载 / HLS 离线缓存 / m3u8 转 MP4 / 浏览器打开
```

## 二、已完成的代码

| 位置 | 内容 | 状态 |
|---|---|---|
| `lib/services/share_import.dart` | 剪贴板读取 + URL 分类 + 视频页识别 | ✅ 已接入主 App（HomeShell 启动检测） |
| `lib/pages/browser_page.dart` | `loadUrl()` 对外接口（供「浏览器打开」） | ✅ |
| `ios/Runner/Info.plist` | `videodl://` URL scheme | ✅ |
| `staged/mvp4-share-extension/ShareViewController.swift` | 扩展控制器（接收/重定向/剪贴板/唤起） | ⏸ 未接入 Xcode target |
| `staged/mvp4-share-extension/Info.plist` | 扩展配置（NSExtensionActivationRule 限 WebURL×1） | ⏸ 未接入 |

## 三、激活条件与步骤（在 Mac 上一次性完成）

前置：**MVP-0 流水线已验证**（首次 CI 构建成功、IPA 可装）。之后：

1. Xcode 打开 `ios/Runner.xcworkspace` → New Target → Share Extension（名 `ShareExtension`）；
2. 控制器换成 `staged/mvp4-share-extension/ShareViewController.swift`；
3. Info.plist 换成 staged 版本（注意 `NSExtensionPrincipalClass` 与模块名一致）；
4. 两 target 用同一 Personal Team 签名；提交 `ios/` 推仓库，CI 构建验证；
5. 真机验证：Safari 分享网页 → 扩展出现 → 剪贴板收到链接 → 打开主 App 导入。

## 四、风险与后续

- ⚠️ **免费账号 sideload 带扩展的 IPA 兼容性未验证**（Sideloadly/爱思对扩展 target 的支持）；
- 各平台解析接口（抖音 playAddr、B 站 WBI、YouTube innertube）为逆向产物、易变 → 建议后续**服务端化**；
- 升级付费账号（688 元/年）后可改 App Groups 标准路线：分享即自动入库、无剪贴板步骤；
- 版权合规：仅个人学习/备份用途，勿传播。
