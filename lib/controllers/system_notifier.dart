import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:local_notifier/local_notifier.dart';

import '../core/app_config.dart';

/// 系统通知封装
///
/// 双端实现：
///   - **Windows**：基于 local_notifier（底层走 Windows 原生 Toast），
///     需在启动时 `setup`（校验开始菜单快捷方式绑定 AppUserModelID），
///     否则原生侧无法弹 Toast。
///   - **macOS**：基于 **UNUserNotificationCenter**（现代 API，本地原生插件
///     `SystemNotificationPlugin.swift`，MethodChannel `com.acgo/system_notification`），
///     替代 local_notifier 使用的废弃 NSUserNotificationCenter。
///   - 其他平台：暂不支持（返回 false，应用内通知仍可用）。
///
/// 系统通知与应用内 NotifyStack 互补：即使窗口被遮挡/最小化/在托盘也能看到。
/// 初始化失败不影响主流程。
class SystemNotifier {
  SystemNotifier._();

  static final SystemNotifier instance = SystemNotifier._();

  bool _ready = false;

  static const MethodChannel _macChannel =
      MethodChannel('com.acgo/system_notification');

  /// macOS 通知点击事件流（identifier → 点击回调）
  final _macClickController = StreamController<String>.broadcast();
  bool _macHandlerSet = false;

  /// 初始化系统通知（应用登录成功后调用一次）
  ///
  /// - macOS：设置通知点击 handler（首次 notify 时原生自动请求授权）
  /// - Windows：local_notifier 用 appName（中文"耶熊"）创建开始菜单快捷方式
  ///   绑定 AUMI；先确保快捷方式存在且图标显式指向 exe（WScript.Shell），
  ///   避免旧缓存"空白文档"图标干扰。
  Future<void> init() async {
    if (_ready) return;
    try {
      if (Platform.isMacOS) {
        _setupMacClickHandler();
        _ready = true; // macOS 无需预初始化，首次 notify 请求授权
        return;
      }
      if (Platform.isWindows) {
        await _ensureStartMenuShortcut();
        await localNotifier.setup(
          appName: AppConfig.appName, // 保持中文应用名"耶熊"
          shortcutPolicy: ShortcutPolicy.requireCreate,
        );
        _ready = true;
      }
    } catch (_) {
      // 系统通知初始化失败不影响主流程（应用内通知仍可用）
      _ready = false;
    }
  }

  /// 设置 macOS 通知点击 MethodChannel handler（全局一次）
  void _setupMacClickHandler() {
    if (_macHandlerSet) return;
    _macHandlerSet = true;
    _macChannel.setMethodCallHandler((call) async {
      if (call.method == 'onNotificationClick') {
        final id = (call.arguments as Map?)?['identifier']?.toString() ?? '';
        if (id.isNotEmpty) {
          _macClickController.add(id);
        }
      }
    });
  }

  /// 确保开始菜单快捷方式存在且图标正确（Windows）：
  /// 路径 `%APPDATA%\Microsoft\Windows\Start Menu\Programs\耶熊.lnk`，
  /// TargetPath/WorkingDirectory 指向当前 exe，IconLocation=exe（Toast 图标来源）。
  Future<void> _ensureStartMenuShortcut() async {
    if (!Platform.isWindows) return;
    try {
      final exe = Platform.resolvedExecutable;
      final workDir = exe.substring(0, exe.lastIndexOf(Platform.pathSeparator));
      final ps = '''
\$lnkPath = Join-Path \$env:APPDATA 'Microsoft\\Windows\\Start Menu\\Programs\\${AppConfig.appName}.lnk'
\$ws = New-Object -ComObject WScript.Shell
\$lnk = \$ws.CreateShortcut(\$lnkPath)
\$lnk.TargetPath = '$exe'
\$lnk.WorkingDirectory = '$workDir'
\$lnk.IconLocation = '$exe,0'
\$lnk.Save()
''';
      await Process.run('powershell', ['-NoProfile', '-Command', ps]);
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
      if (Platform.isMacOS) {
        await _showMac(title, body ?? subtitle, onClick);
        return;
      }
      if (Platform.isWindows) {
        final notification = LocalNotification(
          title: title,
          subtitle: subtitle,
          body: body,
        );
        notification.onClick = onClick;
        await notification.show();
      }
    } catch (_) {
      // 系统通知失败静默（不阻塞业务）
    }
  }

  /// macOS：通过 UNUserNotificationCenter 发送通知（原生插件）
  Future<void> _showMac(String title, String? subtitle, VoidCallback? onClick) async {
    final identifier = 'acgo_notify_${DateTime.now().millisecondsSinceEpoch}';
    // 注册一次性点击回调（按 identifier 匹配，点击后即取消）
    late final StreamSubscription<String> sub;
    sub = _macClickController.stream.listen((id) {
      if (id == identifier && onClick != null) {
        onClick();
      }
      // 匹配到本次通知即取消订阅，避免累积
      if (id == identifier) sub.cancel();
    });
    await _macChannel.invokeMethod<bool>('notify', {
      'title': title,
      'subtitle': subtitle ?? '',
      'identifier': identifier,
    });
  }
}
