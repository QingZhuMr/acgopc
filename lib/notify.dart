import 'dart:collection';
import 'package:flutter/material.dart';

import 'app_theme.dart';

/// 通知条目
class NotifyItem {
  final String id; // 唯一 id（更新通知用 version，其他用时间戳）
  final String title;
  final String message;
  final NotifyType type;
  final bool persistent; // 是否常驻（不自动消失）
  final VoidCallback? onTap; // 点击触发
  final VoidCallback? onDismiss; // 手动关闭/忽略
  final Duration duration;

  /// 自定义背景色（非空则覆盖类型默认色，如检查更新完成的绿色、提示更新的红色）
  final Color? backgroundColor;

  /// 自定义正文/关闭图标前景色（配合 [backgroundColor] 使用）
  final Color? foregroundColor;

  /// 自定义标题/左侧色条色
  final Color? titleColor;

  /// 点击右上角 X 关闭时是否先弹确认对话框（常驻重要通知，如"是否忽略当前版本"）
  final bool confirmOnDismiss;

  /// 确认对话框标题
  final String dismissConfirmTitle;

  /// 确认对话框正文
  final String dismissConfirmMessage;

  /// 确认按钮文案
  final String dismissConfirmText;

  NotifyItem({
    required this.id,
    required this.title,
    required this.message,
    this.type = NotifyType.info,
    this.persistent = false,
    this.onTap,
    this.onDismiss,
    this.duration = const Duration(seconds: 3),
    this.backgroundColor,
    this.foregroundColor,
    this.titleColor,
    this.confirmOnDismiss = false,
    this.dismissConfirmTitle = '忽略提醒',
    this.dismissConfirmMessage = '确定要忽略这条提醒吗？',
    this.dismissConfirmText = '忽略',
  });
}

enum NotifyType { info, success, warning, update }

/// 全局通知栈管理器（继承 ChangeNotifier，监听栈变化）
class NotifyStack extends ChangeNotifier {
  static final NotifyStack instance = NotifyStack._();
  NotifyStack._();

  final ListQueue<NotifyItem> _stack = ListQueue<NotifyItem>();
  List<NotifyItem> get items => List.unmodifiable(_stack);

  /// 顶部展示的多个通知（最多展示 3 条，更早的隐藏但仍在栈中）
  static const int _maxVisible = 3;

  /// 添加通知（同一 id 已存在则替换）
  void push(NotifyItem item) {
    _stack.removeWhere((e) => e.id == item.id);
    _stack.addLast(item);
    notifyListeners();
  }

  /// 移除指定通知
  void dismiss(String id) {
    _stack.removeWhere((e) => e.id == id);
    notifyListeners();
  }

  /// 清理全部
  void clear() {
    _stack.clear();
    notifyListeners();
  }

  /// 当前可见的通知（栈尾的最多 maxVisible 条）
  List<NotifyItem> get visibleItems {
    final list = _stack.toList();
    if (list.length <= _maxVisible) return list;
    return list.sublist(list.length - _maxVisible);
  }

  /// 生成唯一通知 id
  static String _newId() =>
      'n${DateTime.now().microsecondsSinceEpoch}_${_idSeed++}';
  static int _idSeed = 0;

  /// 弹一条普通信息通知（3 秒自动消失）
  ///
  /// [backgroundColor]/[foregroundColor] 可选自定义背景/前景色，覆盖类型默认。
  static void info(
    String message, {
    String title = '',
    Color? backgroundColor,
    Color? foregroundColor,
    Color? titleColor,
    bool persistent = false,
    VoidCallback? onTap,
    VoidCallback? onDismiss,
    bool confirmOnDismiss = false,
    String dismissConfirmTitle = '忽略提醒',
    String dismissConfirmMessage = '确定要忽略这条提醒吗？',
    String dismissConfirmText = '忽略',
  }) {
    instance.push(NotifyItem(
      id: _newId(),
      title: title,
      message: message,
      type: NotifyType.info,
      persistent: persistent,
      onTap: onTap,
      onDismiss: onDismiss,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      titleColor: titleColor,
      confirmOnDismiss: confirmOnDismiss,
      dismissConfirmTitle: dismissConfirmTitle,
      dismissConfirmMessage: dismissConfirmMessage,
      dismissConfirmText: dismissConfirmText,
    ));
  }

  /// 成功通知（绿色调）
  static void success(String message, {String title = '成功'}) {
    instance.push(NotifyItem(
      id: _newId(),
      title: title,
      message: message,
      type: NotifyType.success,
    ));
  }

  /// 警告通知（黄色调）
  static void warning(String message, {String title = '提醒'}) {
    instance.push(NotifyItem(
      id: _newId(),
      title: title,
      message: message,
      type: NotifyType.warning,
    ));
  }

  /// 更新通知（红色调，常驻）
  ///
  /// 点击 X 会先弹"是否忽略当前版本"确认框。
  static void update(
    String message, {
    String title = '发现新版本',
    required VoidCallback onDownload,
    required VoidCallback onIgnore,
    Color? backgroundColor,
  }) {
    instance.push(NotifyItem(
      id: _newId(),
      title: title,
      message: message,
      type: NotifyType.update,
      persistent: true,
      backgroundColor: backgroundColor,
      onTap: onDownload,
      onDismiss: onIgnore,
      // 常驻更新通知：点 X 需确认"是否忽略当前版本"
      confirmOnDismiss: true,
      dismissConfirmTitle: '忽略更新',
      dismissConfirmMessage: '是否忽略当前版本？\n忽略后将不再提示该版本更新。',
      dismissConfirmText: '忽略',
    ));
  }

  /// 通用通知入口：完整自定义一条通知（最灵活，封装所有参数）
  static NotifyItem notify({
    required String title,
    required String message,
    NotifyType type = NotifyType.info,
    bool persistent = false,
    VoidCallback? onTap,
    VoidCallback? onDismiss,
    Color? backgroundColor,
    Color? foregroundColor,
    Color? titleColor,
    bool confirmOnDismiss = false,
    String dismissConfirmTitle = '忽略提醒',
    String dismissConfirmMessage = '确定要忽略这条提醒吗？',
    String dismissConfirmText = '忽略',
  }) {
    final item = NotifyItem(
      id: _newId(),
      title: title,
      message: message,
      type: type,
      persistent: persistent,
      onTap: onTap,
      onDismiss: onDismiss,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      titleColor: titleColor,
      confirmOnDismiss: confirmOnDismiss,
      dismissConfirmTitle: dismissConfirmTitle,
      dismissConfirmMessage: dismissConfirmMessage,
      dismissConfirmText: dismissConfirmText,
    );
    instance.push(item);
    return item;
  }
}

/// 通知栈 UI：全局覆盖（挂在 MaterialApp.builder 之上），
/// 所有路由（主页 / 发布页 / 登录页）都能在窗口底部看到通知。
class NotifyStackView extends StatelessWidget {
  const NotifyStackView({super.key});

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return AnimatedBuilder(
      animation: NotifyStack.instance,
      builder: (context, _) {
        final items = NotifyStack.instance.visibleItems;
        if (items.isEmpty) return const SizedBox.shrink();
        // 通知只占底部卡片区域（不再用全屏 Align 覆盖层），其余区域由外层
        // Stack 直接透传到底层页面，通知出现时不会拦截发布页输入框等的
        // 鼠标点击/聚焦，修复「有通知后无法输入」。
        return Padding(
          padding: const EdgeInsets.only(bottom: 16, left: 16, right: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 新通知在上（reverse: false 时 Column 第一个 child 在最上面）
              for (final item in items.reversed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _NotifyCard(
                    key: ValueKey(item.id),
                    item: item,
                    brightness: b,
                    onDismiss: () {
                      item.onDismiss?.call();
                      NotifyStack.instance.dismiss(item.id);
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 单条通知卡片
class _NotifyCard extends StatefulWidget {
  final NotifyItem item;
  final Brightness brightness;
  final VoidCallback onDismiss;

  const _NotifyCard({
    super.key,
    required this.item,
    required this.brightness,
    required this.onDismiss,
  });

  @override
  State<_NotifyCard> createState() => _NotifyCardState();
}

class _NotifyCardState extends State<_NotifyCard> {
  @override
  void initState() {
    super.initState();
    if (!widget.item.persistent) {
      Future.delayed(widget.item.duration, () {
        if (mounted) widget.onDismiss();
      });
    }
  }

  /// 处理关闭按钮点击：常驻重要通知先弹确认框，确认后才关闭
  Future<void> _handleDismiss() async {
    final item = widget.item;
    if (item.confirmOnDismiss) {
      final ok = await AppDialog.confirm(
        context,
        title: item.dismissConfirmTitle,
        message: item.dismissConfirmMessage,
        confirmText: item.dismissConfirmText,
        danger: true,
      );
      if (ok != true) return;
    }
    widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.brightness;
    final item = widget.item;

    // 颜色解析：优先自定义传参，其次按类型默认
    // 默认（info）白天白底、夜晚黑底；success 绿、warning 黄、update 红
    final Color defaultBg = b == Brightness.dark
        ? DarkColors.bg
        : LightColors.bg;
    final Color bgColor =
        item.backgroundColor ?? _typeBgColor(b, item.type, defaultBg);
    final Color fgColor = item.foregroundColor ?? _typeFgColor(b, item.type);
    final Color titleColor = item.titleColor ?? _typeTitleColor(b, item.type);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: item.onTap,
        mouseCursor: SystemMouseCursors.click, // 悬停显示手指
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 380,
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: b == Brightness.dark ? 0.4 : 0.12),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 左侧色条表示类型
              Container(
                width: 3,
                height: 40,
                decoration: BoxDecoration(
                  color: titleColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (item.title.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          item.title,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: titleColor,
                          ),
                        ),
                      ),
                    Text(
                      item.message,
                      style: TextStyle(fontSize: 13, color: fgColor, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: _handleDismiss,
                mouseCursor: SystemMouseCursors.click, // 悬停显示手指
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.close,
                    size: 16,
                    color: fgColor.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 按通知类型返回默认背景色
///
/// [defaultBg]：info 类型的默认背景（白天白、夜晚黑），由调用方按明暗传入。
/// success 绿、warning 黄、update 红。
Color _typeBgColor(Brightness b, NotifyType type, Color defaultBg) {
  switch (type) {
    case NotifyType.update:
      return kDanger;
    case NotifyType.success:
      return b == Brightness.dark
          ? const Color(0xFF1E3A1F)
          : const Color(0xFFE8F5E8);
    case NotifyType.warning:
      return b == Brightness.dark
          ? const Color(0xFF3F2E0E)
          : const Color(0xFFFFF8E1);
    case NotifyType.info:
      return defaultBg;
  }
}

/// 按通知类型返回默认正文/图标前景色
Color _typeFgColor(Brightness b, NotifyType type) {
  switch (type) {
    case NotifyType.update:
      return Colors.white;
    case NotifyType.success:
      return b == Brightness.dark ? Colors.white : const Color(0xFF14532D);
    case NotifyType.warning:
      return b == Brightness.dark ? Colors.white : const Color(0xFF92400E);
    case NotifyType.info:
      return textColor(b);
  }
}

/// 按通知类型返回默认标题/色条色
Color _typeTitleColor(Brightness b, NotifyType type) {
  switch (type) {
    case NotifyType.update:
      return Colors.white;
    case NotifyType.success:
      return kSuccess;
    case NotifyType.warning:
      return kWarning;
    case NotifyType.info:
      return kPrimary;
  }
}

/// 通用对话框帮助类（确认框 / 提示框）
///
/// 所有"确认类"对话框统一走这里，样式一致、传参即用。
class AppDialog {
  AppDialog._();

  /// 通用确认框：返回 true=确认，false/null=取消
  static Future<bool?> confirm(
    BuildContext context, {
    String? title,
    required String message,
    String confirmText = '确定',
    String cancelText = '取消',
    bool danger = false,
  }) {
    final b = Theme.of(context).brightness;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: bgHoverColor(b),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        title: title == null
            ? null
            : Text(title, style: TextStyle(color: textColor(b), fontSize: 17)),
        content: Text(message,
            style: TextStyle(color: textMutedColor(b), fontSize: 14, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(cancelText,
                style: const TextStyle(color: kPrimary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmText,
                style: TextStyle(color: danger ? kDanger : kPrimary)),
          ),
        ],
      ),
    );
  }
}