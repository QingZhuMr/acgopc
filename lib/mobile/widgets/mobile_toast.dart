import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

/// 移动端顶部提示气泡类型
enum MobileToastType { info, success, error, loading }

/// 移动端全局顶部消息提示气泡（Toast）
///
/// 样式参考微信 / QQ：
///  - 顶部安全区下方居中悬浮，深色半透明胶囊背景 + 白色文字；
///  - 可选图标（成功打勾 / 失败感叹号 / 加载转圈），淡入淡出 + 轻微位移动画；
///  - 默认 2 秒自动消失，[loading] 需手动调用 [hide] 关闭。
///
/// 与桌面端 `NotifyStack`（窗口底部通知卡片栈）解耦，专供移动端页面使用。
///
/// 用法：
/// ```dart
/// MobileToast.show(context, '已复制');
/// MobileToast.success(context, '发送成功');
/// MobileToast.error(context, '发送失败');
/// MobileToast.loading(context, '加载中…');
/// // 加载类手动关闭
/// MobileToast.hide();
/// ```
class MobileToast {
  MobileToast._();

  static OverlayEntry? _entry;

  /// 显示一条顶部提示（同屏仅一条，新提示覆盖旧提示）
  static void show(
    BuildContext context,
    String message, {
    MobileToastType type = MobileToastType.info,
    Duration duration = const Duration(seconds: 2),
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    // 覆盖旧提示，避免叠加
    _entry?.remove();
    _entry = null;

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _ToastView(
        message: message,
        type: type,
        duration: duration,
        onDismissed: () {
          if (_entry == entry) _entry = null;
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  /// 普通提示（无图标，微信风）
  static void info(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 2),
  }) {
    show(context, message, type: MobileToastType.info, duration: duration);
  }

  /// 成功提示（绿色打勾）
  static void success(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 2),
  }) {
    show(context, message, type: MobileToastType.success, duration: duration);
  }

  /// 失败提示（红色感叹号）
  static void error(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 2),
  }) {
    show(context, message, type: MobileToastType.error, duration: duration);
  }

  /// 加载提示（转圈，需手动 [hide]）
  static void loading(BuildContext context, String message) {
    show(context, message, type: MobileToastType.loading);
  }

  /// 立即关闭当前提示
  static void hide() {
    _entry?.remove();
    _entry = null;
  }
}

/// 单条提示气泡（自带入场 / 离场动画与自动关闭）
class _ToastView extends StatefulWidget {
  final String message;
  final MobileToastType type;
  final Duration duration;
  final VoidCallback onDismissed;

  const _ToastView({
    required this.message,
    required this.type,
    required this.duration,
    required this.onDismissed,
  });

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOut,
  );
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _ctrl.forward();
    // loading 类型常驻，由调用方手动 hide；其余按时自动关闭
    if (widget.type != MobileToastType.loading) {
      _timer = Timer(widget.duration, _dismiss);
    }
  }

  Future<void> _dismiss() async {
    _timer?.cancel();
    _timer = null;
    await _ctrl.reverse();
    if (mounted) widget.onDismissed();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    return Positioned(
      top: topInset + 12,
      left: 0,
      right: 0,
      // OverlayEntry 直接构建，需包一层 Material 提供 Material 样式上下文，
      // 否则内部 Text 会渲染出黄色双下划线（详见掘金「FLUTTER TEXT文字下方出现黄色双下划线」）
      child: Material(
        type: MaterialType.transparency,
        child: IgnorePointer(
          child: Center(
            child: FadeTransition(
              opacity: _opacity,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, -0.6),
                  end: Offset.zero,
                ).animate(_opacity),
                child: _buildBubble(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBubble() {
    final Widget icon = switch (widget.type) {
      MobileToastType.success =>
        const Icon(Icons.check_circle_rounded, color: kSuccess, size: 18),
      MobileToastType.error =>
        const Icon(Icons.error_rounded, color: kDanger, size: 18),
      MobileToastType.loading => const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Colors.white,
          ),
        ),
      MobileToastType.info => const SizedBox.shrink(),
    };

    return Container(
      constraints: const BoxConstraints(maxWidth: 300),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        // 微信风：深色胶囊（不透明，白天 / 夜晚一致；修复透明度过高）
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(kRadiusFull),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.type != MobileToastType.info) ...[
            icon,
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              widget.message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                height: 1.3,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
