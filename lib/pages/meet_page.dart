import 'dart:io';

import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../widgets/earth_globe.dart';

/// 「遇见」页面
///
/// 通过左侧导航栏「广场」下方、「我的」上方的「遇见」入口进入。
/// 功能规划：随机推荐用户（随机邂逅，可关注、进主页）。
/// 当前内容：程序化渲染的 3D 彩色旋转地球。
/// 作为侧边栏 tab 内嵌展示（不遮挡左侧导航栏），无返回按钮。
class MeetPage extends StatelessWidget {
  const MeetPage({super.key});

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Scaffold(
      backgroundColor: bgColor(b),
      body: Column(
        children: [
          // 简洁标题行（侧边栏 tab 内嵌用）：无返回按钮/窗口按钮，保留标题
          // 间距规范与通知页一致：Win 标题距顶 5px（macOS 20px），左右边距 24px
          Padding(
            padding: EdgeInsets.fromLTRB(
                24, Platform.isWindows ? 5 : 20, 24, 4),
            child: Row(
              children: [
                Text(
                  '遇见',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: textColor(b)),
                ),
              ],
            ),
          ),
          // 内容区：3D 彩色旋转地球
          Expanded(
            child: Center(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size = constraints.biggest.shortestSide.clamp(220.0, 360.0);
                  return EarthGlobe(size: size);
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
