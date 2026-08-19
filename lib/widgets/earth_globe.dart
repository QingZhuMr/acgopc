import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 3D 彩色地球（真实贴图 + 昼夜切换，自转动画）
///
/// 贴图：NASA Blue Marble（白天）/ 城市灯光（夜晚），4096×2048 equirectangular，
/// 公有领域、无国境线。通过 FragmentShader 做球面纹理映射：
/// 自转 + 23.5° 地轴倾斜 + 太阳光照昼夜平滑过渡 + 镜面高光 + 大气辉光。
class EarthGlobe extends StatefulWidget {
  /// 球体直径（像素）
  final double size;

  /// 自转一圈耗时（慢速）
  final Duration spinDuration;

  const EarthGlobe({
    super.key,
    this.size = 400,
    this.spinDuration = const Duration(seconds: 45),
  });

  @override
  State<EarthGlobe> createState() => _EarthGlobeState();
}

class _EarthGlobeState extends State<EarthGlobe>
    with SingleTickerProviderStateMixin {
  /// 地轴倾斜角
  static const double _tilt = 0.41; // 约 23.5°

  late final AnimationController _ctrl = AnimationController(
      vsync: this, duration: widget.spinDuration)
    ..repeat();

  ui.Image? _dayImage;
  ui.Image? _nightImage;
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _loadAssets();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _dayImage?.dispose();
    _nightImage?.dispose();
    super.dispose();
  }

  Future<void> _loadAssets() async {
    try {
      final day = await _loadImage('assets/images/earth_day.jpg');
      final night = await _loadImage('assets/images/earth_night.jpg');
      final program = await ui.FragmentProgram.fromAsset(
          'shaders/earth_shader.frag');
      if (!mounted) {
        day.dispose();
        night.dispose();
        return;
      }
      setState(() {
        _dayImage = day;
        _nightImage = night;
        _shader = program.fragmentShader();
      });
    } catch (_) {
      // 资源加载失败：保持空，由 painter 降级绘制
    }
  }

  /// 加载并解码贴图（缩小到 2048×1024，高清且省显存）
  Future<ui.Image> _loadImage(String asset) async {
    final data = await rootBundle.load(asset);
    final codec = await ui.instantiateImageCodec(
      data.buffer.asUint8List(),
      targetWidth: 2048,
      targetHeight: 1024,
    );
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          return CustomPaint(
            size: Size.square(widget.size),
            painter: _EarthPainter(
              shader: _shader,
              day: _dayImage,
              night: _nightImage,
              rotation: _ctrl.value * 2 * math.pi,
              tilt: _tilt,
            ),
          );
        },
      ),
    );
  }
}

class _EarthPainter extends CustomPainter {
  final ui.FragmentShader? shader;
  final ui.Image? day;
  final ui.Image? night;
  final double rotation;
  final double tilt;

  const _EarthPainter({
    required this.shader,
    required this.day,
    required this.night,
    required this.rotation,
    required this.tilt,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final s = shader;
    final d = day;
    final n = night;
    if (s == null || d == null || n == null) {
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
    s.setFloat(1, tilt); // uTilt
    s.setFloat(2, size.width); // uSize.x
    s.setFloat(3, size.height); // uSize.y
    s.setImageSampler(0, d); // uDay
    s.setImageSampler(1, n); // uNight

    canvas.drawRect(Offset.zero & size, Paint()..shader = s);
  }

  @override
  bool shouldRepaint(covariant _EarthPainter oldDelegate) =>
      oldDelegate.rotation != rotation ||
      oldDelegate.shader != shader ||
      oldDelegate.day != day ||
      oldDelegate.night != night;
}
