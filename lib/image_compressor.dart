import 'dart:typed_data';
import 'dart:ui' as ui;

/// 表情包压缩结果
class CompressedSticker {
  final Uint8List bytes;
  final String filename;
  final int width;
  final int height;
  final String mime; // 存储后缀：png / gif

  const CompressedSticker({
    required this.bytes,
    required this.filename,
    required this.width,
    required this.height,
    required this.mime,
  });
}

/// 表情包图片压缩工具（客户端处理，避免服务端压力）
///
/// 行业标准（微信/QQ 表情包）：
///   - 尺寸 240x240（静态图强制 contain 进 240x240 画布，透明底保留）
///   - 压缩后大小 ≤ 256KB（GIF 动图 128KB 太紧，256KB 是业界通行上限）
///   - 上传原图上限 1MB（用户选择时就拦截）
///
/// 处理策略：
///   - GIF：不重编码（保持动画），仅校验尺寸（≤512）与字节数（≤256KB）
///   - 静态图（png/jpg/webp/bmp）：解码 → contain 缩放 → PNG 重编码，
///     若超 256KB 依次缩小尺寸重试（240 → 200 → 160 → 128）
/// 客户端处理完后才上传，服务端只需校验格式/大小/尺寸，防止绕过处理。
class StickerCompressor {
  StickerCompressor._();

  /// 压缩后字节数上限（256KB，行业通行）
  static const int maxBytes = 256 * 1024;

  /// 用户原图上传上限（1MB）
  static const int sourceMaxBytes = 1024 * 1024;

  /// 表情包目标尺寸（微信/QQ 标准 240x240）
  static const int targetSize = 240;

  /// GIF 最大边长（不做重编码，仅校验；超大 GIF 直接拒绝）
  static const int maxGifSide = 512;

  /// 静态图重编码候选尺寸（从大到小尝试，直到 ≤256KB）
  static const List<int> _candidateSizes = [240, 200, 160, 128];

  /// 压缩入口
  ///
  /// 返回 [CompressedSticker] 表示成功；返回错误文案表示拒绝。
  static Future<({CompressedSticker? sticker, String? error})> compress({
    required Uint8List bytes,
    required String filename,
  }) async {
    final name = filename.toLowerCase();

    // 1) 原图大小校验（1MB）
    if (bytes.length > sourceMaxBytes) {
      return (sticker: null, error: '图片不能超过 1MB');
    }

    // 2) 类型判定
    final isGif = name.endsWith('.gif') || _isGifBytes(bytes);
    final isStatic =
        name.endsWith('.png') || name.endsWith('.jpg') || name.endsWith('.jpeg') || name.endsWith('.webp') || name.endsWith('.bmp');
    if (!isGif && !isStatic) {
      return (sticker: null, error: '仅支持 jpg/png/gif/webp 图片');
    }

    // 3) GIF：不重编码，保持动画，仅校验尺寸与字节数
    if (isGif) {
      final gifSize = _gifDimension(bytes);
      if (gifSize != null &&
          (gifSize.$1 > maxGifSide || gifSize.$2 > maxGifSide)) {
        return (sticker: null, error: 'GIF 尺寸过大（最大 ${maxGifSide}x$maxGifSide）');
      }
      if (bytes.length > maxBytes) {
        return (sticker: null, error: 'GIF 压缩后不能超过 256KB');
      }
      final (w, h) = gifSize ?? (targetSize, targetSize);
      return (
        sticker: CompressedSticker(
          bytes: bytes,
          filename: _safeName(name, 'gif'),
          width: w,
          height: h,
          mime: 'gif',
        ),
        error: null,
      );
    }

    // 4) 静态图：解码 → contain 缩放 → PNG 重编码，循环降尺寸直到 ≤256KB
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final src = frame.image;
      try {
        for (final size in _candidateSizes) {
          final out = await _resizeToPng(src, size);
          if (out != null && out.length <= maxBytes) {
            return (
              sticker: CompressedSticker(
                bytes: out,
                filename: _safeName(name, 'png'),
                width: size,
                height: size,
                mime: 'png',
              ),
              error: null,
            );
          }
        }
        return (sticker: null, error: '压缩后仍超过 256KB，请换一张图');
      } finally {
        src.dispose();
      }
    } catch (_) {
      return (sticker: null, error: '图片解析失败，请换一张图');
    }
  }

  /// 静态图 contain 进 [size]x[size] 画布（保持比例、透明底）并 PNG 编码
  static Future<Uint8List?> _resizeToPng(ui.Image src, int size) async {
    final srcW = src.width.toDouble();
    final srcH = src.height.toDouble();
    if (srcW <= 0 || srcH <= 0) return null;

    final scale = (size / srcW) < (size / srcH)
        ? size / srcW
        : size / srcH;
    final dstW = (srcW * scale).round().clamp(1, size);
    final dstH = (srcH * scale).round().clamp(1, size);
    final dx = (size - dstW) ~/ 2;
    final dy = (size - dstH) ~/ 2;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      src,
      ui.Rect.fromLTWH(0, 0, srcW, srcH),
      ui.Rect.fromLTWH(dx.toDouble(), dy.toDouble(), dstW.toDouble(), dstH.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    final img = await picture.toImage(size, size);
    try {
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      img.dispose();
      picture.dispose();
    }
  }

  /// 判断字节流是否为 GIF（头部 GIF8）
  static bool _isGifBytes(Uint8List bytes) {
    if (bytes.length < 6) return false;
    return bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38;
  }

  /// 读取 GIF 宽高（字节 6-9，小端）；非 GIF 返回 null
  static (int, int)? _gifDimension(Uint8List bytes) {
    if (bytes.length < 10) return null;
    if (bytes[0] != 0x47) return null; // 'G'
    final w = bytes[6] | (bytes[7] << 8);
    final h = bytes[8] | (bytes[9] << 8);
    if (w <= 0 || h <= 0) return null;
    return (w, h);
  }

  /// 规范化文件名：只保留后缀
  static String _safeName(String original, String fallbackExt) {
    final dot = original.lastIndexOf('.');
    final ext = dot > 0 ? original.substring(dot + 1).toLowerCase() : fallbackExt;
    return 'sticker_${DateTime.now().millisecondsSinceEpoch}.$ext';
  }
}
