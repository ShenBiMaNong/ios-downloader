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
      let asset = AVURLAsset(url: urlObj)
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
        let taskId = args["taskId"] as? String,
        let localUrl = localUrls[taskId]
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
      let asset = AVURLAsset(url: urlObj)
      let downloadConfig = AVAssetDownloadConfiguration(asset: asset, title: title)
      let task = session.makeAssetDownloadTask(downloadConfiguration: downloadConfig)
      taskIds[taskId] = task
      task.resume()
      result(true)

    default:
      result(FlutterMethodNotImplemented)
    }
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
