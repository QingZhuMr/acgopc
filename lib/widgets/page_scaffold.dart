import 'dart:io';

import 'package:flutter/material.dart';

import '../core/app_theme.dart';

/// 页面脚手架：标题 + 右侧按钮 + 内容区
class PageScaffold extends StatelessWidget {
  final String title; // 页面标题
  final Widget child; // 页面内容
  final List<Widget>? actions; // 标题栏右侧按钮

  const PageScaffold({
    super.key,
    required this.title,
    required this.child,
    this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 页面标题 + 右侧按钮
        // 间距规范：Win 端标题距顶 5px（比 macOS 的 20 上移 15px）；
        // 标题与下一行内容间距 20px（本行 bottom 4 + 内容区自带顶部 padding 16 = 20）；
        // Win 顶栏现为 40px，标题距窗口顶 = 40 + 5 = 45px
        Padding(
          padding: EdgeInsets.fromLTRB(
              24, Platform.isWindows ? 5 : 20, 24, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: textColor(b),
                  ),
                ),
              ),
              if (actions != null) ...actions!,
            ],
          ),
        ),
        // 页面内容
        Expanded(child: child),
      ],
    );
  }
}
