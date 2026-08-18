import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:local_notifier/local_notifier.dart';

import '../core/app_config.dart';

/// Windows 系统通知封装
///
/// 基于 local_notifier（底层走 Windows 原生 Toast）。
/// 在回复通知到达时弹出一条系统通知，与内置 NotifyStack 应用内通知互补：
///   - 应用内通知（NotifyStack）：客户端前台常驻时可见
///   - 系统通知（Toast）：即使窗口被遮挡/最小化/在托盘也能看到
///
/// Windows 需在应用启动时 `setup`（会校验开始菜单快捷方式以绑定 AppUserModelID），
/// 否则原生侧无法弹 Toast。初始化失败不影响主流程。
class SystemNotifier {
  SystemNotifier._();

  static final SystemNotifier instance = SystemNotifier._();

  bool _ready = false;

  /// 初始化系统通知（应用登录成功后调用一次）
  ///
  /// 修复 Win10/11 Toast 图标为"空白文档"：
  /// local_notifier 内部 WinToast 用 appName 创建开始菜单快捷方式并绑定 AUMI，
  /// 中文 appName（如"耶熊"）在 Windows 创建快捷方式会失败 → 无 AUMI 关联 → 无图标。
  /// 这里改用**英文 AUMI（Yeahbear）**，先自建带图标的开始菜单快捷方式，
  /// 再让 local_notifier 校验通过（快捷方式名、AUMI、exe 图标一致）。
  Future<void> init() async {
    if (_ready) return;
    try {
      // 自建开始菜单快捷方式（英文名 + AUMI + 显式图标），供 WinToast 校验使用
      await _ensureStartMenuShortcut();
      await localNotifier.setup(
        appName: AppConfig.appNameEn, // 英文名：WinToast 创建/校验快捷方式更可靠
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
      _ready = true;
    } catch (_) {
      // 系统通知初始化失败不影响主流程（应用内通知仍可用）
      _ready = false;
    }
  }

  /// 创建/修复开始菜单快捷方式（Windows）：
  /// 路径 `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Yeahbear.lnk`，
  /// 指向当前 exe，AppUserModelID=Yeahbear（WinToast 用它绑定），
  /// IconLocation=exe（Toast 图标从 exe 资源读取）。
  Future<void> _ensureStartMenuShortcut() async {
    if (!Platform.isWindows) return;
    try {
      final exe = Platform.resolvedExecutable;
      final workDir = exe.substring(0, exe.lastIndexOf(Platform.pathSeparator));
      final ps = '''
\$lnkPath = Join-Path \$env:APPDATA 'Microsoft\\Windows\\Start Menu\\Programs\\${AppConfig.appNameEn}.lnk'
\$ws = New-Object -ComObject WScript.Shell
\$lnk = \$ws.CreateShortcut(\$lnkPath)
\$lnk.TargetPath = '$exe'
\$lnk.WorkingDirectory = '$workDir'
\$lnk.IconLocation = '$exe,0'
\$lnk.Save()
''';
      await Process.run('powershell', ['-NoProfile', '-Command', ps]);
      // 失败不阻塞（local_notifier 自己会再尝试）
    } catch (_) {}
  }

  /// 弹出一条系统通知
  ///
  /// [title] 标题（第一行，如"xxx 回复了你"）
  /// [subtitle] 副标题（可选）
  /// [body] 正文（第二行，动态正文摘要）
  /// [onClick] 点击系统通知时的回调（跳转帖子）
  Future<void> show({
    required String title,
    String? subtitle,
    String? body,
    VoidCallback? onClick,
  }) async {
    if (!_ready) return;
    try {
      final notification = LocalNotification(
        title: title,
        subtitle: subtitle,
        body: body,
      );
      notification.onClick = onClick;
      await notification.show();
    } catch (_) {
      // 系统通知失败静默（不阻塞业务）
    }
  }
}
