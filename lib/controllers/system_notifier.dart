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
  Future<void> init() async {
    if (_ready) return;
    try {
      await localNotifier.setup(appName: AppConfig.appName);
      _ready = true;
    } catch (_) {
      // 系统通知初始化失败不影响主流程（应用内通知仍可用）
      _ready = false;
    }
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
