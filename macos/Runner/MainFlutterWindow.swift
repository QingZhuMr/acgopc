import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 注册自定义照片选择器插件（macOS 照片库选择）
    // 注意：macOS 的 FlutterViewController.registrar(forPlugin:) 返回非可选值
    let registrar = flutterViewController.registrar(forPlugin: "PhotoPickerPlugin")
    PhotoPickerPlugin.register(with: registrar)

    // 注册系统通知插件（UNUserNotificationCenter，替换 local_notifier 的废弃 API）
    let notifyRegistrar = flutterViewController.registrar(forPlugin: "SystemNotificationPlugin")
    SystemNotificationPlugin.register(with: notifyRegistrar)

    super.awakeFromNib()
  }
}
