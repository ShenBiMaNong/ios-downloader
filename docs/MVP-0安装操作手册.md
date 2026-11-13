# MVP-0 安装操作手册（未签名 IPA → iPhone）

> 适用：Windows 开发机 + GitHub 私有仓库 + 免费 Apple ID（Personal Team，7 天签名有效期）

## 一、推送代码触发云端构建

1. 在 GitHub 创建**私有仓库**（如 `video-downloader`），不要勾选 README（避免冲突）；
2. 本地仓库关联并推送：

```bash
git remote add origin https://github.com/<你的用户名>/video-downloader.git
git push -u origin main
```

3. 打开仓库 → **Actions** 页 → `Build unsigned IPA` 工作流开始运行（macOS 构建约 20-40 分钟）；
   - 推送自动触发；也可以在 Actions 页点 **Run workflow** 手动触发，此时可填「版本号覆盖」（如 `0.3.0+2`），留空则用 pubspec.yaml 的 version；
4. 构建成功后，进入本次运行 → **Artifacts** → 下载 `video-downloader-unsigned-ipa-<版本>-<日期>-<提交>`，解压得到带版本信息的 IPA（如 `VideoDownloader-0.2.0+1-20251113-4f718c0e.ipa`；zip 内另有 `build_info.txt` 记录版本/日期/commit/tag，可据此确认是不是最新版）。

> 私有仓库分钟账：macOS 按 10 倍消耗，免费约 200 分钟/月 ≈ 5-10 次构建。省着用或以后考虑公开仓库（开源）解锁免费不限量。

## 二、Windows 上用 Sideloadly 签名安装

1. 官网下载并安装 [Sideloadly](https://sideloadly.io/)（Windows 版，需 iTunes/Apple Devices 组件，安装时按提示装）；
2. iPhone 用数据线连电脑，信任此电脑；
3. 打开 Sideloadly：
   - **IPA** 栏选择解压出的 IPA（如 `VideoDownloader-0.2.0+1-….ipa`）；
   - **Apple ID** 填你的 Apple ID 和**App 专用密码**（没有就在 Apple 账户网页开双重认证后生成）；
   - 设备选择你的 iPhone；
   - 点 **Start**，等签名安装完成；
4. iPhone 上打开 App：**设置 → 通用 → VPN 与设备管理** → 信任你的开发者证书 → 回到桌面打开"视频下载器"。

> 替代方案：**爱思助手**（Windows）→ 工具箱 → 签名安装，同样用 Apple ID 签名。两者任选。

## 三、7 天有效期说明（免费账号）

- 免费 Personal Team 签名的 App **7 天后无法打开**；
- 到期处理：重新连接电脑 → Sideloadly 重签（几秒）→ 手机上确认即可，**App 内已下载的视频文件保留**（沙盒数据不丢，重装时勾选保留数据）；
- 想彻底摆脱 7 天限制：升级付费 Apple Developer Program（688 元/年），可签 1 年。

## 四、常见问题

| 现象 | 处理 |
|---|---|
| 构建失败 | 去 Actions 运行日志看是哪一步；常见：pub 依赖拉取失败 → 重跑；代码 analyze 报错 → 修代码 |
| Sideloadly 报 "Could not find device" | 确认 iPhone 已信任电脑、装好 Apple Devices 组件 |
| 安装后打开闪退 | 通常是签名/信任问题：重新签名，或到设备管理里重新信任 |
| 打开提示"无法验证 App" | 设置 → 通用 → VPN 与设备管理 → 信任证书 |
| 下载视频失败 | 该站点可能校验 Referer/UA/防盗链；先试公开站点（如 sample mp4），确认链路通 |
| 播放器播不了某文件 | 该文件格式 AVPlayer 不支持（如某些 webm），先保底用 mp4 |

## 五、验收清单（MVP-0）

- [ ] 推送后 Actions 自动构建成功，产出 IPA artifact
- [ ] Sideloadly 签名安装成功，App 能打开
- [ ] 内置浏览器能打开网页（bilibili 等）
- [ ] 播放一个 mp4 页面 → 嗅探横幅出现"发现 N 个视频" → 下载 → 本地库可播放
