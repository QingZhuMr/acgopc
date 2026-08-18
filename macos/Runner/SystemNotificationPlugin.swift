import Cocoa
import FlutterMacOS
import UserNotifications

/// macOS 系统通知插件：基于 UNUserNotificationCenter（现代 API）。
/// 用于替换 local_notifier 的废弃 NSUserNotificationCenter 实现。
/// - notify：发送通知（自动请求授权，未授权则请求）
/// - onNotificationClick：点击通知回调（MethodChannel → Flutter）
class SystemNotificationPlugin: NSObject, FlutterPlugin {
  private static let channelName = "com.acgo/system_notification"

  private var channel: FlutterMethodChannel?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger)
    let instance = SystemNotificationPlugin()
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)

    // 设置通知中心 delegate（点击回调需在此触发）
    UNUserNotificationCenter.current().delegate = instance
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "notify":
      let args = call.arguments as? [String: Any] ?? [:]
      notify(
        title: args["title"] as? String ?? "",
        subtitle: args["subtitle"] as? String ?? "",
        identifier: args["identifier"] as? String,
        result: result
      )
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 发送通知：先请求授权（首次弹系统询问），授权后再投递。
  private func notify(
    title: String,
    subtitle: String,
    identifier: String?,
    result: @escaping FlutterResult
  ) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
      DispatchQueue.main.async {
        guard let self else {
          result(false)
          return
        }
        guard granted else {
          // 用户未授权：回调失败（应用内通知仍可用）
          result(false)
          return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        if !subtitle.isEmpty {
          content.subtitle = subtitle
        }
        // 点击回调按 identifier 分发
        content.userInfo = ["identifier": identifier ?? ""]

        // 立即触发（trigger 用 0.1 秒延迟，避免 timeInterval=0 报错）
        let request = UNNotificationRequest(
          identifier: identifier ?? UUID().uuidString,
          content: content,
          trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        center.add(request) { error in
          DispatchQueue.main.async {
            result(error == nil)
          }
        }
      }
    }
  }
}

extension SystemNotificationPlugin: UNUserNotificationCenterDelegate {
  /// 应用前台时也展示通知（默认前台不展示）
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(macOS 11.0, *) {
      completionHandler([.banner, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

  /// 点击通知回调 → MethodChannel 通知 Flutter（仅通知点击，不自动跳转）
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    let identifier = userInfo["identifier"] as? String ?? ""
    if !identifier.isEmpty {
      channel?.invokeMethod("onNotificationClick", arguments: ["identifier": identifier])
    }
    completionHandler()
  }
}
