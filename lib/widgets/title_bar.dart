import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_theme.dart';

/// 内容区自绘顶栏
///
/// - macOS：红黄绿安全区在左侧导航栏顶部，顶栏仅内容区拖拽区（无窗口按钮），高度 20 让内容尽量上移
/// - Windows：内容区顶栏 35px，含拖拽区 + 窗口控制按钮
class TitleBar extends StatelessWidget {
  final Brightness brightness;

  /// 顶栏背景色（消息页时传 bgSoftColor 与左侧导航栏一致）
  final Color? color;

  const TitleBar({super.key, required this.brightness, this.color});

  @override
  Widget build(BuildContext context) {
    // macOS：红黄绿安全区在左侧导航栏顶部，顶栏仅内容区拖拽区（无窗口按钮），高度 20 让内容尽量上移
    if (Platform.isMacOS) {
      return Container(
        height: 20,
        color: color ?? bgColor(brightness),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => windowManager.startDragging(),
          child: const SizedBox.expand(),
        ),
      );
    }
    // Windows：内容区顶栏 35px，含拖拽区 + 窗口控制按钮
    return Container(
      height: 35,
      color: color ?? bgColor(brightness),
      child: Row(
        children: [
          // 可拖拽区域（撑满，可拖动窗口）
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => windowManager.startDragging(),
              child: const SizedBox.expand(),
            ),
          ),
          // 窗口控制按钮（正方形 1:1，靠右上角）
          WinButton(
            icon: Icons.remove,
            onTap: () => windowManager.minimize(),
          ),
          WinButton(
            icon: Icons.crop_square_rounded,
            onTap: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
          WinButton(
            icon: Icons.close,
            isClose: true,
            onTap: () => windowManager.close(),
          ),
        ],
      ),
    );
  }
}

/// 窗口控制按钮
///
/// 遵循微软 Windows 行业规范：
/// - 关闭按钮 hover：红色胶囊（`#E81123`，微软标准关闭红），图标变白
/// - 最小化 / 最大化 hover：灰色胶囊（明暗主题自适应）
/// - 胶囊无圆角，且顶到窗口顶栏上边缘与右边缘（由 `TitleBar` 布局保证对齐）
class WinButton extends StatefulWidget {
  final IconData icon;
  final bool isClose;
  final VoidCallback onTap;

  const WinButton({
    super.key,
    required this.icon,
    this.isClose = false,
    required this.onTap,
  });

  @override
  State<WinButton> createState() => _WinButtonState();
}

class _WinButtonState extends State<WinButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    // 关闭按钮 hover 用微软标准红；其余用主题灰色胶囊
    final bg = _hovered
        ? (widget.isClose
            ? const Color(0xFFE81123)
            : bgHoverColor(b))
        : Colors.transparent;
    // 图标颜色：关闭按钮 hover 变白；其余始终用弱文字色
    final iconColor = widget.isClose && _hovered
        ? Colors.white
        : textMutedColor(b);
    return SizedBox(
      width: 46,
      height: 35, // 正方形 1:1，靠右上角，贴合 35px 顶栏高度
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: InkWell(
          onTap: widget.onTap,
          mouseCursor: SystemMouseCursors.click, // 悬停显示手指
          hoverColor: Colors.transparent, // 背景色由 MouseRegion 控制，避免双层叠加
          child: Container(
            color: bg, // 无圆角，填满按钮区域，与窗口边缘对齐
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: 16,
              color: iconColor,
            ),
          ),
        ),
      ),
    );
  }
}
