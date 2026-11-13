import AVFoundation
import AVKit
import Flutter
import UIKit
import UniformTypeIdentifiers
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var hlsBridge: HlsBridge?
  private var filesBridge: FilesBridge?
  private var backgroundBridge: BackgroundBridge?
  private var shareBridge: ShareBridge?
  private var thumbnailBridge: ThumbnailBridge?
  private var snifferBridge: SnifferBridge?
  private var nativeSegBridge: NativeSegmentBridge?

  /// 其他 App 分享/打开的视频文件队列（已拷贝进本 App 沙盒 tmp）
  private var pendingShareFiles: [(path: String, name: String)] = []

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 冷启动：直接由「打开文件」拉起时，URL 在 launchOptions 里
    if let url = launchOptions?[.url] as? URL, url.isFileURL {
      enqueueShare(url)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// 接收其他 App 分享/打开的视频文件（热启动；系统把文件拷进本 App tmp/inbox，
  /// 或 LSSupportsOpeningDocumentsInPlace 时为 security-scoped 原文件，统一先拷进沙盒）
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if url.isFileURL {
      enqueueShare(url)
      return true
    }
    // 自定义 scheme（videodl://）剪贴板链路继续走主 App 启动检测
    return true
  }

  /// 安全作用域拷贝到沙盒 tmp/pickedShare，再交给 Flutter 导入 Documents/Share
  /// （internal：供 SceneDelegate 在场景生命周期里调用）
  func enqueueShare(_ url: URL) {
    let scoped = url.startAccessingSecurityScopedResource()
    defer {
      if scoped { url.stopAccessingSecurityScopedResource() }
    }
    let fm = FileManager.default
    let destBase = fm.temporaryDirectory.appendingPathComponent("pickedShare", isDirectory: true)
    do {
      try fm.createDirectory(at: destBase, withIntermediateDirectories: true)
      let dest = destBase.appendingPathComponent(
        UUID().uuidString + "_" + url.lastPathComponent)
      try fm.copyItem(at: url, to: dest)
      pendingShareFiles.append((dest.path, url.lastPathComponent))
    } catch {
      // 拷贝失败（罕见）：退回直接用原路径，导入失败由 Dart 侧兜底
      pendingShareFiles.append((url.path, url.lastPathComponent))
    }
  }

  /// Flutter 取走分享队列（取后清空）
  func takePendingShareFiles() -> [(path: String, name: String)] {
    let files = pendingShareFiles
    pendingShareFiles.removeAll()
    return files
  }

  /// 后台 URLSession 事件的入口。工程启用了 UIApplicationSceneManifest / SceneDelegate，
  /// 但 background session 事件仍由 UIApplicationDelegate 交付（没有对应的 scene 回调）。
  /// 🔴 需在真机上验证冷启动唤醒时该回调确实到达 AppDelegate。
  /// 非本桥接的 identifier（如 HlsBridge 的 AVAssetDownloadURLSession）必须转交
  /// FlutterAppDelegate 的 lifecycleDelegate：直接调 completionHandler() 会让系统
  /// 认为事件已处理完，可能吞掉尚未交付的 HLS 回调，破坏已有的离线下载链。
  override func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    guard identifier == NativeSegmentBridge.sessionIdentifier else {
      super.application(
        application,
        handleEventsForBackgroundURLSession: identifier,
        completionHandler: completionHandler)
      return
    }
    if let bridge = nativeSegBridge {
      bridge.storeCompletion(identifier, handler: completionHandler)
    } else {
      // 冷启动时引擎还没起来，先暂存；bridge init 会取走并按同 identifier 重建 session
      NativeSegmentBridge.pendingCompletion[identifier] = completionHandler
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "HlsBridge") {
      let bridge = HlsBridge()
      bridge.register(with: registrar.messenger())
      hlsBridge = bridge
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FilesBridge") {
      let bridge = FilesBridge()
      bridge.register(with: registrar.messenger())
      filesBridge = bridge
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BackgroundBridge") {
      let bridge = BackgroundBridge()
      bridge.register(with: registrar.messenger())
      backgroundBridge = bridge
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ShareBridge") {
      let bridge = ShareBridge(appDelegate: self)
      bridge.register(with: registrar.messenger())
      shareBridge = bridge
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ThumbnailBridge") {
      let bridge = ThumbnailBridge()
      bridge.register(with: registrar.messenger())
      thumbnailBridge = bridge
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SnifferBridge") {
      let bridge = SnifferBridge()
      bridge.register(with: registrar.messenger())
      snifferBridge = bridge
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NativeSegmentBridge") {
      let bridge = NativeSegmentBridge()
      bridge.register(with: registrar.messenger())
      nativeSegBridge = bridge
    }
  }
}

// MARK: - HLS 离线下载桥接（MVP-2：AVAssetDownloadTask）
// 方法通道: video_downloader/hls  (download / cancel / playOffline)
// 事件通道: video_downloader/hls/events (taskId + progress / done)

class HlsBridge: NSObject, AVAssetDownloadDelegate {
  static let methodChannelName = "video_downloader/hls"
  static let eventChannelName = "video_downloader/hls/events"

  private var session: AVAssetDownloadURLSession!
  private var taskIds = [String: AVAssetDownloadTask]()
  private var localUrls = [String: URL]()
  private var eventSink: FlutterEventSink?

  /// 系统「正在下载」实时活动的开关（silent = 不显示）。
  ///
  /// Apple 文档（AVAssetDownloadTask → Live Activity）原文：
  /// 「非酌情下载会在锁定屏幕和灵动岛上显示『实时活动』，以显示实时下载进度；
  ///   酌情下载不会显示『实时活动』。」
  /// 这条「正在下载 + 进度环」是**系统自己画的**（App 内没有任何通知代码），
  /// App 无法单独关掉它，唯一开关就是 isDiscretionary，代价是系统可能把任务
  /// 推迟到网络/电量条件合适时才开始。用户明确不想要这条通知，故默认 silent=true，
  /// 设置页可切回「显示下载进度」（此时立即开始下载）。
  private static let silentKey = "video_downloader.hls.silent"
  private var silent: Bool
  /// 有在途任务时不能立刻换 session（新 session 会顶掉旧的代理回调），
  /// 记下来等任务清空再换
  private var pendingRebuild = false

  override init() {
    let d = UserDefaults.standard
    if d.object(forKey: Self.silentKey) == nil { d.set(true, forKey: Self.silentKey) }
    silent = d.bool(forKey: Self.silentKey)
    super.init()
    session = Self.makeSession(silent: silent, delegate: self)
  }

  /// isDiscretionary 是 URLSessionConfiguration 级属性，只能整条 session 重建
  private static func makeSession(silent: Bool, delegate: AVAssetDownloadDelegate)
    -> AVAssetDownloadURLSession
  {
    let config = URLSessionConfiguration.background(withIdentifier: "video_downloader.hls.bg")
    config.isDiscretionary = silent
    config.sessionSendsLaunchEvents = true
    return AVAssetDownloadURLSession(
      configuration: config, assetDownloadDelegate: delegate, delegateQueue: .main)
  }

  func register(with messenger: FlutterBinaryMessenger) {
    let methodChannel = FlutterMethodChannel(
      name: Self.methodChannelName, binaryMessenger: messenger)
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    let eventChannel = FlutterEventChannel(
      name: Self.eventChannelName, binaryMessenger: messenger)
    eventChannel.setStreamHandler(self)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setSilent":
      // silent=true → 酌情下载，锁屏/灵动岛不再出现「正在下载」实时活动
      guard let args = call.arguments as? [String: Any], let v = args["silent"] as? Bool else {
        result(FlutterError(code: "bad_args", message: "silent 缺失", details: nil))
        return
      }
      silent = v
      UserDefaults.standard.set(v, forKey: Self.silentKey)
      if taskIds.isEmpty {
        pendingRebuild = false
        session = Self.makeSession(silent: silent, delegate: self)
      } else {
        pendingRebuild = true
      }
      result(true)

    case "download":
      guard
        let args = call.arguments as? [String: Any],
        let url = args["url"] as? String,
        let title = args["title"] as? String,
        let urlObj = URL(string: url)
      else {
        result(FlutterError(code: "bad_args", message: "url/title 缺失", details: nil))
        return
      }
      let asset = makeAsset(urlObj, headers: headersOf(args))
      let downloadConfig = AVAssetDownloadConfiguration(asset: asset, title: title)
      let task = session.makeAssetDownloadTask(downloadConfiguration: downloadConfig)
      // taskId 优先沿用 Dart 侧生成的 id（让首帧进度事件就能对上资源库条目），
      // 未传则本地生成。
      let taskId = (args["taskId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        ?? UUID().uuidString
      taskIds[taskId] = task
      // ⚠️ 必须立刻回传 taskId，不能等下载结束：
      // 旧实现把 result 存进 pendingResults 直到 didCompleteWithError 才回调，
      // 导致 Dart 侧 await 一直挂起 —— 任务不进资源库列表、进度事件也找不到条目，
      // 表现为「点了下载但视频列表里根本没有这个视频，更没有进度」。
      result(taskId)
      task.resume()

    case "cancel":
      guard let args = call.arguments as? [String: Any], let taskId = args["taskId"] as? String else {
        result(false)
        return
      }
      taskIds[taskId]?.cancel()
      result(true)

    case "playOffline":
      guard
        let args = call.arguments as? [String: Any],
        let taskId = args["taskId"] as? String
      else {
        result(false)
        return
      }
      // App 重启后内存里的 localUrls 已清空，但 willDownloadTo 已把 .movpkg
      // 路径持久化到 HlsLocalStore（缩略图用的就是它）。这里回退一次并校验落地，
      // 否则历史离线条目播放必然失败，表现为「播放失败：本地缓存不存在」。
      guard
        let localUrl = localUrls[taskId] ?? HlsLocalStore.shared.url(for: taskId),
        FileManager.default.fileExists(atPath: localUrl.path)
      else {
        result(false)
        return
      }
      playOffline(localUrl: localUrl)
      result(true)

    case "playWhileDownloading":
      // 边下边看：下载进行中复用同一 AVURLAsset 播放（官方支持读已缓存分段）
      guard
        let args = call.arguments as? [String: Any],
        let taskId = args["taskId"] as? String,
        let task = taskIds[taskId]
      else {
        result(false)
        return
      }
      let item = AVPlayerItem(asset: task.urlAsset)
      let player = AVPlayer(playerItem: item)
      let vc = AVPlayerViewController()
      vc.player = player
      guard
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
        let root = scene.windows.first?.rootViewController
      else {
        result(false)
        return
      }
      root.present(vc, animated: true) { player.play() }
      result(true)

    case "restore":
      // 重启后重新挂接在途任务：按资产 URL 匹配持久化的 taskId
      guard
        let args = call.arguments as? [String: Any],
        let list = args["tasks"] as? [[String: Any]]
      else {
        result(FlutterError(code: "bad_args", message: "tasks 缺失", details: nil))
        return
      }
      var urlToTaskId = [String: String]()
      for item in list {
        if let tid = item["taskId"] as? String, let url = item["url"] as? String {
          urlToTaskId[url] = tid
        }
      }
      session.getAllTasks { [weak self] tasks in
        guard let self else { return }
        var matched: [String] = []
        for t in tasks {
          guard
            let assetTask = t as? AVAssetDownloadTask,
            let taskId = urlToTaskId[assetTask.urlAsset.url.absoluteString]
          else { continue }
          self.taskIds[taskId] = assetTask
          if !matched.contains(taskId) { matched.append(taskId) }
        }
        DispatchQueue.main.async {
          result(matched)
        }
      }

    case "retry":
      // 失败任务续传：重建 AVAssetDownloadTask，沿用同一 taskId
      guard
        let args = call.arguments as? [String: Any],
        let taskId = args["taskId"] as? String,
        let url = args["url"] as? String,
        let title = args["title"] as? String,
        let urlObj = URL(string: url)
      else {
        result(false)
        return
      }
      let asset = makeAsset(urlObj, headers: headersOf(args))
      let downloadConfig = AVAssetDownloadConfiguration(asset: asset, title: title)
      let task = session.makeAssetDownloadTask(downloadConfiguration: downloadConfig)
      taskIds[taskId] = task
      task.resume()
      result(true)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 从方法参数里取请求头（Dart 侧只有防盗链站才传，通常只有 Referer）
  private func headersOf(_ args: [String: Any]) -> [String: String] {
    if let h = args["headers"] as? [String: String] { return h }
    return [:]
  }

  /// 带 HTTP 头的 AVURLAsset。
  ///
  /// AVAssetDownloadTask 走的是独立的 URLSession，没有 WKWebView 的页面会话：
  /// 不带 Referer / UA 时，防盗链源站会直接 403 —— 表现就是「页面里能播、
  /// 嗅探也 ok，一点离线下载就失败」。AVFoundation 至今没有公开的「给下载任务
  /// 加请求头」API，只能靠 AVURLAssetHTTPHeaderFieldsKey（私有 key，但这是
  /// AVAssetDownloadTask 唯一可行的途径，AVPlayer 生态里广泛使用）。
  private func makeAsset(_ url: URL, headers: [String: String]) -> AVURLAsset {
    if headers.isEmpty { return AVURLAsset(url: url) }
    return AVURLAsset(
      url: url,
      options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
    )
  }

  private func playOffline(localUrl: URL) {
    let asset = AVURLAsset(url: localUrl)
    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    let vc = AVPlayerViewController()
    vc.player = player
    guard
      let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
      let root = scene.windows.first?.rootViewController
    else { return }
    root.present(vc, animated: true) { player.play() }
  }

  // MARK: - AVAssetDownloadDelegate

  func urlSession(
    _ session: URLSession,
    assetDownloadTask: AVAssetDownloadTask,
    didLoad timeRange: CMTimeRange,
    totalTimeDownloaded: Double,
    totalTimeExpectedToLoad: Double
  ) {
    guard let taskId = taskIds.first(where: { $0.value == assetDownloadTask })?.key else { return }
    let progress = totalTimeExpectedToLoad > 0 ? totalTimeDownloaded / totalTimeExpectedToLoad : 0
    eventSink?(["taskId": taskId, "progress": progress])
  }

  func urlSession(
    _ session: URLSession,
    assetDownloadTask: AVAssetDownloadTask,
    willDownloadTo location: URL
  ) {
    guard let taskId = taskIds.first(where: { $0.value == assetDownloadTask })?.key else { return }
    localUrls[taskId] = location
    // 落盘持久化：App 重启后缩略图/离线播放仍能按 taskId 找到 .movpkg
    HlsLocalStore.shared.set(taskId, url: location)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard
      let assetTask = task as? AVAssetDownloadTask,
      let taskId = taskIds.first(where: { $0.value == assetTask })?.key
    else { return }
    if let error {
      eventSink?(["taskId": taskId, "done": false, "error": error.localizedDescription])
    } else {
      eventSink?(["taskId": taskId, "done": true])
    }
    taskIds.removeValue(forKey: taskId)
    // 切「静音 / 显示进度」时还有任务在跑：等全部结束再换 session
    if taskIds.isEmpty && pendingRebuild {
      pendingRebuild = false
      // 此方法的 session 参数（URLSession，隐式 let）会遮蔽同名实例属性，
      // 必须写 self.session 才能给属性重新赋值。
      self.session = Self.makeSession(silent: silent, delegate: self)
    }
  }
}

// MARK: - FlutterStreamHandler

extension HlsBridge: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}

// MARK: - HLS 离线包路径持久化
// 缩略图/播放需要在 App 重启后仍能找到 taskId 对应的 .movpkg，
// 旧实现只在内存里存 localUrls，重启即丢。

final class HlsLocalStore {
  static let shared = HlsLocalStore()
  private static let key = "video_downloader.hls.localUrls"
  private var map: [String: String]

  private init() {
    map = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
  }

  func set(_ taskId: String, url: URL) {
    map[taskId] = url.absoluteString
    UserDefaults.standard.set(map, forKey: Self.key)
  }

  func url(for taskId: String) -> URL? {
    guard let s = map[taskId] else { return nil }
    return URL(string: s)
  }

  func remove(_ taskId: String) {
    map.removeValue(forKey: taskId)
    UserDefaults.standard.set(map, forKey: Self.key)
  }
}

// MARK: - 视频缩略图桥接（AVAssetImageGenerator）
// 方法通道: video_downloader/thumb  (get)
// 入参: { key: 条目唯一 id（缓存键）, path?: 本地 mp4 路径, taskId?: HLS 离线包 id }
// 回传: 生成的 jpg 绝对路径；无法出图时回 nil（列表回退到图标）

class ThumbnailBridge: NSObject {
  static let channelName = "video_downloader/thumb"

  private static let maxSize = CGSize(width: 320, height: 320)

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "get" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard
      let args = call.arguments as? [String: Any],
      let key = args["key"] as? String, !key.isEmpty
    else {
      result(nil)
      return
    }
    let dest = cacheFile(for: key)
    // 命中磁盘缓存直接返回，避免每次滚动列表都解码视频
    // （先于源解析：源地址失效时也应能展示已生成的图）
    if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
      let size = attrs[.size] as? NSNumber, size.intValue > 0
    {
      result(dest.path)
      return
    }
    // 源：优先本地文件路径（mp4 / 转码产物 / 分享导入），其次 HLS 离线包
    var source: URL?
    if let p = args["path"] as? String, !p.isEmpty {
      if FileManager.default.fileExists(atPath: p) { source = URL(fileURLWithPath: p) }
    }
    if source == nil, let tid = args["taskId"] as? String, !tid.isEmpty {
      if let u = HlsLocalStore.shared.url(for: tid),
        FileManager.default.fileExists(atPath: u.path)
      {
        source = u
      }
    }
    // 兜底：老版本下载的离线包没有持久化 taskId→路径映射，
    // 退回用原始 m3u8 地址在线抽一帧（仅 http/https，取不到就回 nil）
    if source == nil, let s = args["url"] as? String,
      s.hasPrefix("http"), let u = URL(string: s)
    {
      source = u
    }
    guard let assetURL = source else {
      result(nil)
      return
    }
    let timeMs = args["timeMs"] as? Int ?? 800
    generate(assetURL: assetURL, timeMs: timeMs, dest: dest) { path in
      DispatchQueue.main.async { result(path) }
    }
  }

  private func cacheFile(for key: String) -> URL {
    let fm = FileManager.default
    let base =
      fm.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? fm.temporaryDirectory
    let dir = base.appendingPathComponent("video_thumbnails", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    // key 来自条目 id，理论上安全；仍做一次清洗，避免出现路径分隔符
    let safe = String(key.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    return dir.appendingPathComponent("\(safe).jpg")
  }

  private func generate(
    assetURL: URL, timeMs: Int, dest: URL, done: @escaping (String?) -> Void
  ) {
    let asset = AVURLAsset(url: assetURL)
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = Self.maxSize
    // 抽帧容忍度放大到 1s：避免关键帧间隔大时取不到帧
    gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
    gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
    let time = CMTime(value: CMTimeValue(max(0, timeMs)), timescale: 1000)
    gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
      [weak self] _, image, _, _, _ in
      guard let image else {
        // 首帧/极短视频取不到时退到 0 秒再试一次
        if timeMs > 0 {
          self?.generate(assetURL: assetURL, timeMs: 0, dest: dest, done: done)
        } else {
          done(nil)
        }
        return
      }
      guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.82) else {
        done(nil)
        return
      }
      do {
        try data.write(to: dest, options: .atomic)
        done(dest.path)
      } catch {
        done(nil)
      }
    }
  }
}

// MARK: - 本地文件选择桥接（文件夹选择 → 复制到沙盒 tmp）
// 方法通道: video_downloader/files  (pickFolder)

class FilesBridge: NSObject, UIDocumentPickerDelegate {
  static let channelName = "video_downloader/files"
  private var pendingResult: FlutterResult?

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pickFolder":
      guard pendingResult == nil else {
        result(FlutterError(code: "busy", message: "已有选择器在运行", details: nil))
        return
      }
      pendingResult = result
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
      picker.delegate = self
      picker.allowsMultipleSelection = false
      guard
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
        let root = scene.windows.first?.rootViewController
      else {
        pendingResult = nil
        result(FlutterError(code: "no_vc", message: "无法获取根控制器", details: nil))
        return
      }
      root.present(picker, animated: true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - UIDocumentPickerDelegate

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let src = urls.first else {
      pendingResult?(nil)
      pendingResult = nil
      return
    }
    let scoped = src.startAccessingSecurityScopedResource()
    defer {
      if scoped { src.stopAccessingSecurityScopedResource() }
    }
    let fm = FileManager.default
    let destBase = fm.temporaryDirectory.appendingPathComponent("picked", isDirectory: true)
    let dest = destBase.appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
      try fm.createDirectory(at: destBase, withIntermediateDirectories: true)
      try fm.copyItem(at: src, to: dest)
      pendingResult?(dest.path)
    } catch {
      pendingResult?(
        FlutterError(code: "copy_failed", message: error.localizedDescription, details: nil))
    }
    pendingResult = nil
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingResult?(nil)
    pendingResult = nil
  }
}

// MARK: - 后台任务桥接（iOS beginBackgroundTask，尽力而为）
// 方法通道: video_downloader/bg  (begin / end)

class BackgroundBridge: NSObject {
  static let channelName = "video_downloader/bg"
  private var tasks: [Int: UIBackgroundTaskIdentifier] = [:]
  private var nextId = 1

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "begin":
      let id = nextId
      nextId += 1
      let identifier = UIApplication.shared.beginBackgroundTask(expirationHandler: {
        [weak self] in
        guard let self, let stored = self.tasks[id] else { return }
        if stored != .invalid {
          UIApplication.shared.endBackgroundTask(stored)
        }
        self.tasks.removeValue(forKey: id)
      })
      tasks[id] = identifier
      result(id)
    case "end":
      guard let args = call.arguments as? [String: Any], let id = args["id"] as? Int else {
        result(false)
        return
      }
      if let identifier = tasks.removeValue(forKey: id), identifier != .invalid {
        UIApplication.shared.endBackgroundTask(identifier)
      }
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

// MARK: - 分享接收桥接（其他 App 分享/打开的视频文件 → Documents/Share）
// 方法通道: video_downloader/share  (takePending)

class ShareBridge: NSObject {
  static let channelName = "video_downloader/share"
  private weak var appDelegate: AppDelegate?

  init(appDelegate: AppDelegate) {
    self.appDelegate = appDelegate
  }

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "takePending":
      let files = appDelegate?.takePendingShareFiles() ?? []
      let items = files.map { ["source": $0.path, "name": $0.name] }
      result(items)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

// MARK: - 嗅探脚本早期注入桥接（iOS WKUserScript atDocumentStart + 全帧注入）
// 方法通道: video_downloader/sniffer  (installUserScripts)
// 相比 onPageFinished 的 runJavaScript 注入：
// 1) atDocumentStart —— 先于页面脚本挂钩 fetch/XHR，站点缓存原始 fetch 引用也抓得到；
// 2) forMainFrameOnly:false —— 注入到所有帧（含跨域 iframe 播放器），
//    每次文档加载都会执行（含之后动态创建的 iframe）。
// 首次注入对当前已加载页不生效，下一次导航起生效（onPageFinished 注入继续兜底首页）。

class SnifferBridge: NSObject {
  static let channelName = "video_downloader/sniffer"
  private weak var installedWebView: WKWebView?
  private var installed = false

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "installUserScripts":
      guard let scripts = call.arguments as? [String], !scripts.isEmpty else {
        result(FlutterError(code: "bad_args", message: "scripts 缺失", details: nil))
        return
      }
      result(install(scripts))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 找到 webview_flutter 创建的 WKWebView 并注册 user script；找不到返回 false
  ///（Dart 侧稍后重试，直到 WebView 平台视图就绪）。
  private func install(_ scripts: [String]) -> Bool {
    guard let webView = findWKWebView() else { return false }
    if installedWebView !== webView {
      installedWebView = webView
      installed = false
    }
    if installed { return true }
    let controller = webView.configuration.userContentController
    for src in scripts {
      controller.addUserScript(
        WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }
    installed = true
    return true
  }

  private func findWKWebView() -> WKWebView? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    for window in windows {
      if let wv = findWKWebView(in: window) { return wv }
    }
    return nil
  }

  private func findWKWebView(in view: UIView) -> WKWebView? {
    if let wv = view as? WKWebView { return wv }
    for sub in view.subviews {
      if let found = findWKWebView(in: sub) { return found }
    }
    return nil
  }
}

// MARK: - 原生后台分片下载（background URLSession，作业化）
// 方法通道: video_downloader/native_seg  (submit / cancel / listJobs / markRemuxed)
// 事件通道: video_downloader/native_seg/events
//
// 与 HlsBridge（AVAssetDownloadTask → .movpkg）完全不同：这里下的是清单里的
// 原始分片，落到 App 自己的目录，产物可导出 / 可进 PlayerPage / 有大小与缩略图。
// Apple《Downloading files in the background》的硬约束：
// 1) 必须是 URLSessionDownloadTask（data task 不支持后台）；
// 2) didFinishDownloadingTo 返回前必须把临时文件搬走；
// 3) 全部 task 一次性提交，绝不能「批 4 个 → 下完再提交下一批」，否则系统
//    rate limiter 会随每次唤醒递增延迟，几百个分片基本下不完；
// 4) 后台传输的重定向始终跟随，willPerformHTTPRedirection 不会被调用；
// 5) 用户从多任务界面强杀 App → 系统取消 session 全部传输且不再自动重启。
//
// 状态以 Documents/NativeSegJobs/<jobId>/state.json 为准。后台期间 eventSink
// 可能根本不存在（Flutter 引擎未启动），所以事件只用于前台刷新，正确性靠
// Dart 冷启动 / 回前台调用 listJobs() 对账保证。

final class NativeSegmentBridge: NSObject, URLSessionDownloadDelegate, FlutterStreamHandler {
  static let methodChannelName = "video_downloader/native_seg"
  static let eventChannelName = "video_downloader/native_seg/events"
  static let sessionIdentifier = "video_downloader.native_seg.bg"

  /// 冷启动时 handleEventsForBackgroundURLSession 可能早于 Flutter 引擎初始化，
  /// 先静态暂存 completionHandler，bridge 建好后取走。
  static var pendingCompletion: [String: () -> Void] = [:]

  private lazy var session: URLSession = {
    let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
    cfg.sessionSendsLaunchEvents = true
    // 前台发起时不要让系统择机（否则复现「点了半天 0%」）。
    // 后台发起的任务系统仍会强制按 discretionary 处理，这个标志改不了。
    cfg.isDiscretionary = false
    cfg.httpMaximumConnectionsPerHost = 6
    return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
  }()

  private var eventSink: FlutterEventSink?
  private var completionHandlers: [String: () -> Void] = [:]
  private let lock = NSLock()

  /// 在途 task 的字节计数（taskIdentifier → 已写/预期），仅内存态。
  /// didWriteData 只在 App 运行时（前台）被调用，后台期间不更新，所以它只用于
  /// 「前台真实字节进度」；正确性仍以磁盘分片 + state.json 为准。
  private struct LiveBytes {
    var jobId: String
    var written: Int64 = 0
    var expected: Int64 = 0
  }
  private var live: [Int: LiveBytes] = [:]
  /// jobId → 已落盘分片的字节数（缓存；缺失时扫盘重建）
  private var diskBytes: [String: Int64] = [:]
  /// taskIdentifier → jobId（taskDescription 在后台重启后可能丢失，兜底缓存）
  private var taskJob: [Int: String] = [:]
  /// 事件节流：每个作业最多每 0.5s 推一次（几百个 task 每个都写 state.json 会把 IO 打满）
  private var lastEmitAt: [String: Date] = [:]
  private static let emitInterval: TimeInterval = 0.5

  override init() {
    super.init()
    // 必须用同一 identifier 重建 session，才能接管系统代跑的 task（含冷启动唤醒）。
    _ = session
    for (id, handler) in Self.pendingCompletion {
      completionHandlers[id] = handler
    }
    Self.pendingCompletion.removeAll()
  }

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: Self.methodChannelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    let events = FlutterEventChannel(
      name: Self.eventChannelName, binaryMessenger: messenger)
    events.setStreamHandler(self)
  }

  func storeCompletion(_ identifier: String, handler: @escaping () -> Void) {
    guard identifier == Self.sessionIdentifier else { return }
    completionHandlers[identifier] = handler
    _ = session
  }

  // MARK: - 方法通道

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "submit":
      result(submit(call.arguments))
    case "cancel":
      result(cancelJob(call.arguments))
    case "listJobs":
      result(listJobs())
    case "markRemuxed":
      result(clearJob(call.arguments))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 一次性提交整个作业：写状态文件 + 批量建 task + 全部 resume。
  /// 已存在且非空的分片直接跳过（断点续传），不重复建 task。
  private func submit(_ arguments: Any?) -> Bool {
    guard
      let args = arguments as? [String: Any],
      let jobId = args["jobId"] as? String, !jobId.isEmpty,
      let workDir = args["workDir"] as? String, !workDir.isEmpty,
      let rawParts = args["parts"] as? [[String: Any]]
    else { return false }

    var headers = [String: String]()
    if let rawHeaders = args["headers"] as? [String: Any] {
      for (k, v) in rawHeaders {
        if let s = v as? String { headers[k] = s }
      }
    }
    let playlistPath = args["playlistPath"] as? String ?? ""

    // 只接受可解析的绝对 URL，避免无效项让 finished 永远追不上 total
    let parts: [[String: Any]] = rawParts.compactMap { part in
      guard let u = part["url"] as? String, let n = part["name"] as? String,
        !u.isEmpty, !n.isEmpty, URL(string: u) != nil
      else { return nil }
      return ["url": u, "name": n]
    }
    guard !parts.isEmpty else { return false }

    let fm = FileManager.default
    do {
      try fm.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    } catch {
      return false
    }

    let base = URL(fileURLWithPath: workDir)
    var pending = [[String: Any]]()
    var skipped = 0
    var skippedBytes: Int64 = 0
    for part in parts {
      let name = part["name"] as? String ?? ""
      let path = base.appendingPathComponent(name).path
      if hasNonEmptyFile(path) {
        skipped += 1
        skippedBytes += fileSize(path)
      } else {
        pending.append(part)
      }
    }

    var state: [String: Any] = [
      "jobId": jobId,
      "workDir": workDir,
      "playlistPath": playlistPath,
      "parts": parts,
      "headers": headers,
      "state": "downloading",
      "done": skipped,
      "finished": skipped,
      "failed": 0,
      "total": parts.count,
      "bytes": Int(skippedBytes),
    ]
    saveState(jobId, state)
    lock.lock()
    diskBytes[jobId] = skippedBytes
    lastEmitAt.removeValue(forKey: jobId)
    lock.unlock()

    if pending.isEmpty {
      state["state"] = "ready"
      saveState(jobId, state)
      emit(state)
      return true
    }

    for part in pending {
      guard let urlString = part["url"] as? String,
        let name = part["name"] as? String,
        let url = URL(string: urlString)
      else { continue }
      var req = URLRequest(url: url)
      for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
      let task = session.downloadTask(with: req)
      // 后台 relaunch 后 taskDescription 不保证保留，didFinish 里另有 URL 查表兜底
      task.taskDescription = "\(jobId)|\(name)"
      lock.lock()
      taskJob[task.taskIdentifier] = jobId
      live[task.taskIdentifier] = LiveBytes(jobId: jobId)
      lock.unlock()
      task.resume()
    }
    return true
  }

  private func cancelJob(_ arguments: Any?) -> Bool {
    guard let args = arguments as? [String: Any],
      let jobId = args["jobId"] as? String, !jobId.isEmpty
    else { return false }
    session.getAllTasks { tasks in
      for t in tasks where (t.taskDescription ?? "").hasPrefix("\(jobId)|") {
        t.cancel()
      }
    }
    dropCaches(jobId)
    clearJob(arguments)
    return true
  }

  /// Dart 侧 mp4 合成成功后清状态；分片目录由 ConvertManager._finishMp4 删除。
  @discardableResult
  private func clearJob(_ arguments: Any?) -> Bool {
    guard let args = arguments as? [String: Any],
      let jobId = args["jobId"] as? String, !jobId.isEmpty
    else { return false }
    let dir = stateURL(jobId).deletingLastPathComponent()
    try? FileManager.default.removeItem(at: dir)
    dropCaches(jobId)
    return true
  }

  /// 清掉内存态计数，避免作业被删后还留着字节数
  private func dropCaches(_ jobId: String) {
    lock.lock()
    defer { lock.unlock() }
    let ids = live.filter { $0.value.jobId == jobId }.map { $0.key }
    for tid in ids {
      live.removeValue(forKey: tid)
      taskJob.removeValue(forKey: tid)
    }
    diskBytes.removeValue(forKey: jobId)
    lastEmitAt.removeValue(forKey: jobId)
  }

  private func listJobs() -> [[String: Any]] {
    allStates().map { entry -> [String: Any] in
      let st = entry.1
      let p = progress(for: entry.0, state: st)
      return [
        "jobId": st["jobId"] as? String ?? "",
        "state": st["state"] as? String ?? "downloading",
        "workDir": st["workDir"] as? String ?? "",
        "done": st["done"] as? Int ?? 0,
        "total": st["total"] as? Int ?? 0,
        "bytes": Int(p.bytes),
        "bytesTotal": Int(p.total),
        "bytesEstimated": p.estimated,
        "error": st["error"] as? String ?? "",
      ]
    }
  }

  // MARK: - 字节进度

  /// 已下字节 = 已落盘分片 + 在途 task 已写字节；总量在拿不到 Content-Length
  /// 的分片上按已知分片均值外推（estimated=true 时 Dart 侧标 ≈）。
  private func progress(for jobId: String, state: [String: Any])
    -> (bytes: Int64, total: Int64, estimated: Bool)
  {
    let workDir = state["workDir"] as? String ?? ""
    lock.lock()
    if diskBytes[jobId] == nil { diskBytes[jobId] = scanBytes(workDir) }
    let disk = diskBytes[jobId] ?? 0
    var written: Int64 = 0
    var knownExp: Int64 = 0
    var knownCnt = 0
    var unknownCnt = 0
    for (_, c) in live where c.jobId == jobId {
      written += c.written
      if c.expected > 0 {
        knownExp += c.expected
        knownCnt += 1
      } else {
        unknownCnt += 1
      }
    }
    lock.unlock()

    let bytes = disk + written
    // 一个 Content-Length 都还没拿到时（全部 task 排队中）不给总量：
    // 返回 bytes 会让 Dart 算出「已下 == 总量 == 100%」，正是要避免的假进度。
    var total: Int64 = 0
    if knownCnt > 0 {
      total = disk + knownExp
      if unknownCnt > 0 {
        total += Int64(Double(knownExp) / Double(knownCnt) * Double(unknownCnt))
      }
      if total < bytes { total = bytes }
    }
    return (bytes, total, unknownCnt > 0)
  }

  /// 目录内实际落盘字节（冷启动接管系统代跑 task 时用它重建基线）
  private func scanBytes(_ workDir: String) -> Int64 {
    guard !workDir.isEmpty else { return 0 }
    let fm = FileManager.default
    guard
      let names = try? fm.contentsOfDirectory(atPath: workDir)
    else { return 0 }
    var sum: Int64 = 0
    for n in names {
      // playlist.m3u8 也在同一目录，几 KB，忽略不影响进度
      if n.hasSuffix(".m3u8") { continue }
      sum += fileSize((workDir as NSString).appendingPathComponent(n))
    }
    return sum
  }

  private func fileSize(_ path: String) -> Int64 {
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
  }

  /// 节流判定（同时记录本次推送时间）
  private func shouldEmit(_ jobId: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let now = Date()
    if let last = lastEmitAt[jobId], now.timeIntervalSince(last) < Self.emitInterval {
      return false
    }
    lastEmitAt[jobId] = now
    return true
  }

  // MARK: - URLSessionDownloadDelegate

  /// 前台实时字节进度。后台期间系统不会调用（App 被挂起），所以这里只用于
  /// 「亮屏时的真实速度」，回前台/冷启动的进度由 listJobs() 扫盘重建。
  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    let tid = downloadTask.taskIdentifier
    lock.lock()
    let jobId = taskJob[tid] ?? Self.jobIdOf(downloadTask)
    if let jobId {
      var c = live[tid] ?? LiveBytes(jobId: jobId)
      c.written = totalBytesWritten
      if totalBytesExpectedToWrite > 0 { c.expected = totalBytesExpectedToWrite }
      live[tid] = c
      taskJob[tid] = jobId
    }
    lock.unlock()
    guard let jid = jobId, shouldEmit(jid), let st = loadState(jid) else { return }
    emit(st)
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    guard let resolved = resolve(task: downloadTask) else { return }
    let jobId = resolved.0
    let name = resolved.1
    let st = resolved.2
    let workDir = st["workDir"] as? String ?? ""
    let dest = URL(fileURLWithPath: workDir).appendingPathComponent(name)
    let fm = FileManager.default
    var ok = false
    // 后台 session 会把 403/404 的响应体也当「下载成功」交给 delegate，
    // 不校验状态码就会把错误页当成 .ts 落盘，最后 ffmpeg 才报错且无法定位。
    let httpOk = (downloadTask.response as? HTTPURLResponse)
      .map { (200...299).contains($0.statusCode) } ?? true
    if httpOk {
      try? fm.removeItem(at: dest)
      do {
        // 官方：临时文件只在 delegate 方法返回前有效，必须同步搬走
        try fm.moveItem(at: location, to: dest)
        ok = hasNonEmptyFile(dest.path)
      } catch {
        ok = false
      }
    }
    // 这一片的实际大小计入磁盘基线，同时清掉在途计数（避免同一片被算两次）
    let tid = downloadTask.taskIdentifier
    lock.lock()
    if ok { diskBytes[jobId, default: 0] += fileSize(dest.path) }
    live.removeValue(forKey: tid)
    taskJob.removeValue(forKey: tid)
    let diskNow = diskBytes[jobId] ?? 0
    lock.unlock()

    if let updated = updateState(jobId, { state in
      state["finished"] = (state["finished"] as? Int ?? 0) + 1
      if ok {
        state["done"] = (state["done"] as? Int ?? 0) + 1
        state["bytes"] = Int(diskNow)
      } else {
        state["failed"] = (state["failed"] as? Int ?? 0) + 1
        if state["error"] == nil { state["error"] = "分片落盘失败: \(name)" }
      }
      self.finalizeIfNeeded(&state)
    }) {
      emit(updated)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let tid = task.taskIdentifier
    lock.lock()
    live.removeValue(forKey: tid)
    taskJob.removeValue(forKey: tid)
    lock.unlock()
    // 成功路径已在 didFinishDownloadingTo 里计过 finished，这里只补失败
    guard let error else { return }
    guard let resolved = resolve(task: task) else { return }
    let jobId = resolved.0
    if let updated = updateState(jobId, { state in
      state["finished"] = (state["finished"] as? Int ?? 0) + 1
      state["failed"] = (state["failed"] as? Int ?? 0) + 1
      if state["error"] == nil { state["error"] = error.localizedDescription }
      self.finalizeIfNeeded(&state)
    }) {
      emit(updated)
    }
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let handler = self.completionHandlers.removeValue(forKey: Self.sessionIdentifier)
      handler?()
    }
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  // MARK: - 状态文件

  private func jobsRoot() -> URL {
    let fm = FileManager.default
    let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? fm.temporaryDirectory
    let dir = base.appendingPathComponent("NativeSegJobs", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func stateURL(_ jobId: String) -> URL {
    let safe = String(jobId.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    return jobsRoot()
      .appendingPathComponent(safe, isDirectory: true)
      .appendingPathComponent("state.json")
  }

  private func loadState(_ jobId: String) -> [String: Any]? {
    guard let data = try? Data(contentsOf: stateURL(jobId)),
      let obj = try? JSONSerialization.jsonObject(with: data),
      let j = obj as? [String: Any]
    else { return nil }
    return j
  }

  private func saveState(_ jobId: String, _ state: [String: Any]) {
    let url = stateURL(jobId)
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let data = try? JSONSerialization.data(withJSONObject: state) else { return }
    try? data.write(to: url, options: .atomic)
  }

  private func allStates() -> [(String, [String: Any])] {
    let fm = FileManager.default
    guard
      let dirs = try? fm.contentsOfDirectory(
        at: jobsRoot(), includingPropertiesForKeys: nil)
    else { return [] }
    var out: [(String, [String: Any])] = []
    for d in dirs {
      let f = d.appendingPathComponent("state.json")
      guard let data = try? Data(contentsOf: f),
        let obj = try? JSONSerialization.jsonObject(with: data),
        let j = obj as? [String: Any]
      else { continue }
      out.append(((j["jobId"] as? String) ?? d.lastPathComponent, j))
    }
    return out
  }

  @discardableResult
  private func updateState(
    _ jobId: String, _ mutate: (inout [String: Any]) -> Void
  ) -> [String: Any]? {
    lock.lock()
    defer { lock.unlock() }
    guard var st = loadState(jobId) else { return nil }
    mutate(&st)
    saveState(jobId, st)
    return st
  }

  private func finalizeIfNeeded(_ state: inout [String: Any]) {
    let total = state["total"] as? Int ?? 0
    let finished = state["finished"] as? Int ?? 0
    guard total > 0, finished >= total,
      (state["state"] as? String ?? "downloading") == "downloading"
    else { return }
    let failed = state["failed"] as? Int ?? 0
    state["state"] = failed > 0 ? "failed" : "ready"
  }

  private func emit(_ state: [String: Any]) {
    let jobId = state["jobId"] as? String ?? ""
    let p = progress(for: jobId, state: state)
    let payload: [String: Any] = [
      "jobId": jobId,
      "state": state["state"] as? String ?? "downloading",
      "done": state["done"] as? Int ?? 0,
      "total": state["total"] as? Int ?? 0,
      "bytes": Int(p.bytes),
      "bytesTotal": Int(p.total),
      "bytesEstimated": p.estimated,
      "error": state["error"] as? String ?? "",
    ]
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(payload)
    }
  }

  /// 从 taskDescription（`<jobId>|<name>`）取 jobId；后台重启后可能为空
  private static func jobIdOf(_ task: URLSessionTask) -> String? {
    guard let desc = task.taskDescription,
      let range = desc.range(of: "|")
    else { return nil }
    let id = String(desc[desc.startIndex..<range.lowerBound])
    return id.isEmpty ? nil : id
  }

  private func hasNonEmptyFile(_ path: String) -> Bool {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
      let size = attrs[.size] as? NSNumber
    else { return false }
    return size.intValue > 0
  }

  /// 定位回调属于哪个作业 / 哪个文件。taskDescription 在后台重启后可能丢失，
  /// 因此再用 originalRequest.url 去所有 state.json 的 parts 里查一遍。
  private func resolve(task: URLSessionTask) -> (String, String, [String: Any])? {
    if let desc = task.taskDescription,
      let range = desc.range(of: "|"),
      let st = loadState(String(desc[desc.startIndex..<range.lowerBound]))
    {
      let jobId = String(desc[desc.startIndex..<range.lowerBound])
      let name = String(desc[range.upperBound...])
      if !jobId.isEmpty && !name.isEmpty { return (jobId, name, st) }
    }
    guard let urlString = task.originalRequest?.url?.absoluteString else { return nil }
    for (jobId, st) in allStates() {
      guard let parts = st["parts"] as? [[String: Any]] else { continue }
      for part in parts {
        if let u = part["url"] as? String, u == urlString,
          let name = part["name"] as? String
        {
          return (jobId, name, st)
        }
      }
    }
    return nil
  }
}
