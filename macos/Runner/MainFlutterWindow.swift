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

    super.awakeFromNib()
  }
}
