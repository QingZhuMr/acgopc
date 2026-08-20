import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../core/app_theme.dart';
import '../core/device_service.dart';
import '../pages/home/home_page.dart';
import '../pages/login_page.dart';
import '../pages/maintenance.dart';
import '../pages/post_detail_page.dart';
import '../pages/splash_page.dart';
import '../services/chat_notifier.dart';
import '../services/chat_service.dart';
import '../services/chat_store.dart';
import '../services/notification_store.dart';
import '../services/notification_center.dart';
import '../services/post_draft_store.dart';
import '../services/secure_storage.dart';
import '../services/theme_controller.dart';
import '../services/updater.dart';
import '../services/ws_service.dart';
import '../widgets/match_dialog.dart';
import '../widgets/notify.dart';

/// 应用根组件：主题 + 登录状态 + 全局导航
class AcgoPcApp extends StatefulWidget {
  const AcgoPcApp({super.key});

  @override
  State<AcgoPcApp> createState() => AcgoPcAppState();
}

class AcgoPcAppState extends State<AcgoPcApp> {
  final ThemeController _theme = ThemeController();

  /// 全局 Navigator key：供无 BuildContext 场景（如通知中心）跳转路由
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// 当前登录用户；null 表示未登录（显示登录页）
  Map<String, dynamic>? _user;

  /// WS 聊天消息入库订阅（登录时注册，退出/踢下线时取消）
  StreamSubscription<Map<String, dynamic>>? _chatMsgSub;

  /// 启动页是否结束（期间判断登录）；false 时显示启动页，避免窗口闪烁
  bool _splashDone = false;

  @override
  void initState() {
    super.initState();
    // 监听主题偏好变化，强制 setState 重建，确保切换生效
    _theme.addListener(_onThemeChanged);
    // 启动加载：期间判断自动/手动登录，结束后跳转对应页面
    _runSplash();
  }

  /// 启动加载流程：等待 splashDuration，期间拉取环境配置 + 尝试自动登录
  ///
  /// 自动登录规则：仅当用户上次勾选了"自动登录"（且因此记住了密码）时才自动进入；
  /// 否则进入登录页（登录页会按"记住密码"自动填充账号密码，需手动登录）。
  Future<void> _runSplash() async {
    // 先从服务端获取运行环境（ws/wss），供 WebSocket 连接使用
    await _loadDomainConfig();
    // 尝试自动登录（若启用了自动登录）
    await _checkAutoLogin();
    // 等待启动页动画展示完毕（确保平滑，避免窗口闪烁）
    await Future<void>.delayed(
        Duration(milliseconds: SplashPage.splashDuration));
    if (mounted) setState(() => _splashDone = true);
  }

  /// 检查登录偏好：若启用了"自动登录"，用记住的账号密码自动登录并进入主界面
  Future<void> _checkAutoLogin() async {
    final pref = await SecureStorage.instance.readPreferences();
    // 未启用自动登录，或未记住账号密码 → 交给登录页手动登录
    if (pref == null || !pref.autoLogin || !pref.rememberPwd) return;
    if (pref.account.isEmpty || pref.password.isEmpty) return;

    // 自动登录：用记住的账号密码调登录接口
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
        // 保存新签发的设备密钥
        final deviceKey = (json['data']?['device_key'] as String?) ?? '';
        if (deviceKey.isNotEmpty) {
          DeviceService.instance.saveDeviceKey(deviceKey);
        }
        final user = (json['data']?['user'] as Map<String, dynamic>?) ?? {};
        // 保存封禁状态到 user，供个人中心显示"正常/封禁"
        final banned = (json['data']?['banned'] as bool?) ?? false;
        if (user.isNotEmpty) user['banned'] = banned;
        // 进入主界面 + 启动 WS 实时推送 + 检查更新（_onLoginSuccess 统一处理）
        _onLoginSuccess(user);
      } else {
        // 自动登录失败（密码变更/被踢等）→ 留在登录页手动登录
        if (mounted) {
          NotifyStack.warning((json['msg'] as String?) ?? '自动登录失败，请重新登录',
              title: '账号提示');
        }
      }
    } catch (_) {
      // 网络异常：留在登录页手动登录
    }
  }

  /// 从服务端获取运行环境配置，设置 WebSocket 连接地址
  ///
  /// 服务端返回 `ws_url`（完整连接地址，开发 ws:// 生产 wss://），客户端只读取、不自行判断。
  /// 拉取失败时保留默认 ws（开发环境），不阻塞启动。
  Future<void> _loadDomainConfig() async {
    try {
      final resp = await ApiClient.instance
          .getDomainConfig()
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return;
      final json = jsonDecode(resp.body) as Map<String, dynamic>?;
      final data = json?['data'] as Map<String, dynamic>?;
      if (data == null) return;

      // 平台维护状态：维护中推送常驻公告（不强制退出登录）
      MaintenanceService.instance.updateFromDomain(data);
      if (MaintenanceService.instance.enabled) {
        MaintenanceService.instance.pushNotify();
      }

      // 时钟校准：用服务端权威时间计算本地偏移，避免设备时钟不准导致"签名已过期"
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
      // 兜底：无 ws_url 时用 ws_scheme + ws_host + ws_port 拼接
      final scheme = data['ws_scheme'] as String?;
      final host = data['ws_host'] as String?;
      final port = data['ws_port'];
      if ((scheme == 'ws' || scheme == 'wss') &&
          host != null &&
          host.isNotEmpty) {
        AppConfig.wsBase = '$scheme://$host:$port';
      }
    } catch (_) {
      // 网络异常：保留默认 ws，由 WS 重连兜底
    }
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  /// 登录成功回调：进入主界面并启动 WebSocket 实时推送
  void _onLoginSuccess(Map<String, dynamic> user) {
    if (mounted) setState(() => _user = user);
    // 切换聊天本地库到该账号专属文件（acgo_chat_<uid>.db）：
    // 不同账号会话/消息互不可见，防止 A 看到 B 的历史会话
    final uid = _resolveCurrentUid(user);
    if (uid > 0) {
      ChatStore.instance.openForUser(uid);
      // 串号兜底：清除本账号库中不属于当前账号的历史脏数据（防会话列表串号残留）
      unawaited(ChatStore.instance.pruneForeignData(uid));
      // 发帖草稿按账号隔离（draft/<uid>/）
      PostDraftStore.instance.openForUser(uid);
      // 通知缓存按账号隔离（acgo_notification_<uid>.db）
      NotificationStore.instance.openForUser(uid);
      // 尽早初始化聊天服务（设置 _userId，WS 消息到达前即正确计算会话归属）
      // 防止实时消息在 init 前到达导致 chatId 计算错误/入库失败
      unawaited(() async {
        await ChatService.instance.init(uid);
        // 首次登录/切换账号后立即同步离线期间的消息：
        // WS 重连才会触发 onReconnected，全新登录永远不会走到那条路径，
        // 导致离线消息不落库 → 会话列表空、无角标、无通知、已读无法上报
        ChatService.instance.syncOffline();
      }());
      // 全局注册 WS 聊天消息入库：实时推送解密落库（串行队列保证顺序）。
      // 之前该监听缺失，实时消息不落库，全靠 sync/pullHistory 补齐，顺序错乱
      _chatMsgSub?.cancel();
      _chatMsgSub = WsService.instance.onChatMessage.listen((m) {
        ChatService.instance.onIncomingMessage(m);
      });
    }
    // 刷新左侧消息角标（该账号的未读总数；HomePage 监听 tick 自行汇总）
    ChatStore.instance.chatUnreadTick.value++;
    // 登录成功后启动 WebSocket 实时推送（接收封禁/踢下线/更新/维护/回复通知等主动推送）
    WsService.instance.start(
      onForceLogout: _handleWsForceLogout,
      onUpdate: _handleWsUpdate,
      onMaintenance: _handleWsMaintenance,
      onReplyNotice: NotificationCenter.instance.handleWsReply,
      onFollowNotice: NotificationCenter.instance.handleWsFollow,
      onMatchNotice: NotificationCenter.instance.handleWsMatch,
      // 断线重连成功后：补发聊天失败消息
      onReconnected: () => ChatService.instance.onReconnected(),
    );
    // 启动通知中心：初始化系统通知 + 拉取未读数 + 定时轮询兜底
    NotificationCenter.instance.start(
      onOpenPost: _openPostFromNotice,
      onOpenUserProfile: _openUserProfileFromNotice,
      onShowMatchDialog: _showMatchDialogGlobal,
    );
    // 启动聊天离线消息通知：点击通知跳转对应会话
    ChatNotifier.instance.start(
      onOpenChat: (peerId) {
        if (HomePageState.current?.mounted == true) {
          HomePageState.current!.openChatWithPeer(peerId);
        }
      },
    );
    // 登录成功后异步检查更新（不阻塞 UI）
    Updater.instance.showUpdateIfAvailable();
  }

  /// 从 user map 解析当前用户 id（兼容 id/user_id/uid）
  static int _resolveCurrentUid(Map<String, dynamic> user) {
    for (final key in const ['id', 'user_id', 'uid']) {
      final raw = user[key];
      if (raw is num) return raw.toInt();
      if (raw is String) {
        final v = int.tryParse(raw);
        if (v != null) return v;
      }
    }
    return 0;
  }

  /// 从通知/应用内通知跳转到帖子详情
  void _openPostFromNotice(int postId, String postContent) {
    // 双端统一：在内容区打开帖子（保留左侧导航栏，不遮盖）
    if (HomePageState.current?.mounted == true) {
      HomePageState.current!.openPostInContent(postId, postContent, null);
      return;
    }
    final nav = _navigatorKey.currentState;
    if (nav == null) return;
    final uid = _user == null ? 0 : _resolveCurrentUid(_user!);
    nav.push(
      MaterialPageRoute(
        builder: (_) => PostDetailPage(
          postBrief: {'id': postId, 'content': postContent},
          postId: postId,
          currentUserId: uid,
          currentUserMap: _user,
        ),
      ),
    );
  }

  /// 从通知/应用内通知跳转到他人主页（type=3 被关注通知）
  void _openUserProfileFromNotice(int uid, String nickname, String avatar) {
    if (uid <= 0) return;
    if (HomePageState.current?.mounted == true) {
      HomePageState.current!.openUserProfile(uid, nickname, avatar);
      return;
    }
  }

  /// 配对成功全局弹窗
  ///
  /// 显示对方头像/昵称/填写的资料，弹窗无法手动关闭，
  /// 仅点击「去聊天」按钮关闭并跳转到与对方的对话框（通知流程结束）。
  Future<bool> _showMatchDialogGlobal(MatchInfo info) async {
    final hp = HomePageState.current;
    if (hp == null || !hp.mounted) return false;
    return showMatchDialog(
      hp.context,
      info,
      onOpenChat: () {
        if (HomePageState.current?.mounted == true) {
          HomePageState.current!.openChatWithPeer(info.uid);
        }
      },
    );
  }

  /// WebSocket 实时推送的强制退出处理（带原因提示）
  void _handleWsForceLogout(String reason) {
    if (!mounted) return;
    // 展示退出原因提示
    NotifyStack.warning(reason, title: '账号提示');
    WsService.instance.stop();
    NotificationCenter.instance.stop();
    ChatNotifier.instance.stop();
    _chatMsgSub?.cancel();
    _chatMsgSub = null;
    // 重置聊天服务账号上下文（防止残留 sync/队列任务把上个账号消息写入新库）
    ChatService.instance.logout();
    // 关闭聊天库连接（下次登录按新账号重新打开）
    ChatStore.instance.closeForUser();
    // 发帖草稿目录重置（下次登录按新账号切回）
    PostDraftStore.instance.openForUser(0);
    // 关闭通知缓存库连接（下次登录按新账号重新打开）
    NotificationStore.instance.closeForUser();
    // 按需清除：仅清登录态（device_key），保留记住的密码与设备标识
    DeviceService.instance.clearDeviceKey();
    setState(() => _user = null);
  }

  /// WebSocket 实时推送的新版本更新处理
  void _handleWsUpdate(Map<String, dynamic> update) {
    if (!mounted) return;
    Updater.instance.showUpdateFromPush(update);
  }

  /// WebSocket 实时推送的维护状态处理（后台开启/关闭维护时实时提醒）
  void _handleWsMaintenance(Map<String, dynamic> msg) {
    if (!mounted) return;
    final enabled = msg['enabled'] == true;
    final notice = msg['notice']?.toString() ?? '';
    if (enabled) {
      // 维护开启：更新状态 + 推送常驻公告
      MaintenanceService.instance.updateFromDomain({
        'maintenance': {'enabled': true, 'notice': notice},
      });
      MaintenanceService.instance.pushNotify();
    } else {
      // 维护关闭：移除公告
      MaintenanceService.instance.reset();
      MaintenanceService.instance.dismissNotify();
    }
  }

  /// 退出登录：停止实时推送 + 按需清除登录态，回到登录页
  ///
  /// **按需清除**（见 docs/安全规范.md）：
  ///  - 清除：登录态 device_key、内存中的会话（_user）
  ///  - 保留：记住的密码（config 目录）、设备标识 device_id、忽略的更新版本
  Future<void> _logout() async {
    WsService.instance.stop();
    NotificationCenter.instance.stop();
    ChatNotifier.instance.stop();
    _chatMsgSub?.cancel();
    _chatMsgSub = null;
    // 重置聊天服务账号上下文（防止残留 sync/队列任务把上个账号消息写入新库）
    ChatService.instance.logout();
    // 关闭聊天库连接（下次登录按新账号重新打开）
    ChatStore.instance.closeForUser();
    // 发帖草稿目录重置（下次登录按新账号切回）
    PostDraftStore.instance.openForUser(0);
    // 关闭通知缓存库连接（下次登录按新账号重新打开）
    NotificationStore.instance.closeForUser();
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
    // 根据模式与系统亮度决定实际 themeMode
    final ThemeMode themeMode = switch (_theme.mode) {
      AppThemeMode.light => ThemeMode.light,
      AppThemeMode.dark => ThemeMode.dark,
      AppThemeMode.system => ThemeMode.system,
    };
    return MaterialApp(
      title: AppConfig.appName,
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      // 本地化：右键菜单等 Material 组件文案跟随系统语言（简体中文为主，回退英文）
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
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      // 全局通知栈：覆盖在所有路由之上（主页、发布页、登录页等都能看到通知）。
      // 用 Stack 对齐到底部中央，而非 Positioned.fill 全屏层：通知只占底部
      // 卡片区域，其余区域透传，避免拦截底层页面（如发布页输入框）的交互。
      builder: (context, child) {
        return Stack(
          alignment: Alignment.bottomCenter,
          children: [
            if (child != null) child,
            const NotifyStackView(),
          ],
        );
      },
      // 启动页结束后再根据登录状态跳转（避免窗口打开时闪烁/位置移动）
      home: !_splashDone
          ? const SplashPage()
          : _user == null
              ? LoginPage(onSuccess: _onLoginSuccess)
              : HomePage(
                  theme: _theme,
                  user: _user!,
                  onLogout: _logout,
                ),
    );
  }
}
