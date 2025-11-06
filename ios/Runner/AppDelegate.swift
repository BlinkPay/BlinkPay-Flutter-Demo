import Flutter
import UIKit
import SafariServices

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
    // Only dismiss Safari VC if both scheme and host match (consistent with Android)
    if url.scheme == "blinkpaydemo" && url.host == "callback" {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self.dismissSafariViewControllerIfPresent()
      }
    }

    return super.application(app, open: url, options: options)
  }

  func dismissSafariViewControllerIfPresent() {
    // Use connectedScenes API (Requires iOS 13.0+ Deployment Target in Xcode)
    guard let window = UIApplication.shared.connectedScenes
              .filter({$0.activationState == .foregroundActive})
              .compactMap({$0 as? UIWindowScene})
              .first?.windows
              .filter({$0.isKeyWindow}).first, let rootViewController = window.rootViewController else {
      print("AppDelegate: Could not get key window or root view controller.")
      return
    }

    var topViewController = rootViewController
    while let presentedViewController = topViewController.presentedViewController {
      topViewController = presentedViewController
    }

    if let safariVC = topViewController as? SFSafariViewController {
      print("AppDelegate: Found SFSafariViewController (\(safariVC)), dismissing it.")
      safariVC.dismiss(animated: true, completion: nil)
    } else {
      print("AppDelegate: Topmost view controller (\(topViewController)) is not SFSafariViewController.")
    }
  }
}
