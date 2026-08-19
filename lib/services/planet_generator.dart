import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// 星球表面材质风格
///
/// 成员名与后端 `planet.type` 存储值一一对应（[apiValue]），
/// 客户端从接口解析 type 后经 [fromApi] 得到对应材质。
enum PlanetStyle {
  /// 类地行星：蓝海 / 绿草地 / 白沙漠 / 极地冰雪
  earth('earth'),

  /// 岩浆行星：整颗炽热熔岩表面（熔岩流明暗纹理），无海陆
  lava('lava'),

  /// 气态巨行星（木星式）：奶黄/棕褐纬向条纹云带 + 大红斑，无海陆
  jupiter('jupiter'),

  /// 岩石行星：整颗岩石表面 + 陨坑纹理，无海陆
  rock('rock'),

  /// 渐变色行星：整颗绿色渐变表面（柔和明暗），无海陆
  gradientGreen('gradient_green'),

  /// 渐变色行星：整颗蓝色渐变表面（柔和明暗），无海陆
  gradientBlue('gradient_blue'),

  /// 渐变色行星：整颗粉色渐变表面（柔和明暗），无海陆
  gradientPink('gradient_pink'),

  /// 渐变色行星：整颗红色渐变表面（柔和明暗），无海陆
  gradientRed('gradient_red'),

  /// 黑洞：全黑无陆地，橙色亮光晕，不自转
  blackhole('blackhole');

  const PlanetStyle(this.apiValue);

  /// 后端 `planet.type` 存储值
  final String apiValue;

  /// 从后端 type 字符串解析材质（未知/空返回 null）
  static PlanetStyle? fromApi(String? v) {
    if (v == null || v.isEmpty) return null;
    for (final s in values) {
      if (s.apiValue == v) return s;
    }
    return null;
  }
}

/// ============================================================
/// 方块风格星球生成器（Minecraft 像素风）
///
/// 生成 equirectangular 贴图（低分辨率 + 最近邻采样 → 方块像素感）：
/// - earth：唯一有海陆的类型。海洋主题蓝（约 65%）、陆地绿色草地为主 + 白色沙漠为次（约 35%）
/// - lava：整颗炽热熔岩表面（熔岩流明暗纹理），无海陆
/// - jupiter：木星式纬向条纹云带 + 大红斑（气态无海陆）
/// - rock：整颗岩石表面 + 陨坑纹理，无海陆
/// - gradient_*：整颗渐变表面（柔和明暗云纹），无海陆（绿/蓝/粉/红）
/// - blackhole：黑洞（全黑无陆地，光晕由 shader 橙色高亮）
/// - 低分辨率让每个像素呈大方块，符合"我的世界"像素风
///
/// 仅 earth（类地）使用高度场 + 分位数海平面（海陆二分，海陆比稳定）。
/// 其余材质（lava/rock/gradient_*/jupiter/blackhole）均无海陆：
/// lava/rock/gradient_* 直接由经纬度 fBm 噪声生成整颗表面纹理。
/// ============================================================
class MinecraftPlanetGenerator {
  /// 星球种子（同一种子 → 同一星球）
  final int seed;

  /// 贴图宽（高 = 宽/2）。低分辨率营造方块像素感
  final int width;


  /// 海洋（含海岸带）占比 0..1（陆地 = 1 - oceanRatio）。
  /// 通过高度场分位数精确锁定，海陆比稳定不受种子影响
  final double oceanRatio;

  /// 陆地中沙漠占比（0..1，绿色 = 1 - desertRatio，绿应 > 沙）
  final double desertRatio;

  /// 海洋/陆地边界宽度（0..0.2，越大海岸线越碎）
  final double coastWidth;

  /// 星球表面材质风格（决定着色方式与色板）
  final PlanetStyle style;

  /// 颜色：海洋主题蓝
  static const Color oceanColor = Color(0xFF3B7FD4);

  /// 颜色：海洋深色（水深渐变）
  static const Color oceanDeepColor = Color(0xFF2A5FA8);

  /// 颜色：绿色草地（主）
  static const Color greenColor = Color(0xFF4CAF50);

  /// 颜色：沙漠（白）
  static const Color desertColor = Color(0xFFF6F3EC);

  /// 颜色：草地深色（纹理变化）
  static const Color greenDarkColor = Color(0xFF3A8F3E);

  /// 颜色：沙漠深色（纹理变化）
  static const Color desertDarkColor = Color(0xFFE3DED2);

  /// 颜色：海岸沙滩（陆地与海洋交界）
  static const Color sandColor = Color(0xFFF2EEE6);

  /// 颜色：极地冰雪（南极/北极白色大陆）
  static const Color polarColor = Color(0xFFF0F6FF);

  /// 颜色：极地冰雪暗部（纹理）
  static const Color polarDarkColor = Color(0xFFD8E4F2);

  /// 颜色（岩浆）：熔岩海（浅）
  static const Color lavaOceanColor = Color(0xFF5A1206);

  /// 颜色（岩浆）：熔岩海深色（越深越黑）
  static const Color lavaDeepColor = Color(0xFF1A0302);

  /// 颜色（岩浆）：海岸亮熔岩（陆地与熔岩海交界）
  static const Color lavaCoastColor = Color(0xFFC2441B);

  /// 颜色（岩浆）：陆地熔岩暗部（纹理）
  static const Color lavaDarkColor = Color(0xFF8A2208);

  /// 颜色（岩浆）：陆地熔岩亮部（亮橙黄熔岩流）
  static const Color lavaBrightColor = Color(0xFFFF8C1A);

  /// 颜色（岩浆）：黑曜石裂纹
  static const Color lavaCrackColor = Color(0xFF150A06);

  /// 颜色（木星）：深棕条纹
  static const Color jupiterDark = Color(0xFF8A6A44);

  /// 颜色（木星）：橙棕条纹
  static const Color jupiterOrange = Color(0xFFC98A4B);

  /// 颜色（木星）：奶黄条纹
  static const Color jupiterLight = Color(0xFFE8D5B0);

  /// 颜色（木星）：奶油白亮带
  static const Color jupiterCream = Color(0xFFF4ECDD);

  /// 颜色（木星）：大红斑
  static const Color jupiterSpot = Color(0xFFC65B3F);

  /// 颜色（木星）：大红斑暗缘
  static const Color jupiterSpotDark = Color(0xFFA8492E);

  /// 颜色（岩石）：岩海深灰蓝
  static const Color rockOceanColor = Color(0xFF46505C);

  /// 颜色（岩石）：岩海深色
  static const Color rockDeepColor = Color(0xFF2A3038);

  /// 颜色（岩石）：海岸灰岩
  static const Color rockCoastColor = Color(0xFF6B7480);

  /// 颜色（岩石）：陆块主色（灰岩）
  static const Color rockLandColor = Color(0xFF8A929B);

  /// 颜色（岩石）：陆块亮部（浅灰岩）
  static const Color rockLandLightColor = Color(0xFFB0B6BE);

  /// 颜色（岩石）：陆块暗部（深灰纹理）
  static const Color rockLandDarkColor = Color(0xFF5C636C);

  /// 颜色（渐变·绿）：渐变海浅绿
  static const Color gradientGreenOcean = Color(0xFF6FC98A);

  /// 颜色（渐变·绿）：渐变海深绿
  static const Color gradientGreenDeep = Color(0xFF3FA96B);

  /// 颜色（渐变·绿）：海岸过渡（浅绿）
  static const Color gradientGreenCoast = Color(0xFFC6EBD0);

  /// 颜色（渐变·绿）：陆块主色（浅绿渐变）
  static const Color gradientGreenLand = Color(0xFFA6E0B4);

  /// 颜色（渐变·绿）：陆块亮部（浅绿白）
  static const Color gradientGreenLandLight = Color(0xFFD6F4DE);

  /// 颜色（渐变·绿）：陆块暗部（深绿，纹理变化）
  static const Color gradientGreenLandDark = Color(0xFF5CB877);

  /// 颜色（渐变·蓝）：渐变海浅蓝
  static const Color gradientBlueOcean = Color(0xFF7FC8FF);

  /// 颜色（渐变·蓝）：渐变海深蓝
  static const Color gradientBlueDeep = Color(0xFF3A9BDB);

  /// 颜色（渐变·蓝）：海岸过渡（浅蓝）
  static const Color gradientBlueCoast = Color(0xFFC2E8FF);

  /// 颜色（渐变·蓝）：陆块主色（浅蓝渐变）
  static const Color gradientBlueLand = Color(0xFFA8DCFF);

  /// 颜色（渐变·蓝）：陆块亮部（浅蓝白）
  static const Color gradientBlueLandLight = Color(0xFFD8F2FF);

  /// 颜色（渐变·蓝）：陆块暗部（深蓝，纹理变化）
  static const Color gradientBlueLandDark = Color(0xFF5FB0E8);

  /// 颜色（渐变·粉）：渐变海浅粉
  static const Color gradientPinkOcean = Color(0xFFFFA8C5);

  /// 颜色（渐变·粉）：渐变海深粉
  static const Color gradientPinkDeep = Color(0xFFE56AA0);

  /// 颜色（渐变·粉）：海岸过渡（浅粉）
  static const Color gradientPinkCoast = Color(0xFFFFD1E0);

  /// 颜色（渐变·粉）：陆块主色（浅粉渐变）
  static const Color gradientPinkLand = Color(0xFFF7B7D0);

  /// 颜色（渐变·粉）：陆块亮部（浅粉白）
  static const Color gradientPinkLandLight = Color(0xFFFFDCE8);

  /// 颜色（渐变·粉）：陆块暗部（深粉，纹理变化）
  static const Color gradientPinkLandDark = Color(0xFFE88AB2);

  /// 颜色（渐变·红）：渐变海浅红
  static const Color gradientRedOcean = Color(0xFFFF9A8A);

  /// 颜色（渐变·红）：渐变海深红
  static const Color gradientRedDeep = Color(0xFFD45A5A);

  /// 颜色（渐变·红）：海岸过渡（浅红）
  static const Color gradientRedCoast = Color(0xFFFFC9BC);

  /// 颜色（渐变·红）：陆块主色（浅红渐变）
  static const Color gradientRedLand = Color(0xFFFFB0A0);

  /// 颜色（渐变·红）：陆块亮部（浅红白）
  static const Color gradientRedLandLight = Color(0xFFFFD8CE);

  /// 颜色（渐变·红）：陆块暗部（深红，纹理变化）
  static const Color gradientRedLandDark = Color(0xFFE0735F);

  MinecraftPlanetGenerator({
    required this.seed,
    this.width = 768,
    this.oceanRatio = 0.65,
    this.desertRatio = 0.20,
    this.coastWidth = 0.06,
    this.style = PlanetStyle.earth,
  });

  // ---- 确定性伪随机哈希 ----
  int _hash(int x, int y) {
    var h = x * 374761393 + y * 668265263 + seed * 1442695041;
    h = (h ^ (h >> 13)) * 1274126177;
    return (h ^ (h >> 16)) & 0x7fffffff;
  }

  int _wrap(int v, int m) => ((v % m) + m) % m;

  /// 网格噪声 [0,1]，x 方向取模循环（经度无缝）
  double _noise(double x, double y) {
    final xi = x.floor();
    final yi = y.floor();
    final xf = x - xi;
    final yf = y - yi;
    final u = xf * xf * (3 - 2 * xf);
    final v = yf * yf * (3 - 2 * yf);

    final a = _hash(_wrap(xi, 6), _wrap(yi, 4)) / 0x7fffffff;
    final b = _hash(_wrap(xi + 1, 6), _wrap(yi, 4)) / 0x7fffffff;
    final c = _hash(_wrap(xi, 6), _wrap(yi + 1, 4)) / 0x7fffffff;
    final d = _hash(_wrap(xi + 1, 6), _wrap(yi + 1, 4)) / 0x7fffffff;

    final ab = a + (b - a) * u;
    final cd = c + (d - c) * u;
    return ab + (cd - ab) * v;
  }

  /// fBm 分形噪声（多倍频，经度频率 gridX 整数倍 → 无缝）
  double _fbm(double x, double y, {int octaves = 5}) {
    var v = 0.0;
    var amp = 0.5;
    var freq = 1.0;
    var sum = 0.0;
    for (var i = 0; i < octaves; i++) {
      v += amp * _noise(x * freq, y * freq);
      sum += amp;
      amp *= 0.5;
      freq *= 2;
    }
    return v / sum;
  }

  /// 高斯钟形分布（纬度场用）
  double _gauss(double x, double center, double sigma) {
    final d = (x - center) / sigma;
    return math.exp(-d * d);
  }

  static double _smoothstep(double e0, double e1, double x) {
    final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  /// 单点地形高度（0..1，多尺度噪声叠加，经度无缝）
  double _terrainHeight(double lonN, double latN) {
    // 高度场（经度无缝，频率 6 的整数倍）：
    // - 低频：大洲骨架（cont 大块）
    // - 中频：大陆碎片/半岛
    // - 高频：岛屿点缀
    // 多尺度叠加让陆地呈自然大陆 + 群岛布局
    final cont = _fbm(lonN * 6 + seed * 0.13, latN * 2, octaves: 4);
    final detail = _fbm(lonN * 12 + seed * 0.31, latN * 4 + 5, octaves: 3);
    final islands = _fbm(lonN * 24 + 17, latN * 8, octaves: 2);
    return cont * 0.42 + detail * 0.38 + islands * 0.20;
  }

  /// 是否为渐变色星球（绿/蓝/粉/红）
  bool get _isGradient =>
      style == PlanetStyle.gradientGreen ||
      style == PlanetStyle.gradientBlue ||
      style == PlanetStyle.gradientPink ||
      style == PlanetStyle.gradientRed;

  /// 渐变色星球色板（$1 海浅色 / $2 海深色 / $3 海岸 / $4 陆主色 / $5 陆亮色 / $6 陆暗色）
  (Color, Color, Color, Color, Color, Color) _gradientPalette() {
    return switch (style) {
      PlanetStyle.gradientGreen => (
          gradientGreenOcean,
          gradientGreenDeep,
          gradientGreenCoast,
          gradientGreenLand,
          gradientGreenLandLight,
          gradientGreenLandDark,
        ),
      PlanetStyle.gradientBlue => (
          gradientBlueOcean,
          gradientBlueDeep,
          gradientBlueCoast,
          gradientBlueLand,
          gradientBlueLandLight,
          gradientBlueLandDark,
        ),
      PlanetStyle.gradientRed => (
          gradientRedOcean,
          gradientRedDeep,
          gradientRedCoast,
          gradientRedLand,
          gradientRedLandLight,
          gradientRedLandDark,
        ),
      _ => (
          gradientPinkOcean,
          gradientPinkDeep,
          gradientPinkCoast,
          gradientPinkLand,
          gradientPinkLandLight,
          gradientPinkLandDark,
        ),
    };
  }

  /// 生成星球表面贴图（ui.Image，RGBA8888，低分辨率像素风）
  Future<ui.Image> generate() async {
    final height = width ~/ 2;
    final total = width * height;
    final bytes = Uint8List(total * 4);

    // ---- 第一遍：预计算整张贴图的高度场 ----
    // 海平面 = 高度场 oceanRatio 分位值，保证"海洋(含海岸带)"精确占 oceanRatio、
    // 陆地精确占 1 - oceanRatio。不受噪声分布不均与种子偏移影响 → 海陆比稳定。
    final heights = Float32List(total);
    var minH = double.infinity;
    for (var y = 0; y < height; y++) {
      final latN = y / height; // 0=南极，1=北极
      for (var x = 0; x < width; x++) {
        final lonN = x / width;
        final h = _terrainHeight(lonN, latN);
        final i = y * width + x;
        heights[i] = h;
        if (h < minH) minH = h;
      }
    }
    final sorted = Float32List.fromList(heights)..sort();
    final seaSurface =
        sorted[(oceanRatio * total).round().clamp(0, total - 1)];

    // ---- 第二遍：按高度着色 ----
    // （气态材质 jupiter 忽略高度场，直接用经纬度生成条纹云带）
    for (var y = 0; y < height; y++) {
      final latN = y / height; // 0=南极，1=北极
      final aLat = (latN - 0.5).abs() * 2; // 0=赤道，1=极地

      for (var x = 0; x < width; x++) {
        final lonN = x / width;
        final h = heights[y * width + x];

        Color color;
        if (style == PlanetStyle.jupiter) {
          // ---- 木星式气态巨行星：纬向条纹云带 + 大红斑，无海陆 ----
          // 纬向条纹：纬度方向高频率条带 + 低频经度扰动（经度频率 6 的倍数保持无缝）
          final band = _fbm(lonN * 12 + 7, latN * 22 + seed * 0.07, octaves: 3);
          // 木星色带分段（深棕→橙棕→奶黄→奶油白→奶黄→橙棕→深棕，回环对称）
          final ring = (band * 4) % 4;
          final seg = ring.floor();
          final t = ring - seg;
          final from = switch (seg) {
            0 => jupiterDark,
            1 => jupiterOrange,
            2 => jupiterLight,
            _ => jupiterCream,
          };
          final to = switch (seg) {
            0 => jupiterOrange,
            1 => jupiterLight,
            2 => jupiterCream,
            _ => jupiterLight,
          };
          var c = Color.lerp(from, to, _smoothstep(0.0, 1.0, t))!;

          // 大红斑：南半球 ~24°S（latN≈0.27），经度 ~0.35 一带，椭圆斑
          final spotLat = _gauss(latN, 0.27, 0.055);
          final spotLon = _gauss(lonN, 0.35, 0.085);
          final spot = spotLat * spotLon;
          if (spot > 0.45) {
            final spotT = _smoothstep(0.45, 1.0, spot);
            // 斑体橙红，外缘更暗（类似大红斑的气旋边缘）
            c = Color.lerp(
              jupiterSpotDark,
              jupiterSpot,
              _smoothstep(0.6, 1.0, spotT),
            )!;
          }

          color = c;
        } else if (style == PlanetStyle.lava) {
          // ---- 岩浆：整颗炽热熔岩表面（无海陆） ----
          // 熔岩流明暗纹理：暗黑熔岩底 → 红棕熔岩 → 亮橙熔岩流
          final t = _fbm(lonN * 18 + 5, latN * 12, octaves: 3);
          final body = Color.lerp(
              lavaOceanColor, lavaBrightColor, _smoothstep(0.40, 0.85, t))!;
          color = Color.lerp(lavaDeepColor, body, _smoothstep(0.15, 0.40, t))!;
        } else if (style == PlanetStyle.rock) {
          // ---- 岩石：整颗岩石表面（无海陆）+ 陨坑纹理 ----
          final t = _fbm(lonN * 18 + 9, latN * 12, octaves: 3);
          final body = Color.lerp(
              rockLandColor, rockLandLightColor, _smoothstep(0.35, 0.75, t))!;
          var c = Color.lerp(
              rockLandDarkColor, body, _smoothstep(0.12, 0.35, t))!;
          // 陨坑：seed 决定的 4 个圆形暗斑（坑底更暗，向边缘过渡回岩石色）
          for (var k = 0; k < 4; k++) {
            final cx = _hash(k * 101 + seed, 17) / 0x7fffffff;
            final cy = _hash(k * 73 + seed, 29) / 0x7fffffff;
            final cr = 0.05 + (_hash(k * 31 + seed, 11) / 0x7fffffff) * 0.05;
            var dlon = (lonN - cx).abs();
            if (dlon > 0.5) dlon = 1 - dlon;
            final dlat = (latN - cy).abs();
            final d = math.sqrt(dlon * dlon * 2.2 + dlat * dlat * 2.2) / cr;
            if (d < 1) {
              c = Color.lerp(rockDeepColor, c, _smoothstep(0.15, 1.0, d))!;
            }
          }
          color = c;
        } else if (_isGradient) {
          // ---- 渐变：整颗渐变表面（无海陆，糖果风） ----
          // 柔和明暗云纹：海浅色亮区 ↔ 海深色暗区
          // 经度频率取 6 的倍数（_noise 经度环绕周期为 6），保证经度 0°/360° 贴图无缝
          final p = _gradientPalette();
          final t = _fbm(lonN * 12 + 5, latN * 8, octaves: 3);
          color = Color.lerp(p.$2, p.$1, _smoothstep(0.15, 0.85, t))!;
        } else if (style == PlanetStyle.blackhole) {
          // ---- 黑洞：全黑，无陆地（光晕由 shader 橙色高亮，此处仅贴图） ----
          color = const Color(0xFF000000);
        } else {
          // ---- 默认材质：海洋 + 草地/沙漠陆地 + 极地冰雪 ----
          if (h < seaSurface - coastWidth) {
            // 深海：越深越暗（以实际最深处归一化）
            final depth = ((seaSurface - coastWidth - h) /
                    (seaSurface - coastWidth - minH))
                .clamp(0.0, 1.0);
            color = Color.lerp(oceanColor, oceanDeepColor, depth)!;
          } else if (h < seaSurface + coastWidth) {
            // 海岸沙滩过渡带
            final t = ((h - (seaSurface - coastWidth)) / (2 * coastWidth))
                .clamp(0.0, 1.0);
            color = Color.lerp(oceanColor, sandColor, t)!;
          } else {
            // 极地（南极/北极）：白色冰雪大陆
            // aLat > 0.85（纬度约 > 76°）为冰盖，带冰雪纹理
            final polar = _smoothstep(0.80, 0.92, aLat);
            if (polar > 0.5) {
              final t = _fbm(lonN * 18 + 5, latN * 10, octaves: 2);
              // 冰雪纹理平滑混合，避免硬切锯齿
              color = Color.lerp(
                  polarDarkColor, polarColor, _smoothstep(0.40, 0.60, t))!;
            } else {
              // 陆地：绿色为主、沙漠为次
              // 沙漠倾向低纬（回归线带），绿地在赤道+温带
              final desertLat = _gauss(aLat, 0.35, 0.20);
              final greenLat = _gauss(aLat, 0.12, 0.18) +
                  0.6 * _gauss(aLat, 0.65, 0.15);

              // 噪声扰动让沙漠/绿地分布自然
              final n = _fbm(lonN * 12 + 7, latN * 8, octaves: 3);
              final desertWeight =
                  (desertLat * (0.5 + n * 0.8)) * desertRatio;
              final greenWeight = greenLat *
                  (1.2 + (1 - n) * 0.6) *
                  (1 - desertRatio);

              // 沙漠占比 0..1（0=纯绿，1=纯沙），用于平滑过渡
              final desertFrac = desertWeight / (desertWeight + greenWeight);

              // 绿↔沙平滑过渡：在中间区间渐变，避免交界生硬
              final transition = _smoothstep(0.35, 0.65, desertFrac);

              // 绿色：深浅纹理斑块（smoothstep 平滑混合，避免硬切锯齿）
              final gt = _fbm(lonN * 24 + 3, latN * 16, octaves: 2);
              final gCol = Color.lerp(
                  greenDarkColor, greenColor, _smoothstep(0.40, 0.60, gt))!;
              // 沙漠：深浅纹理（平滑混合）
              final st = _fbm(lonN * 24 + 11, latN * 16, octaves: 2);
              final sCol = Color.lerp(
                  desertDarkColor, desertColor, _smoothstep(0.40, 0.60, st))!;

              // 按过渡系数混合绿/沙，过渡带呈现自然黄绿色渐变
              color = Color.lerp(gCol, sCol, transition)!;
            }
          }
        }

        final i = (y * width + x) * 4;
        bytes[i] = (color.r * 255).round();
        bytes[i + 1] = (color.g * 255).round();
        bytes[i + 2] = (color.b * 255).round();
        bytes[i + 3] = 255;
      }
    }

    // 经度 0°/360° 环绕接缝：末列复制首列，让球面映射接缝两侧像素完全一致，
    // 消除自转时经度 0 处出现的"经纬线分割"割裂感
    for (var y = 0; y < height; y++) {
      final src = y * width * 4;
      final dst = src + (width - 1) * 4;
      bytes[dst] = bytes[src];
      bytes[dst + 1] = bytes[src + 1];
      bytes[dst + 2] = bytes[src + 2];
      bytes[dst + 3] = bytes[src + 3];
    }

    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        bytes, width, height, ui.PixelFormat.rgba8888, (img) => c.complete(img));
    return c.future;
  }
}
