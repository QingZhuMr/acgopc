import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

/// 骨架屏：首次加载 / 搜索时的瀑布流占位动画（呼吸闪烁）
class SkeletonGrid extends StatefulWidget {
  final int columns;
  const SkeletonGrid({super.key, required this.columns});

  @override
  State<SkeletonGrid> createState() => SkeletonGridState();
}

class SkeletonGridState extends State<SkeletonGrid>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  )..repeat(reverse: true);
  late final Animation<double> _opacity = Tween<double>(begin: 0.35, end: 1.0)
      .animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = bgHoverColor(Theme.of(context).brightness);
    // 高度错落模拟瀑布流
    const cardHeights = [200.0, 260.0, 180.0, 240.0, 220.0, 280.0];
    final cols = List.generate(widget.columns, (_) => <double>[]);
    for (var i = 0; i < widget.columns * 2; i++) {
      cols[i % widget.columns].add(cardHeights[i % cardHeights.length]);
    }
    return FadeTransition(
      opacity: _opacity,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < widget.columns; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(
              child: Column(
                children: [
                  for (final h in cols[i])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: SkeletonCard(height: h, base: base),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 骨架卡片：封面占位 + 头像/昵称占位
class SkeletonCard extends StatelessWidget {
  final double height;
  final Color base;
  const SkeletonCard({super.key, required this.height, required this.base});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: height,
          decoration: BoxDecoration(
            color: base,
            borderRadius: BorderRadius.circular(kRadiusMd),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(color: base, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                height: 10,
                decoration: BoxDecoration(
                  color: base,
                  borderRadius: BorderRadius.circular(kRadiusSm),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          width: 90,
          height: 10,
          decoration: BoxDecoration(
            color: base,
            borderRadius: BorderRadius.circular(kRadiusSm),
          ),
        ),
      ],
    );
  }
}
