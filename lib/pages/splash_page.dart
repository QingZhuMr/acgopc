import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_theme.dart';

/// 启动页（加载动画）：打开软件时先显示，期间判断自动/手动登录，
/// 结束后通过回调跳转对应页面。用于避免窗口打开时闪烁/位置移动。
class SplashPage extends StatelessWidget {
  /// 启动页显示时长（毫秒）
  static const int splashDuration = 4000;

  const SplashPage({super.key});

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Scaffold(
      backgroundColor: bgColor(b),
      body: Column(
        children: [
          // 自绘顶栏（与主窗口一致，保持平滑，无 logo）
          _buildTitleBar(b),
          // 加载主体
          Expanded(
            child: _ChaseScene(),
          ),
        ],
      ),
    );
  }

  /// 自绘顶栏：macOS 预留红黄绿按钮安全距离、不绘制窗口按钮；Windows 绘制窗口按钮
  Widget _buildTitleBar(Brightness b) {
    // macOS：左侧预留红黄绿按钮安全距离，右侧仅拖拽（无窗口按钮）
    if (Platform.isMacOS) {
      return SizedBox(
        height: 40,
        child: Row(
          children: [
            SizedBox(
              width: kMacTrafficLightWidth,
              child: Container(color: bgColor(b)),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => windowManager.startDragging(),
                child: Container(color: bgColor(b)),
              ),
            ),
          ],
        ),
      );
    }
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => windowManager.startDragging(),
              child: Container(color: bgColor(b)),
            ),
          ),
          _SplashWinButton(
            icon: Icons.remove,
            onTap: () => windowManager.minimize(),
          ),
          _SplashWinButton(
            icon: Icons.crop_square_rounded,
            onTap: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
          _SplashWinButton(
            icon: Icons.close,
            isClose: true,
            onTap: () => windowManager.close(),
          ),
        ],
      ),
    );
  }
}

/// 追逐场景：奥特曼从左往右追逐怪兽，速度随加载时间逐渐加快。
class _ChaseScene extends StatefulWidget {
  @override
  State<_ChaseScene> createState() => _ChaseSceneState();
}

class _ChaseSceneState extends State<_ChaseScene>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late final Stopwatch _elapsed; // 记录加载已过时间，决定速度

  // 角色位置（像素，相对场景宽度的比例 0~1）
  double _ultraman = 0.08;
  double _monster = 0.72;

  // 当前速度基准（随加载时间递增）
  double _speed = 0.05;

  @override
  void initState() {
    super.initState();
    _elapsed = Stopwatch()..start();
    _ticker = createTicker(_onTick);
    _ticker.start();
  }

  void _onTick(Duration elapsed) {
    if (!mounted) return;
    setState(() {
      // 加载时间（毫秒）映射为速度：初期慢，随时间加快
      final t = min(elapsed.inMilliseconds / SplashPage.splashDuration, 1.0);
      _speed = 0.04 + t * 0.16; // 0.04 ~ 0.20

      // 奥特曼与怪兽都向右移动，奥特曼更快（逐渐追上）
      _ultraman += _speed * 0.0016;
      _monster += _speed * 0.0011;

      // 怪兽被追上后，重置到右侧重新追逐
      if (_ultraman >= 1.0) {
        _ultraman = -0.1;
        _monster = 0.72;
      }
      // 怪兽出界重置
      if (_monster >= 1.15) {
        _monster = 0.8;
      }
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _elapsed.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        // 场景绘制区域（居中，宽高比约 3:1）
        final sceneH = min(h * 0.55, 260.0);
        final sceneW = min(w * 0.9, 620.0);

        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 无背景胶囊：角色直接画在主体背景上，保持整体和谐
              CustomPaint(
                size: Size(sceneW, sceneH),
                painter: _ChasePainter(
                  ultramanX: _ultraman,
                  monsterX: _monster,
                  phase: _elapsed.elapsedMicroseconds / 700000.0 % 1.0,
                  speed: _speed,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                '正在加载…',
                style: TextStyle(fontSize: 13, color: textMutedColor(b)),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 追逐场景绘制器：画奥特曼、怪兽、地面。
class _ChasePainter extends CustomPainter {
  final double ultramanX; // 奥特曼位置（0~1）
  final double monsterX; // 怪兽位置（0~1）
  final double phase; // 奔跑相位
  final double speed; // 当前速度（影响奔跑频率）

  _ChasePainter({
    required this.ultramanX,
    required this.monsterX,
    required this.phase,
    required this.speed,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // 地面线
    final groundY = h * 0.8;
    final groundPaint = Paint()
      ..color = const Color(0xFF8C9EAB)
      ..strokeWidth = 2;
    canvas.drawLine(Offset(0, groundY), Offset(w, groundY), groundPaint);

    // 摆动幅度随速度增大（跑得越快摆得越激烈）
    final swing = sin(phase * 2 * pi) * (0.5 + speed * 1.6);

    // 怪兽（在奥特曼前面）
    _drawMonster(canvas, w * monsterX, groundY, h, swing);

    // 奥特曼（在后面追）
    _drawUltraman(canvas, w * ultramanX, groundY, h, swing);
  }

  /// 画奥特曼：蓝色身体 + 红色条纹 + 黄色双眼 + 摆动四肢
  void _drawUltraman(Canvas canvas, double x, double groundY, double h,
      double swing) {
    final bodyH = h * 0.5;
    final cy = groundY - bodyH;

    final blue = Paint()
      ..color = const Color(0xFF3B82F6)
      ..style = PaintingStyle.fill;
    final red = Paint()
      ..color = const Color(0xFFEF4444)
      ..style = PaintingStyle.fill;
    final skin = Paint()
      ..color = const Color(0xFFFDE68A)
      ..style = PaintingStyle.fill;
    final silver = Paint()
      ..color = const Color(0xFFCBD5E1)
      ..style = PaintingStyle.fill;
    final outline = Paint()
      ..color = const Color(0xFF1E3A8A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // 腿（左右交替摆动）
    canvas.drawLine(Offset(x, cy + bodyH * 0.4), Offset(x - bodyH * 0.12, groundY + swing * bodyH * 0.12), blue..strokeWidth = 4);
    canvas.drawLine(Offset(x, cy + bodyH * 0.4), Offset(x + bodyH * 0.12, groundY - swing * bodyH * 0.12), blue..strokeWidth = 4);

    // 躯干（蓝色矩形 + 红色条纹）
    final bodyRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(x - bodyH * 0.18, cy, bodyH * 0.36, bodyH * 0.45),
      const Radius.circular(kRadiusSm),
    );
    canvas.drawRRect(bodyRect, blue);
    canvas.drawRRect(bodyRect, outline);
    // 胸前红色能量灯
    canvas.drawOval(
      Rect.fromCenter(center: Offset(x, cy + bodyH * 0.14), width: 6, height: 9),
      red,
    );

    // 手臂（银色，摆动）
    canvas.drawLine(
        Offset(x - bodyH * 0.13, cy + bodyH * 0.05),
        Offset(x - bodyH * 0.24, cy - bodyH * 0.18 + swing * bodyH * 0.1),
        silver..strokeWidth = 4);
    canvas.drawLine(
        Offset(x + bodyH * 0.13, cy + bodyH * 0.05),
        Offset(x + bodyH * 0.24, cy - bodyH * 0.18 - swing * bodyH * 0.1),
        silver..strokeWidth = 4);

    // 头（银色圆形 + 黄色双眼 + 红色额灯）
    final headR = bodyH * 0.14;
    canvas.drawCircle(Offset(x, cy - bodyH * 0.08), headR, silver);
    canvas.drawCircle(Offset(x, cy - bodyH * 0.08), headR, outline);
    // 黄色双眼（左右各一）
    canvas.drawCircle(Offset(x - headR * 0.45, cy - bodyH * 0.1), 2.5, skin);
    canvas.drawCircle(Offset(x + headR * 0.45, cy - bodyH * 0.1), 2.5, skin);
    // 头顶红色额灯
    canvas.drawCircle(Offset(x, cy - bodyH * 0.2), 2.5, red);
  }

  /// 画怪兽：绿色身体 + 犄角 + 尖牙 + 大眼睛
  void _drawMonster(Canvas canvas, double x, double groundY, double h,
      double swing) {
    final bodyH = h * 0.42;
    final cy = groundY - bodyH;

    final green = Paint()
      ..color = const Color(0xFF22C55E)
      ..style = PaintingStyle.fill;
    final darkGreen = Paint()
      ..color = const Color(0xFF166534)
      ..style = PaintingStyle.fill;
    final eyeWhite = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.fill;
    final eyePupil = Paint()
      ..color = const Color(0xFF000000)
      ..style = PaintingStyle.fill;
    final outline = Paint()
      ..color = const Color(0xFF14532D)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // 腿（短粗）
    canvas.drawLine(Offset(x - bodyH * 0.1, cy + bodyH * 0.42), Offset(x - bodyH * 0.1, groundY - swing * bodyH * 0.05), darkGreen..strokeWidth = 5);
    canvas.drawLine(Offset(x + bodyH * 0.1, cy + bodyH * 0.42), Offset(x + bodyH * 0.1, groundY + swing * bodyH * 0.05), darkGreen..strokeWidth = 5);

    // 身体（绿色圆胖）
    canvas.drawOval(
      Rect.fromCenter(center: Offset(x, cy + bodyH * 0.25), width: bodyH * 0.6, height: bodyH * 0.55),
      green,
    );
    canvas.drawOval(
      Rect.fromCenter(center: Offset(x, cy + bodyH * 0.25), width: bodyH * 0.6, height: bodyH * 0.55),
      outline,
    );

    // 手臂（前伸追赶状，表现逃跑）
    canvas.drawLine(
        Offset(x - bodyH * 0.2, cy + bodyH * 0.1),
        Offset(x - bodyH * 0.4, cy + bodyH * 0.05 + swing * bodyH * 0.08),
        darkGreen..strokeWidth = 4);
    canvas.drawLine(
        Offset(x + bodyH * 0.2, cy + bodyH * 0.1),
        Offset(x + bodyH * 0.4, cy + bodyH * 0.05 - swing * bodyH * 0.08),
        darkGreen..strokeWidth = 4);

    // 头（比身体小，圆 + 犄角）
    final headR = bodyH * 0.18;
    canvas.drawCircle(Offset(x, cy - bodyH * 0.1), headR, green);
    canvas.drawCircle(Offset(x, cy - bodyH * 0.1), headR, outline);
    // 犄角
    canvas.drawLine(Offset(x - headR * 0.5, cy - bodyH * 0.22), Offset(x - headR * 0.75, cy - bodyH * 0.4), darkGreen..strokeWidth = 3);
    canvas.drawLine(Offset(x + headR * 0.5, cy - bodyH * 0.22), Offset(x + headR * 0.75, cy - bodyH * 0.4), darkGreen..strokeWidth = 3);
    // 大眼睛（惊恐）
    canvas.drawCircle(Offset(x - headR * 0.4, cy - bodyH * 0.12), 4, eyeWhite);
    canvas.drawCircle(Offset(x + headR * 0.4, cy - bodyH * 0.12), 4, eyeWhite);
    canvas.drawCircle(Offset(x - headR * 0.4, cy - bodyH * 0.12), 2, eyePupil);
    canvas.drawCircle(Offset(x + headR * 0.4, cy - bodyH * 0.12), 2, eyePupil);
    // 尖牙
    canvas.drawLine(Offset(x - 3, cy - bodyH * 0.02), Offset(x - 3, cy + bodyH * 0.06), eyeWhite..strokeWidth = 3);
    canvas.drawLine(Offset(x + 3, cy - bodyH * 0.02), Offset(x + 3, cy + bodyH * 0.06), eyeWhite..strokeWidth = 3);
  }

  @override
  bool shouldRepaint(covariant _ChasePainter oldDelegate) {
    return oldDelegate.ultramanX != ultramanX ||
        oldDelegate.monsterX != monsterX ||
        oldDelegate.phase != phase ||
        oldDelegate.speed != speed;
  }
}

/// 启动页窗口控制按钮
class _SplashWinButton extends StatelessWidget {
  final IconData icon;
  final bool isClose;
  final VoidCallback onTap;

  const _SplashWinButton({
    required this.icon,
    this.isClose = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return SizedBox(
      width: 46,
      height: 40,
      child: InkWell(
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click, // 悬停显示手指
        hoverColor: isClose ? const Color(0xFFE81123) : bgHoverColor(b),
        child: Icon(
          icon,
          size: 16,
          color: isClose ? null : textMutedColor(b),
        ),
      ),
    );
  }
}
