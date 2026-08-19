import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/planet_generator.dart';

/// 3D 星球（Minecraft 方块风格，程序化生成表面，慢速自转）
///
/// 表面由 [MinecraftPlanetGenerator] 按种子程序化生成：
/// - earth：海洋主题蓝（约 2/3）、绿色草地为主、白色沙漠为次（陆地约 1/3）
/// - lava：熔岩海 + 亮橙熔岩陆块 + 黑曜石裂纹
/// - jupiter：木星式纬向条纹云带 + 大红斑
/// - 低分辨率贴图 + 球面映射 → 方块像素感（我的世界风格）
class PlanetGlobe extends StatefulWidget {
  /// 球体直径（像素）
  final double size;

  /// 星球种子（同一种子 → 同一星球）
  final int seed;

  /// 星球表面材质风格
  final PlanetStyle style;

  /// 自转一圈耗时（慢速）
  final Duration spinDuration;

  const PlanetGlobe({
    super.key,
    this.size = 400,
    this.seed = 0,
    this.style = PlanetStyle.earth,
    this.spinDuration = const Duration(seconds: 45),
  });

  @override
  State<PlanetGlobe> createState() => _PlanetGlobeState();
}

class _PlanetGlobeState extends State<PlanetGlobe>
    with SingleTickerProviderStateMixin {
  /// 星球表面贴图缓存（key = "seed_styleIndex"）。
  ///
  /// 目的：星球页 PageView 循环滑动时，同一颗星球会反复进出视口，
  /// 缓存让已生成过的星球立即可显示（无需重新计算），滑动更平滑。
  /// 贴图数量 = 不同 (seed,style) 组合数，星球规模小，常驻内存可控。
  static final Map<String, ui.Image> _surfaceCache = {};

  static String _cacheKey(int seed, PlanetStyle style) =>
      '${seed}_${style.index}';

  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: widget.spinDuration);

  /// 黑洞不自转：自转仅对非黑洞材质开启
  bool get _rotating => widget.style != PlanetStyle.blackhole;

  /// 大气光晕颜色（黑洞 = 亮橙，其余 = 淡蓝）
  Color get _glowColor => widget.style == PlanetStyle.blackhole
      ? const Color(0xFFFF8C1A)
      : const Color(0xFF73ADFF);

  /// 光晕强度（黑洞光晕更亮更醒目）
  double get _glowStrength =>
      widget.style == PlanetStyle.blackhole ? 1.2 : 0.5;

  ui.Image? _surface;
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    if (_rotating) _ctrl.repeat();
    _load();
  }

  @override
  void didUpdateWidget(covariant PlanetGlobe oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 种子或材质变化：重新生成星球表面
    if (oldWidget.seed != widget.seed || oldWidget.style != widget.style) {
      _load();
    }
    // 材质切换影响自转/光晕：同步动画与重绘
    if (oldWidget.style != widget.style) {
      if (_rotating && !_ctrl.isAnimating) {
        _ctrl.repeat();
      } else if (!_rotating && _ctrl.isAnimating) {
        _ctrl.stop();
        _ctrl.value = 0;
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    // 注意：_surface 来自静态缓存（跨 widget 共享），不在此 dispose，
    // 由缓存生命周期统一管理，避免 PageView 滑动销毁/重建时重复释放崩溃。
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final key = _cacheKey(widget.seed, widget.style);
      var surface = _surfaceCache[key];
      if (surface == null) {
        surface = await MinecraftPlanetGenerator(
          seed: widget.seed,
          style: widget.style,
        ).generate();
        _surfaceCache[key] = surface;
      }
      final program = await ui.FragmentProgram.fromAsset(
          'assets/shaders/planet_shader.frag');
      if (!mounted) return;
      setState(() {
        _surface = surface;
        _shader = program.fragmentShader();
      });
    } catch (_) {
      // 生成/加载失败：保持空，由 painter 降级绘制
    }
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          return CustomPaint(
            size: Size.square(widget.size),
            painter: _PlanetPainter(
              shader: _shader,
              surface: _surface,
              rotation: _ctrl.value * 2 * math.pi,
              glowColor: _glowColor,
              glowStrength: _glowStrength,
            ),
          );
        },
      ),
    );
  }
}

class _PlanetPainter extends CustomPainter {
  final ui.FragmentShader? shader;
  final ui.Image? surface;
  final double rotation;

  /// 大气光晕颜色（黑洞为橙色）
  final Color glowColor;

  /// 大气光晕强度（黑洞更亮）
  final double glowStrength;

  const _PlanetPainter({
    required this.shader,
    required this.surface,
    required this.rotation,
    required this.glowColor,
    required this.glowStrength,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final s = shader;
    final img = surface;
    if (s == null || img == null) {
      // 资源未就绪：降级为暗蓝渐变圆占位
      final rect = Offset.zero & size;
      canvas.drawCircle(
        rect.center,
        size.width / 2,
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(-0.35, -0.45),
            radius: 1.4,
            colors: [Color(0xFF2A5FA8), Color(0xFF0B2550)],
          ).createShader(rect),
      );
      return;
    }

    s.setFloat(0, rotation); // uRot
    s.setFloat(1, size.width); // uSize.x
    s.setFloat(2, size.height); // uSize.y
    s.setFloat(3, glowColor.red / 255.0); // uGlowColor.r
    s.setFloat(4, glowColor.green / 255.0); // uGlowColor.g
    s.setFloat(5, glowColor.blue / 255.0); // uGlowColor.b
    s.setFloat(6, glowStrength); // uGlowStrength
    s.setImageSampler(0, img); // uSurface -> sampler 0

    canvas.drawRect(Offset.zero & size, Paint()..shader = s);
  }

  @override
  bool shouldRepaint(covariant _PlanetPainter oldDelegate) =>
      oldDelegate.rotation != rotation ||
      oldDelegate.shader != shader ||
      oldDelegate.surface != surface ||
      oldDelegate.glowColor != glowColor ||
      oldDelegate.glowStrength != glowStrength;
}
