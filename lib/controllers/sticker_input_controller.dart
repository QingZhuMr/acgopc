import 'package:flutter/material.dart';

import '../widgets/sticker_panel.dart';
import '../utils/net_image.dart';

/// 支持输入框内联显示表情包图片的 TextEditingController。
///
/// 重写 [buildTextSpan]，把 `[sticker:id]` 标记渲染为固定大小的内联图片
/// （WidgetSpan），实现抖音/小红书式"输入框内直接显示表情包"。
/// 详情页评论框与发布页输入框共用。
class StickerInputController extends TextEditingController {
  /// 表情包映射解析器（由外层注入，返回 id -> StickerItem）
  Map<int, StickerItem> Function()? stickerResolver;

  /// 内联图片尺寸（占输入框文字 2 行高度；发布页按需求可设 64）
  double inlineSize = 34;

  /// Backspace 时整体删除光标前的表情包标记（含半截残片）
  ///
  /// 返回 true 表示已处理，false 则走默认删除。
  /// 向前找最近的 "[sticker:" 起点，若该起点到光标之间只含表情标记内容
  /// （sticker:数字 或残片），则删除从 "[" 到光标的所有内容，防止遗留半截。
  bool deleteStickerBeforeCaret() {
    final text = this.text;
    if (text.isEmpty) return false;
    final offset = selection.baseOffset;
    if (offset <= 0) return false;
    final before = text.substring(0, offset);

    // 情况A：光标前是完整标记 [sticker:1] → 整体删
    var m = RegExp(r'\[sticker:\d+\]$').firstMatch(before);
    if (m != null) {
      final after = text.substring(offset);
      this.text = before.substring(0, m.start) + after;
      selection = TextSelection.collapsed(offset: m.start);
      return true;
    }

    // 情况B：光标前是 [sticker: 前缀（缺 ]，可能在删除过程中）→ 删到 [ 前
    final idx = before.lastIndexOf('[sticker:');
    if (idx >= 0) {
      final seg = before.substring(idx + 1); // "sticker:1" 或 "sticker:"
      if (RegExp(r'^sticker:\d*$').hasMatch(seg)) {
        final after = text.substring(offset);
        this.text = before.substring(0, idx) + after;
        selection = TextSelection.collapsed(offset: idx);
        return true;
      }
    }

    // 情况C：残片 "sticker:1]"（[ 已被删）→ 整体删残片
    m = RegExp(r'sticker:\d+\]$').firstMatch(before);
    if (m != null && (m.start == 0 || before[m.start - 1] != '[')) {
      final after = text.substring(offset);
      this.text = before.substring(0, m.start) + after;
      selection = TextSelection.collapsed(offset: m.start);
      return true;
    }

    return false;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final map = stickerResolver?.call() ?? const <int, StickerItem>{};
    if (map.isEmpty || !text.contains('[sticker:')) {
      return super.buildTextSpan(
          context: context, style: style, withComposing: withComposing);
    }
    final reg = RegExp(r'\[sticker:(\d+)\]');
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in reg.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      final id = int.tryParse(m.group(1) ?? '');
      final s = id != null ? map[id] : null;
      if (s != null && s.url.isNotEmpty) {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: NetImage(
            url: s.url,
            width: inlineSize,
            height: inlineSize,
            fit: BoxFit.contain,
            bgColor: Colors.transparent,
            errorIcon: Icons.image_not_supported_outlined,
            errorIconSize: inlineSize,
            errorIconColor: Colors.grey,
          ),
        ));
      } else {
        spans.add(const TextSpan(text: '[表情]'));
      }
      last = m.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last)));
    }
    return TextSpan(style: style, children: spans);
  }
}
