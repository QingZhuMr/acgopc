import 'dart:io';

import 'package:flutter/material.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../core/app_theme.dart';

/// 隐私设置页
///
/// 两种展示模式：
/// - 内容区覆盖模式（`embedded: true`，默认由个人中心省略号菜单触发）：
///   通过 `_HomePageState` 的 `_macOverlay` 机制展示在内容区，**保留左侧导航栏**
///   不遮挡。此时顶部距离由宿主窗口的 `_TitleBar` 承担，标题栏无需额外顶距，
///   样式与 `PublishPostPage`/`PostDetailPage` 内嵌模式一致（高 48、标题 15px/w600）。
/// - 全屏模式（`embedded: false`）：遵守 macOS / Windows 顶部距离规范
///   （Win 顶距 5px / macOS 20px，标题 20px/w600、左右 24px）。
///
/// 样式遵循 docs/UI规范.md：可滚动区域用 SilkyListView，颜色一律用
/// app_theme.dart 的函数/常量，禁硬编码。
///
/// 当前为页面骨架：内容项在后续迭代中填充。
class PrivacySettingsPage extends StatefulWidget {
  /// 是否以内嵌模式展示（内容区覆盖，保留左侧导航栏）
  final bool embedded;

  /// 内嵌模式下点击返回按钮的回调（由宿主清空内容区覆盖层）
  final VoidCallback? onBack;

  const PrivacySettingsPage({
    super.key,
    this.embedded = false,
    this.onBack,
  });

  @override
  State<PrivacySettingsPage> createState() => _PrivacySettingsPageState();
}

class _PrivacySettingsPageState extends State<PrivacySettingsPage> {
  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Scaffold(
      backgroundColor: bgColor(b),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTitleBar(b, context),
          Expanded(
            child: SilkyListView(
              padding: const EdgeInsets.all(16),
              scrollSpeed: 1.6,
              silkyScrollDuration: const Duration(milliseconds: 600),
              animationCurve: Curves.easeOutCubic,
              children: [
                // ===== 隐私设置内容区（待填充） =====
                // 骨架阶段先放置占位说明，后续迭代替换为具体设置项。
                Card(
                  elevation: 0,
                  color: bgHoverColor(b),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(kRadiusMd),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 32),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.privacy_tip_outlined,
                              size: 40, color: textFaintColor(b)),
                          const SizedBox(height: 12),
                          Text(
                            '隐私设置功能开发中',
                            style: TextStyle(
                              fontSize: 14,
                              color: textSecondaryColor(b),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 标题栏
  ///
  /// embedded（内容区覆盖）：与 PublishPostPage 内嵌模式一致——高 48、
  /// 水平 8px、标题 15px/w600、macOS 风格返回按钮（40x40、kRadiusMd 圆角、
  /// arrow_back_ios_new_rounded 16px）。顶部距离由宿主 _TitleBar 承担。
  ///
  /// 全屏模式：返回按钮 + 标题，遵守双端顶部距离规范
  /// （Win 顶距 5px / macOS 20px，标题 20px/w600，左右 24px）。
  Widget _buildTitleBar(Brightness b, BuildContext context) {
    if (widget.embedded) {
      return SizedBox(
        height: 48,
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
                  onTap: () {
                    if (widget.onBack != null) {
                      widget.onBack!();
                    } else {
                      Navigator.of(context).maybePop();
                    }
                  },
                  mouseCursor: SystemMouseCursors.click,
                  hoverColor: bgHoverColor(b),
                  child: Icon(Icons.arrow_back_ios_new_rounded,
                      size: 16, color: textMutedColor(b)),
                ),
              ),
              Text(
                '隐私设置',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: textColor(b),
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        Platform.isWindows ? 5 : 20,
        24,
        4,
      ),
      child: Row(
        children: [
          // 返回按钮（kRadiusMd 圆角 hover）
          SizedBox(
            width: 36,
            height: 36,
            child: InkWell(
              borderRadius: BorderRadius.circular(kRadiusMd),
              onTap: () => Navigator.of(context).pop(),
              mouseCursor: SystemMouseCursors.click,
              hoverColor: bgHoverColor(b),
              child: Icon(Icons.arrow_back,
                  size: 18, color: textMutedColor(b)),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              '隐私设置',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: textColor(b),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
