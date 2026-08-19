import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 程序化伪 3D 彩色地球（自转动画，无外部资源依赖）
///
/// 原理：球面网格（经纬格子）+ 环形谐波噪声生成海陆与大陆颜色，
/// 正交投影 + 23.5° 轴倾斜呈现 3D 感，经度随时间自转。
/// 所有绘制被裁剪到球体圆形内，保证轮廓始终是正圆。
class EarthGlobe extends StatefulWidget {
  /// 球体直径（像素）
  final double size;

  /// 自转一圈耗时
  final Duration spinDuration;

  const EarthGlobe({super.key, this.size = 320, this.spinDuration = const Duration(seconds: 14)});

  @override
  State<EarthGlobe> createState() => _EarthGlobeState();
}

class _EarthGlobeState extends State<EarthGlobe>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
      vsync: this, duration: widget.spinDuration)
    ..repeat();

  /// 海陆网格（固定种子，每次进入页面大陆形状一致）
  late final _EarthModel _model = _EarthModel.generate();

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
          return CustomPaint(
            size: Size.square(widget.size),
            painter: _EarthPainter(
              model: _model,
              rotation: _ctrl.value * 2 * math.pi,
            ),
          );
        },
      ),
    );
  }
}

/// 大陆色板：热带绿 / 黄绿 / 沙漠黄 / 棕 / 极地浅色
const List<Color> _landColors = [
  Color(0xFF3E8E3E),
  Color(0xFF7FA84E),
  Color(0xFFD2A24B),
  Color(0xFF8F6F47),
  Color(0xFFD9CBB0),
];

/// 海陆模型：经纬网格每个格子标记 海/陆 与大陆颜色索引
class _EarthModel {
  final int lonSegs;
  final int latSegs;
  final List<List<bool>> land; // [latIdx][lonIdx]
  final List<List<int>> colorIdx;

  _EarthModel._(this.lonSegs, this.latSegs, this.land, this.colorIdx);

  /// 环形谐波噪声：lonUnit ∈ [0,1) 环形连续（无经度接缝），返回 [0,1]
  static double _ringNoise(double lonUnit, double latNorm, [int phase = 0]) {
    var s = 0.0;
    s += 0.55 *
        math.sin(2 * math.pi * (lonUnit * 3 + phase * 0.13) + 1.7) *
        math.cos(2 * math.pi * (latNorm * 2.2) + 0.5);
    s += 0.30 * math.sin(2 * math.pi * (lonUnit * 6 + latNorm * 1.6) + 0.3);
    s += 0.15 * math.sin(2 * math.pi * (lonUnit * 10 - latNorm * 2.8) + 2.1);
    return (s + 1) * 0.5;
  }

  /// 根据纬度 + 噪声为陆地格子选颜色
  static int _pickColor(double latDeg, double lonUnit, double latNorm) {
    final absLat = latDeg.abs();
    final rnd = _ringNoise(lonUnit + 0.7, latNorm + 0.5, 7);
    if (absLat >= 68) return 4; // 极地
    if (absLat <= 28) return rnd > 0.45 ? 0 : 2; // 热带绿 / 沙漠
    if (absLat <= 50) return rnd > 0.5 ? 1 : 3; // 黄绿 / 棕
    return rnd > 0.5 ? 1 : 4; // 高纬绿 / 极地浅色
  }

  static _EarthModel generate({int lonSegs = 48, int latSegs = 24}) {
    final land = List.generate(latSegs, (_) => List<bool>.filled(lonSegs, false));
    final colorIdx =
        List.generate(latSegs, (_) => List<int>.filled(lonSegs, 0));
    for (var li = 0; li < latSegs; li++) {
      final latDeg = li / latSegs * 180 - 90;
      final latNorm = (latDeg + 90) / 180;
      for (var lni = 0; lni < lonSegs; lni++) {
        final lonUnit = lni / lonSegs;
        final v = _ringNoise(lonUnit, latNorm);
        if (v > 0.54) {
          land[li][lni] = true;
          colorIdx[li][lni] = _pickColor(latDeg, lonUnit, latNorm);
        }
      }
    }
    return _EarthModel._(lonSegs, latSegs, land, colorIdx);
  }
}

class _EarthPainter extends CustomPainter {
  final _EarthModel model;

  /// 当前自转角度（弧度）
  final double rotation;

  /// 球体轴倾斜角（模拟地轴 23.5°）
  static const double _tilt = 0.41;

  const _EarthPainter({required this.model, required this.rotation});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final R = size.width / 2 * 0.92;

    // 裁剪到球体圆形，保证背面格子/超界部分不外泄
    final clipPath = Path()..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: R));
    canvas.save();
    canvas.clipPath(clipPath);

    // 1. 海洋：球底色 + 左上光源的径向渐变
    canvas.drawCircle(
      Offset(cx, cy),
      R,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.35, -0.45),
          radius: 1.4,
          colors: [Color(0xFF3D7BD9), Color(0xFF1B4F9C), Color(0xFF0A2A66)],
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: R)),
    );

    // 2. 大陆格子：球面投影成多边形填充
    final landPaint = Paint();
    final path = Path();
    for (var li = 0; li < model.latSegs; li++) {
      final lat1 = li / model.latSegs * 180 - 90;
      final lat2 = (li + 1) / model.latSegs * 180 - 90;
      final latMid = (lat1 + lat2) / 2;
      for (var lni = 0; lni < model.lonSegs; lni++) {
        if (!model.land[li][lni]) continue;
        final lon1 = lni / model.lonSegs * 360;
        final lon2 = (lni + 1) / model.lonSegs * 360;
        final lonMid = (lon1 + lon2) / 2;
        if (!_visible(lonMid, latMid, cx, cy, R)) continue; // 背面跳过

        path.reset();
        path.moveTo(_px(lon1, lat1, cx, cy, R), _py(lon1, lat1, cx, cy, R));
        path.lineTo(_px(lon2, lat1, cx, cy, R), _py(lon2, lat1, cx, cy, R));
        path.lineTo(_px(lon2, lat2, cx, cy, R), _py(lon2, lat2, cx, cy, R));
        path.lineTo(_px(lon1, lat2, cx, cy, R), _py(lon1, lat2, cx, cy, R));
        path.close();

        // 亮度微调，让大陆有自然纹理
        final base = _landColors[model.colorIdx[li][lni]];
        final hsl = HSLColor.fromColor(base);
        final delta = ((li * 7 + lni * 13) % 9) / 9 * 0.10 - 0.05;
        landPaint.color = hsl
            .withLightness((hsl.lightness + delta).clamp(0.0, 1.0))
            .toColor();
        canvas.drawPath(path, landPaint);
      }
    }

    // 3. 经纬网格线（半透明白，细线）
    final gridPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = Colors.white.withValues(alpha: 0.22);
    // 纬线：始终画正面半弧
    for (var lat = -60; lat <= 60; lat += 30) {
      final pts = Path();
      for (var i = 0; i <= 36; i++) {
        final th = -math.pi / 2 + i / 36 * math.pi;
        final phi = lat * math.pi / 180;
        final x = cx + R * math.cos(phi) * math.cos(th);
        final zT = R * math.cos(phi) * math.sin(th) * math.sin(_tilt) +
            R * math.sin(phi) * math.cos(_tilt);
        final y = cy - zT;
        if (i == 0) {
          pts.moveTo(x, y);
        } else {
          pts.lineTo(x, y);
        }
      }
      canvas.drawPath(pts, gridPaint);
    }
    // 经线：仅正面（cos(th) >= 0）
    for (var lon0 = 0; lon0 < 360; lon0 += 30) {
      final th0 = lon0 * math.pi / 180 + rotation;
      if (math.cos(th0) < 0) continue;
      final pts = Path();
      for (var i = 0; i <= 36; i++) {
        final phi = -math.pi / 2 + i / 36 * math.pi;
        final x = cx + R * math.cos(phi) * math.cos(th0);
        final zT = R * math.cos(phi) * math.sin(th0) * math.sin(_tilt) +
            R * math.sin(phi) * math.cos(_tilt);
        final y = cy - zT;
        if (i == 0) {
          pts.moveTo(x, y);
        } else {
          pts.lineTo(x, y);
        }
      }
      canvas.drawPath(pts, gridPaint);
    }

    // 4. 左上高光（模拟光照）
    canvas.drawCircle(
      Offset(cx, cy),
      R,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.5, -0.6),
          radius: 1.3,
          colors: [Color(0x66FFFFFF), Color(0x00000000)],
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: R)),
    );

    canvas.restore();

    // 5. 球体边缘细线（轮廓）
    canvas.drawCircle(
      Offset(cx, cy),
      R,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withValues(alpha: 0.30),
    );

    // 6. 大气辉光（球体外围淡蓝光晕）
    canvas.drawCircle(
      Offset(cx, cy),
      R * 1.12,
      Paint()
        ..shader = RadialGradient(
          center: Alignment.center,
          radius: 1.0,
          colors: [
            Colors.lightBlueAccent.withValues(alpha: 0.10),
            Colors.lightBlueAccent.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: R * 1.12)),
    );
  }

  /// 经度/纬度 → 3D 球面坐标（含旋转 + 轴倾斜）→ 屏幕 x
  double _px(double lonDeg, double latDeg, double cx, double cy, double R) {
    final phi = latDeg * math.pi / 180;
    final th = lonDeg * math.pi / 180 + rotation;
    return cx + R * math.cos(phi) * math.cos(th);
  }

  /// 屏幕 y（纬度 + 深度经倾斜投影）
  double _py(double lonDeg, double latDeg, double cx, double cy, double R) {
    final phi = latDeg * math.pi / 180;
    final th = lonDeg * math.pi / 180 + rotation;
    final y3 = R * math.cos(phi) * math.sin(th);
    final z3 = R * math.sin(phi);
    final zT = y3 * math.sin(_tilt) + z3 * math.cos(_tilt);
    return cy - zT;
  }

  /// 该点是否朝向观察者（正面）
  bool _visible(double lonDeg, double latDeg, double cx, double cy, double R) {
    final phi = latDeg * math.pi / 180;
    final th = lonDeg * math.pi / 180 + rotation;
    final y3 = R * math.cos(phi) * math.sin(th);
    final z3 = R * math.sin(phi);
    return y3 * math.cos(_tilt) - z3 * math.sin(_tilt) > 0;
  }

  @override
  bool shouldRepaint(covariant _EarthPainter oldDelegate) =>
      oldDelegate.rotation != rotation || oldDelegate.model != model;
}
