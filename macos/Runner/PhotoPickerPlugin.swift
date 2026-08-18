import Cocoa
import FlutterMacOS
import PhotosUI
import UniformTypeIdentifiers

/// macOS 照片选择器插件：通过 MethodChannel 调起系统照片库选择器（PHPickerViewController），
/// 返回选中图片的字节数据，供发动态/头像/评论/表情包上传使用。
class PhotoPickerPlugin: NSObject, FlutterPlugin {
  private static let channelName = "com.acgo/photopicker"

  /// 当前正在进行的选择回调
  private var pendingResult: FlutterResult?
  private var pickerVC: PHPickerViewController?
  /// 照片选择器所在窗口（独立窗口呈现，便于关闭）
  private var pickerWindow: NSWindow?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger)
    let instance = PhotoPickerPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pickImages":
      // 参数：allowMultiple 是否允许多选
      let allowMultiple = (call.arguments as? [String: Any])?["allowMultiple"] as? Bool ?? false
      showPhotoPicker(allowMultiple: allowMultiple, result: result)
    case "readImage":
      // 读取系统剪贴板中的图片（NSPasteboard），返回图片字节数组
      readClipboardImage(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 从系统剪贴板读取图片字节（PNG 优先，回退 TIFF）。
  /// 返回 UInt8 数组（Flutter 侧转 Uint8List）；无图片返回空数组。
  private func readClipboardImage(result: @escaping FlutterResult) {
    let pasteboard = NSPasteboard.general
    // 取剪贴板数据：先找 PNG，再找 TIFF（macOS 复制图片时常见这两种）
    var data = pasteboard.data(forType: .png)
    if data == nil {
      data = pasteboard.data(forType: .tiff)
    }
    guard let imageData = data else {
      result([])
      return
    }
    // 统一转成 PNG：TIFF/PNG 都转 PNG（保透明、兼容性好，Dart 侧再按需转 jpg）。
    // 注意：必须返回 FlutterStandardTypedData（Dart 侧 decode 为 Uint8List），
    // 不能解包成 Data——Data 不是标准编解码器支持的类型。
    if let nsImage = NSImage(data: imageData),
       let pngData = nsImage.pngData() {
      result(FlutterStandardTypedData(bytes: pngData))
    } else {
      // NSImage 转换失败时直接返回原始数据（可能是 PNG）
      result(FlutterStandardTypedData(bytes: imageData))
    }
  }

  private func showPhotoPicker(allowMultiple: Bool, result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(FlutterError(code: "busy", message: "照片选择器已打开", details: nil))
      return
    }
    // PHPickerViewController 在 macOS 13.0+ 可用
    guard #available(macOS 13.0, *) else {
      result(FlutterError(code: "unsupported", message: "macOS 13.0 及以上版本才支持照片选择器", details: nil))
      return
    }
    guard let window = NSApp.keyWindow ?? NSApp.windows.first else {
      result(FlutterError(code: "no_window", message: "无法获取主窗口", details: nil))
      return
    }

    pendingResult = result

    var config = PHPickerConfiguration()
    config.selectionLimit = allowMultiple ? 9 : 1
    config.filter = .images

    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    pickerVC = picker

    // 以独立窗口呈现照片选择器，并设置合理的初始尺寸，避免系统默认的极小弹框
    let pickerWindow = NSWindow(contentViewController: picker)
    pickerWindow.title = allowMultiple ? "选择照片" : "选择照片"
    pickerWindow.setContentSize(NSSize(width: 680, height: 560))
    pickerWindow.minSize = NSSize(width: 480, height: 400)
    pickerWindow.styleMask = [.titled, .closable, .resizable]
    pickerWindow.isReleasedWhenClosed = false
    pickerWindow.center()
    pickerWindow.makeKeyAndOrderFront(nil)
    self.pickerWindow = pickerWindow
    NSApp.activate(ignoringOtherApps: true)
  }

  private func finish(_ value: Any?) {
    // 关闭照片选择器窗口
    pickerWindow?.close()
    pickerWindow = nil
    let res = pendingResult
    pendingResult = nil
    pickerVC = nil
    res?(value)
  }
}

extension PhotoPickerPlugin: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    // 用户点选完成：关闭选择器窗口（图片仍在异步读取，等读取完再 finish）
    pickerWindow?.close()
    pickerWindow = nil
    pickerVC = nil

    guard !results.isEmpty else {
      // 用户取消
      finish(nil)
      return
    }

    let group = DispatchGroup()
    var images: [String] = [] // base64 编码的图片原始字节
    let lock = NSLock()

    for item in results {
      group.enter()
      let provider = item.itemProvider
      // 读取原始图片字节，保持原格式（含 GIF 动画），避免 NSImage 转 JPEG 丢失动画/透明度
      provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
        if let data {
          lock.lock()
          images.append(data.base64EncodedString())
          lock.unlock()
        }
        group.leave()
      }
    }

    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      if images.isEmpty {
        self.finish(nil)
      } else {
        self.finish(images)
      }
    }
  }
}

/// NSImage → PNG 字节（macOS 的 NSImage 没有内置 pngData，与 iOS UIImage 不同）
extension NSImage {
  func pngData() -> Data? {
    guard let tiff = tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
  }
}
