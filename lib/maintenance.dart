import 'package:flutter/foundation.dart';

import 'app_theme.dart';
import 'notify.dart';

/// 平台维护状态管理（单例）
///
/// 启动时从 `user/domain` 获取维护状态；维护中**不退出登录**，
/// 仅推送常驻维护公告通知；登录接口在维护时拒绝（503）并展示公告。
class MaintenanceService extends ChangeNotifier {
  MaintenanceService._();

  static final MaintenanceService instance = MaintenanceService._();

  /// 是否处于维护中
  bool _enabled = false;

  /// 维护公告内容
  String _notice = '';

  bool get enabled => _enabled;
  String get notice => _notice;

  /// 是否已初始化（本次启动是否成功获取过维护状态）
  bool _initialized = false;
  bool get initialized => _initialized;

  /// 从 user/domain 响应数据更新维护状态
  void updateFromDomain(Map<String, dynamic>? data) {
    _initialized = true;
    final m = (data?['maintenance'] as Map<String, dynamic>?) ?? {};
    final enabled = (m['enabled'] as bool?) ?? false;
    final notice = m['notice']?.toString() ?? '';
    final changed = enabled != _enabled || notice != _notice;
    _enabled = enabled;
    _notice = notice;
    if (changed) notifyListeners();
  }

  /// 由登录接口返回的维护信息更新（登录被 503 拒绝时）
  void updateFromLogin(Map<String, dynamic>? data) {
    final m = (data?['maintenance'] as Map<String, dynamic>?) ?? {};
    final enabled = (m['enabled'] as bool?) ?? false;
    final notice = m['notice']?.toString() ?? '';
    if (enabled != _enabled || notice != _notice) {
      _enabled = enabled;
      _notice = notice;
      notifyListeners();
    }
  }

  /// 推送维护常驻通知（与更新推送同逻辑：常驻、点 X 可关）
  void pushNotify() {
    if (!_enabled) return;
    NotifyStack.instance.dismiss('maintenance');
    NotifyStack.instance.push(NotifyItem(
      id: 'maintenance',
      title: '平台维护中',
      message: _notice.isEmpty ? '平台正在维护升级，请稍后再试。' : _notice,
      type: NotifyType.update,
      persistent: true,
      backgroundColor: kDanger,
    ));
  }

  /// 移除维护通知
  void dismissNotify() {
    NotifyStack.instance.dismiss('maintenance');
  }

  /// 重置（退出维护时清除状态）
  void reset() {
    _enabled = false;
    _notice = '';
    _initialized = false;
    notifyListeners();
  }
}
