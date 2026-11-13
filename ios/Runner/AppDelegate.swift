import AVFoundation
import AVKit
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var hlsBridge: HlsBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "HlsBridge") {
      let bridge = HlsBridge()
      bridge.register(with: registrar.messenger())
      hlsBridge = bridge
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
    } else {
      pendingResults.removeValue(forKey: taskId)?(localUrls[taskId]?.path ?? "")
    }
    taskIds.removeValue(forKey: taskId)
    eventSink?(["taskId": taskId, "done": error == nil])
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
