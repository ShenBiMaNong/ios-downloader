import AVFoundation
import AVKit
import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var hlsBridge: HlsBridge?
  private var filesBridge: FilesBridge?
  private var backgroundBridge: BackgroundBridge?
  private var shareBridge: ShareBridge?

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
  private func enqueueShare(_ url: URL) {
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
  private var pendingResults = [String: FlutterResult]()
  private var eventSink: FlutterEventSink?

  override init() {
    super.init()
    let config = URLSessionConfiguration.background(withIdentifier: "video_downloader.hls.bg")
    config.isDiscretionary = false
    config.sessionSendsLaunchEvents = true
    session = AVAssetDownloadURLSession(
      configuration: config, assetDownloadDelegate: self, delegateQueue: .main)
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
      let taskId = UUID().uuidString
      taskIds[taskId] = task
      pendingResults[taskId] = result
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
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard
      let assetTask = task as? AVAssetDownloadTask,
      let taskId = taskIds.first(where: { $0.value == assetTask })?.key
    else { return }
    if let error {
      pendingResults.removeValue(forKey: taskId)?(
        FlutterError(code: "download_failed", message: error.localizedDescription, details: nil))
      eventSink?(["taskId": taskId, "done": false, "error": error.localizedDescription])
    } else {
      pendingResults.removeValue(forKey: taskId)?(localUrls[taskId]?.path ?? "")
      eventSink?(["taskId": taskId, "done": true])
    }
    taskIds.removeValue(forKey: taskId)
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
