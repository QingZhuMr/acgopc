import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crop_image_pro/crop_image.dart';
import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../widgets/notify.dart';

/// 头像裁剪对话框（大厂体验：图片在固定 1:1 方形框内缩放/平移，裁剪后返回 PNG bytes）
class AvatarCropDialog extends StatefulWidget {
  final Uint8List imageBytes;

  const AvatarCropDialog({super.key, required this.imageBytes});

  /// 弹出裁剪对话框，返回裁剪后的 PNG bytes；用户取消返回 null
  static Future<Uint8List?> show(BuildContext context, Uint8List bytes) {
    return showDialog<Uint8List>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AvatarCropDialog(imageBytes: bytes),
    );
  }

  @override
  State<AvatarCropDialog> createState() => _AvatarCropDialogState();
}

class _AvatarCropDialogState extends State<AvatarCropDialog> {
  // 固定 1:1 方形（适配圆形头像），经典可拖拽网格（鼠标可直接拖拽边缘/角缩放）
  late final CropController _controller = CropController(
    aspectRatio: 1,
    defaultCrop: const Rect.fromLTWH(0.2, 0.2, 0.6, 0.6),
  );
  bool _busy = false;

  /// 完成裁剪：导出 PNG bytes 并返回给调用方
  Future<void> _finish() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bitmap = await _controller.croppedBitmap(maxSize: 512);
      final data = await bitmap.toByteData(format: ui.ImageByteFormat.png);
      bitmap.dispose();
      if (!mounted) return;
      Navigator.pop(context, data?.buffer.asUint8List());
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        NotifyStack.warning('裁剪失败，请重试');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Dialog(
      backgroundColor: bgHoverColor(b),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusMd),
      ),
      insetPadding: const EdgeInsets.all(32),
      child: SizedBox(
        width: 520,
        height: 600,
        child: Column(
          children: [
            // 标题栏
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
              child: Row(
                children: [
                  Text('裁剪头像',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: textColor(b))),
                  const Spacer(),
                  InkWell(
                    onTap: () => Navigator.pop(context),
                    mouseCursor: SystemMouseCursors.click, // 悬停显示手指
                    borderRadius: BorderRadius.circular(kRadiusSm),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(Icons.close,
                          size: 20, color: textMutedColor(b)),
                    ),
                  ),
                ],
              ),
            ),
            // 裁剪区：经典可拖拽网格（鼠标可直接拖拽网格边缘/角调整裁剪框大小与位置）
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: CropImagePro(
                  controller: _controller,
                  image: Image.memory(widget.imageBytes),
                  interactionMode: CropInteractionMode.resizeCropRect,
                  gridColor: Colors.white70,
                  gridCornerColor: kPrimary,
                  alwaysShowThirdLines: true,
                  scrimColor: Colors.black54,
                  shortAxisMinDisplaySize: 300,
                  minimumImageSize: 100,
                  maximumImageSize: double.infinity,
                ),
              ),
            ),
            // 操作提示
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('拖拽网格边缘或角调整裁剪框 · 按住框内可移动',
                  style: TextStyle(
                      fontSize: 12, color: textMutedColor(b))),
            ),
            // 底部操作：取消 / 完成
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => Navigator.pop(context),
                    child: Text('取消',
                        style: TextStyle(color: textMutedColor(b))),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: kPrimary,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _busy ? null : _finish,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.check, size: 18),
                    label: Text(_busy ? '处理中…' : '完成',
                        style: const TextStyle(
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 编辑资料对话框中的头像预览：优先本地新图，否则当前头像，兜底首字
class EditAvatarPreview extends StatelessWidget {
  final String? currentUrl;
  final String nickname;
  final List<int>? selectedBytes;

  const EditAvatarPreview({
    super.key,
    required this.currentUrl,
    required this.nickname,
    required this.selectedBytes,
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    const size = 120.0;
    // 有本地新图：直接显示（裁剪后的头像，铺满圆形容器）
    if (selectedBytes != null) {
      return Image.memory(
        Uint8List.fromList(selectedBytes!),
        width: size,
        height: size,
        fit: BoxFit.cover,
      );
    }
    // 有当前头像：网络图
    if (currentUrl != null && currentUrl!.isNotEmpty) {
      return Image.network(
        currentUrl!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _initialBox(b, size),
      );
    }
    // 兜底：首字
    return _initialBox(b, size);
  }

  Widget _initialBox(Brightness b, double size) {
    final name = nickname.trim();
    final initial =
        name.isEmpty ? '?' : (name.length <= 2 ? name : name.substring(0, 2));
    return Container(
      width: size,
      height: size,
      color: primarySoftColor(b),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          fontSize: size * 0.28,
          fontWeight: FontWeight.w600,
          color: kPrimary,
        ),
      ),
    );
  }
}
