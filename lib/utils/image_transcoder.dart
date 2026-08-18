import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

/// 图片客户端转码工具
///
/// 规范：所有图片类上传（头像/帖子/评论/聊天）在客户端统一转码为 **JPEG**
/// （支持 webp/png/bmp/jpg 等解码），GIF 动图保留原样（除头像禁止外）。
/// 转码在客户端完成，服务端只需按 JPEG 处理，减少带宽与存储。
class ImageTranscoder {
  ImageTranscoder._();

  /// 读取系统剪贴板中的图片字节。
  /// - **Windows**：dart:ffi 直连 user32/kernel32 读 CF_DIBV5/CF_DIB（GDI DIB，
  ///   浏览器/截图工具复制图片时系统统一转成该格式），转 BMP 字节返回；
  /// - **macOS**：走原生 MethodChannel「com.acgo/photopicker/readClipboardImage」
  ///   （NSPasteboard 读 PNG/TIFF 图片）；
  /// - 其他平台：返回 null（粘贴图片暂不支持）。
  /// 无图片/读取失败返回 null。
  static Future<Uint8List?> readClipboardImage() async {
    try {
      if (Platform.isWindows) {
        final dib = _readClipboardDibWindows();
        if (dib == null || dib.length < 40) return null;
        // DIB 前 40 字节为 BITMAPINFOHEADER（BITMAPV5HEADER 前 40 字节兼容）
        // 构造完整 BMP 文件：14 字节 BITMAPFILEHEADER + BITMAPINFOHEADER + 像素
        final bmp = Uint8List(14 + dib.length);
        bmp[0] = 0x42; // 'B'
        bmp[1] = 0x4D; // 'M'
        _writeInt32(bmp, 2, bmp.length); // bfSize
        final headerSize = _readInt32(dib, 0); // bfOffBits = 14 + header size
        _writeInt32(bmp, 10, 14 + headerSize);
        bmp.setAll(14, dib);
        return bmp;
      }
      if (Platform.isMacOS) {
        // 复用照片选择器原生插件的通道（已注册 com.acgo/photopicker）
        const channel = MethodChannel('com.acgo/photopicker');
        final data = await channel.invokeMethod<Uint8List>('readImage');
        if (data == null || data.isEmpty) return null;
        return data;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ---- Windows：dart:ffi 直连 Win32（不依赖 win32 包，macOS 上不会 import 崩溃） ----
  // 常量
  static const int _kCfDib = 8;
  static const int _kCfDibV5 = 17;

  static bool? _win32Loaded;
  static int Function(int hWnd)? _openClipboard;
  static int Function(int format)? _isFormatAvailable;
  static int Function(int format)? _getClipboardData;
  static int Function(int hMem)? _globalLock;
  static int Function(int hMem)? _globalUnlock;
  static int Function(int hMem)? _globalSize;
  static int Function()? _closeClipboard;

  /// 懒加载 user32/kernel32 函数（非 Windows 返回 false）
  static bool _loadWin32() {
    if (_win32Loaded != null) return _win32Loaded!;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      _openClipboard = user32
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
              'OpenClipboard');
      _isFormatAvailable = user32
          .lookupFunction<Int32 Function(Uint32), int Function(int)>(
              'IsClipboardFormatAvailable');
      _getClipboardData = user32
          .lookupFunction<IntPtr Function(Uint32), int Function(int)>(
              'GetClipboardData');
      _closeClipboard = user32
          .lookupFunction<Int32 Function(), int Function()>('CloseClipboard');
      _globalLock = kernel32
          .lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
              'GlobalLock');
      _globalUnlock = kernel32
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
              'GlobalUnlock');
      _globalSize = kernel32
          .lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
              'GlobalSize');
      _win32Loaded = true;
      return true;
    } catch (_) {
      _win32Loaded = false;
      return false;
    }
  }

  /// Windows：打开剪贴板读 DIB（优先 CF_DIBV5，回退 CF_DIB）
  static Uint8List? _readClipboardDibWindows() {
    if (!_loadWin32()) return null;
    try {
      if (_openClipboard!(0) == 0) return null;
      try {
        final format = _isFormatAvailable!(_kCfDibV5) != 0
            ? _kCfDibV5
            : (_isFormatAvailable!(_kCfDib) != 0 ? _kCfDib : 0);
        if (format == 0) return null;
        final hMem = _getClipboardData!(format);
        if (hMem == 0) return null;
        final ptr = _globalLock!(hMem);
        if (ptr == 0) return null;
        try {
          final size = _globalSize!(hMem);
          if (size <= 0) return null;
          final typed = Pointer<Uint8>.fromAddress(ptr);
          return Uint8List.fromList(typed.asTypedList(size));
        } finally {
          _globalUnlock!(hMem);
        }
      } finally {
        _closeClipboard!();
      }
    } catch (_) {
      return null;
    }
  }

  static int _readInt32(Uint8List data, int offset) {
    final bd = ByteData.sublistView(data, offset, offset + 4);
    return bd.getInt32(0, Endian.little);
  }

  static void _writeInt32(Uint8List data, int offset, int value) {
    final bd = ByteData.sublistView(data, offset, offset + 4);
    bd.setInt32(0, value, Endian.little);
  }

  /// JPEG 编码质量（88 为体积/画质平衡，行业常用）
  static const int jpegQuality = 88;

  /// 判断字节是否为 GIF 动图（魔数 GIF8）
  static bool isGif(Uint8List bytes) {
    if (bytes.length < 6) return false;
    return bytes[0] == 0x47 && // 'G'
        bytes[1] == 0x49 && // 'I'
        bytes[2] == 0x46 && // 'F'
        bytes[3] == 0x38; // '8'
  }

  /// 判断字节是否为 JPEG（魔数 FFD8）
  static bool isJpeg(Uint8List bytes) {
    if (bytes.length < 2) return false;
    return bytes[0] == 0xFF && bytes[1] == 0xD8;
  }

  /// 按文件名后缀判断是否图片格式
  static bool isImageName(String name) {
    final n = name.toLowerCase();
    return n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.png') ||
        n.endsWith('.gif') ||
        n.endsWith('.webp') ||
        n.endsWith('.bmp');
  }

  /// 统一转码：GIF 原样返回；其余格式解码 → JPEG 重编码。
  ///
  /// 返回 [bytes]（转码后字节）与 [name]（转码后的文件名，GIF 保持原名）。
  /// 解码失败返回 null（调用方提示换图）。
  static Future<({Uint8List bytes, String name})?> toJpeg({
    required Uint8List bytes,
    required String name,
  }) async {
    // GIF 动图保留动画（不重编码）
    if (isGif(bytes)) return (bytes: bytes, name: name);
    // 已是 JPEG 且字节有效，直接返回（避免无谓解码）
    if (isJpeg(bytes)) return (bytes: bytes, name: _jpegName(name));
    try {
      // 用 image 包解码（支持 webp/png/bmp/jpg 等）再编码 JPEG
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      final jpg = img.encodeJpg(decoded, quality: jpegQuality);
      if (jpg.isEmpty) return null;
      return (bytes: Uint8List.fromList(jpg), name: _jpegName(name));
    } catch (_) {
      return null;
    }
  }

  /// 规范化文件名：统一 .jpg 后缀
  static String _jpegName(String name) {
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    return '$stem.jpg';
  }
}
