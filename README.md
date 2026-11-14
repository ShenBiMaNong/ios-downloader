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
| M6.9 | HLS 三种产物明确区分：页内角标卡新增「下载 m3u8 分片（可转 MP4）」与「直接转 MP4」，系统离线缓存改标注「仅播放，不可导出」；资源库已完成的系统 HLS 缓存条目新增「重新下载并转 MP4」（用元数据里的原始 m3u8 重拉一次） | 已实现（待真机验证） |
| M6.10 | HLS 多线路判定：嗅探改为「候选池 + 证据分级」，网络状态码 / 清单内容 / 播放锚定 / 分片目录佐证共同打分，死链不再被当作首选；角标显示 `✓` 可用 / `✗` 失效 / `?` 未验证，卡片列出全部候选可手动切线路 | 已实现（jsdom 回归通过，待真机验证） |
| M6.11 | 点播放即接管（默认**关**，菜单/设置页可开）：用户点页面播放器且拿到 http(s) 直链时，页面不播、改由 App 播放器播放（可边播边缓存、无页面贴片广告）。blob:/MSE、DRM、`.mpd`、小窗广告、非用户点击一律放行给页面自己播，保证「点了总有反应」 | 已实现（jsdom 行为测试通过，待真机验证） |
| M6.12 | HLS 原生后台分片下载：角标卡/剪贴板导入新增「后台下载并转 MP4」，Dart 前台解析清单 → 一次性把整个作业交给 iOS `background URLSession`（全部 `URLSessionDownloadTask` 批量提交、锁屏/切 App 由系统继续）→ 分片齐备后回前台 ffmpeg `-c copy` 合成自有 mp4。作业状态持久化在原生侧磁盘，冷启动/回前台对账；产物可进 PlayerPage、可导出，不落 `.movpkg`。详见 [docs/后台分片下载-实施方案.md](docs/后台分片下载-实施方案.md) | 已实现（🔴 待 Xcode 编译与真机验证） |
| M6.13 | 下载进度统一口径：**所有下载链路**（mp4 直链 / 边播边缓存 / HLS 转 MP4 / 系统 HLS 离线缓存）在资源库统一按 `速度 · 已下/总量 · 剩余时长 · 已下分片/总分片` 显示，如 `3.2MB/s · 12.4MB/≈86MB · 剩余 2 分 10 秒 · 120/300`；字段缺失自动跳过（mp4 无分片就不出第四段），总量为外推值时标 ≈。实现集中在 `formatProgressLine()`；原生后台链由 iOS 上报「已落盘 + 在途已写」字节与真实分片计数 | 已实现（🔴 待 Xcode 编译与真机验证） |
| M6.14 | 列表文案去冗：状态只留必要信息——`待合成` / `合成中` / `系统下载中` / `准备中`、`系统缓存 · 日期`、`分片包 · 日期`；失败行只显示原因（`已暂停` / `HTTP 403` / `缓存已失效`），不再带「失败：」「（请…）」「进度见…」这类说明性后缀。服务层错误文案同步精简，完整异常仍进日志与「查看错误详情」 | 已实现（🔴 待编译验证） |
| M6.15 | 嗅探新增第 5 类证据：**播放器容器属性**（`data-url` / `data-src` / `data-m3u8` …）。DPlayer 系站点把真地址写在 `.dplayer[data-url]` 上、`<video src>` 只有 `blob:`（MSE），元素永远拿不到地址、清单还可能在 Worker 里拉 —— 属性是唯一入口。属性证据给 550（旁有 blob 播放器）/ 350（孤立属性），**永远低于任何真实请求证据（600+）**。同时修签名 URL 的两处硬伤：`auth_key`/`expires`/`wsTime`/`X-Amz-*` 的过期时间解析（过期不推荐、将过期给提示），以及 `\/`、`&amp;`、`\u0026` 转义还原与相对路径归一 | 已实现（jsdom 回归 5 个新场景通过，待真机验证） |
| M6.18 | 角标「刷新后不出来，点一下页面才冒出来」：旧版 `update()` 里 `if (!src) continue` —— 站点懒赋 `src`（点播放才给地址）时一个角标都不建。改为「**有元素地址 / 嗅探器已拿到候选 / 是主播放器尺寸**」三者任一出角标：有地址照旧；只有容器 `data-url` 等候选时显示 `HLS ?`；什么都没有时先给中性「视频」角标 + 「尚未捕获地址」卡片，地址一到卡片**自动重绘**成可下载项。同时修三角标被站点浮层盖住/跑出屏幕的两个成因：z-index 提到 `2147483647`、挂载点从 `body` 换成 `documentElement`（站点给 body 加 transform 时 fixed 会跟着偏出屏幕）；不带扩展名的播放地址（`/play?id=1`）不再被当噪声跳过，也给下载项。新增一次性诊断上报（App 日志「标记诊断 帧/视频/大播放器/角标/可见/被遮挡」），用来区分「页面里没有 video（在跨域 iframe）」和「角标被浮层盖住」 | 已实现（jsdom 回归 P1–P4 通过，待真机验证） |
| M6.19 | 角标「刷新后不出、设置项关了又开就有了」——按用户实测线索定位到**注入链路与元素收集**，四类根因一起修：① marker 只靠 `onPageStarted/onPageFinished` 的 `runJavaScript` 注入，导航竞态下脚本打在旧文档上；改为 **WKUserScript 全帧 atDocumentStart 注入**（每个新文档自动装），`onPageFinished` 后 1.2s 再补一次兜底。② `_injectMarker` 注入/清理两次调用并发时完成顺序不定（关→开可能变成「先注入后清理」），改为 **Future 链串行**。③ `__vdlBadge` 残留（指向已脱离文档的 badge）让 `if (!badge)` 永远走不进去、不再重建 —— 开关的 cleanup 恰好清残留，所以「关→开就好了」；`update()` 增加自愈：无跟踪角标时清光残留重建。④ 收集面补齐：`attachShadow` 钩子 + 兜底扫描抓 **shadow root 内的 `<video>`**（自绘播放器）；`video.srcObject`（`src`/`currentSrc` 全空）不再被当「没地址」；同源 iframe 内视频由主帧收集且**坐标逐级换算 frameElement 偏移**。诊断升级为 tag/shadow/frames/playing/srcObj/原生全屏，「点播放没角标」一次日志定位 | 已实现（jsdom 回归 E1–E4/F1–F2 六场景通过，待真机验证） |
| M6.20 | HLS 转 MP4「仍要合成」：分片部分下载失败后，失败条目出「仍要合成（缺 N 片）」入口（行内按钮 + 菜单），`ConvertManager.mergeAnyway` 把本地清单**过滤成磁盘上真实存在的分片子集**（缺失/空分片连同其 #EXTINF/#EXT-DISCONTINUITY 丢掉；#EXT-X-KEY 立即保留——密钥对其后所有分片生效）后强制出片，正常入库并清理工作目录。代价在确认框说清：合成后不能续传补片、缺片处时长偏短/跳跃，AES-128 无显式 IV 时 IV=片序号、从缺失位置起可能解密失败（HLS 协议层限制）。`failedSegments`/`canForceMerge` 持久化（重启按钮不丢），与 retry 互斥去重；合成失败回到失败态、按钮保留 | 已实现（🔴 待编译与真机验证；已知边界：旧任务绕过 retry 直接强合会踩未重写的本地清单（fMP4 无 MAP），需 retry 重写后再强合） |
| M6.21 | 浏览器手势导航：WebView 区域内**右滑=后退、左滑=前进**（与地址栏按钮同语义）。JS 注入检测水平滑动（`browser_swipe.js`，WKUserScript 全帧 + onPageFinished 兜底），经 `browserGesture` 通道触发 `goBack/goForward`。防误触：输入框/contenteditable、文本选区、多点触控、慢速拖拽（>800ms）、纵向主导、位移 <80px 均不触发；横向滚动容器（轮播/横滑列表）该方向未到边界时手势让给页面滚动，到边界才导航；触发后吞掉合成 click 防误触链接 | 已实现（jsdom 回归 13 场景通过，🔴 待 Xcode 编译与真机验证） |
| M6.22 | m3u8 转 MP4 默认走系统级后台下载：iOS 上「直接转 MP4」不再由 Dart 批下分片，而是解析清单后一次性提交给原生 `background URLSession`（锁屏/切 App/进程被回收仍继续传输），分片齐备后同样在前台 `ffmpeg -c copy` 合成——亮屏时 `ready` 事件即时触发，锁屏期间下完则回前台对账触发。原生通道不可用（非 iOS / 桥未注册 / 模拟器）时**就地降级**为原 Dio 前台链路并把降级写进断点记录，避免「不支持后台」变成用户可见的下载失败。入口随之收敛为一个：页内角标卡与剪贴板面板去掉并列的「后台下载并转 MP4」 | 已实现（🔴 待 Xcode 编译与真机验证） |
| M6.23 | 浏览器「更多」菜单新增**强制重置浏览器状态**：治「页面加载一半就卡住、点刷新也没用」。刷新治不好是因为它只调 `reload()`，三条成因一条都不动——渲染进程假死、坏缓存/ServiceWorker 把半截响应喂给每个新文档、半截导航还占着连接。重置按序做四件事：原生 `stopLoading` → 页内注销 ServiceWorker + 删光 CacheStorage（按源清，WebKit 没有对应的 WKWebsiteDataType） → 清 HTTP 内存/磁盘缓存与 SW 注册 → **销毁并重建 WebView 实例**（换新渲染进程，这是唯一能治假死的手段），250ms 后重新加载原地址。`Cookies/LocalStorage/IndexedDB` 有意不动（自救按钮不该把已登录站点全登出）；代价是前进/后退历史随旧实例销毁。每步都限时（假死时调用可能永不返回，宁可跳过也要走到重建），结果状态串进 App 日志（`sw=ok/partial/err/timeout/skipped`）。重建后必须在新实例上重装 WKUserScript，否则新页面没角标 | 已实现（新增 3 例 widget 用例覆盖「换实例 + 重载原地址 + 取消不动」，🔴 本机无 Flutter 未跑 `flutter test`，待 CI 编译与真机验证） |
| M6.24 | mp4 直链下载接入系统级后台：iOS 上「下载视频」不再走 Dio 前台流（锁屏即断），改为提交**单文件原生作业**给同一个 `background URLSession`（`singleFile` 标记，落盘文件即产物，无清单无合成）。进度改由 `getAllTasks` 的 `countOfBytesReceived/ExpectedToReceive` 提供——单文件作业在下载期间磁盘上一直没有增量，只看文件的旧口径会全程 0%；总量拿不到时退回「已下 X B」不显示百分比。暂停走 `cancel(byProducingResumeData:)` 存断点数据、继续走 `downloadTask(withResumeData:)`；原生侧把主动取消（-999）与真实失败分开，暂停不会再被标成错误。下完由 Dart 把中间文件搬进 Downloads 唯一名并写元数据，与 Dio 链产物同格式。通道不可用（非 iOS/模拟器）就地降级回 Dio 链 | 已实现（🔴 待 Xcode 编译与真机验证） |
| M6.25 | 解除 CI 卡在打包前的问题：`unintended_html_in_doc_comment` 有 2 处（`download_manager.dart` 里 `.direct_<id>`）让 `flutter analyze` 以退出码 1 结束，v0.3.6 那次构建因此停在 Analyze 步、Test 与打包全被 skip，没出 IPA。文档注释中的 ASCII 尖括号会被 dartdoc 当 HTML 标签吞掉，统一包反引号；顺带把 `<video>`、`<名字>` 这类分析器不报但渲染会出问题的写法一起包起来（分析器跳过合法 HTML 标签名，也只匹配 ASCII 标识符）。副作用是放行 Analyze 后暴露出 Test 从未在 CI 执行过：`browser_page_navigation_test.dart` 3 例失败。两处根因——① 测试桩 `_FakeController.addJavaScriptChannel` 是空实现，从没把手势通道记进 `channels`，于是「应注册 browserGesture 通道」恒为 null（产品代码的注册本身是好的）；② 重置链路里页内 ServiceWorker 注销兜底只挂在 `MissingPluginException` 上，桥超时/报错/空回包都静默跳过，而 CacheStorage 恰是「刷新治不好」那半条成因，改为任何未成功路径统一走页内兜底。v0.3.5 无构建记录、v0.3.6 被 Analyze 挡住，故这三例一直没跑到。Test 放行后又暴露第三道闸门：`ios/Runner/AppDelegate.swift` 续传路径把 `if let` 写成 `guard let` 却留着 `} else {`（`guard` 的条件后必须紧跟 `else`），v0.3.5/v0.3.6 那 400 多行原生后台下载代码从未进过编译器，这次是首次 Xcode 编译 | 已修（analyze `No issues found!`、52 例 `flutter test` 全过，均经 CI 实测；Swift 语法修正同样待 CI 编译确认） |
| M6.26 | 修「已下载的 MP4 全部提示视频损坏」（`OSStatus -17913`）：根因不是文件坏，是**元数据里记的绝对路径失效**。`Downloads/<id>.json` 的 `localPath` 写的是下载那一刻的 `/var/mobile/Containers/Data/Application/<UUID>/Documents/...`，iOS 数据容器 UUID 不保证跨安装稳定（实测：新下载条目的 JSON 里 UUID 与旧条目不同），换了容器后文件跟着 Documents 一起搬了家、老记录却还指着上一个容器 —— AVFoundation 拿到指不到东西的路径只回一句不分成因的 `-17913`，界面就写成「文件可能损坏」，而同一批文件在系统「文件」App 里照常能播。三层处理：① `scanSaved()` 后新增 `_repairSavedPaths()`，对 stat 不到的记录按当前容器重定位（改挂 Documents → 按文件名在 `Downloads`/`Share` 回查），命中即修正内存条目并回写 JSON，稳态下每条只多一次 `existsSync`（`local_media_path.dart` 的判定做成纯函数，单测覆盖三种命中与全部落空）；② 起播前对本地文件做预检（存在性 → 非空 → 头 12 字节是不是 ISO-BMFF box），把「路径失联 / 0 字节 / 不是视频」三种成因分开写成不同文案并记进日志，不再一律甩锅「损坏」；③ m3u8 转 MP4 的断点记录 `.convert.json` 里 `workDir` 同样按当前容器重定位——旧逻辑一看目录不在就直接删记录，续传机会明明还在却没了。已知未覆盖：系统 HLS 离线缓存（`.movpkg`，`hls=true`）由系统按任务标识寻址、不在此列，换容器后只能重新下载 | 已实现（本机无 Flutter，未跑 analyze/test；判定逻辑有单测，待 CI 与真机验证） |
| M6.27 | 视频嗅探「有时显示有时不显示」的现场取证：浏览器「更多」菜单新增**嗅探诊断（当前页）**只读面板，每秒从主框架拉一次快照，不碰任何开关。三层证据——① 脚本层：嗅探/标记脚本是否装上、注入来源（`early`=WKUserScript 早注入 / `dart`=导航回调补注入）、WebView 代次、脚本文档 href 与地址栏是否一致（导航竞态把脚本打进旧文档时直接标出）；② 采集层：`fetch`/`XHR` 钩子是否还在（站点注入后重新赋值会丢）、挂钩时的 `readyState`（`complete/interactive` = 晚于页面脚本，站点缓存过原生引用的请求会绕过嗅探）、候选池按 `ok/dead/未验证` 分档 + 事件时间线（new/dead/ok/up/play）；③ 展示层：每个 `<video>` 的 state（`badged` / `hidden:rect-null|zero-size|offscreen` / `skipped:no-src-small` / `unbadged` / `ignored`）、角标可见/被遮挡、`srcObject` 与原生全屏、跨域 iframe 各自上报。主播放器在播却无角标（或角标全不可见）时自动升为 WARN 写入系统日志；报告可一键复制或写入日志。角标开关关闭时脚本仍留最小快照，避免把「开关关了」误判成「没注入」 | 已实现（新增 jsdom 回归 `test_diag.js` 覆盖快照/关闭态/四种角标状态/上报字段，8 组测试全部通过；🔴 本机无 Flutter，面板 UI 未编译，待 CI 与真机验证） |
| M6.28 | 播放页手势与进度条易用性：① 长按不再分区——去掉「按住左半边持续快退」的 300ms 定点回退循环，长按视频任意位置统一按设置的倍速加速播放、松开恢复（快退仍走双击左半边与快退按钮）。② 进度条从 `VideoProgressIndicator`（约 2px 细线、高度仅 5px 的触摸带）换成本地绘制的加粗轨道：40 高的整块触控区、5px 轨道（拖动时 7px）、常显白色圆形滑块（拖动时放大）、缓冲段独立显示；点按轨道任意位置直接跳转，横向拖动跟手（100ms 节流预览）且拖动期间先暂停、松手恢复原播放状态，目标时间在下方时间文字里以高亮色实时显示。同时把「上一个/下一个」移到底部按钮行，进度条独占一行，可拖宽度约翻倍 | 已实现（🔴 本机无 Flutter，未跑 analyze/test，待 CI 编译与真机验证） |

## 架构

- 内置浏览器：`webview_flutter`（iOS 底层 WKWebView），页面加载时注入 [assets/sniffer.js](assets/sniffer.js)（钩住 fetch/XHR + 扫描 `<video>` + MutationObserver + 资源时间线 + 静态脚本解析），再注入 [assets/video_marker.js](assets/video_marker.js) 把可下载视频**直接标在页面上**（蓝色虚线描边 + 右上角角标，蓝=直链 / 紫=HLS），点角标展开页内操作卡（下载 / HLS 缓存 m3u8 / 转 MP4 / 复制链接 / 忽略），动作经 `videoAction` 通道回传 Dart。
  角标出现条件（M6.18）：`<video>` 有可用地址、或嗅探器已拿到候选（容器 `data-url` 等）、或是「主播放器尺寸」（≥240×135）三者任一条成立就出；都还没有时先给中性「视频」角标，地址一到卡片自动重绘。角标挂 `documentElement` 且 `z-index:2147483647`，避免被站点浮层盖住或随 body 的 transform 跑出屏幕。
- 嗅探判定（M6.10 / M6.15）：不判断「有没有出现过 URL」，只判断「哪条真的在跑」。每条候选按证据打分 ——
  `播放锚定 1000` > `元素 currentSrc 900` > `分片目录匹配 850` > `清单内容含 #EXTM3U 800` > `清单 MIME 700` > `2xx 未验证 600` > `播放器容器属性(blob 旁) 550` > `资源时间线成功传输 400` > `容器属性(孤立) 350` > `脚本里扫到的猜测 100`，`404/5xx/网络错误/200+HTML 错误页` 记 `-1` 且不会被选为首选。
  多线路站点逐条试探时，「最近一条」往往是失败的那条（v1 的 `getLatest` 就栽在这），现在由 `getBest` 按分数挑，角标显示 `✓/✗/?`，卡片可手动切线路。
  MSE(`blob:`) 场景额外用三条推断：播放前最近一次**成功**的清单请求、播放后 `.ts/.m4s` 分片 URL 与候选清单的目录前缀匹配（同域多线路靠目录区分）、以及**播放器容器上的 `data-url`**（元素句柄是 blob 时，属性就是它自己的配置）。
  签名 URL 有时效（`auth_key=过期时间戳-…`、`expires`、`wsTime`、`X-Amz-Expires`）：本地已过期的候选不推荐，5 分钟内到期在卡片上提示。
  回归测试见 [dev/sniff-test](dev/sniff-test)（含 v1 对照）。
- 点播放即接管（M6.11，默认关）：与「禁止自动播放」共用 [assets/no_autoplay.js](assets/no_autoplay.js) 里的 `play()` 钩子和手势判据（`navigator.userActivation` + 坐标命中 video + 4s 窗口）。
  判据不满足就**原样放行**：`blob:`(MSE)、`.mpd`、字幕/分片、小窗（<240×135）、非用户点击都不接管。
  接管时把当前帧地址作为 `Referer` 一并回传 —— 跨域 iframe 播放器用主框架地址会 403。
  ⚠️ 已知边界：接管后若 App 侧起播失败（CDN 403、DRM 等），页面视频已被拦下，需关掉开关并刷新页面才能恢复。
- 手势导航（M6.21）：[assets/browser_swipe.js](assets/browser_swipe.js) 在 capture 阶段跟踪 touch，水平位移 ≥80px 且横向主导（|dy| ≤ 0.7×|dx|）、800ms 内完成才判定为滑动；右滑→`goBack`、左滑→`goForward`。横向滚动容器在该方向未到边界时手势让给页面（轮播/地图不误触），触发后 400ms 窗口吞掉合成 click。
- 下载：mp4 直链在 iOS 上提交给原生 `background URLSession` 的单文件作业（M6.24，锁屏后系统继续传、暂停走 `resumeData` 续传），产物由 Dart 搬进 `Documents/Downloads/<唯一名>.mp4` 并写 `<id>.json`；非 iOS 与原生通道不可用时仍走 Dio（带移动端 UA + Range 断点续传）。两条链的元数据格式一致，资源库不区分来源。
- 本地库：path_provider 扫描元数据 + video_player 播放。

## 构建 & 安装（Windows 开发机）

1. 推送到 GitHub 私有仓库，Actions 在 macOS runner 上构建并打包**未签名 IPA**。IPA 文件名带版本/日期/commit（如 `VideoDownloader-0.2.0+1-20251113-4f718c0e.ipa`），zip 内附 `build_info.txt` 记录版本/日期/commit/tag，方便区分新旧版本。
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

- `blob:`(MSE) 本身不可下载：只能靠嗅探兜底到它背后的直链/清单（证据分级见上），取不到地址就只做播放接管，卡片上给降级提示。
  HLS(m3u8) 已支持：分片包下载、转 MP4（iOS 走系统级后台传输）、系统离线缓存（`.movpkg`，不可导出）三条产物。
- 系统级后台（iOS 上 HLS 转 MP4 与 mp4 直链共用同一个 `background URLSession`）只覆盖**传输**阶段：
  合成 `-c copy` 必须回 App 前台跑；锁屏期间 `didWriteData` 不回调，进度数字原地不动属预期，
  回前台按原生侧状态对账；用户从多任务界面强杀 App 会取消该 session 全部传输且不自动重启
  （分片与断点数据已落盘，点「继续」可续传）。
- 续传凭据绑的是**原始请求**：签名 URL 在后台过期后，续传依旧 403；此时只能回页面刷新重新
  嗅探、新建一条下载（直链换地址等于从头下，已下字节不作数）。
- 安卓侧 mp4 直链仍是 Dio 前台链（只有 `beginBackgroundTask` 的约 30 秒宽限），锁屏即中断，
  靠 `.part` + Range 续传；iOS 上原生通道不可用（模拟器 / 桥未注册）时也按这条降级。
- 分享扩展依赖付费账号的 App Groups 才能走标准路线，免费账号用剪贴板降级方案（MVP-4）。
- 各平台（抖音/快手/B站/YouTube）分享链接解析为逆向接口，易变，建议后续服务端化。

## 合规声明

仅用于个人学习、备份与测试，请勿传播或用于商业用途；尊重各平台服务条款与版权。
