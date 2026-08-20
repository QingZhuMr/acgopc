import 'package:flutter/material.dart';

import '../theme/mobile_theme.dart';

/// 移动端表单容器（iOS 观感，适配平板强约束）
///
/// 将表单列（输入框 / 按钮 / 验证码行等）居中并限制最大宽度
/// （`MobileTheme.formMaxWidth`，默认 480），避免 iPad / 平板横屏下
/// 表单被 `CrossAxisAlignment.stretch` 拉成全宽过度拉伸。
///
/// 用法：登录 / 注册页把 `Form > Column` 外包本组件即可：
///
/// ```dart
/// MobileFormPane(
///   child: Form(
///     child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...]),
///   ),
/// )
/// ```
///
/// 权威规格见 `docs/移动端UI规范.md` §4.5 / §6.4。
class MobileFormPane extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const MobileFormPane(
      {super.key,
      required this.child,
      this.maxWidth = MobileTheme.formMaxWidth});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
