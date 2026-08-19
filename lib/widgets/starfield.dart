import 'dart:math';

import 'package:flutter/material.dart';

import '../core/app_config.dart';

/// 宇宙星空背景（背景板，不遮挡前端内容）
///
/// - 纯黑背景 + 星星（数量等预设参数统一取自 [AppConfig]）
/// - 星星有大有小、亮度各异、颜色从预设色板确定性分配
/// - 全部缓慢从右往左漂移，移出左侧后从右侧重新进入
/// - 白天/夜晚主题同步（背景恒定宇宙黑）
class StarfieldBackground extends StatefulWidget {
  /// 暂停滚动（撞击动画期间 true，撞击结束恢复）
  final bool paused;

  /// 背景色（默认纯黑；可自定义，如白天主题的稍亮深蓝黑）
  final Color backgroundColor;

  const StarfieldBackground({
    super.key,
    this.paused = false,
    this.backgroundColor = const Color(0xFF000000),
  });

  @override
  State<StarfieldBackground> createState() => _StarfieldBackgroundState();
}

class _StarfieldBackgroundState extends State<StarfieldBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
      vsync: this,
      duration:
          Duration(seconds: AppConfig.starDriftSeconds))
    ..repeat();

  late final List<_Star> _stars = List.generate(
      AppConfig.starCount, (i) => _Star.random(i, Random()));

  @override
  void didUpdateWidget(covariant StarfieldBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 暂停/恢复星星滚动
    if (oldWidget.paused != widget.paused) {
      if (widget.paused) {
        _ctrl.stop();
      } else if (!_ctrl.isAnimating) {
        _ctrl.repeat();
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          // 用 lastElapsedDuration（单调递增，动画循环回卷不影响）作为时间基准，
          // 每颗星星按自身周期连续漂移，永不瞬移。
          final elapsedSec =
              (_ctrl.lastElapsedDuration?.inMicroseconds ?? 0) / 1e6;
          return CustomPaint(
            size: Size.infinite,
            painter: _StarfieldPainter(
              stars: _stars,
              elapsedSec: elapsedSec,
              backgroundColor: widget.backgroundColor,
            ),
          );
        },
      ),
    );
  }
}

/// 预设星色板（真实星空常见星色，避免全是白光刺眼）。
/// 星星创建时按索引确定性分配（[StarPalette.byIndex]），不做运行时随机取色。
class StarPalette {
  StarPalette._();

  /// 预设 6 种星色
  static const List<Color> colors = [
    Color(0xFFFFFFFF), // 白
    Color(0xFFCFE4FF), // 淡蓝
    Color(0xFFFFE9C9), // 淡黄
    Color(0xFFFFD6B0), // 淡橙
    Color(0xFFD9C8FF), // 淡紫
    Color(0xFFC4F0FF), // 淡青
  ];

  /// 按索引取预设色（越界循环，返回非空）
  static Color byIndex(int i) => colors[i % colors.length];
}

/// 单颗星星
class _Star {
  /// 起始 x 比例 0..1（右→左漂移用 phase 回卷）
  final double x;

  /// y 比例 0..1（固定不上下移动）
  final double y;

  /// 半径（像素），有大有小
  final double radius;

  /// 亮度 0..1
  final double alpha;

  /// 星色（创建时按索引从预设色板确定性分配，非空）
  final Color color;

  /// 速度系数（不同星星速度略不同，0.7~1.3）
  final double speed;

  _Star.random(int index, Random r)
      : x = r.nextDouble(),
        y = r.nextDouble(),
        radius = AppConfig.starMinRadius +
            r.nextDouble() * (AppConfig.starMaxRadius - AppConfig.starMinRadius),
        alpha = AppConfig.starMinAlpha +
            r.nextDouble() * (AppConfig.starMaxAlpha - AppConfig.starMinAlpha),
        color = StarPalette.byIndex(index),
        speed = AppConfig.starSpeedMin +
            r.nextDouble() * (AppConfig.starSpeedMax - AppConfig.starSpeedMin);
}

class _StarfieldPainter extends CustomPainter {
  final List<_Star> stars;

  /// 已运行时间（秒，单调递增，从动画启动起累计）
  final double elapsedSec;

  /// 背景色
  final Color backgroundColor;

  const _StarfieldPainter({
    required this.stars,
    required this.elapsedSec,
    required this.backgroundColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 背景色（默认纯黑）
    canvas.drawRect(Offset.zero & size, Paint()..color = backgroundColor);
    for (final s in stars) {
      // 每颗星星周期 = 基础漂移耗时 / 速度（周期内连续移动，永无跳变）。
      // 位置 = 起始 - 已运行时间/周期，Dart 取模恒非负 → 自动从左侧移出、
      // 从右侧进入，视觉连续。
      final period = AppConfig.starDriftSeconds / s.speed;
      final x = (s.x - elapsedSec / period) % 1.0;
      final c = Offset(x * size.width, s.y * size.height);

      // 1. 光晕扩散层：大半径径向渐变，边缘淡出（柔和，不过曝）
      final glowR = s.radius * AppConfig.starGlowRatio;
      final glowPaint = Paint()
        ..shader = RadialGradient(
          colors: [
            s.color.withValues(
                alpha: s.alpha * AppConfig.starGlowMaxAlpha),
            s.color.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromCircle(center: c, radius: glowR));
      canvas.drawCircle(c, glowR, glowPaint);

      // 2. 中心亮点：小实心星核
      final corePaint = Paint()..color = s.color.withValues(alpha: s.alpha);
      canvas.drawCircle(c, s.radius, corePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _StarfieldPainter oldDelegate) =>
      oldDelegate.elapsedSec != elapsedSec ||
      oldDelegate.stars != stars ||
      oldDelegate.backgroundColor != backgroundColor;
}
