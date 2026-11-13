// MVP-4 分享扩展（待激活）
// 方案：免费账号无 App Groups → 剪贴板交接。
// 流程：接收分享的 URL → 跟随重定向解析 → 写入系统剪贴板 → 尝试用自定义 scheme 唤起主 App
//      （唤起若不生效，用户手动打开主 App，启动时检测剪贴板导入，见 lib/services/share_import.dart）
// ⚠️ 本文件尚未加入 Xcode target（见 README.md 激活步骤），激活后由 CI 编译验证。

import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    handle()
  }

  private func handle() {
    guard
      let item = extensionContext?.inputItems.first as? NSExtensionItem,
      let provider = item.attachments?.first
    else {
      complete()
      return
    }

    let urlType = UTType.url.identifier
    if provider.hasItemConformingToTypeIdentifier(urlType) {
      provider.loadItem(forTypeIdentifier: urlType, options: nil) { [weak self] (loaded, _) in
        guard let self = self else { return }
        if let url = loaded as? URL {
          // 解析重定向（抖音/快手短链等）
          var resolved = url.absoluteString
          if let finalURL = self.resolveRedirect(url) {
            resolved = finalURL
          }
          UIPasteboard.general.string = resolved
          // 尝试唤起主 App（自定义 scheme；官方不保证 Share Extension 可用，实测为准）
          if let appURL = URL(string: "videodl://import") {
            UIApplication.shared.open(appURL, options: [:], completionHandler: nil)
          }
        }
        self.complete()
      }
    } else {
      complete()
    }
  }

  /// 跟随重定向拿到最终 URL（超时 10s，失败返回原链接）
  private func resolveRedirect(_ url: URL) -> URL? {
    var request = URLRequest(url: url)
    request.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
      forHTTPHeaderField: "User-Agent")
    var finalURL: URL?
    let sema = DispatchSemaphore(value: 0)
    let task = URLSession.shared.dataTask(with: request) { _, response, _ in
      finalURL = response?.url
      sema.signal()
    }
    task.resume()
    _ = sema.wait(timeout: .now() + 10)
    return finalURL
  }

  private func complete() {
    extensionContext?.completeRequest(returningItems: nil)
  }
}
