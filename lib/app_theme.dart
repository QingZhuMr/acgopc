import 'package:flutter/material.dart';

/// ACGO PC 主题色板
///
/// 采用「二层背景」层次：
///  - 侧边栏（副区块）背景为略深一层的颜色
///  - 内容页（主区块）背景为标准色
/// 白天标准色：内容页 #FFFFFF，侧边栏 #F5F7FA
/// 黑夜标准色：内容页 #23232A，侧边栏 #1E1E23
///
/// 所有颜色必须从本文件取值，禁止在业务代码中硬编码颜色。

/// 主题蓝
const Color kPrimary = Color(0xFF0A84FF);

/// 语义色
const Color kSuccess = Color(0xFF34C759);
const Color kWarning = Color(0xFFFF9500);
const Color kDanger = Color(0xFFFF3B30);
const Color kInfo = Color(0xFF32ADE6);

/// 白天色板
abstract final class LightColors {
  /// 内容页背景（主区块标准色）
  static const Color bg = Color(0xFFFFFFFF);

  /// 侧边栏背景（副区块标准色）
  static const Color bgSoft = Color(0xFFF5F7FA);

  /// 悬停 / 输入框背景
  static const Color bgHover = Color(0xFFEBEEF3);

  /// 选中浅蓝底
  static const Color primarySoft = Color(0x1A0A84FF); // 10%

  /// 主文字
  static const Color text = Color(0xFF111827);

  /// 正文
  static const Color textBody = Color(0xFF374151);

  /// 次要文字
  static const Color textSecondary = Color(0xFF4B5563);

  /// 弱文字
  static const Color textMuted = Color(0xFF6B7280);

  /// 最弱 / 占位
  static const Color textFaint = Color(0xFF9CA3AF);

  /// 分隔线（导航内容页间本已无边框，此处备用）
  static const Color border = Color(0xFFE5E7EB);
}

/// 黑夜色板
abstract final class DarkColors {
  /// 内容页背景（主区块标准色）
  static const Color bg = Color(0xFF23232A);

  /// 侧边栏背景（副区块标准色）
  static const Color bgSoft = Color(0xFF1E1E23);

  /// 悬停 / 输入框背景
  static const Color bgHover = Color(0xFF2C2C2E);

  /// 选中浅蓝底
  static const Color primarySoft = Color(0x380A84FF); // 22%

  /// 主文字
  static const Color text = Color(0xFFF5F5F7);

  /// 正文
  static const Color textBody = Color(0xFFE5E5EA);

  /// 次要文字
  static const Color textSecondary = Color(0xFFD1D1D6);

  /// 弱文字
  static const Color textMuted = Color(0xFF98989D);

  /// 最弱 / 占位
  static const Color textFaint = Color(0xFF636366);

  /// 分隔线（备用）
  static const Color border = Color(0xFF3A3A3C);
}

/// 根据明暗返回对应颜色
Color bgColor(Brightness b) =>
    b == Brightness.dark ? DarkColors.bg : LightColors.bg;
Color bgSoftColor(Brightness b) =>
    b == Brightness.dark ? DarkColors.bgSoft : LightColors.bgSoft;
Color bgHoverColor(Brightness b) =>
    b == Brightness.dark ? DarkColors.bgHover : LightColors.bgHover;
Color primarySoftColor(Brightness b) =>
    b == Brightness.dark ? DarkColors.primarySoft : LightColors.primarySoft;
Color textColor(Brightness b) =>
    b == Brightness.dark ? DarkColors.text : LightColors.text;
Color textBodyColor(Brightness b) =>
    b == Brightness.dark ? DarkColors.textBody : LightColors.textBody;
Color textSecondaryColor(Brightness b) =>
    b == Brightness.dark ? DarkColors.textSecondary : LightColors.textSecondary;
Color textMutedColor(Brightness b) =>
    b == Brightness.dark ? DarkColors.textMuted : LightColors.textMuted;
Color textFaintColor(Brightness b) =>
    b == Brightness.dark ? DarkColors.textFaint : LightColors.textFaint;

/// 构建明亮主题
ThemeData buildLightTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: LightColors.bg,
    colorScheme: const ColorScheme.light(
      primary: kPrimary,
      surface: LightColors.bg,
    ),
    fontFamily: 'Segoe UI Variable',
    fontFamilyFallback: const [
      'Segoe UI',
      'Microsoft YaHei',
      'Microsoft YaHei UI',
    ],
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: LightColors.bgSoft,
      indicatorColor: LightColors.primarySoft,
      indicatorShape: const StadiumBorder(),
      selectedIconTheme: const IconThemeData(color: kPrimary),
      unselectedIconTheme: IconThemeData(color: LightColors.textMuted),
      selectedLabelTextStyle: TextStyle(
        color: kPrimary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        fontFamily: 'Segoe UI Variable',
        fontFamilyFallback: const [
          'Segoe UI',
          'Microsoft YaHei',
          'Microsoft YaHei UI',
        ],
      ),
      unselectedLabelTextStyle: TextStyle(
        color: LightColors.textMuted,
        fontSize: 13,
        fontFamily: 'Segoe UI Variable',
        fontFamilyFallback: const [
          'Segoe UI',
          'Microsoft YaHei',
          'Microsoft YaHei UI',
        ],
      ),
    ),
  );
}

/// 构建暗色主题
ThemeData buildDarkTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: DarkColors.bg,
    colorScheme: const ColorScheme.dark(
      primary: kPrimary,
      surface: DarkColors.bg,
    ),
    fontFamily: 'Segoe UI Variable',
    fontFamilyFallback: const [
      'Segoe UI',
      'Microsoft YaHei',
      'Microsoft YaHei UI',
    ],
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: DarkColors.bgSoft,
      indicatorColor: DarkColors.primarySoft,
      indicatorShape: const StadiumBorder(),
      selectedIconTheme: const IconThemeData(color: kPrimary),
      unselectedIconTheme: IconThemeData(color: DarkColors.textMuted),
      selectedLabelTextStyle: TextStyle(
        color: kPrimary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        fontFamily: 'Segoe UI Variable',
        fontFamilyFallback: const [
          'Segoe UI',
          'Microsoft YaHei',
          'Microsoft YaHei UI',
        ],
      ),
      unselectedLabelTextStyle: TextStyle(
        color: DarkColors.textMuted,
        fontSize: 13,
        fontFamily: 'Segoe UI Variable',
        fontFamilyFallback: const [
          'Segoe UI',
          'Microsoft YaHei',
          'Microsoft YaHei UI',
        ],
      ),
    ),
  );
}
