import 'package:flutter/foundation.dart';

/// 窗口玻璃效果（侧边栏磨砂半透明）管理
///
/// 当前为「实心版本」：Windows / macOS 均不启用任何玻璃效果，
/// 窗口背景为不透明实心色。
///
/// 背景：曾尝试用 Win11 官方 DwmSetWindowAttribute(SYSTEMBACKDROP_TYPE)
/// + WS_EX_NOREDIRECTIONBITMAP 直通合成实现 Acrylic 磨砂（任务栏同款），
/// 但直通合成与 Flutter 引擎渲染冲突，窗口内容整体消失（只剩纯色底），
/// 2026-08-17 最终回退实心。接口保留，便于将来恢复。
abstract final class WindowEffectService {
  /// 是否启用侧边栏透明玻璃效果。
  ///
  /// 实心版本恒为 false。
  static bool get sidebarGlassEnabled => false;

  /// 初始化（no-op，实心版本无需任何原生处理）。
  static Future<void> initialize() async {
    debugPrint('[glass] sidebarGlassEnabled=$sidebarGlassEnabled');
  }

  /// 应用窗口玻璃效果（no-op，实心版本无需任何原生处理）。
  static Future<void> applyEffect() async {
    // no-op
  }
}
