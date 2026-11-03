import Flutter
import UIKit

// Вход через Google открывается в браузере, а ответ приходит ссылкой
// com.googleusercontent.apps.<id>:/oauth2redirect — передаём её во Flutter.
@main
@objc class AppDelegate: FlutterAppDelegate {
  private var authChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      authChannel = FlutterMethodChannel(name: "cavey/auth", binaryMessenger: controller.binaryMessenger)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if url.scheme?.hasPrefix("com.googleusercontent.apps.") == true {
      authChannel?.invokeMethod("redirect", arguments: url.absoluteString)
      return true
    }
    return super.application(app, open: url, options: options)
  }
}
