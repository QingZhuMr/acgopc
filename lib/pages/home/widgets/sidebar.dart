import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';

/// macOS Finder 风格侧边栏导航项（图标 + 文字，左对齐）
class MacRailItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final Brightness brightness;
  final int badge;

  /// 是否叠加"土星环"（星球导航专用）：在图标上叠加倾斜椭圆环
  final bool saturnRing;
  final VoidCallback onTap;

  const MacRailItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.brightness,
    this.badge = 0,
    this.saturnRing = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(kRadiusMd),
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        hoverColor: bgHoverColor(brightness),
        child: SizedBox(
          height: 36,
          child: Row(
            children: [
              const SizedBox(width: 10),
              // 图标整体下移 1px（视觉对齐用，不参与布局，旁边文字位置不受影响）
              Transform.translate(
                offset: const Offset(0, 1),
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    Icon(
                      icon,
                      size: 20,
                      color: selected ? kPrimary : textColor(brightness),
                    ),
                    // 土星环：倾斜椭圆环穿过星球图标
                    if (saturnRing)
                      Positioned.fill(
                        child: Transform.rotate(
                          angle: -0.35,
                          child: CustomPaint(
                            painter: SaturnRingPainter(
                              color: selected
                                  ? kPrimary
                                  : textColor(brightness),
                            ),
                          ),
                        ),
                      ),
                    if (badge > 0)
                      Positioned(
                        right: -8,
                        top: -5,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: kDanger,
                            borderRadius: BorderRadius.circular(kRadiusFull),
                          ),
                          child: Text(
                            badge > 99 ? '99+' : '$badge',
                            style: const TextStyle(
                                fontSize: 9, color: Colors.white),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: selected ? kPrimary : textColor(brightness),
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

/// 土星环画笔：绘制一条穿过星球中心的倾斜椭圆环（星球导航图标用）
class SaturnRingPainter extends CustomPainter {
  final Color color;

  const SaturnRingPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: size.width * 1.55,
      height: size.height * 0.42,
    );
    canvas.drawOval(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = color
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant SaturnRingPainter oldDelegate) =>
      oldDelegate.color != color;
}
