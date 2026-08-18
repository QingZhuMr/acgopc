import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/image_transcoder.dart';
import 'bubble_menu.dart';

/// 输入框统一右键气泡菜单（规范：所有输入框右键一律用气泡方案，替代系统菜单）
///
/// 用法：外包任意 [child]（TextField/TextFormField），并给输入框设置
/// `contextMenuBuilder: (_, __) => const SizedBox.shrink()` 禁用系统菜单。
/// 提供：剪切 / 复制 / 粘贴 / 全选；[onPasteImage] 非空时粘贴优先检测剪贴板图片。
class TextInputBubbleMenu extends StatelessWidget {
  final Widget child;
  final TextEditingController controller;

  /// 是否密码框（隐藏剪切/复制，与系统密码框行为一致）
  final bool obscure;

  /// 剪贴板含图片时回调（聊天输入框粘贴图片用）。
  /// 返回 true 表示已处理图片（不再粘贴文本）。
  final Future<bool> Function()? onPasteImage;

  const TextInputBubbleMenu({
    super.key,
    required this.child,
    required this.controller,
    this.obscure = false,
    this.onPasteImage,
  });

  List<BubbleMenuItem> _buildItems() {
    final sel = controller.selection;
    final hasSelection = sel.isValid && !sel.isCollapsed;
    return [
      if (!obscure && hasSelection)
        BubbleMenuItem(
          label: '剪切',
          icon: Icons.content_cut_rounded,
          onTap: () => _cut(),
        ),
      if (!obscure && hasSelection)
        BubbleMenuItem(
          label: '复制',
          icon: Icons.copy_rounded,
          onTap: () => _copy(),
        ),
      BubbleMenuItem(
        label: '粘贴',
        icon: Icons.content_paste_rounded,
        onTap: () => _paste(),
      ),
      BubbleMenuItem(
        label: '全选',
        icon: Icons.select_all_rounded,
        onTap: () => _selectAll(),
      ),
    ];
  }

  void _copy() {
    final sel = controller.selection;
    if (!sel.isValid || sel.isCollapsed) return;
    final text = controller.text.substring(sel.start, sel.end);
    Clipboard.setData(ClipboardData(text: text));
  }

  void _cut() {
    final sel = controller.selection;
    if (!sel.isValid || sel.isCollapsed) return;
    final text = controller.text.substring(sel.start, sel.end);
    Clipboard.setData(ClipboardData(text: text));
    _replaceSelection('');
  }

  Future<void> _paste() async {
    // 优先尝试剪贴板图片（聊天输入框）
    final onImg = onPasteImage;
    if (onImg != null) {
      try {
        final handled = await onImg();
        if (handled) return;
      } catch (_) {}
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _replaceSelection(text);
  }

  void _selectAll() {
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
  }

  /// 用 [replacement] 替换选中区间（无选中则在光标处插入）
  void _replaceSelection(String replacement) {
    final sel = controller.selection;
    if (!sel.isValid) {
      controller.text = replacement;
      return;
    }
    final newText =
        controller.text.replaceRange(sel.start, sel.end, replacement);
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: sel.start + replacement.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BubbleMenu(
      triggerOnRightClick: true,
      items: _buildItems(),
      child: child,
    );
  }
}

/// 读取系统剪贴板中的图片字节（webp/png/jpeg/bmp 等），无图片返回 null。
Future<Uint8List?> readClipboardImageBytes() async {
  try {
    return await ImageTranscoder.readClipboardImage();
  } catch (_) {
    return null;
  }
}
