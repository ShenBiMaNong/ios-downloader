import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  /// 其他 App 分享/打开的视频文件（iOS 13+ 场景生命周期）：
  /// 热启动走 scene(_:openURLContexts:)，冷启动在 willConnectTo 的 urlContexts 里。
  /// 系统把文件拷进本 App 沙盒 tmp/inbox（或传 security-scoped 原文件），
  /// 统一交给 AppDelegate 入队，Flutter 侧 takePending() 取走导入 Documents/Share。
  /// （场景生命周期下 AppDelegate.application(_:open:options:) 不会被调用，
  ///   此前文件分享被当作深链路由吞掉，导致「分享无反应」——必须在这里接收。）
  private func enqueueFileUrls(_ urls: [URL]) {
    guard let app = UIApplication.shared.delegate as? AppDelegate else { return }
    for url in urls where url.isFileURL {
      app.enqueueShare(url)
    }
  }

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    enqueueFileUrls(connectionOptions.urlContexts.map { $0.url })
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    enqueueFileUrls(URLContexts.map { $0.url })
  }
}
