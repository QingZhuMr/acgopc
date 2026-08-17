import 'package:flutter/material.dart';
import '../core/app_theme.dart';

/// 气泡菜单项
class BubbleMenuItem {
  final String? label;
  final IconData? icon;
  final Color? color; // 文字/图标颜色（默认取主题文字色）
  final VoidCallback? onTap;

  const BubbleMenuItem({this.label, this.icon, this.color, this.onTap});

  /// 删除项：红字 + 删除图标
  const BubbleMenuItem.delete(String label, {VoidCallback? onTap})
      : this(
          label: label,
          icon: Icons.delete_outline_rounded,
          color: kDanger,
          onTap: onTap,
        );

  /// 举报项：默认色 + 旗帜图标
  const BubbleMenuItem.report(String label, {VoidCallback? onTap})
      : this(label: label, icon: Icons.flag_outlined, color: null, onTap: onTap);
}

/// 全局气泡菜单管理器：保证同一时刻最多只显示一个气泡。
/// 打开新气泡前自动关闭已打开的气泡。
class BubbleMenuManager {
  BubbleMenuManager._();

  static final BubbleMenuManager instance = BubbleMenuManager._();

  _BubbleMenuOverlay? _current;

  /// 注册当前打开的气泡（关闭旧的）
  void register(_BubbleMenuOverlay overlay) {
    _current?.close();
    _current = overlay;
  }

  /// 取消注册（当前气泡自己关闭时调用）
  void unregister(_BubbleMenuOverlay overlay) {
    if (_current == overlay) _current = null;
  }

  /// 关闭当前气泡（供其它逻辑触发，如打开别的弹层）
  void closeCurrent() => _current?.close();
}

/// 通用气泡弹出菜单（popover，聊天气泡样式，带小三角箭头）
///
/// - 点击 child 弹出气泡，同一时刻全局最多一个
/// - 默认向下弹出，下方空间不足自动向上
/// - 气泡小三角水平对齐 child 中心
/// - 显示/消失带淡入 + 缩放动画
/// - 点击气泡外部 / 鼠标滚动 / 再点触发图标时关闭
class BubbleMenu extends StatefulWidget {
  final List<BubbleMenuItem> items;
  final Widget child;

  /// 气泡固定宽度
  final double width;

  /// 每个菜单项固定高度
  final double itemHeight;

  /// 气泡内容上下内边距
  final double verticalPadding;

  /// 三角箭头边长
  final double arrowSize;

  /// 气泡圆角
  final double radius;

  /// 气泡与 child 的间距
  final double gap;

  /// 动画时长
  final Duration duration;

  const BubbleMenu({
    super.key,
    required this.items,
    required this.child,
    this.width = 96,
    this.itemHeight = 34,
    this.verticalPadding = 6,
    this.arrowSize = 7,
    this.radius = kRadiusBtn,
    this.gap = 6,
    this.duration = const Duration(milliseconds: 150),
  });

  @override
  State<BubbleMenu> createState() => _BubbleMenuState();
}

class _BubbleMenuState extends State<BubbleMenu> {
  final GlobalKey _anchorKey = GlobalKey();
  _BubbleMenuOverlay? _overlay;

  @override
  void dispose() {
    _overlay?.close();
    super.dispose();
  }

  void _toggle() {
    if (_overlay != null) {
      _overlay!.close();
    } else {
      _openMenu();
    }
  }

  void _openMenu() {
    final overlay = Overlay.of(context);
    setState(() => _overlay = _BubbleMenuOverlay.pending());
    // 通过 nextFrame 确保 anchor 已布局，再定位
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final entry = OverlayEntry(
        builder: (ctx) => _BubbleMenuOverlayView(
          anchorKey: _anchorKey,
          items: widget.items,
          width: widget.width,
          itemHeight: widget.itemHeight,
          verticalPadding: widget.verticalPadding,
          arrowSize: widget.arrowSize,
          radius: widget.radius,
          gap: widget.gap,
          duration: widget.duration,
          onClosed: _onClosed,
        ),
      );
      overlay.insert(entry);
      _overlay!.entry = entry;
      BubbleMenuManager.instance.register(_overlay!);
    });
  }

  void _onClosed() {
    if (!mounted) return;
    _overlay?.close(); // 移除 entry + 取消全局注册
    if (_overlay != null) {
      setState(() => _overlay = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: _anchorKey,
      behavior: HitTestBehavior.opaque,
      onTap: _toggle,
      child: widget.child,
    );
  }
}

/// 气泡 Overlay 控制器（记录 entry，负责移除）
class _BubbleMenuOverlay {
  OverlayEntry? entry;

  _BubbleMenuOverlay.pending();

  void close() {
    BubbleMenuManager.instance.unregister(this);
    entry?.remove();
    entry = null;
  }
}

/// 气泡 Overlay 视图：全屏拦截 + 定位 + 动画
class _BubbleMenuOverlayView extends StatelessWidget {
  final GlobalKey anchorKey;
  final List<BubbleMenuItem> items;
  final double width;
  final double itemHeight;
  final double verticalPadding;
  final double arrowSize;
  final double radius;
  final double gap;
  final Duration duration;
  final VoidCallback onClosed;

  const _BubbleMenuOverlayView({
    required this.anchorKey,
    required this.items,
    required this.width,
    required this.itemHeight,
    required this.verticalPadding,
    required this.arrowSize,
    required this.radius,
    required this.gap,
    required this.duration,
    required this.onClosed,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final overlaySize = constraints.biggest;
        final anchorBox =
            anchorKey.currentContext?.findRenderObject() as RenderBox?;
        if (anchorBox == null || !anchorBox.hasSize || !anchorBox.attached) {
          return const SizedBox.shrink();
        }
        final origin = anchorBox.localToGlobal(Offset.zero);
        final anchorRect = Rect.fromLTWH(
          origin.dx,
          origin.dy,
          anchorBox.size.width,
          anchorBox.size.height,
        );

        final contentHeight = items.length * itemHeight + verticalPadding * 2;
        // 总高度 = 内容 + 框外小三角占位
        final bubbleHeight = contentHeight + arrowSize;

        // 方向：下方空间不足则向上（按总高度判断）
        final spaceBelow = overlaySize.height - anchorRect.bottom;
        final spaceAbove = anchorRect.top;
        final showDown =
            spaceBelow >= bubbleHeight + gap || spaceBelow >= spaceAbove;

        final top = showDown
            ? anchorRect.bottom + gap - arrowSize // 三角尖贴 anchor 底部，矩形本体在三角下方
            : anchorRect.top - bubbleHeight - gap;

        // 水平：箭头默认对齐 anchor 中心，气泡不越界
        final targetX = anchorRect.center.dx;
        var left = targetX - width / 2;
        final minLeft = 8.0;
        final maxLeft = overlaySize.width - width - 8;
        if (left > maxLeft) left = maxLeft;
        if (left < minLeft) left = minLeft;

        final arrowCenterDx =
            (targetX - left).clamp(arrowSize, width - arrowSize);

        final bubbleKey = GlobalKey<_AnimatedBubbleState>();
        return Stack(
          children: [
            // 全屏拦截层：点击外部 / 滚动关闭（触发气泡淡出动画）
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerSignal: (_) => bubbleKey.currentState?.beginClose(),
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => bubbleKey.currentState?.beginClose(),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            // 气泡（带动画，含框外小三角）
            Positioned(
              left: left,
              top: top,
              child: _AnimatedBubble(
                key: bubbleKey,
                width: width,
                height: bubbleHeight,
                contentHeight: contentHeight,
                arrowSize: arrowSize,
                radius: radius,
                arrowCenterDx: arrowCenterDx,
                arrowPointUp: showDown,
                items: items,
                itemHeight: itemHeight,
                verticalPadding: verticalPadding,
                duration: duration,
                onDismissed: onClosed,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 气泡本体（带显示/消失动画）：圆角矩形 + 框外小三角箭头（聊天气泡样式）
class _AnimatedBubble extends StatefulWidget {
  final double width;
  final double height; // 总高度 = contentHeight + arrowSize
  final double contentHeight; // 矩形本体高度（不含三角）
  final double arrowSize;
  final double radius;
  final double arrowCenterDx; // 箭头水平中心相对气泡 left 的偏移
  final bool arrowPointUp; // true=三角在顶部（气泡在 anchor 下方）
  final List<BubbleMenuItem> items;
  final double itemHeight;
  final double verticalPadding;
  final Duration duration;
  final VoidCallback onDismissed;

  const _AnimatedBubble({
    super.key,
    required this.width,
    required this.height,
    required this.contentHeight,
    required this.arrowSize,
    required this.radius,
    required this.arrowCenterDx,
    required this.arrowPointUp,
    required this.items,
    required this.itemHeight,
    required this.verticalPadding,
    required this.duration,
    required this.onDismissed,
  });

  @override
  State<_AnimatedBubble> createState() => _AnimatedBubbleState();
}

class _AnimatedBubbleState extends State<_AnimatedBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      reverseDuration: widget.duration,
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _scale = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );
    _controller.forward();
  }

  /// 开始关闭：淡出动画结束后移除气泡并回调
  void beginClose() {
    if (_controller.status == AnimationStatus.dismissed ||
        _controller.isAnimating) {
      return;
    }
    _controller.reverse().whenComplete(widget.onDismissed);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return FadeTransition(
      opacity: _opacity,
      child: ScaleTransition(
        scale: _scale,
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: CustomPaint(
            painter: _BubblePainter(
              brightness: b,
              radius: widget.radius,
              arrowSize: widget.arrowSize,
              contentHeight: widget.contentHeight,
              arrowCenterDx: widget.arrowCenterDx,
              arrowPointUp: widget.arrowPointUp,
            ),
            // 内容避开三角区域：三角在顶部时下方留顶距，三角在底部时下方留底距
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                0,
                (widget.arrowPointUp ? widget.arrowSize : 0) +
                    widget.verticalPadding,
                0,
                (widget.arrowPointUp ? 0 : widget.arrowSize) +
                    widget.verticalPadding,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < widget.items.length; i++)
                    _MenuItemTile(
                      item: widget.items[i],
                      height: widget.itemHeight,
                      onTap: () {
                        widget.items[i].onTap?.call();
                        beginClose();
                      },
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 气泡绘制：圆角矩形本体 + 框外小三角箭头（聊天气泡样式）
/// 三角完全在矩形本体外侧，仅底边与矩形边缘相接，不侵入框内
class _BubblePainter extends CustomPainter {
  final Brightness brightness;
  final double radius;
  final double arrowSize;
  final double contentHeight; // 矩形本体高度
  final double arrowCenterDx;
  final bool arrowPointUp; // true=三角在顶部（矩形本体在三角下方）

  _BubblePainter({
    required this.brightness,
    required this.radius,
    required this.arrowSize,
    required this.contentHeight,
    required this.arrowCenterDx,
    required this.arrowPointUp,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = bgColor(brightness);
    // 边框：白天浅灰 / 夜晚深灰
    final border = Paint()
      ..color = bgHoverColor(brightness)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    // 矩形本体位置：三角在顶部时本体从 y=arrowSize 开始；三角在底部时本体从 0 开始
    final bodyTop = arrowPointUp ? arrowSize : 0.0;
    final bodyRect = Rect.fromLTWH(0, bodyTop, size.width, contentHeight);

    // 三角：顶点在框外；底边延伸到矩形内部几像素，覆盖矩形边框，使三角与气泡融为一体
    final halfBase = arrowSize * 0.6;
    final double tipY;
    final double baseY;
    if (arrowPointUp) {
      tipY = 0; // 三角尖朝上，顶点在顶部外侧
      baseY = arrowSize + 2; // 底边深入矩形内，盖住矩形上边缘的 1px 边框
    } else {
      tipY = size.height; // 三角尖朝下，顶点在底部外侧
      baseY = size.height - arrowSize - 2; // 底边深入矩形内，盖住矩形下边缘边框
    }
    final tip = Offset(arrowCenterDx, tipY);
    final base1 = Offset(arrowCenterDx - halfBase, baseY);
    final base2 = Offset(arrowCenterDx + halfBase, baseY);

    // 矩形本体（圆角）
    final bodyPath = Path()..addRRect(RRect.fromRectAndRadius(bodyRect, Radius.circular(radius)));

    // 三角填充路径（底边深入矩形内，覆盖该处矩形边框）
    final arrowPath = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(base1.dx, base1.dy)
      ..lineTo(base2.dx, base2.dy)
      ..close();

    // 画本体
    canvas.drawPath(bodyPath, fill);
    canvas.drawPath(bodyPath, border);
    // 画三角：先填充（覆盖矩形边框，形成融合）；斜边描边只画到矩形边缘（不侵入气泡内部）
    canvas.drawPath(arrowPath, fill);
    // 矩形边缘 y：三角只描边到矩形边缘处，与本体圆角边框衔接
    final edgeY = arrowPointUp ? arrowSize : size.height - arrowSize;
    final edge1 = Offset(arrowCenterDx - halfBase, edgeY);
    final edge2 = Offset(arrowCenterDx + halfBase, edgeY);
    final sidePath = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(edge1.dx, edge1.dy)
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(edge2.dx, edge2.dy);
    canvas.drawPath(sidePath, border);
  }

  @override
  bool shouldRepaint(covariant _BubblePainter old) {
    return old.arrowCenterDx != arrowCenterDx ||
        old.arrowPointUp != arrowPointUp ||
        old.arrowSize != arrowSize ||
        old.contentHeight != contentHeight ||
        old.brightness != brightness ||
        old.radius != radius;
  }
}

/// 单个菜单项（可点击）：无背景胶囊、无加粗；仅鼠标悬停时文字/图标变蓝，其余默认白天黑/夜晚白
class _MenuItemTile extends StatefulWidget {
  final BubbleMenuItem item;
  final double height;
  final VoidCallback onTap;

  const _MenuItemTile({
    required this.item,
    required this.height,
    required this.onTap,
  });

  @override
  State<_MenuItemTile> createState() => _MenuItemTileState();
}

class _MenuItemTileState extends State<_MenuItemTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    // hover：蓝底胶囊 + 图标文字变白；其余用项自身颜色（默认白天黑 / 夜晚白），不加粗
    final bg = _hovered ? kPrimary : Colors.transparent;
    final color =
        _hovered ? Colors.white : (widget.item.color ?? textColor(b));
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          height: widget.height,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(kRadiusBtn),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.item.icon != null) ...[
                Icon(widget.item.icon, size: 15, color: color),
                const SizedBox(width: 6),
              ],
              if (widget.item.label != null)
                Text(
                  widget.item.label!,
                  style: TextStyle(
                    fontSize: 13,
                    color: color,
                    fontWeight: FontWeight.w400,
                    decoration: TextDecoration.none,
                    decorationColor: Colors.transparent,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
