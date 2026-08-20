import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

/// 移动端主题（Android / iOS 统一）
///
/// 与桌面主题（`app_theme.dart`）的区别（详见 `docs/移动端UI规范.md` §1.1 / §6.4）：
///  - **字体用系统默认**（不设 `fontFamily`，由 iOS 苹方 / Android 系统字体渲染），
///    桌面硬编码 Segoe UI 不适用于移动端；
///  - 按钮 **胶囊化**（`kRadiusFull`）+ 高 44~48dp 大触摸目标；
///  - 输入框二级玻璃：半透明底 + 细描边（`kRadiusMd`）；
///  - 字号阶梯：页面大标题 20 / 卡片标题与正文 16 / 正文 15 / 次要 13 / 最小 12。
/// 颜色一律从 `app_theme.dart` 取值，禁止业务代码硬编码。
class MobileTheme {
  const MobileTheme._();

  /// 表单（输入框 / 按钮等）最大宽度，居中限制以适配平板（强约束）。
  ///
  /// 移动端表单列统一套 `MobileFormPane`（居中 + `maxWidth: formMaxWidth`），
  /// 避免 iPad / 平板横屏下输入框与按钮被 `stretch` 拉成全宽过度拉伸；
  /// `GlassButton` 内部同样以该值兜底（见 `mobile/widgets/glass_button.dart`）。
  static const double formMaxWidth = 480;

  /// 移动端页面主背景（iOS Liquid Glass 风格）：
  /// 白天纯白 / 夜间**纯黑**（与桌面端夜间 `#23232A` 区分，2026-08-20）。
  ///
  /// 移动端所有页面（登录 / 注册 / 消息 / 广场 / 探索 / 我的 / 系统通知页）
  /// 统一使用该纯色背景，禁止在移动端直接用 `bgColor(b)`（那是桌面主背景色）。
  static Color pageBackground(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF000000) : Colors.white;

  /// 【已弃用】页面背景渐变（浅色白→极浅蓝灰 / 深色深灰蓝）。
  ///
  /// 2026-08-20 起移动端页面（登录 / 注册 / 消息 / 广场 / 探索 / 我的）
  /// 统一改用纯色主背景 `pageBackground(b)`（夜间纯黑），不再使用渐变。
  /// 本方法保留仅供历史参考，新页面一律用 `pageBackground(b)` 纯色。
  static LinearGradient background(Brightness b) {
    if (b == Brightness.dark) {
      return const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF23232A), Color(0xFF2C2C3A)],
      );
    }
    return const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFFFFFFFF), Color(0xFFF1F5FB)],
    );
  }

  /// 一级玻璃浮层：高斯模糊底（自绘兜底，见 UI规范 11.2）
  static BoxDecoration glassLayer(Brightness b) {
    return BoxDecoration(
      color: (b == Brightness.dark ? DarkColors.bg : Colors.white)
          .withValues(alpha: b == Brightness.dark ? 0.72 : 0.68),
      borderRadius: kRadiusCardAll,
      border: Border.all(
        color: (b == Brightness.dark ? Colors.white : Colors.black)
            .withValues(alpha: 0.06),
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black
              .withValues(alpha: b == Brightness.dark ? 0.35 : 0.08),
          blurRadius: 24,
          offset: const Offset(0, 8),
        ),
      ],
    );
  }

  /// 构建明亮主题
  static ThemeData light() => _build(Brightness.light);

  /// 构建暗色主题
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness b) {
    final bg = pageBackground(b);
    final text = textColor(b);
    final textBody = textBodyColor(b);
    final textMuted = textMutedColor(b);
    final textFaint = textFaintColor(b);
    final inputFill =
        bgHoverColor(b).withValues(alpha: b == Brightness.dark ? 0.5 : 0.6);
    final borderColor = (b == Brightness.dark ? Colors.white : Colors.black)
        .withValues(alpha: 0.08);

    final base = b == Brightness.dark
        ? ThemeData.dark(useMaterial3: true)
        : ThemeData.light(useMaterial3: true);

    return base.copyWith(
      brightness: b,
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme.fromSeed(
        seedColor: kPrimary,
        brightness: b,
        surface: bg,
      ),
      // 系统默认字体（不设 fontFamily）
      // 文本样式（字号阶梯）
      textTheme: base.textTheme.copyWith(
        headlineSmall:
            TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: text),
        titleLarge:
            TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: text),
        titleMedium:
            TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: text),
        bodyLarge: TextStyle(fontSize: 16, color: textBody),
        bodyMedium: TextStyle(fontSize: 15, color: textBody),
        bodySmall: TextStyle(fontSize: 13, color: textMuted),
        labelLarge: TextStyle(
            fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
        labelMedium: TextStyle(fontSize: 13, color: textMuted),
        labelSmall: TextStyle(fontSize: 12, color: textFaint),
      ),
      // iOS 26 强约束：按钮统一走 GlassButton（CupertinoButton 观感），
      // 不再提供 Material FilledButton / OutlinedButton 主题，防止误用。
      // 输入框：二级玻璃（半透明底 + 细描边），大圆角与聊天页输入框一致（2026-08-21）
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: inputFill,
        hintStyle: TextStyle(fontSize: 15, color: textFaint),
        labelStyle: TextStyle(fontSize: 15, color: textMuted),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide(color: borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide(color: borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide:
              BorderSide(color: kPrimary.withValues(alpha: 0.7), width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: const BorderSide(color: kDanger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: const BorderSide(color: kDanger, width: 1.4),
        ),
      ),
      // 页面转场：真机右滑进入（iOS 观感）
      //
      // 桌面平台（仅手机预览模式 `--dart-define=MOBILE_PREVIEW=true` 会用到）
      // 不用 Cupertino 滑动转场：Windows 下鼠标 hover 在滑动动画期间会命中
      // 尚未完成布局的新路由节点，触发 mouse_tracker 断言
      // （"Cannot hit test a render box that has never been laid out"），
      // 桌面版走 Material 默认转场无此问题；真机无鼠标 hover，Cupertino 安全。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: ZoomPageTransitionsBuilder(),
          TargetPlatform.macOS: ZoomPageTransitionsBuilder(),
          TargetPlatform.linux: ZoomPageTransitionsBuilder(),
        },
      ),
      // 复选 / 开关着色（iOS 观感）
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? kPrimary : null,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(Colors.white),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? kPrimary : null,
        ),
      ),
    );
  }
}
