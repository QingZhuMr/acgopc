import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

/// 移动端顶部返回按钮（PC 客户端同款风格）
///
/// 与 [SecondaryTitleBar] 一致：macOS 风格 40x40 / 圆形 hover 胶囊 /
/// arrow_back_ios_new_rounded 16px，带 hover 底色。
class PcStyleBackButton extends StatelessWidget {
  const PcStyleBackButton({super.key, this.onPressed});

  /// 返回回调；为空时走 Navigator.maybePop
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return SizedBox(
      width: 40,
      height: 40,
      child: InkWell(
        // 圆形胶囊：40x40 全圆角（2026-08-20 定案）
        borderRadius: BorderRadius.circular(20),
        onTap: onPressed ?? () => Navigator.of(context).maybePop(),
        hoverColor: bgHoverColor(b),
        child: Center(
          // 图标下移 1px，与标题文字视觉中线对齐（Material 箭头基线偏上）
          child: Transform.translate(
            offset: const Offset(0, 1),
            child: Icon(Icons.arrow_back_ios_new_rounded,
                size: 16, color: textMutedColor(b)),
          ),
        ),
      ),
    );
  }
}
