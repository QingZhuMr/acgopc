import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import 'pc_style_back_button.dart';

/// 移动端二级页顶栏（通用组件，2026-08-20 定案）
///
/// 规格：**无圆角、无边框、无背景色**（纯透明，直接叠在页面背景上）；
/// 行固定高 44（返回按钮位置在任何模式下都不受标题/右侧按钮变化影响）；
/// 标题 15 号不加粗；顶部留白 12、底部留白 8。
///
/// 使用方建议用 [Stack] 将其置于内容列表上层（位置恒定），
/// 列表顶部需用 [totalHeight] 占位避免首条被遮。
class MobileTopBar extends StatelessWidget {
  const MobileTopBar({
    super.key,
    required this.title,
    this.onBack,
    this.actions = const [],
  });

  /// 顶栏总高（上留白 12 + 行高 44 + 下留白 8），列表顶部占位用
  static const double totalHeight = 64;

  /// 标题文字
  final String title;

  /// 返回回调；为空时走 Navigator.maybePop（多选等场景由调用方传自定义逻辑）
  final VoidCallback? onBack;

  /// 右侧操作按钮（如「全部已读」「取消」「删除」），按顺序排列
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final dark = b == Brightness.dark;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
          // 固定行高 44：返回按钮位置在任何模式下都不受标题/右侧按钮变化影响
          child: SizedBox(
            height: 44,
            child: Row(
              children: [
                PcStyleBackButton(onPressed: onBack),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      color: textColor(b),
                    ),
                  ),
                ),
                ...actions,
              ],
            ),
          ),
        ),
        // 分割线：距右侧 4px 与顶栏对齐，0.5px 细线
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Divider(
            height: 1,
            thickness: 0.5,
            color: dark ? const Color(0x22FFFFFF) : const Color(0x19000000),
          ),
        ),
      ],
    );
  }
}
