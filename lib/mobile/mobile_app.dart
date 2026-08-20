import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../core/device_service.dart';
import '../services/secure_storage.dart';
import '../services/theme_controller.dart';
import '../widgets/notify.dart';
import 'pages/home_page.dart';
import 'pages/login_page.dart';
import 'theme/mobile_theme.dart';

/// 移动端应用根组件：主题 + 登录分流（Android / iOS / Windows 手机预览模式共用）
///
/// 与桌面根组件（`app/app.dart`）解耦：不依赖桌面页面 / WS / 通知中心，
/// 仅承载移动端 UI 所需的主题与登录态。
class MobileApp extends StatefulWidget {
  const MobileApp({super.key});

  @override
  State<MobileApp> createState() => MobileAppState();
}

class MobileAppState extends State<MobileApp> {
  final ThemeController _theme = ThemeController();

  /// 当前登录用户；null 表示未登录（显示登录页）
  Map<String, dynamic>? _user;

  @override
  void initState() {
    super.initState();
    _theme.addListener(_onThemeChanged);
    // 启动尝试自动登录（仅当偏好启用了自动登录且记住了账号密码）
    _checkAutoLogin();
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  /// 自动登录：用记住的账号密码调登录接口，成功进入主界面
  Future<void> _checkAutoLogin() async {
    final pref = await SecureStorage.instance.readPreferences();
    if (pref == null || !pref.autoLogin || !pref.rememberPwd) return;
    if (pref.account.isEmpty || pref.password.isEmpty) return;
    try {
      final resp = await ApiClient.instance
          .postLogin(
            account: pref.account,
            password: pref.password,
            platform: DeviceService.instance.platform,
            deviceId: DeviceService.instance.getDeviceId(),
          )
          .timeout(const Duration(seconds: 10));
      final json = (jsonDecode(resp.body) as Map<String, dynamic>?) ?? {};
      if (json['code'] == 0 && mounted) {
        final deviceKey = (json['data']?['device_key'] as String?) ?? '';
        if (deviceKey.isNotEmpty) {
          DeviceService.instance.saveDeviceKey(deviceKey);
        }
        final user = (json['data']?['user'] as Map<String, dynamic>?) ?? {};
        final banned = (json['data']?['banned'] as bool?) ?? false;
        if (user.isNotEmpty) user['banned'] = banned;
        _onLoginSuccess(user);
      }
    } catch (_) {
      // 网络异常：留在登录页手动登录
    }
  }

  /// 登录 / 注册成功回调：进入主界面
  void _onLoginSuccess(Map<String, dynamic> user) {
    if (!mounted) return;
    setState(() => _user = user);
  }

  /// 退出登录：清除登录态回到登录页
  Future<void> _logout() async {
    DeviceService.instance.clearDeviceKey();
    if (mounted) setState(() => _user = null);
  }

  @override
  void dispose() {
    _theme.removeListener(_onThemeChanged);
    _theme.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeMode themeMode = switch (_theme.mode) {
      AppThemeMode.light => ThemeMode.light,
      AppThemeMode.dark => ThemeMode.dark,
      AppThemeMode.system => ThemeMode.system,
    };
    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      themeMode: themeMode,
      theme: MobileTheme.light(),
      darkTheme: MobileTheme.dark(),
      // 全局通知栈（共享 NotifyStack，规范 §6.2）
      builder: (context, child) => Stack(
        children: [
          if (child != null) child,
          const NotifyStackView(),
        ],
      ),
      home: _user == null
          ? LoginPage(onSuccess: _onLoginSuccess)
          : HomePage(user: _user!, onLogout: _logout),
    );
  }
}
