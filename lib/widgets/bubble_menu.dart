import 'package:flutter/gestures.dart';
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

  BubbleMenuOverlay? _current;

  /// 注册当前打开的气泡（关闭旧的）
  void register(BubbleMenuOverlay overlay) {
    _current?.close();
    _current = overlay;
  }

  /// 取消注册（当前气泡自己关闭时调用）
  void unregister(BubbleMenuOverlay overlay) {
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
  /// 菜单项（[content] 为空时渲染菜单项列表）
  final List<BubbleMenuItem> items;

  /// 自定义面板内容（如表情面板）。非空时气泡内渲染 [content] 替代菜单项，
  /// 用于弹出非菜单的扩展面板（配合 [width]/[panelHeight] 控制尺寸）。
  final Widget? content;

  /// [content] 面板的固定高度（气泡定位需预先知道总高度；默认 230）
  final double panelHeight;

  final Widget child;

  /// 气泡宽度。null=根据最长菜单项文字自动计算（避免固定宽度截断文字）；
  /// 传入数值则固定宽度（兼容省略号菜单等场景）
  final double? width;

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

  /// true=鼠标右键触发（桌面端右键菜单），false=点击触发（默认）
  final bool triggerOnRightClick;

  /// true=长按触发（移动端聊天气泡等），优先级高于其它触发方式
  final bool triggerOnLongPress;

  /// true=微信风格（移动端聊天长按菜单）：深色半透明圆角面板、
  /// 无小三角箭头、白字白图标、整行点击高亮、菜单项间细分割线
  final bool wechatStyle;

  /// true=优先在按压点/锚点上方弹出（移动端长按菜单，微信习惯在上方）；
  /// 上方空间不足时自动回落下方。默认 false=优先下方（PC 端行为不变）。
  final bool preferUp;

  /// 打开/关闭状态回调（触发按钮图标高亮等 UI 联动）
  final ValueChanged<bool>? onOpenChange;

  const BubbleMenu({
    super.key,
    this.items = const [],
    this.content,
    this.panelHeight = 230,
    required this.child,
    this.width,
    this.itemHeight = 34,
    this.verticalPadding = 6,
    this.arrowSize = 7,
    this.radius = kRadiusBtn,
    this.gap = 6,
    this.duration = const Duration(milliseconds: 150),
    this.triggerOnRightClick = false,
    this.triggerOnLongPress = false,
    this.wechatStyle = false,
    this.preferUp = false,
    this.onOpenChange,
  });

  @override
  State<BubbleMenu> createState() => BubbleMenuState();
}

class BubbleMenuState extends State<BubbleMenu> {
  final GlobalKey _anchorKey = GlobalKey();
  BubbleMenuOverlay? _overlay;

  /// 触发时的指针全局坐标（右键/左键点击位置），用于菜单跟随鼠标
  Offset? _triggerPos;

  /// 是否已打开（用布尔量判断，避免 overlay 已 close 但引用未置空导致死状态）
  bool _isOpen = false;

  @override
  void dispose() {
    _overlay?.close();
    _isOpen = false;
    super.dispose();
  }

  void _toggle([Offset? pos]) {
    if (_isOpen) {
      close();
    } else {
      _openMenu(pos);
    }
  }

  void _openMenu([Offset? pos]) {
    // 防御：若残留旧 overlay，先关闭
    _overlay?.close();
    _overlay = null;
    _isOpen = true;
    _triggerPos = pos;
    widget.onOpenChange?.call(true);
    final overlay = Overlay.of(context);
    setState(() => _overlay = BubbleMenuOverlay.pending());
    // 通过 nextFrame 确保 anchor 已布局，再定位
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isOpen) return;
      final entry = OverlayEntry(
        builder: (ctx) => _BubbleMenuOverlayView(
          anchorKey: _anchorKey,
          items: widget.items,
          content: widget.content,
          panelHeight: widget.panelHeight,
          width: widget.width,
          itemHeight: widget.itemHeight,
          verticalPadding: widget.verticalPadding,
          arrowSize: widget.arrowSize,
          radius: widget.radius,
          gap: widget.gap,
          duration: widget.duration,
          triggerPosition: _triggerPos,
          wechatStyle: widget.wechatStyle,
          preferUp: widget.preferUp,
          onClosed: _onClosed,
        ),
      );
      overlay.insert(entry);
      _overlay!.entry = entry;
      BubbleMenuManager.instance.register(_overlay!);
    });
  }

  /// 关闭菜单（供 toggle 使用；onClosed 由菜单自身移除时回调）。
  /// 对外公开：点击面板内容（如表情/表情包）后由外部调用收起气泡。
  void close() {
    _isOpen = false;
    _triggerPos = null;
    _overlay?.close();
    _overlay = null;
    widget.onOpenChange?.call(false);
  }

  void _onClosed() {
    if (!mounted) return;
    close();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // 长按触发（移动端聊天气泡等）：用 GestureDetector 长按，菜单跟随按压位置
    if (widget.triggerOnLongPress) {
      return GestureDetector(
        key: _anchorKey,
        behavior: HitTestBehavior.translucent,
        onLongPressStart: (details) => _openMenu(details.globalPosition),
        child: widget.child,
      );
    }
    // 直接用 Listener 监听 PointerDownEvent，绕过 GestureRecognizer arena：
    // - triggerOnRightClick：仅响应右键（左键穿透给 child 的 InkWell）
    // - 默认：仅响应左键
    // Listener 默认 HitTestBehavior.deferToChild，不影响子项命中测试
    return Listener(
      key: _anchorKey,
      onPointerDown: (event) {
        if (widget.triggerOnRightClick) {
          if (event.buttons == kSecondaryButton) {
            _toggle(event.position);
          }
        } else if (event.buttons == kPrimaryButton) {
          _toggle(event.position);
        }
      },
      child: widget.child,
    );
  }
}

/// 气泡 Overlay 控制器（记录 entry，负责移除）
/// 仅供 [BubbleMenu]/[BubbleMenuManager] 内部使用（公开类型以匹配公开 API 签名）。
class BubbleMenuOverlay {
  OverlayEntry? entry;

  BubbleMenuOverlay.pending();

  void close() {
    BubbleMenuManager.instance.unregister(this);
    entry?.remove();
    entry = null;
  }
}

/// 气泡 Overlay 视图：全屏拦截 + 定位 + 动画
/// 单个菜单项的内容宽度（图标 15 + 间距 6 + 文字宽）
double _measureMenuItemWidth(BubbleMenuItem item) {
  final label = item.label ?? '';
  if (label.isEmpty) return 0;
  final tp = TextPainter(
    text: TextSpan(
      text: label,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w400),
    ),
    maxLines: 1,
    textDirection: TextDirection.ltr,
  )..layout();
  var w = tp.width;
  if (item.icon != null) w += 15 + 6;
  return w;
}

/// 所有菜单项内容宽度是否一致（一致 → 内容居中；不一致 → 左对齐）
bool _menuItemsAlignCenter(List<BubbleMenuItem> items) {
  double? first;
  for (final item in items) {
    final w = _measureMenuItemWidth(item);
    if (w <= 0) continue;
    if (first == null) {
      first = w;
    } else if ((w - first).abs() > 0.5) {
      return false;
    }
  }
  return true;
}

/// 按最长菜单项文字计算气泡宽度（完整显示不截断）：
/// 文字宽度 + 图标(15) + 图标间距(6) + 水平 padding(12*2) + 项外边距(6*2)
/// 结果 clamp 在 [84, 240]（太短贴图标、太长限制最大宽度）
double _measureMenuWidth(List<BubbleMenuItem> items) {
  var maxText = 0.0;
  for (final item in items) {
    final w = _measureMenuItemWidth(item);
    if (w > maxText) maxText = w;
  }
  return (maxText + 24 + 12).clamp(84.0, 240.0);
}

class _BubbleMenuOverlayView extends StatelessWidget {
  final GlobalKey anchorKey;
  final List<BubbleMenuItem> items;
  final Widget? content;
  final double panelHeight;
  final double? width;
  final double itemHeight;
  final double verticalPadding;
  final double arrowSize;
  final double radius;
  final double gap;
  final Duration duration;
  final Offset? triggerPosition;
  final bool wechatStyle;
  final bool preferUp;
  final VoidCallback onClosed;

  const _BubbleMenuOverlayView({
    required this.anchorKey,
    required this.items,
    required this.content,
    required this.panelHeight,
    required this.width,
    required this.itemHeight,
    required this.verticalPadding,
    required this.arrowSize,
    required this.radius,
    required this.gap,
    required this.duration,
    required this.triggerPosition,
    required this.wechatStyle,
    required this.preferUp,
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

        // 微信风格：无小三角箭头（占位归零），菜单固定宽度（更接近微信长按菜单）
        final effArrowSize = wechatStyle ? 0.0 : arrowSize;
        // 面板内容：使用固定 panelHeight；菜单项：按项数计算
        final contentHeight = content != null
            ? panelHeight
            : items.length * itemHeight + verticalPadding * 2;
        // 总高度 = 内容 + 框外小三角占位
        final bubbleHeight = contentHeight + effArrowSize;
        // 宽度：固定值则用固定值；null 按最长菜单项文字自动计算（完整显示不截断）
        final bubbleWidth =
            width ?? (wechatStyle ? 200.0 : _measureMenuWidth(items));
        // 内容对齐：所有菜单项内容宽度一致 → 居中；不一致 → 左对齐
        // 微信风格：统一左对齐
        final alignCenter = wechatStyle ? false : _menuItemsAlignCenter(items);

        // 参考点：有指针坐标（右键/左键位置）则跟随鼠标，否则对齐 anchor
        final ref = triggerPosition;
        // 方向：下方空间不足则向上（按总高度判断）
        final spaceBelow =
            ref != null ? overlaySize.height - ref.dy : overlaySize.height - anchorRect.bottom;
        final spaceAbove = ref != null ? ref.dy : anchorRect.top;
        // preferUp：优先向上（移动端长按菜单，微信习惯在按压点上方），
        // 上方空间不足才回落下方；默认优先向下（PC 端行为不变）。
        final showDown = preferUp
            ? !(spaceAbove >= bubbleHeight + gap)
            : (spaceBelow >= bubbleHeight + gap || spaceBelow >= spaceAbove);

        final double topRaw;
        if (ref != null) {
          // 跟随鼠标：气泡本体直接出现在指针下方/上方
          topRaw = showDown ? ref.dy + gap : ref.dy - bubbleHeight - gap;
        } else {
          // 对齐 anchor：三角尖贴 anchor 底部，矩形本体在三角下方
          topRaw = showDown
              ? anchorRect.bottom + gap - arrowSize
              : anchorRect.top - bubbleHeight - gap;
        }
        // 垂直 clamp，避免超出屏幕（考虑小三角占位）
        final maxTop = (overlaySize.height - bubbleHeight - 8.0).clamp(8.0, overlaySize.height);
        final top = topRaw.clamp(8.0, maxTop);

        // 水平：箭头默认对齐指针/anchor 中心，气泡不越界
        final targetX = ref?.dx ?? anchorRect.center.dx;
        var left = targetX - bubbleWidth / 2;
        final minLeft = 8.0;
        final maxLeft = overlaySize.width - bubbleWidth - 8;
        if (left > maxLeft) left = maxLeft;
        if (left < minLeft) left = minLeft;

        final arrowCenterDx =
            (targetX - left).clamp(effArrowSize, bubbleWidth - effArrowSize);

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
                width: bubbleWidth,
                height: bubbleHeight,
                contentHeight: contentHeight,
                arrowSize: effArrowSize,
                radius: radius,
                arrowCenterDx: arrowCenterDx,
                arrowPointUp: showDown,
                wechatStyle: wechatStyle,
                items: items,
                content: content,
                itemHeight: itemHeight,
                verticalPadding: verticalPadding,
                duration: duration,
                alignCenter: alignCenter,
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
  final bool wechatStyle; // true=微信风格（深色半透明面板、无三角、白字）
  final List<BubbleMenuItem> items;

  /// 自定义面板内容（非空时替代菜单项渲染）
  final Widget? content;
  final double itemHeight;
  final double verticalPadding;
  final Duration duration;
  final bool alignCenter;
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
    required this.wechatStyle,
    required this.items,
    required this.content,
    required this.itemHeight,
    required this.verticalPadding,
    required this.duration,
    required this.alignCenter,
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
              wechatStyle: widget.wechatStyle,
            ),
            // 内容避开三角区域：三角在顶部时下方留顶距，三角在底部时下方留底距
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                widget.wechatStyle ? 0 : 0,
                (widget.arrowPointUp ? widget.arrowSize : 0) +
                    widget.verticalPadding,
                0,
                (widget.arrowPointUp ? 0 : widget.arrowSize) +
                    widget.verticalPadding,
              ),
              // 面板内容（表情等）→ 直接渲染；否则渲染菜单项列表。
              // Overlay 中无 Material 祖先，content 内的 InkWell（如表情面板）会崩，
              // 故包一层透明 Material（不影响视觉，splash 正常显示）
              child: widget.content != null
                  ? Material(
                      type: MaterialType.transparency,
                      child: widget.content!,
                    )
                  // 微信风格：ClipRRect 按面板圆角裁剪，使菜单项按压水波纹不溢出圆角
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(
                        widget.wechatStyle ? widget.radius : 0,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < widget.items.length; i++)
                            _MenuItemTile(
                              item: widget.items[i],
                              height: widget.itemHeight,
                              alignCenter: widget.alignCenter,
                              wechatStyle: widget.wechatStyle,
                              isLast: i == widget.items.length - 1,
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
  final bool wechatStyle; // true=微信风格：深色半透明面板、无小三角、边框更淡

  _BubblePainter({
    required this.brightness,
    required this.radius,
    required this.arrowSize,
    required this.contentHeight,
    required this.arrowCenterDx,
    required this.arrowPointUp,
    required this.wechatStyle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 微信风格：始终深色半透明底（白天夜晚一致），参考微信长按菜单弹层
    final fill = Paint()
      ..color = wechatStyle
          ? const Color(0xF01C1C1E)
          : bgColor(brightness);
    // 边框：微信风格更淡（白 10%）；默认白天浅灰 / 夜晚深灰
    final border = Paint()
      ..color = wechatStyle
          ? const Color(0x1AFFFFFF)
          : bgHoverColor(brightness)
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
        old.radius != radius ||
        old.wechatStyle != wechatStyle;
  }
}

/// 单个菜单项（可点击）：无背景胶囊、无加粗；仅鼠标悬停时文字/图标变蓝，其余默认白天黑/夜晚白。
/// 微信风格：白字白图标、整行高亮、项间细分割线（参考微信长按菜单）。
class _MenuItemTile extends StatefulWidget {
  final BubbleMenuItem item;
  final double height;

  /// true=所有菜单项内容宽度一致，居中显示；false=宽窄不一，左对齐
  final bool alignCenter;

  /// true=微信风格：白字白图标、整行 hover 高亮、分割线
  final bool wechatStyle;

  /// true=最后一项（无底部分割线）
  final bool isLast;
  final VoidCallback onTap;

  const _MenuItemTile({
    required this.item,
    required this.height,
    required this.alignCenter,
    required this.wechatStyle,
    required this.isLast,
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

    // ============ 微信风格：深色面板上白字白图标、按压水波纹、项间分割线 ============
    if (widget.wechatStyle) {
      final color = widget.item.color ?? Colors.white;
      return Material(
        type: MaterialType.transparency,
        // 按压水波纹（白 8%）——微信长按菜单的点击反馈
        child: InkWell(
          onTap: widget.onTap,
          splashColor: const Color(0x14FFFFFF),
          highlightColor: const Color(0x14FFFFFF),
          child: Container(
            height: widget.height,
            // 整行内边距（微信菜单项左右留白较大）
            padding: const EdgeInsets.symmetric(horizontal: 16),
            // 底部细分割线（最后一项无）
            decoration: BoxDecoration(
              border: widget.isLast
                  ? null
                  : const Border(
                      bottom: BorderSide(
                        color: Color(0x14FFFFFF),
                        width: 0.5,
                      ),
                    ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                if (widget.item.icon != null) ...[
                  Icon(widget.item.icon, size: 17, color: color),
                  const SizedBox(width: 10),
                ],
                if (widget.item.label != null)
                  Flexible(
                    child: Text(
                      widget.item.label!,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 14,
                        color: color,
                        fontWeight: FontWeight.w400,
                        decoration: TextDecoration.none,
                        decorationColor: Colors.transparent,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    // ============ 默认风格（PC 气泡菜单） ============
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
            // 内容宽度一致 → 居中；宽窄不一 → 左对齐
            mainAxisAlignment: widget.alignCenter
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
            children: [
              if (widget.item.icon != null) ...[
                Icon(widget.item.icon, size: 15, color: color),
                const SizedBox(width: 6),
              ],
              if (widget.item.label != null)
                Flexible(
                  child: Text(
                    widget.item.label!,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 13,
                      color: color,
                      fontWeight: FontWeight.w400,
                      decoration: TextDecoration.none,
                      decorationColor: Colors.transparent,
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
