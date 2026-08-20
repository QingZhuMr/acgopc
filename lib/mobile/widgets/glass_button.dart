import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../theme/mobile_theme.dart';

/// iOS 26 液态玻璃按钮（`CupertinoButton` 观感）
///
/// 遵循 `docs/UI规范.md` §11.3 按钮规格 / `docs/移动端UI规范.md` §6.4：
///  - 胶囊化（`kRadiusFull`）；
///  - **primary**：主操作，`kPrimary` 实底 + 白字 + 高 48；
///  - **secondary**：次操作，半透明玻璃底（`primarySoft`）+ 细描边 + `kPrimary`
///    文字 + 高 44；
///  - **link**：纯文字 `kPrimary`（辅助跳转，如"去登录 / 去注册"）；
/// 按压反馈为 CupertinoButton 观感（按压半透明），无 Material 水波。
///
/// 移动端所有按钮统一走本组件，禁止直接用 Material 按钮（iOS 26 风格为强约束）。
/// `expanded` 时宽度受 [maxWidth] 限制（默认 `MobileTheme.formMaxWidth` = 480），
/// 避免平板下按钮被拉成全宽过度拉伸（适配 pad 强约束）。
enum GlassButtonVariant { primary, secondary, link }

class GlassButton extends StatelessWidget {
  final GlassButtonVariant variant;
  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  /// 是否撑满父级宽度（主操作按钮通常为 true）
  final bool expanded;

  /// expanded 时的最大宽度（适配平板限宽，默认 `MobileTheme.formMaxWidth`）
  final double? maxWidth;

  const GlassButton.primary({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.expanded = true,
    this.maxWidth,
  }) : variant = GlassButtonVariant.primary;

  const GlassButton.secondary({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.expanded = false,
    this.maxWidth,
  }) : variant = GlassButtonVariant.secondary;

  const GlassButton.link({
    super.key,
    required this.label,
    required this.onPressed,
    this.expanded = false,
    this.maxWidth,
  })  : variant = GlassButtonVariant.link,
        loading = false;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final disabled = onPressed == null || loading;

    final Color bg;
    final Color fg;
    final double height;
    final Border? border;
    final double fontSize;

    switch (variant) {
      case GlassButtonVariant.primary:
        bg = kPrimary;
        fg = Colors.white;
        height = 48;
        border = null;
        fontSize = 16;
      case GlassButtonVariant.secondary:
        bg = primarySoftColor(b);
        fg = kPrimary;
        height = 44;
        border = Border.all(
          color: kPrimary.withValues(alpha: b == Brightness.dark ? 0.5 : 0.35),
          width: 1,
        );
        fontSize = 15;
      case GlassButtonVariant.link:
        bg = Colors.transparent;
        fg = kPrimary;
        height = 44;
        border = null;
        fontSize = 15;
    }

    final Widget content = loading
        ? SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: fg),
          )
        : Text(
            label,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          );

    // expanded 时以 maxWidth 限宽（默认 480，适配平板强约束）：
    // 用 ConstrainedBox 限制最大宽度 + Center 居中，
    // 平板下按钮不会随 stretch 列拉成全宽。
    final Widget button = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      width: expanded ? double.infinity : null,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(kRadiusFull),
        border: border,
        boxShadow: variant == GlassButtonVariant.primary
            ? [
                BoxShadow(
                  color: kPrimary.withValues(alpha: 0.25),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: content,
    );

    return Opacity(
      opacity: disabled ? 0.45 : 1,
      child: CupertinoButton(
        onPressed: disabled ? null : onPressed,
        padding: EdgeInsets.zero,
        pressedOpacity: 0.55,
        borderRadius: BorderRadius.circular(kRadiusFull),
        child: expanded
            ? Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: maxWidth ?? MobileTheme.formMaxWidth,
                  ),
                  child: button,
                ),
              )
            : button,
      ),
    );
  }
}
