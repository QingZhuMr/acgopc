import 'dart:io';
import 'package:flutter/widgets.dart';

import 'app_config.dart';

/// 主题偏好模式
enum AppThemeMode {
  /// 白天
  light,

  /// 黑夜
  dark,

  /// 跟随系统
  system,
}

/// 主题偏好控制器：管理白天/黑夜/跟随系统，并持久化到用户目录。
class ThemeController extends ChangeNotifier {
  ThemeController() {
    _load();
  }

  /// 当前模式
  AppThemeMode _mode = AppThemeMode.system;
  AppThemeMode get mode => _mode;

  /// 当前实际的明暗（跟随系统时解析系统值）
  Brightness get effectiveBrightness {
    switch (_mode) {
      case AppThemeMode.light:
        return Brightness.light;
      case AppThemeMode.dark:
        return Brightness.dark;
      case AppThemeMode.system:
        return WidgetsBinding.instance.platformDispatcher.platformBrightness;
    }
  }

  /// 设置主题模式并持久化
  void setMode(AppThemeMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    _save();
  }

  /// 配置文件路径：文档目录/acgopc/theme_pref
  String get _prefFile =>
      '${AppConfig.dataDir}${Platform.pathSeparator}theme_pref';

  void _load() {
    try {
      final f = File(_prefFile);
      if (!f.existsSync()) return;
      switch (f.readAsStringSync().trim()) {
        case 'light':
          _mode = AppThemeMode.light;
          break;
        case 'dark':
          _mode = AppThemeMode.dark;
          break;
        default:
          _mode = AppThemeMode.system;
      }
    } catch (_) {
      _mode = AppThemeMode.system;
    }
  }

  void _save() {
    try {
      final value = switch (_mode) {
        AppThemeMode.light => 'light',
        AppThemeMode.dark => 'dark',
        AppThemeMode.system => 'system',
      };
      File(_prefFile).writeAsStringSync(value);
    } catch (_) {
      // 持久化失败不影响运行
    }
  }
}
