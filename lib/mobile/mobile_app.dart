import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../core/device_service.dart';
import '../services/chat_service.dart';
import '../services/chat_store.dart';
import '../services/notification_store.dart';
import '../services/ws_service.dart';
import '../services/secure_storage.dart';
import '../services/theme_controller.dart';
import 'pages/home_page.dart';
import 'pages/login_page.dart';
import 'theme/mobile_theme.dart';

/// 移动端应用根组件：主题 + 登录分流（Android / iOS / Windows 手机预览模式共用）
///
/// 与桌面根组件（`app/app.dart`）解耦：复用共享的 WS / 聊天 / 通知服务，
/// 仅承载移动端 UI 所需的主题与登录态。
class MobileApp extends StatefulWidget {
  const MobileApp({super.key});

  @override
  State<MobileApp> createState() => MobileAppState();
}

class MobileAppState extends State<MobileApp> {
  final ThemeController _theme = ThemeController();

  /// 全局登录提示（踢下线等）的 ScaffoldMessenger 入口
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  /// 当前登录用户；null 表示未登录（显示登录页）
  Map<String, dynamic>? _user;

  /// WS 实时聊天消息入库订阅（登录期间常驻，保证消息页/聊天页实时刷新）
  StreamSubscription<Map<String, dynamic>>? _chatMsgSub;

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

  /// 登录 / 注册成功回调：进入主界面，并启动 WebSocket 实时链路
  ///
  /// WS 承载：在线状态上报（好友列表 online 字段）、实时消息推送、
  /// 消息已读/撤回/清屏、踢下线等，与 PC 端行为对齐。
  void _onLoginSuccess(Map<String, dynamic> user) {
    if (!mounted) return;
    // 通知缓存按账号隔离（acgo_notification_<uid>.db）
    final uid = (user['id'] as num?)?.toInt() ?? 0;
    if (uid > 0) {
      unawaited(NotificationStore.instance.openForUser(uid));
      // 尽早初始化聊天服务（设置 _userId，确保发送消息时 chatId 计算正确）
      unawaited(() async {
        await ChatService.instance.init(uid);
        // 首次登录/换账号后立即同步离线期间漏收的消息
        ChatService.instance.syncOffline();
      }());
      // 全局订阅 WS 实时聊天消息 → 解密入库（消息页 tick / 会话列表实时刷新）
      _chatMsgSub?.cancel();
      _chatMsgSub = WsService.instance.onChatMessage.listen((m) {
        ChatService.instance.onIncomingMessage(m);
      });
    }
    setState(() => _user = user);
    // 先拉取 ws_url 再启动 WS（保证连接到客户端可达地址）
    unawaited(_startRealtime(uid));
  }

  /// 拉取 user/domain 配置（ws_url 写入 AppConfig.wsBase）后启动 WebSocket
  Future<void> _startRealtime(int uid) async {
    await _loadDomainConfig();
    if (uid <= 0 || !mounted) return;
    WsService.instance.start(
      onForceLogout: _handleWsForceLogout,
      onReconnected: () => ChatService.instance.onReconnected(),
    );
  }

  /// 拉取域名配置：ws_url / 时钟校准，失败保留默认值由 WS 重连兜底
  Future<void> _loadDomainConfig() async {
    try {
      final resp = await ApiClient.instance
          .getDomainConfig()
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return;
      final data = (jsonDecode(resp.body) as Map<String, dynamic>?)?
              ['data'] as Map<String, dynamic>?;
      if (data == null) return;
      final serverTime = data['server_time'];
      if (serverTime is int) {
        AppConfig.clockOffset =
            serverTime - (DateTime.now().millisecondsSinceEpoch ~/ 1000);
      }
      final url = data['ws_url'] as String?;
      if (url != null && url.isNotEmpty) {
        AppConfig.wsBase = url;
        return;
      }
      final scheme = data['ws_scheme'] as String?;
      final host = data['ws_host'] as String?;
      final port = data['ws_port'];
      if ((scheme == 'ws' || scheme == 'wss') &&
          host != null &&
          host.isNotEmpty) {
        AppConfig.wsBase = '$scheme://$host:$port';
      }
    } catch (_) {
      // 拉取失败：保留默认地址，WS 自身重连兜底
    }
  }

  /// 被踢下线：提示原因并清理登录态回到登录页
  void _handleWsForceLogout(String reason) {
    if (!mounted) return;
    _scaffoldMessengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(reason)));
    _stopRealtime();
    DeviceService.instance.clearDeviceKey();
    if (mounted) setState(() => _user = null);
  }

  /// 停止 WS 实时链路：取消消息订阅、断开连接、重置聊天/通知账号上下文
  void _stopRealtime() {
    _chatMsgSub?.cancel();
    _chatMsgSub = null;
    WsService.instance.stop();
    ChatService.instance.logout();
    ChatStore.instance.closeForUser();
  }

  /// 退出登录：清除登录态回到登录页
  Future<void> _logout() async {
    _stopRealtime();
    // 关闭通知缓存库连接（下次登录按新账号重新打开）
    await NotificationStore.instance.closeForUser();
    DeviceService.instance.clearDeviceKey();
    if (mounted) setState(() => _user = null);
  }

  @override
  void dispose() {
    _chatMsgSub?.cancel();
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
      scaffoldMessengerKey: _scaffoldMessengerKey,
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
      home: _user == null
          ? LoginPage(onSuccess: _onLoginSuccess)
          : HomePage(user: _user!, onLogout: _logout),
    );
  }
}
