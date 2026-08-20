import 'package:flutter/material.dart';

import '../core/app_theme.dart';

/// 二级页面嵌入式标题栏（内容区覆盖时使用，保留左侧导航栏）
///
/// 统一规范（帖子详情 / 他人主页等所有二级页面共用）：
/// - 高 48、水平 padding 8
/// - macOS 风格返回按钮 40x40 / kRadiusMd 圆角 / arrow_back_ios_new_rounded 16px
/// - 标题 15px / w600，Expanded 占满中间空隙（省略号被推到最右）
/// - 右侧可选操作按钮（举报 / 更多等）
///
/// width: double.infinity 强制撑满 cross axis —— 根因修复：若不加宽，
/// 在 Column(crossAxisAlignment: start) 下会收缩为内容宽 → Row 不撑满 →
/// Expanded/Spacer 失效 → 省略号紧跟标题（看起来"前移"）。
///
/// 全屏模式（独立窗口、无左侧导航）的标题栏带窗口按钮/拖拽区，属"特殊约定"，
/// 由各页面自行实现，不在此组件内。
class SecondaryTitleBar extends StatelessWidget {
  const SecondaryTitleBar({
    super.key,
    required this.title,
    this.onBack,
    this.actions,
  });

  /// 标题（通常为 15px/w600 的 Text）
  final Widget title;

  /// 返回回调；为空时走 Navigator.maybePop
  final VoidCallback? onBack;

  /// 右侧操作按钮（举报/更多等），如无则不渲染
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return SizedBox(
      height: 48,
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            // macOS 风格返回按钮
            SizedBox(
              width: 40,
              height: 40,
              child: InkWell(
                borderRadius: BorderRadius.circular(kRadiusMd),
                onTap: onBack ?? () => Navigator.of(context).maybePop(),
                mouseCursor: SystemMouseCursors.click,
                hoverColor: bgHoverColor(b),
                child: Center(
                  // 图标下移 1px，与 15px 标题文字视觉中线对齐（Material 箭头基线偏上）
                  child: Transform.translate(
                    offset: const Offset(0, 1),
                    child: Icon(Icons.arrow_back_ios_new_rounded,
                        size: 16, color: textMutedColor(b)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            // 标题占满中间空隙（同 PageScaffold），省略号被推到最右
            Expanded(child: title),
            if (actions != null) ...actions!,
          ],
        ),
      ),
    );
  }
}
