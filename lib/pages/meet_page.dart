import 'dart:io';

import 'package:flutter/material.dart';

import '../core/app_theme.dart';

/// 「遇见」页面（占位）
///
/// 通过左侧导航栏「广场」下方、「我的」上方的「遇见」入口进入。
/// 功能规划：随机推荐用户（随机邂逅，可关注、进主页），当前为占位页面。
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
          // 内容区：占位空态（功能规划中）
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: bgSoftColor(b),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Icon(
                      Icons.explore_rounded,
                      size: 34,
                      color: textFaintColor(b),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    '遇见',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: textColor(b)),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '随机邂逅用户功能即将上线',
                    style: TextStyle(fontSize: 13, color: textFaintColor(b)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
