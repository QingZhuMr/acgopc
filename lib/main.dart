// ACGO PC 桌面客户端 —— 简单 Demo
//
// 运行方式（需已安装 Flutter SDK + Visual Studio C++ 桌面开发）：
//   1. 进入本项目目录 d:/webroot/acgopc
//   2. flutter create .     （补齐 Windows 平台编译文件，已执行）
//   3. flutter run -d windows
//
// 本 Demo 演示了：
//   - Windows 桌面窗口 + 左侧导航 + 右侧内容区的基本布局
//   - 无边框的左右分区：导航栏(副区块 #F5F7FA/#1E1E23) + 内容页(标准色 #FFF/#23232A)
//   - 白天 / 黑夜 / 跟随系统 三套主题
//   - 三个示例页面（首页 / 用户 / 设置）
//
// 字体：Segoe UI Variable + 中文回退微软雅黑，颜色统一取自 app_theme.dart。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crop_image_pro/crop_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:window_manager/window_manager.dart';

import 'core/api_client.dart';
import 'core/app_config.dart';
import 'services/app_service.dart';
import 'core/app_theme.dart';
import 'core/device_service.dart';
import 'pages/login_page.dart';
import 'pages/maintenance.dart';
import 'services/notification_center.dart';
import 'pages/notification_page.dart';
import 'widgets/notify.dart';
import 'widgets/pick_images.dart';
import 'pages/post_detail_page.dart';
import 'pages/publish_post_page.dart';
import 'services/secure_storage.dart';
import 'pages/splash_page.dart';
import 'services/theme_controller.dart';
import 'services/updater.dart';
import 'utils/net_image.dart';
import 'services/ws_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化窗口管理器
  await windowManager.ensureInitialized();

  // 初始化应用服务（单实例 + 关闭驻留）；失败说明已有实例运行
  // 注意：单实例锁必须最先判定，绝不能阻塞或漏判，避免多开
  if (!await AppService.instance.init()) {
    // 已有实例在运行：必须显式 exit，否则 Flutter 引擎进程不会自动退出
    exit(0);
  }
  // 全程序统一安全最小窗口尺寸（登录窗口与主窗口共用）
  const Size kMinWindowSize = Size(900, 640);
  // 标题栏策略：所有平台都隐藏原生标题栏，由 Flutter 自绘顶栏承担。
  //   - macOS：隐藏原生栏后红黄绿窗口按钮仍显示在左上角，自绘顶栏为其预留安全距离、不绘制窗口按钮
  //   - Windows：隐藏原生栏，自绘顶栏绘制窗口按钮
  final options = WindowOptions(
    size: const Size(1080, 720),
    center: true,
    minimumSize: kMinWindowSize,
    // 窗口标题（任务栏 / 菜单栏展示名 = AppConfig.appName）
    title: AppConfig.appName,
    titleBarStyle: TitleBarStyle.hidden,
  );
  windowManager.waitUntilReadyToShow(options, () async {
    // 先固定窗口尺寸，避免 show 时出现"瞬间放大又回归"的闪烁
    await windowManager.setMinimumSize(kMinWindowSize);
    await windowManager.setSize(const Size(1080, 720));
    await windowManager.center();
    await windowManager.show();
    await windowManager.focus();
  });
  // 立即启动 UI，确保窗口第一时间显示
  runApp(const AcgoPcApp());
}

/// 应用根组件
class AcgoPcApp extends StatefulWidget {
  const AcgoPcApp({super.key});

  @override
  State<AcgoPcApp> createState() => _AcgoPcAppState();
}

class _AcgoPcAppState extends State<AcgoPcApp> {
  final ThemeController _theme = ThemeController();

  /// 全局 Navigator key：供无 BuildContext 场景（如通知中心）跳转路由
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// 当前登录用户；null 表示未登录（显示登录页）
  Map<String, dynamic>? _user;

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
    // 登录成功后启动 WebSocket 实时推送（接收封禁/踢下线/更新/维护/回复通知等主动推送）
    WsService.instance.start(
      onForceLogout: _handleWsForceLogout,
      onUpdate: _handleWsUpdate,
      onMaintenance: _handleWsMaintenance,
      onReplyNotice: NotificationCenter.instance.handleWsReply,
    );
    // 启动通知中心：初始化系统通知 + 拉取未读数 + 定时轮询兜底
    NotificationCenter.instance.start(
      onOpenPost: _openPostFromNotice,
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
    if (_HomePageState.current?.mounted == true) {
      _HomePageState.current!.openPostInContent(postId, postContent, null);
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
        ),
      ),
    );
  }

  /// WebSocket 实时推送的强制退出处理（带原因提示）
  void _handleWsForceLogout(String reason) {
    if (!mounted) return;
    // 展示退出原因提示
    NotifyStack.warning(reason, title: '账号提示');
    WsService.instance.stop();
    NotificationCenter.instance.stop();
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

/// 主导航项数据
class _NavItem {
  final IconData icon; // 导航图标
  final String label; // 导航文字
  final Widget view; // 对应视图
  const _NavItem(this.icon, this.label, this.view);
}

/// 主页面：左侧导航 + 右侧内容
class HomePage extends StatefulWidget {
  final ThemeController theme;

  /// 当前登录用户
  final Map<String, dynamic> user;

  /// 退出登录回调
  final VoidCallback onLogout;

  const HomePage({
    super.key,
    required this.theme,
    required this.user,
    required this.onLogout,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// 当前挂载的实例（macOS 用于 WS 推送在内容区打开帖子，保留左侧导航栏）
  static _HomePageState? current;

  // 当前选中的导航索引（0=广场，1=个人中心）
  int _currentIndex = 0;

  /// macOS 内容区覆盖页（发帖/详情内嵌展示，保留左侧导航栏，无返回按钮）
  /// 非 macOS 恒为 null
  Widget? _macOverlay;

  /// 通知 tab 索引（双端统一为 2）
  int get _notificationIndex => 2;

  /// 设置 tab 索引（双端统一为 3，通知 tab 占第 2 位）
  int get _settingsIndex => 3;

  @override
  void initState() {
    super.initState();
    // 记录当前实例（macOS WS 推送在内容区打开帖子用）
    _HomePageState.current = this;
    // 监听通知中心（未读数变化时刷新铃铛角标）
    NotificationCenter.instance.addListener(_onNotifyChanged);
  }

  @override
  void dispose() {
    if (_HomePageState.current == this) _HomePageState.current = null;
    NotificationCenter.instance.removeListener(_onNotifyChanged);
    super.dispose();
  }

  /// 在内容区打开帖子（WS 推送/简单跳转用，保留左侧导航栏）
  void openPostInContent(int postId, String postContent, int? commentId) {
    if (!mounted) return;
    _showPostFromNoticeOverlay(postId, postContent, commentId);
  }

  /// 在内容区打开帖子（完整帖子数据，保留左侧导航栏）
  void openPostFullInContent(Map<String, dynamic> post, int id) {
    if (!mounted) return;
    _showPostOverlay(post, id);
  }

  void _onNotifyChanged() {
    if (mounted) setState(() {});
  }

  /// 从 user map 解析用户 id（兼容 'id' / 'user_id' 字段）
  static int _resolveUid(Map<String, dynamic> user) {
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

  // 注意：用 getter 而非 late final，确保每次 build 时 `_ProfileView.active`
  // 都能随 `_currentIndex` 实时更新（切到个人中心时刷新收藏列表）。
  List<_NavItem> get _navItems => [
        _NavItem(
          Icons.space_dashboard_rounded,
          '广场',
          _HomeView(
            user: widget.user,
            onOpenPublish: _showPublishOverlay,
            onOpenPost: _showPostOverlay,
          ),
        ),
        _NavItem(
          Icons.person_outline,
          '我的',
          _ProfileView(
            user: widget.user,
            onLogout: widget.onLogout,
            active: _currentIndex == 1,
            onUserChanged: (_) {
              // 个人中心修改资料（昵称/头像）后触发刷新，让左侧头像等同步更新。
              // _ProfileView 会直接更新共享的 user map，这里只需触发 rebuild。
              if (mounted) setState(() {});
            },
          ),
        ),
        // 通知作为侧边栏 tab 内嵌（双端统一：不 push、无返回按钮、不遮盖导航栏）
        _NavItem(
          Icons.notifications_none_rounded,
          '通知',
          NotificationPage(
            currentUserId: _resolveUid(widget.user),
            embedded: true,
            onChanged: () => NotificationCenter.instance.fetchUnreadForce(),
            onOpenPost: _showPostFromNoticeOverlay,
          ),
        ),
        _NavItem(
          Icons.settings_outlined,
          '',
          _SettingsView(
            theme: widget.theme,
            user: widget.user,
            onLogout: widget.onLogout,
          ),
        ),
      ];

  /// macOS 侧边栏宽度（Finder 风格：图标 + 文字），双端统一
  static const double _macRailWidth = 150;

  /// 导航栏实际宽度：双端统一 Finder 风格侧边栏（宽 150），方便统一修改
  double get _effectiveRailWidth => _macRailWidth;

  /// 切换导航 tab（macOS 同时清空内容区覆盖页）
  void _switchTab(int index) {
    setState(() {
      _macOverlay = null;
      _currentIndex = index;
    });
  }

  /// macOS：在内容区显示发帖页覆盖（保留导航栏）
  void _showPublishOverlay() {
    setState(() {
      _macOverlay = PublishPostPage(
        user: widget.user,
        embedded: true,
        onBack: () => setState(() => _macOverlay = null),
        // 发布成功后：在内容区展示新帖子详情（保留左侧导航栏）
        onPublished: (postId, brief) {
          final currentUid = _resolveUid(widget.user);
          setState(() {
            _macOverlay = PostDetailPage(
              postBrief: brief,
              postId: postId,
              currentUserId: currentUid,
              embedded: true,
              onBack: () => setState(() => _macOverlay = null),
            );
          });
        },
      );
    });
  }

  /// 在内容区显示帖子详情覆盖（保留导航栏）
  void _showPostOverlay(Map<String, dynamic> post, int id) {
    final currentUid = _resolveUid(widget.user);
    setState(() {
      _macOverlay = PostDetailPage(
        postBrief: post,
        postId: id,
        currentUserId: currentUid,
        embedded: true,
        onBack: () => setState(() => _macOverlay = null),
      );
    });
  }

  /// 从通知打开帖子，用内容区覆盖（保留左侧导航栏，可定位到评论）
  void _showPostFromNoticeOverlay(int postId, String postContent, int? commentId) {
    final currentUid = _resolveUid(widget.user);
    setState(() {
      _macOverlay = PostDetailPage(
        postBrief: {'id': postId, 'content': postContent},
        postId: postId,
        currentUserId: currentUid,
        embedded: true,
        focusCommentId: (commentId != null && commentId > 0) ? commentId : null,
        onBack: () => setState(() => _macOverlay = null),
      );
    });
  }

  /// macOS：Finder 风格侧边栏（宽栏，图标 + 文字，左对齐）
  Widget _buildMacRail(Brightness b) {
    return Column(
      children: [
        // 顶部留白：让导航项避开顶栏区域，与 Finder 侧边栏间距一致
        const SizedBox(height: 16),
        // 导航项（广场）
        _MacRailItem(
          icon: Icons.space_dashboard_rounded,
          label: '广场',
          selected: _currentIndex == 0,
          brightness: b,
          onTap: () => _switchTab(0),
        ),
        // 导航项（个人中心）
        _MacRailItem(
          icon: Icons.person_outline,
          label: '我的',
          selected: _currentIndex == 1,
          brightness: b,
          onTap: () => _switchTab(1),
        ),
        const Spacer(),
        // 通知（双端统一：作为 tab 内嵌）
        _MacRailItem(
          icon: Icons.notifications_none_rounded,
          label: '通知',
          selected: _currentIndex == _notificationIndex,
          brightness: b,
          badge: NotificationCenter.instance.unread,
          onTap: () => _switchTab(_notificationIndex),
        ),
        // 设置
        _MacRailItem(
          icon: Icons.settings_outlined,
          label: '设置',
          selected: _currentIndex == _settingsIndex,
          brightness: b,
          onTap: () => _switchTab(_settingsIndex),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Scaffold(
      // 内容页背景标准色
      backgroundColor: bgColor(b),
      body: Column(
        children: [
          // ========== 自绘顶栏（macOS：红黄绿安全区 + logo，无窗口按钮；Windows：窗口按钮） ==========
          _TitleBar(
            navWidth: _effectiveRailWidth,
            brightness: b,
          ),
          // ========== 下方主体：左侧导航 + 右侧内容 ==========
          Expanded(
            child: Row(
              children: [
                // 左侧导航栏（副区块背景，无边框，Finder 风格，双端一致）
                Container(
                  width: _effectiveRailWidth,
                  color: bgSoftColor(b),
                  child: _buildMacRail(b),
                ),

                // 右侧内容区（无分割线，无边框）
                Expanded(
                  child: _macOverlay != null
                      // macOS 覆盖页（发帖/详情内嵌，保留导航栏）
                      ? _macOverlay!
                      : IndexedStack(
                          index: _currentIndex,
                          children: [
                            for (final item in _navItems) item.view,
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// macOS Finder 风格侧边栏导航项（图标 + 文字，左对齐）
class _MacRailItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final Brightness brightness;
  final int badge;
  final VoidCallback onTap;

  const _MacRailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.brightness,
    this.badge = 0,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(kRadiusMd),
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        hoverColor: bgHoverColor(brightness),
        child: SizedBox(
          height: 36,
          child: Row(
            children: [
              const SizedBox(width: 10),
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(
                    icon,
                    size: 20,
                    color: selected ? kPrimary : textMutedColor(brightness),
                  ),
                  if (badge > 0)
                    Positioned(
                      right: -8,
                      top: -5,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: kDanger,
                          borderRadius: BorderRadius.circular(kRadiusFull),
                        ),
                        child: Text(
                          badge > 99 ? '99+' : '$badge',
                          style: const TextStyle(
                              fontSize: 9, color: Colors.white),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? textColor(brightness) : textMutedColor(brightness),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 自绘顶栏：左侧用导航栏色(副区块)，右侧用内容栏色(主区块)，右侧带窗口控制按钮。
class _TitleBar extends StatelessWidget {
  final double navWidth;
  final Brightness brightness;

  const _TitleBar({
    required this.navWidth,
    required this.brightness,
  });

  @override
  Widget build(BuildContext context) {
    // macOS：隐藏原生栏后红黄绿按钮悬浮在左上角，导航栏色区域整体扩展 kMacTrafficLightWidth
    // 容纳按钮安全距离，logo 居中于整个导航栏色区（远离按钮），右侧仅拖拽（无窗口按钮）。
    // 顶栏高度 20：让内容区尽可能上移（Windows 保持 60）
    if (Platform.isMacOS) {
      return SizedBox(
        height: 20,
        child: Row(
          children: [
            // 左侧导航栏色区（已含红黄绿安全距离，macOS 不显示 logo）
            Container(
              width: navWidth,
              color: bgSoftColor(brightness),
            ),
            // 右侧：与内容栏同色，可拖拽（无窗口控制按钮）
            Expanded(
              child: Container(
                color: bgColor(brightness),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => windowManager.startDragging(),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return SizedBox(
      height: 60,
      child: Row(
        children: [
          // 左侧：与导航栏同色 + 应用 logo
          Container(
            width: navWidth,
            color: bgSoftColor(brightness),
            child: const Center(
              child: Image(
                image: AssetImage(AppConfig.assetLogo),
                width: 36,
                height: 36,
                fit: BoxFit.contain,
              ),
            ),
          ),
          // 右侧：与内容栏同色，含窗口控制按钮
          Expanded(
            child: Container(
              color: bgColor(brightness),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start, // 按钮靠顶部对齐（右上角）
                children: [
                  // 可拖拽区域（撑满，可拖动窗口）
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (_) => windowManager.startDragging(),
                      child: const SizedBox.expand(),
                    ),
                  ),
                  // 窗口控制按钮（正方形 1:1，靠右上角）
                  _WinButton(
                    icon: Icons.remove,
                    onTap: () => windowManager.minimize(),
                  ),
                  _WinButton(
                    icon: Icons.crop_square_rounded,
                    onTap: () async {
                      if (await windowManager.isMaximized()) {
                        await windowManager.unmaximize();
                      } else {
                        await windowManager.maximize();
                      }
                    },
                  ),
                  _WinButton(
                    icon: Icons.close,
                    isClose: true,
                    onTap: () => windowManager.close(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 窗口控制按钮
///
/// 遵循微软 Windows 行业规范：
/// - 关闭按钮 hover：红色胶囊（`#E81123`，微软标准关闭红），图标变白
/// - 最小化 / 最大化 hover：灰色胶囊（明暗主题自适应）
/// - 胶囊无圆角，且顶到窗口顶栏上边缘与右边缘（由 `_TitleBar` 布局保证对齐）
class _WinButton extends StatefulWidget {
  final IconData icon;
  final bool isClose;
  final VoidCallback onTap;

  const _WinButton({
    required this.icon,
    this.isClose = false,
    required this.onTap,
  });

  @override
  State<_WinButton> createState() => _WinButtonState();
}

class _WinButtonState extends State<_WinButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    // 关闭按钮 hover 用微软标准红；其余用主题灰色胶囊
    final bg = _hovered
        ? (widget.isClose
            ? const Color(0xFFE81123)
            : bgHoverColor(b))
        : Colors.transparent;
    // 图标颜色：关闭按钮 hover 变白；其余始终用弱文字色
    final iconColor = widget.isClose && _hovered
        ? Colors.white
        : textMutedColor(b);
    return SizedBox(
      width: 46,
      height: 46, // 正方形 1:1，靠右上角
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: InkWell(
          onTap: widget.onTap,
          mouseCursor: SystemMouseCursors.click, // 悬停显示手指
          hoverColor: Colors.transparent, // 背景色由 MouseRegion 控制，避免双层叠加
          child: Container(
            color: bg, // 无圆角，填满按钮区域，与窗口边缘对齐
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: 16,
              color: iconColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// 广场视图（帖子列表，小红书风格）
class _HomeView extends StatefulWidget {
  final Map<String, dynamic> user;

  /// macOS 发帖/详情回调（由主窗口处理内容区覆盖）；非 macOS 为 null 则走原 push
  final VoidCallback? onOpenPublish;
  final void Function(Map<String, dynamic> post, int id)? onOpenPost;

  const _HomeView({required this.user, this.onOpenPublish, this.onOpenPost});

  @override
  State<_HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<_HomeView>
    with SingleTickerProviderStateMixin {
  final List<Map<String, dynamic>> _posts = [];
  int _page = 1;
  bool _loading = false; // 整页加载（首次 / 搜索）：显示骨架屏
  bool _refreshing = false; // 刷新按钮：转圈
  bool _loadingMore = false; // 触底加载更多：底部转圈
  bool _allLoaded = false;
  bool _loadFailed = false;
  DateTime? _lastLoadMore;
  String _keyword = '';
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  late final AnimationController _refreshAnim;

  @override
  void initState() {
    super.initState();
    _refreshAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fetchFirstPage();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _refreshAnim.dispose();
    super.dispose();
  }

  /// 加载第一页
  ///
  /// [clear] 为 true 时清空现有列表（搜索场景，显示骨架屏）；
  /// [refreshing] 为 true 时走「刷新按钮」通道（按钮转圈，保留旧列表）。
  Future<void> _fetchFirstPage({bool clear = false, bool refreshing = false}) async {
    if (refreshing && _refreshing) return;
    setState(() {
      if (refreshing) {
        _refreshing = true;
      } else {
        _loading = true;
      }
      _loadFailed = false;
      _page = 1;
      _allLoaded = false;
      if (clear) _posts.clear();
    });
    if (refreshing) {
      _spinRefresh();
    }
    try {
      final resp = await ApiClient.instance
          .getPostList(
            page: 1,
            pageSize: 10,
            keyword: _keyword.isEmpty ? null : _keyword,
          )
          .timeout(const Duration(seconds: 10));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] != 0) {
        throw Exception((json['msg'] as String?) ?? '加载失败');
      }
      final list = (json['data']?['list'] as List<dynamic>?) ?? [];
      final posts = list.whereType<Map<String, dynamic>>().toList();
      if (!mounted) return;
      setState(() {
        _posts
          ..clear()
          ..addAll(posts);
        _page = 1;
        _allLoaded = posts.length < 10;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadFailed = true);
      NotifyStack.warning('加载失败：$e');
    } finally {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
      });
    }
  }

  /// 刷新图标旋转：每圈转完才判断是否继续，保证「只要转了就至少转完整一圈」
  void _spinRefresh() {
    _refreshAnim.forward(from: 0).whenComplete(() {
      if (mounted && _refreshing) {
        _spinRefresh();
      }
    });
  }

  /// 搜索输入：缓冲期内无操作则自动搜索，无需确认按钮
  void _onSearchChanged(String value) {
    setState(() {}); // 实时刷新清除按钮显隐
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 500), () {
      final kw = value.trim();
      if (kw == _keyword) return;
      _keyword = kw;
      _fetchFirstPage(clear: true);
    });
  }

  /// 清空搜索框并恢复浏览
  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchCtrl.clear();
    if (_keyword.isEmpty) return;
    _keyword = '';
    _fetchFirstPage(clear: true);
  }

  /// 加载更多（触底自动触发，带节流避免滚动过程中频繁 setState 导致卡顿）
  Future<void> _loadMore() async {
    if (_loading || _refreshing || _loadingMore || _allLoaded) return;
    final now = DateTime.now();
    if (_lastLoadMore != null &&
        now.difference(_lastLoadMore!) < const Duration(milliseconds: 800)) {
      return;
    }
    _lastLoadMore = now;
    setState(() => _loadingMore = true);
    try {
      final resp = await ApiClient.instance
          .getPostList(
            page: _page + 1,
            pageSize: 10,
            excludeIds: _posts.map((p) => (p['id'] as num?)?.toInt() ?? 0).toList(),
            keyword: _keyword.isEmpty ? null : _keyword,
          )
          .timeout(const Duration(seconds: 10));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] != 0) {
        throw Exception((json['msg'] as String?) ?? '加载失败');
      }
      final list = (json['data']?['list'] as List<dynamic>?) ?? [];
      final posts = list.whereType<Map<String, dynamic>>().toList();
      if (!mounted) return;
      setState(() {
        _posts.addAll(posts);
        _page += 1;
        _allLoaded = posts.length < 10;
      });
    } catch (e) {
      if (!mounted) return;
      NotifyStack.warning('加载更多失败：$e');
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Column(
      children: [
        _buildTopBar(b),
        Expanded(child: _buildBody(b)),
      ],
    );
  }

  /// 顶部栏「发动态」按钮（高度与搜索框统一 40，与发布页按钮同规格）
  Widget _buildPublishFab(Brightness b) {
    return SizedBox(
      height: 38,
      child: FilledButton(
        onPressed: _openPublishPage,
        style: FilledButton.styleFrom(
          backgroundColor: kPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 22),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kRadiusCard)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_rounded, size: 16, color: Colors.white),
            SizedBox(width: 6),
            Text(
              '发动态',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 打开发动态页面
  Future<void> _openPublishPage() async {
    // 双端统一：发帖页作为内容区内嵌覆盖展示（保留左侧导航栏）
    if (widget.onOpenPublish != null) {
      widget.onOpenPublish!();
      return;
    }
    await Navigator.of(context).push<Object?>(
      MaterialPageRoute(
        builder: (_) => PublishPostPage(
          user: widget.user,
        ),
      ),
    );
    // 返回时不触发重新加载，保持广场当前列表状态（需要时手动下拉刷新）
  }

  /// 从用户 map 解析用户 id（兼容 'id' / 'user_id' 字段，值可能是 int/num/String）
  static int _resolveUid(Map<String, dynamic> user) {
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

  /// 打开帖子详情页（广场动态内容页）
  Future<void> _openPostDetail(Map<String, dynamic> post) async {
    final id = (post['id'] as num?)?.toInt() ?? 0;
    if (id <= 0) return;
    // 双端统一：详情页作为内容区内嵌覆盖展示（保留左侧导航栏）
    if (widget.onOpenPost != null) {
      widget.onOpenPost!(post, id);
      return;
    }
    // 当前登录用户 id：优先 'id'，兼容 'user_id'，取不到给 0（无法判断则默认非本人）
    final currentUid = _resolveUid(widget.user);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PostDetailPage(
          postBrief: post,
          postId: id,
          currentUserId: currentUid,
        ),
      ),
    );
    // 返回时不触发重新加载，保持广场当前列表状态
  }

  /// 顶部栏：搜索框 + 发动态按钮 + 刷新按钮
  Widget _buildTopBar(Brightness b) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 40,
              decoration: BoxDecoration(
                color: bgHoverColor(b),
                borderRadius: BorderRadius.circular(kRadiusCard),
              ),
              child: TextField(
                controller: _searchCtrl,
                onChanged: _onSearchChanged,
                textInputAction: TextInputAction.search,
                textAlignVertical: TextAlignVertical.center,
                style: TextStyle(fontSize: 14, color: textColor(b)),
                cursorColor: kPrimary,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                  prefixIcon:
                      Icon(Icons.search, size: 20, color: textFaintColor(b)),
                  prefixIconConstraints:
                      const BoxConstraints(minWidth: 40, minHeight: 40),
                  suffixIconConstraints:
                      const BoxConstraints(minWidth: 40, minHeight: 40),
                  suffixIcon: _loading
                      ? Center(
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: textFaintColor(b),
                            ),
                          ),
                        )
                      : _searchCtrl.text.isEmpty
                          ? null
                          : IconButton(
                              icon: Icon(Icons.close,
                                  size: 18, color: textFaintColor(b)),
                              onPressed: _clearSearch,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 40, minHeight: 40),
                            ),
                  hintText: '搜索感兴趣的动态',
                  hintStyle:
                      TextStyle(fontSize: 14, color: textFaintColor(b)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _buildPublishFab(b),
          const SizedBox(width: 4),
          SizedBox(
            width: 40,
            height: 40,
            child: IconButton(
              onPressed:
                  _refreshing ? null : () => _fetchFirstPage(refreshing: true),
              tooltip: '刷新',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              icon: RotationTransition(
                turns: _refreshAnim,
                child: const Icon(Icons.refresh, color: kPrimary),
              ),
              iconSize: 22,
            ),
          ),
        ],
      ),
    );
  }

  /// 帖子列表主体（小红书瀑布流）
  Widget _buildBody(Brightness b) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = _columnCount(constraints.maxWidth);
        if (_loading && _posts.isEmpty) {
          return SilkySingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            scrollSpeed: 1.6,
            silkyScrollDuration: const Duration(milliseconds: 600),
            animationCurve: Curves.easeOutCubic,
            child: _SkeletonGrid(columns: columns),
          );
        }
        if (_loadFailed && _posts.isEmpty) {
          return _buildEmpty(b, Icons.error_outline, '加载失败，请点击右上角刷新重试');
        }
        if (_posts.isEmpty) {
          return _buildEmpty(b, Icons.forum_outlined, '这是一个荒无人烟的世界吗？');
        }
        return NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
              _loadMore();
            }
            return false;
          },
          child: SilkySingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            scrollSpeed: 1.6,
            silkyScrollDuration: const Duration(milliseconds: 600),
            animationCurve: Curves.easeOutCubic,
            child: Column(
              children: [
                _MasonryGrid(
                  posts: _posts,
                  columns: columns,
                  coverHeight: _coverHeight,
                  onPostTap: _openPostDetail,
                ),
                if (_loadingMore)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                if (_allLoaded && _posts.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: Text(
                        '没有更多了',
                        style:
                            TextStyle(fontSize: 12, color: textFaintColor(b)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 依据页面宽度决定瀑布流列数（卡片最小宽约 240，间距 12）
  int _columnCount(double width) {
    const minCardWidth = 240.0;
    const gap = 12.0;
    final n = ((width + gap) / (minCardWidth + gap)).floor();
    return n.clamp(1, 6).toInt();
  }

  /// 封面图高度：确定性伪随机（按帖子 id + 正文长度），落在 [170, 288] 区间，
  /// 制造小红书式错落，且满足「高度跟随封面图、有最大/最小限制」。
  double _coverHeight(Map<String, dynamic> post) {
    final id = (post['id'] as num?)?.toInt() ?? 0;
    final content = post['content']?.toString() ?? '';
    final images = (post['images'] as List<dynamic>?) ?? const [];
    final seed = ((id * 31 + content.length + images.length) % 100).abs();
    return 170 + seed * 1.2;
  }

  Widget _buildEmpty(Brightness b, IconData icon, String text) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 56, color: textFaintColor(b)),
          const SizedBox(height: 12),
          Text(text, style: TextStyle(color: textMutedColor(b))),
        ],
      ),
    );
  }
}

/// 帖子卡片（小红书瀑布流：封面图 + 正文 + 头像昵称 + 点赞数）
class _PostCard extends StatefulWidget {
  final Map<String, dynamic> post;
  final double coverHeight;
  final VoidCallback onTap;

  const _PostCard({
    required this.post,
    required this.coverHeight,
    required this.onTap,
  });

  @override
  State<_PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<_PostCard> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final post = widget.post;

    final nickname = post['nickname']?.toString() ?? '匿名用户';
    final avatar = post['avatar']?.toString() ?? '';
    final content = post['content']?.toString() ?? '';
    final images = ((post['images'] as List<dynamic>?) ?? [])
        .map((e) => e.toString())
        .where((s) => s.isNotEmpty)
        .toList();
    final likeCount = (post['like_count'] as num?)?.toInt() ?? 0;
    final isLiked = (post['is_liked'] as bool?) ?? false;
    final cover = images.isNotEmpty ? images.first : null;

    final borderColor =
        b == Brightness.dark ? DarkColors.border : LightColors.border;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : (_hover ? 1.02 : 1.0),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            mouseCursor: SystemMouseCursors.click, // 悬停显示手指
            onHighlightChanged: (v) => setState(() => _pressed = v),
            borderRadius: kRadiusCardAll,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              decoration: BoxDecoration(
                color: bgColor(b),
                borderRadius: kRadiusCardAll,
                border: Border.all(color: borderColor),
                boxShadow: _hover
                    ? [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 14,
                          offset: const Offset(0, 6),
                        ),
                      ]
                    : null,
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 封面：有图用首图，无图用纯色文字封面（客户端算法生成，省服务器开销）
                  if (cover != null)
                    _CoverImage(url: cover, height: widget.coverHeight)
                  else
                    _TextCover(content: content, height: widget.coverHeight),
                  // 正文（有图时最多 2 行；无图时文字已展示在纯色封面中，避免重复）
                  if (content.isNotEmpty && cover != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                      child: Text(
                        content,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: textBodyColor(b),
                          height: 1.45,
                        ),
                      ),
                    ),
                  // 底部：头像 + 昵称 + 点赞数
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                    child: Row(
                      children: [
                        _UserAvatar(
                          avatarUrl: avatar.isEmpty
                              ? null
                              : AppConfig.resolveUrl(avatar),
                          nickname: nickname,
                          size: 22,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            nickname,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: textMutedColor(b),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Icon(
                              isLiked ? Icons.favorite : Icons.favorite_border,
                              size: 14,
                              color: isLiked ? kDanger : textMutedColor(b),
                            ),
                            const SizedBox(width: 3),
                            Text(
                              '$likeCount',
                              style: TextStyle(
                                fontSize: 12,
                                color: textMutedColor(b),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 封面图（网络图 + 统一加载 / 错误兜底）
class _CoverImage extends StatelessWidget {
  final String url;
  final double height;

  const _CoverImage({required this.url, required this.height});

  @override
  Widget build(BuildContext context) {
    // 封面图片自身裁剪顶部圆角，确保圆角平滑（比依赖外层整体 clip 更细腻）
    return ClipRRect(
      borderRadius: BorderRadius.vertical(top: Radius.circular(kRadiusCard)),
      child: NetImage(
        url: url,
        width: double.infinity,
        height: height,
        fit: BoxFit.cover,
        cacheWidth: 480, // 限制解码尺寸，降低内存与解码开销，提升滚动流畅度
      ),
    );
  }
}

/// 无图动态的算法封面：确定性纯色背景 + 内容文字（浅底深字，对比度固定，客户端本地生成，不占服务器开销）
class _TextCover extends StatelessWidget {
  final String content;
  final double height;

  const _TextCover({required this.content, required this.height});

  // 小红书风柔和浅色背景（均配深色文字，保证「背景色不与文字冲突」）
  static const List<Color> _bgColors = [
    Color(0xFFF6A5A5), // 珊瑚粉
    Color(0xFFF2B98D), // 杏橙
    Color(0xFFF0D18A), // 奶油黄
    Color(0xFFA9D3A9), // 薄荷绿
    Color(0xFF8FC7C9), // 青蓝
    Color(0xFF9BB8E8), // 淡蓝
    Color(0xFFBFA3E3), // 淡紫
    Color(0xFFE3A3C2), // 粉紫
  ];
  static const List<Color> _fgColors = [
    Color(0xFF8C3B3B),
    Color(0xFF5A3412),
    Color(0xFF5A4612),
    Color(0xFF174B22),
    Color(0xFF17494B),
    Color(0xFF17345B),
    Color(0xFF331A5B),
    Color(0xFF541A3A),
  ];

  /// 确定性 hash（同内容固定同色，避免每次 build 变色闪烁）
  static int _stableHash(String s) {
    var h = 0;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h;
  }

  @override
  Widget build(BuildContext context) {
    final text = content.trim();
    final seed = text.isEmpty ? ' ' : text;
    final idx = _stableHash(seed) % _bgColors.length;
    // 截取合适长度：约 30 字内，超长溢出用 "..."；加中文双引号
    final excerpt = text.length <= 30 ? text : '${text.substring(0, 30)}...';

    return Container(
      width: double.infinity,
      height: height,
      color: _bgColors[idx],
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Text(
        '“$excerpt”',
        maxLines: 5,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: _fgColors[idx],
          fontSize: 18,
          fontWeight: FontWeight.w600,
          height: 1.5,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// 骨架屏：首次加载 / 搜索时的瀑布流占位动画（呼吸闪烁）
class _SkeletonGrid extends StatefulWidget {
  final int columns;
  const _SkeletonGrid({required this.columns});

  @override
  State<_SkeletonGrid> createState() => _SkeletonGridState();
}

class _SkeletonGridState extends State<_SkeletonGrid>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  )..repeat(reverse: true);
  late final Animation<double> _opacity = Tween<double>(begin: 0.35, end: 1.0)
      .animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = bgHoverColor(Theme.of(context).brightness);
    // 高度错落模拟瀑布流
    const cardHeights = [200.0, 260.0, 180.0, 240.0, 220.0, 280.0];
    final cols = List.generate(widget.columns, (_) => <double>[]);
    for (var i = 0; i < widget.columns * 2; i++) {
      cols[i % widget.columns].add(cardHeights[i % cardHeights.length]);
    }
    return FadeTransition(
      opacity: _opacity,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < widget.columns; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(
              child: Column(
                children: [
                  for (final h in cols[i])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _SkeletonCard(height: h, base: base),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 骨架卡片：封面占位 + 头像/昵称占位
class _SkeletonCard extends StatelessWidget {
  final double height;
  final Color base;
  const _SkeletonCard({required this.height, required this.base});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: height,
          decoration: BoxDecoration(
            color: base,
            borderRadius: BorderRadius.circular(kRadiusMd),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(color: base, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                height: 10,
                decoration: BoxDecoration(
                  color: base,
                  borderRadius: BorderRadius.circular(kRadiusSm),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          width: 90,
          height: 10,
          decoration: BoxDecoration(
            color: base,
            borderRadius: BorderRadius.circular(kRadiusSm),
          ),
        ),
      ],
    );
  }
}

/// 瀑布流：贪心分配到最短列（每列宽度由 Expanded 等分）
class _MasonryGrid extends StatelessWidget {
  final List<Map<String, dynamic>> posts;
  final int columns;
  final double Function(Map<String, dynamic>) coverHeight;
  final void Function(Map<String, dynamic>) onPostTap;

  const _MasonryGrid({
    required this.posts,
    required this.columns,
    required this.coverHeight,
    required this.onPostTap,
  });

  @override
  Widget build(BuildContext context) {
    // 估算每张卡片高度用于贪心分配（近似即可，不影响实际渲染高度）
    double estHeight(Map<String, dynamic> p) {
      final content = p['content']?.toString() ?? '';
      final lines =
          content.isEmpty ? 0 : (content.length / 14).ceil().clamp(1, 2).toInt();
      return coverHeight(p) + (content.isEmpty ? 0 : 10 + lines * 20) + 56;
    }

    final cols = List.generate(columns, (_) => <Map<String, dynamic>>[]);
    final heights = List.filled(columns, 0.0);
    for (final p in posts) {
      var idx = 0;
      var minH = heights[0];
      for (var i = 1; i < columns; i++) {
        if (heights[i] < minH) {
          minH = heights[i];
          idx = i;
        }
      }
      cols[idx].add(p);
      heights[idx] += estHeight(p);
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < columns; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          Expanded(
            child: Column(
              children: [
                for (final p in cols[i])
                  RepaintBoundary(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _PostCard(
                        post: p,
                        coverHeight: coverHeight(p),
                        onTap: () => onPostTap(p),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// 个人中心视图
class _ProfileView extends StatefulWidget {
  /// 当前登录用户（map 引用，编辑成功后直接更新，供主页面左侧头像同步）
  final Map<String, dynamic> user;

  /// 退出登录回调
  final VoidCallback onLogout;

  /// 资料变更（昵称/头像）回调，用于触发主页面刷新
  final ValueChanged<Map<String, dynamic>> onUserChanged;

  /// 当前是否处于显示状态（个人中心 tab 被选中时为 true）
  ///
  /// 用于在每次切换到个人中心时刷新收藏列表（按需拉取，非定时轮询）。
  final bool active;

  const _ProfileView({
    required this.user,
    required this.onLogout,
    required this.onUserChanged,
    this.active = true,
  });

  @override
  State<_ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<_ProfileView> {
  /// 当前用户信息（持有同一 map 引用）
  late Map<String, dynamic> _user = widget.user;

  /// 是否封禁
  bool get _banned => (_user['banned'] as bool?) ?? false;

  /// 昵称
  String get _nickname {
    final n = _user['nickname'] as String?;
    if (n != null && n.isNotEmpty) return n;
    return (_user['phone'] as String?) ?? '用户';
  }

  /// 手机号（脱敏展示后四位）
  String get _phone {
    final p = (_user['phone'] as String?) ?? '';
    if (p.length >= 7)
      return '${p.substring(0, 3)}****${p.substring(p.length - 4)}';
    return p.isEmpty ? '' : p;
  }

  /// 头像 URL
  String? get _avatarUrl {
    final raw = _user['avatar'] as String?;
    if (raw == null || raw.isEmpty) return null;
    return AppConfig.resolveUrl(raw);
  }

  /// 熊爪余额（整数积分）
  int get _paw {
    final raw = _user['paw'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return 0;
  }

  /// 用户 UID（用户 id）
  String get _uid {
    final raw = _user['id'];
    if (raw == null) return '';
    return raw.toString();
  }

  // ===== 我的收藏 =====
  final List<Map<String, dynamic>> _favorites = [];
  int _favPage = 1;
  bool _favLoading = false;
  bool _favLoadingMore = false;
  bool _favAllLoaded = false;
  bool _favLoadFailed = false;

  @override
  void initState() {
    super.initState();
    // 监听钱包余额推送（充值到账后 WS 实时刷新熊爪余额）
    WsService.instance.onWallet = _onWalletPushed;
    // 加载我的收藏列表（首次进入个人中心）
    if (widget.active) _loadFavorites();
  }

  @override
  void didUpdateWidget(covariant _ProfileView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 从其他 tab 切回个人中心（active 由 false → true）时刷新收藏列表，
    // 保证「广场里收藏/取消收藏」后切回来能看到最新数据（按需拉取，无轮询开销）。
    if (widget.active && !oldWidget.active) {
      _loadFavorites();
    }
  }

  @override
  void dispose() {
    if (WsService.instance.onWallet == _onWalletPushed) {
      WsService.instance.onWallet = null;
    }
    super.dispose();
  }

  /// WS 钱包余额推送回调：更新本地余额并刷新显示
  void _onWalletPushed(Map<String, dynamic> wallet) {
    if (!mounted) return;
    if (wallet.containsKey('paw')) _user['paw'] = wallet['paw'];
    if (wallet.containsKey('cny')) _user['cny'] = wallet['cny'];
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return _PageScaffold(
      title: '个人中心',
      actions: [
        // 右上角省略号：更多操作（更改密码 / 退出账户）
        PopupMenuButton<String>(
          tooltip: '更多操作',
          icon: Icon(Icons.more_horiz, size: 22, color: textColor(b)),
          color: bgHoverColor(b),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadiusBtn),
          ),
          onSelected: (v) {
            if (v == 'change_password') _openChangePasswordDialog();
            if (v == 'logout') _confirmLogout();
          },
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: 'change_password',
              height: 40,
              child: Row(
                children: [
                  Icon(Icons.lock_outline, size: 18, color: kPrimary),
                  SizedBox(width: 10),
                  Text('更改密码'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'logout',
              height: 40,
              child: Row(
                children: [
                  Icon(Icons.logout, size: 18, color: kDanger),
                  SizedBox(width: 10),
                  Text('退出账户', style: TextStyle(color: kDanger)),
                ],
              ),
            ),
          ],
        ),
      ],
      child: LayoutBuilder(
        builder: (context, constraints) {
          return NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
                _loadMoreFavorites();
              }
              return false;
            },
            child: SilkySingleChildScrollView(
              padding: const EdgeInsets.all(16),
              scrollSpeed: 1.6,
              silkyScrollDuration: const Duration(milliseconds: 600),
              animationCurve: Curves.easeOutCubic,
              child: ConstrainedBox(
                constraints:
                    BoxConstraints(minHeight: constraints.maxHeight - 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                  // ===== 用户信息卡（头像 + 昵称/UID/状态 + 熊爪余额） =====
                  Card(
                    elevation: 0,
                    color: bgHoverColor(b),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(kRadiusBtn),
                    ),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              // 头像
                              _UserAvatar(
                                avatarUrl: _avatarUrl,
                                nickname: _nickname,
                                size: 56,
                              ),
                              const SizedBox(width: 16),
                              // 昵称 + UID + 状态
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            _nickname,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.w600,
                                              color: textColor(b),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        // 当前用户状态：正常 / 封禁
                                        _StatusBadge(banned: _banned),
                                      ],
                                    ),
                                    if (_uid.isNotEmpty || _phone.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        [
                                          if (_uid.isNotEmpty) 'UID：$_uid',
                                          if (_phone.isNotEmpty) _phone,
                                        ].join('  ·  '),
                                        style: TextStyle(
                                            fontSize: 13,
                                            color: textMutedColor(b)),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              // 编辑入口
                              InkWell(
                                onTap: _openEditDialog,
                                mouseCursor: SystemMouseCursors.click, // 悬停显示手指
                                borderRadius: BorderRadius.circular(kRadiusSm),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6),
                                  child: Text('编辑',
                                      style: TextStyle(
                                          fontSize: 14,
                                          color: kPrimary,
                                          fontWeight: FontWeight.w500)),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // 熊爪余额（图标 + 文字 + 数字，统一字号与行高对齐）
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // // 金币图标（橙金色，避免爪印图形）
                              // const Icon(Icons.monetization_on,
                              //     size: 15, color: Color(0xFFF5A623)),
                              // const SizedBox(width: 3),
                              Text('熊爪数:',
                                  style: TextStyle(
                                      fontSize: 13,
                                      height: 1.0,
                                      color: textMutedColor(b))),
                              const SizedBox(width: 8),
                              Text('$_paw',
                                  style: TextStyle(
                                      fontSize: 14,
                                      height: 1.0,
                                      fontWeight: FontWeight.w700,
                                      color: textColor(b))),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  // ===== 我的收藏（小红书/抖音风格双列瀑布流） =====
                  Padding(
                    padding: const EdgeInsets.only(left: 2, bottom: 12),
                    child: Row(
                      children: [
                        // Icon(Icons.bookmark_border,
                        //     size: 18, color: kPrimary),
                        // const SizedBox(width: 6),
                        Text('收藏',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: textColor(b))),
                        const SizedBox(width: 8),
                        if (_favorites.isNotEmpty)
                          Text('${_favorites.length}',
                              style: TextStyle(
                                  fontSize: 13, color: textMutedColor(b))),
                      ],
                    ),
                  ),
                  // 收藏列表内容：加载中 / 失败重试 / 空态 / 瀑布流
                  if (_favLoading && _favorites.isEmpty)
                    const _SkeletonGrid(columns: 3)
                  else if (_favLoadFailed && _favorites.isEmpty)
                    _FavRetry(onRetry: _loadFavorites)
                  else if (_favorites.isEmpty)
                    _EmptyFavorites(b: b)
                  else
                    _MasonryGrid(
                      posts: _favorites,
                      columns: _favColumns(constraints.maxWidth),
                      coverHeight: _favCoverHeight,
                      onPostTap: (p) => _openFavPost(p),
                    ),
                  if (_favLoadingMore)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      ),
                    )
                  else if (!_favAllLoaded && _favorites.isNotEmpty)
                    const SizedBox(height: 24),
                  const SizedBox(height: 16),
                ],
              ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ===== 我的收藏：加载 =====

  /// 计算收藏瀑布流列数（复用首页瀑布流算法：卡片最小宽约 240，间距 12）
  int _favColumns(double width) {
    const minCardWidth = 240.0;
    const gap = 12.0;
    final n = ((width + gap) / (minCardWidth + gap)).floor();
    return n.clamp(1, 6).toInt();
  }

  /// 收藏卡片封面高度（与首页一致：确定性伪随机，落在 [170, 288] 区间）
  double _favCoverHeight(Map<String, dynamic> post) {
    final id = (post['id'] as num?)?.toInt() ?? 0;
    final content = post['content']?.toString() ?? '';
    final images = (post['images'] as List<dynamic>?) ?? const [];
    final seed = ((id * 31 + content.length + images.length) % 100).abs();
    return 170 + seed * 1.2;
  }

  /// 加载我的收藏第一页
  Future<void> _loadFavorites() async {
    if (_favLoading) return;
    setState(() {
      _favLoading = true;
      _favLoadFailed = false;
      _favPage = 1;
    });
    if (!mounted) return;
    try {
      final resp = await ApiClient.instance
          .getMyFavorites(page: 1, pageSize: 12)
          .timeout(const Duration(seconds: 15));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (resp.statusCode == 200 && json['code'] == 0) {
        final list = ((json['data'] ?? {})['list'] ?? []) as List;
        setState(() {
          _favorites.clear();
          _favorites.addAll(list.map((e) => Map<String, dynamic>.from(e)));
          _favPage = 1;
          _favAllLoaded = list.length < 12;
          _favLoading = false;
        });
      } else {
        setState(() {
          _favLoading = false;
          _favLoadFailed = true;
        });
      }
    } catch (_) {
      setState(() {
        _favLoading = false;
        _favLoadFailed = true;
      });
    }
  }

  /// 加载更多收藏（触底自动加载）
  Future<void> _loadMoreFavorites() async {
    if (_favLoading ||
        _favLoadingMore ||
        _favAllLoaded ||
        _favorites.isEmpty) {
      return;
    }
    setState(() => _favLoadingMore = true);
    try {
      final resp = await ApiClient.instance
          .getMyFavorites(page: _favPage + 1, pageSize: 12)
          .timeout(const Duration(seconds: 15));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (resp.statusCode == 200 && json['code'] == 0) {
        final list = ((json['data'] ?? {})['list'] ?? []) as List;
        setState(() {
          _favPage++;
          _favorites.addAll(list.map((e) => Map<String, dynamic>.from(e)));
          _favAllLoaded = list.length < 12;
          _favLoadingMore = false;
        });
      } else {
        setState(() => _favLoadingMore = false);
      }
    } catch (_) {
      setState(() => _favLoadingMore = false);
    }
  }

  /// 点击收藏卡片 → 打开帖子详情
  Future<void> _openFavPost(Map<String, dynamic> p) async {
    final id = (p['id'] as num?)?.toInt() ?? 0;
    if (id <= 0) return;
    // 双端统一：在内容区打开帖子详情（保留左侧导航栏，不遮盖）
    if (_HomePageState.current?.mounted == true) {
      _HomePageState.current!.openPostFullInContent(p, id);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PostDetailPage(
          postBrief: p,
          postId: id,
          currentUserId: (_user['id'] as num?)?.toInt() ?? 0,
        ),
      ),
    );
    // 从详情页返回后刷新收藏列表（可能取消了收藏）
    _loadFavorites();
  }

  // ===== 我的收藏：加载 =====

  Future<void> _openEditDialog() async {
    final b = Theme.of(context).brightness;
    final nameCtrl = TextEditingController(text: _nickname);
    bool uploading = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            backgroundColor: bgHoverColor(b),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kRadiusMd),
            ),
            title: Text('编辑资料',
                style: TextStyle(color: textColor(b), fontSize: 17)),
            content: SizedBox(
              width: 300,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 头像居中展示，右下角"修改"相机图标
                  Center(
                    child: SizedBox(
                      width: 120,
                      height: 120,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          // 圆形头像（预览：已裁剪的新图 / 当前头像 / 首字兜底）
                          ClipOval(
                            child: Container(
                              width: 120,
                              height: 120,
                              color: primarySoftColor(b),
                              child: _EditAvatarPreview(
                                currentUrl: _avatarUrl,
                                nickname: _nickname,
                                selectedBytes: _selectedAvatarBytes,
                              ),
                            ),
                          ),
                          // 右下角"修改"图标：点击选图并裁剪
                          Positioned(
                            right: -4,
                            bottom: -4,
                            child: InkWell(
                              onTap: () => _pickAndCropAvatar(setDialogState),
                              mouseCursor: SystemMouseCursors.click, // 悬停显示手指
                              borderRadius: kRadiusCardAll,
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: kPrimary,
                                  border: Border.all(
                                      color: bgHoverColor(b), width: 2),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: .2),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: const Icon(Icons.photo_camera,
                                    size: 18, color: Colors.white),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  // 昵称
                  TextField(
                    controller: nameCtrl,
                    style: TextStyle(color: textColor(b)),
                    decoration: InputDecoration(
                      labelText: '昵称',
                      labelStyle: TextStyle(color: textMutedColor(b)),
                      filled: true,
                      fillColor: bgColor(b),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(kRadiusMd),
                        borderSide: BorderSide(
                            color: textFaintColor(b).withValues(alpha: .3)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(kRadiusMd),
                        borderSide:
                            const BorderSide(color: kPrimary, width: 1.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('取消',
                    style: TextStyle(color: textMutedColor(b))),
              ),
              TextButton(
                onPressed: uploading ? null : () => _saveProfile(ctx, nameCtrl),
                child: uploading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('保存', style: TextStyle(color: kPrimary)),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 本地选中的头像文件字节（预览用）
  List<int>? _selectedAvatarBytes;
  String? _selectedAvatarName;

  /// 选择头像图片并裁剪：选图 → 打开裁剪对话框 → 得到裁剪后的 PNG bytes → 本地预览
  Future<void> _pickAndCropAvatar(StateSetter setDialogState) async {
    try {
      final picked = await pickImages(allowMultiple: false);
      if (picked.isEmpty) return;
      final file = picked.single;

      // 读取原图 bytes（裁剪对话框用）
      final Uint8List sourceBytes = file.bytes;

      // 原始图片 ≤5MB 限制
      if (sourceBytes.length > 5 * 1024 * 1024) {
        NotifyStack.warning('头像图片不能超过5MB', title: '提示');
        return;
      }

      // 打开裁剪对话框
      final cropped = await _AvatarCropDialog.show(context, sourceBytes);
      if (cropped == null || !mounted) return;

      // 裁剪成功：更新本地预览（还没上传，保存时才上传）
      _selectedAvatarBytes = cropped;
      _selectedAvatarName = 'avatar_cropped.png';
      // 用对话框的 setDialogState 刷新头像预览（对话框是独立 StatefulBuilder，
      // 用 ProfileView 的 setState 不会触发它 rebuild）
      setDialogState(() {});
    } catch (_) {}
  }

  /// 保存资料：若选了新头像先上传，再更新昵称
  Future<void> _saveProfile(
      BuildContext dialogCtx, TextEditingController nameCtrl) async {
    final nickname = nameCtrl.text.trim();
    if (nickname.isEmpty) {
      NotifyStack.warning('昵称不能为空');
      return;
    }

    // 保存按钮进入加载态
    setState(() {});

    try {
      // 1) 若已选择新头像，先上传（直接传裁剪后的 bytes，避免本地临时文件 IO）
      String? avatarPath;
      if (_selectedAvatarBytes != null) {
        final resp = await ApiClient.instance
            .uploadAvatarBytes(
              Uint8List.fromList(_selectedAvatarBytes!),
              filename: _selectedAvatarName ?? 'avatar.png',
            )
            .timeout(const Duration(seconds: 20));
        final json = ApiClient.safeJsonDecode(resp.body);
        if (json['code'] != 0) {
          NotifyStack.warning((json['msg'] as String?) ?? '头像上传失败');
          return;
        }
        avatarPath = (json['data']?['avatar'] as String?) ?? '';
      }

      // 2) 更新昵称（即使未改昵称，也请求一次，保持用户信息一致性）
      final resp = await ApiClient.instance
          .postProfile(nickname: nickname)
          .timeout(const Duration(seconds: 10));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] != 0) {
        NotifyStack.warning((json['msg'] as String?) ?? '保存失败');
        return;
      }

      // 3) 更新本地 user map + 触发主页面刷新
      if (avatarPath != null && avatarPath.isNotEmpty) {
        _user['avatar'] = avatarPath;
      }
      if (nickname != _user['nickname']) {
        _user['nickname'] = nickname;
      }
      if (mounted) {
        setState(() {
          _selectedAvatarBytes = null;
          _selectedAvatarName = null;
        });
      }
      widget.onUserChanged(Map<String, dynamic>.from(_user));
      Navigator.pop(dialogCtx);
      NotifyStack.success('资料已更新', title: '成功');
    } catch (e) {
      // 展示真实错误，便于排查（不再笼统提示"请检查网络"）
      debugPrint('保存资料失败: $e');
      NotifyStack.warning('保存失败：$e');
    } finally {
      setState(() {});
    }
  }

  /// 打开更改密码对话框
  Future<void> _openChangePasswordDialog() async {
    final b = Theme.of(context).brightness;
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    bool saving = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            backgroundColor: bgHoverColor(b),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kRadiusMd),
            ),
            title: Text('更改密码',
                style: TextStyle(color: textColor(b), fontSize: 17)),
            content: SizedBox(
              width: 320,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PwdField(
                    label: '原密码',
                    controller: oldCtrl,
                    brightness: b,
                  ),
                  const SizedBox(height: 12),
                  _PwdField(
                    label: '新密码',
                    controller: newCtrl,
                    brightness: b,
                  ),
                  const SizedBox(height: 12),
                  _PwdField(
                    label: '确认新密码',
                    controller: confirmCtrl,
                    brightness: b,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('取消',
                    style: TextStyle(color: textMutedColor(b))),
              ),
              TextButton(
                onPressed: saving
                    ? null
                    : () => _savePassword(
                        ctx, setDialogState, oldCtrl, newCtrl, confirmCtrl),
                child: saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('确定', style: TextStyle(color: kPrimary)),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 提交修改密码
  Future<void> _savePassword(
    BuildContext dialogCtx,
    StateSetter setDialogState,
    TextEditingController oldCtrl,
    TextEditingController newCtrl,
    TextEditingController confirmCtrl,
  ) async {
    final oldPwd = oldCtrl.text;
    final newPwd = newCtrl.text;
    final confirmPwd = confirmCtrl.text;

    if (oldPwd.isEmpty) {
      NotifyStack.warning('请输入原密码');
      return;
    }
    if (newPwd.length < 6) {
      NotifyStack.warning('新密码长度至少6位');
      return;
    }
    if (newPwd != confirmPwd) {
      NotifyStack.warning('两次输入的新密码不一致');
      return;
    }

    setDialogState(() {}); // 进入加载态
    try {
      final resp = await ApiClient.instance
          .postChangePassword(
            oldPassword: oldPwd,
            newPassword: newPwd,
          )
          .timeout(const Duration(seconds: 10));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] != 0) {
        NotifyStack.warning((json['msg'] as String?) ?? '修改失败');
        return;
      }
      if (dialogCtx.mounted) Navigator.pop(dialogCtx);
      // 密码已变更：强制下线，回登录页重新登录
      NotifyStack.warning((json['msg'] as String?) ?? '密码修改成功，请重新登录',
          title: '提示');
      widget.onLogout();
    } catch (_) {
      NotifyStack.warning('修改失败，请检查网络');
    }
  }

  /// 退出账户确认对话框（统一走 AppDialog.confirm）
  Future<void> _confirmLogout() async {
    final result = await AppDialog.confirm(
      context,
      title: '退出账户',
      message: '确定要退出当前登录吗？\n本地登录凭据将被清除。',
      confirmText: '退出',
      danger: true,
    );
    if (result == true && mounted) {
      widget.onLogout();
    }
  }
}

/// 我的收藏：加载失败重试
class _FavRetry extends StatelessWidget {
  final VoidCallback onRetry;
  const _FavRetry({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 42, color: textMutedColor(b)),
            const SizedBox(height: 12),
            Text('收藏加载失败',
                style: TextStyle(fontSize: 14, color: textMutedColor(b))),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重试'),
              style: OutlinedButton.styleFrom(
                foregroundColor: kPrimary,
                side: const BorderSide(color: kPrimary, width: 1.2),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 我的收藏：空态（暂无收藏）
class _EmptyFavorites extends StatelessWidget {
  final Brightness b;
  const _EmptyFavorites({required this.b});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 48),
      decoration: BoxDecoration(
        color: bgHoverColor(b),
        borderRadius: BorderRadius.circular(kRadiusMd),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bookmark_border, size: 40, color: textMutedColor(b)),
          const SizedBox(height: 12),
          Text('还没有收藏任何动态',
              style: TextStyle(fontSize: 14, color: textMutedColor(b))),
          const SizedBox(height: 6),
          Text('去广场逛逛，看到喜欢的内容点个收藏吧',
              style: TextStyle(fontSize: 12, color: textMutedColor(b))),
        ],
      ),
    );
  }
}

/// 状态徽标：正常（绿）/ 封禁（红）
class _StatusBadge extends StatelessWidget {
  final bool banned;
  const _StatusBadge({required this.banned});

  @override
  Widget build(BuildContext context) {
    final fg = banned ? kDanger : kSuccess;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(kRadiusSm),
      ),
      child: Text(
        banned ? '封禁' : '正常',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }
}

/// 头像裁剪对话框（大厂体验：图片在固定 1:1 方形框内缩放/平移，裁剪后返回 PNG bytes）
class _AvatarCropDialog extends StatefulWidget {
  final Uint8List imageBytes;

  const _AvatarCropDialog({required this.imageBytes});

  /// 弹出裁剪对话框，返回裁剪后的 PNG bytes；用户取消返回 null
  static Future<Uint8List?> show(BuildContext context, Uint8List bytes) {
    return showDialog<Uint8List>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AvatarCropDialog(imageBytes: bytes),
    );
  }

  @override
  State<_AvatarCropDialog> createState() => _AvatarCropDialogState();
}

class _AvatarCropDialogState extends State<_AvatarCropDialog> {
  // 固定 1:1 方形（适配圆形头像），经典可拖拽网格（鼠标可直接拖拽边缘/角缩放）
  late final CropController _controller = CropController(
    aspectRatio: 1,
    defaultCrop: const Rect.fromLTWH(0.2, 0.2, 0.6, 0.6),
  );
  bool _busy = false;

  /// 完成裁剪：导出 PNG bytes 并返回给调用方
  Future<void> _finish() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bitmap = await _controller.croppedBitmap(maxSize: 512);
      final data = await bitmap.toByteData(format: ui.ImageByteFormat.png);
      bitmap.dispose();
      if (!mounted) return;
      Navigator.pop(context, data?.buffer.asUint8List());
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        NotifyStack.warning('裁剪失败，请重试');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Dialog(
      backgroundColor: bgHoverColor(b),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusMd),
      ),
      insetPadding: const EdgeInsets.all(32),
      child: SizedBox(
        width: 520,
        height: 600,
        child: Column(
          children: [
            // 标题栏
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
              child: Row(
                children: [
                  Text('裁剪头像',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: textColor(b))),
                  const Spacer(),
                  InkWell(
                    onTap: () => Navigator.pop(context),
                    mouseCursor: SystemMouseCursors.click, // 悬停显示手指
                    borderRadius: BorderRadius.circular(kRadiusSm),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(Icons.close,
                          size: 20, color: textMutedColor(b)),
                    ),
                  ),
                ],
              ),
            ),
            // 裁剪区：经典可拖拽网格（鼠标可直接拖拽网格边缘/角调整裁剪框大小与位置）
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: CropImagePro(
                  controller: _controller,
                  image: Image.memory(widget.imageBytes),
                  interactionMode: CropInteractionMode.resizeCropRect,
                  gridColor: Colors.white70,
                  gridCornerColor: kPrimary,
                  alwaysShowThirdLines: true,
                  scrimColor: Colors.black54,
                  shortAxisMinDisplaySize: 300,
                  minimumImageSize: 100,
                  maximumImageSize: double.infinity,
                ),
              ),
            ),
            // 操作提示
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('拖拽网格边缘或角调整裁剪框 · 按住框内可移动',
                  style: TextStyle(
                      fontSize: 12, color: textMutedColor(b))),
            ),
            // 底部操作：取消 / 完成
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => Navigator.pop(context),
                    child: Text('取消',
                        style: TextStyle(color: textMutedColor(b))),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: kPrimary,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _busy ? null : _finish,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.check, size: 18),
                    label: Text(_busy ? '处理中…' : '完成',
                        style: const TextStyle(
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 编辑资料对话框中的头像预览：优先本地新图，否则当前头像，兜底首字
class _EditAvatarPreview extends StatelessWidget {
  final String? currentUrl;
  final String nickname;
  final List<int>? selectedBytes;

  const _EditAvatarPreview({
    required this.currentUrl,
    required this.nickname,
    required this.selectedBytes,
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    const size = 120.0;
    // 有本地新图：直接显示（裁剪后的头像，铺满圆形容器）
    if (selectedBytes != null) {
      return Image.memory(
        Uint8List.fromList(selectedBytes!),
        width: size,
        height: size,
        fit: BoxFit.cover,
      );
    }
    // 有当前头像：网络图
    if (currentUrl != null && currentUrl!.isNotEmpty) {
      return Image.network(
        currentUrl!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _initialBox(b, size),
      );
    }
    // 兜底：首字
    return _initialBox(b, size);
  }

  Widget _initialBox(Brightness b, double size) {
    final name = nickname.trim();
    final initial =
        name.isEmpty ? '?' : (name.length <= 2 ? name : name.substring(0, 2));
    return Container(
      width: size,
      height: size,
      color: primarySoftColor(b),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          fontSize: size * 0.28,
          fontWeight: FontWeight.w600,
          color: kPrimary,
        ),
      ),
    );
  }
}

/// 密码输入框
class _PwdField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final Brightness brightness;

  const _PwdField({
    required this.label,
    required this.controller,
    required this.brightness,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: true,
      style: TextStyle(color: textColor(brightness)),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: textMutedColor(brightness)),
        filled: true,
        fillColor: bgColor(brightness),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(kRadiusMd),
          borderSide:
              BorderSide(color: textFaintColor(brightness).withValues(alpha: .3)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(kRadiusMd),
          borderSide: const BorderSide(color: kPrimary, width: 1.5),
        ),
      ),
    );
  }
}

/// 设置视图
class _SettingsView extends StatefulWidget {
  final ThemeController theme;

  /// 当前登录用户
  final Map<String, dynamic> user;

  /// 退出登录回调
  final VoidCallback onLogout;

  const _SettingsView({
    required this.theme,
    required this.user,
    required this.onLogout,
  });

  @override
  State<_SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<_SettingsView> {
  ThemeController get _theme => widget.theme;

  /// 选择主题模式：更新控制器并强制本地刷新 UI
  void _selectMode(AppThemeMode mode) {
    _theme.setMode(mode);
    // 本地 setState 确保单选圈等 UI 立即刷新（不依赖父级重建）
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final theme = _theme;
    return _PageScaffold(
      title: '设置',
      child: SilkyListView(
        padding: const EdgeInsets.all(16),
        scrollSpeed: 1.6,
        silkyScrollDuration: const Duration(milliseconds: 600),
        animationCurve: Curves.easeOutCubic,
        children: [
          // ===== 主题模式（自绘可点击行，彻底避免 Material Radio 的"同值不触发"行为） =====
          Card(
            elevation: 0,
            color: bgHoverColor(b),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kRadiusMd),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题（无左侧图标）
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('主题模式',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: textColor(b))),
                ),
                _ThemeOption(
                  label: '白天',
                  subtitle: '浅色界面',
                  value: AppThemeMode.light,
                  current: theme.mode,
                  brightness: b,
                  onTap: _selectMode,
                ),
                _ThemeOption(
                  label: '黑夜',
                  subtitle: '深色界面',
                  value: AppThemeMode.dark,
                  current: theme.mode,
                  brightness: b,
                  onTap: _selectMode,
                ),
                _ThemeOption(
                  label: '跟随系统',
                  subtitle: '自动跟随 Windows 明暗',
                  value: AppThemeMode.system,
                  current: theme.mode,
                  brightness: b,
                  onTap: _selectMode,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // ===== 检查更新 =====
          Card(
            elevation: 0,
            color: bgHoverColor(b),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kRadiusMd),
            ),
            child: ListTile(
              leading: const Icon(Icons.system_update, color: kPrimary),
              title: Text('检查更新',
                  style: TextStyle(color: textColor(b), fontSize: 14)),
              subtitle: Text('当前版本 ${AppConfig.appVersion}',
                  style: TextStyle(color: textMutedColor(b))),
              onTap: () async {
                // 用固定 id 展示"正在检查"，完成后 dismiss（避免提示残留）
                const checkingId = 'checking_update';
                NotifyStack.instance.push(NotifyItem(
                  id: checkingId,
                  title: '检查更新',
                  message: '正在检查更新…',
                  type: NotifyType.info,
                ));
                // 手动检查：绕开本地忽略缓存，始终以服务端最新版本为准
                final info =
                    await Updater.instance.checkUpdate(ignoreFilter: false);
                NotifyStack.instance.dismiss(checkingId);
                if (info == null) {
                  NotifyStack.success('已是最新版本');
                } else {
                  // 直接推送更新通知（不再重复 checkUpdate，避免被忽略过滤）
                  await Updater.instance.showUpdateIfAvailable(info);
                }
              },
            ),
          ),
          const SizedBox(height: 12),
          // 关于（直接 ListTile，无上方分割线，不可点击）
          ListTile(
            enabled: false,
            leading: Icon(Icons.info_outline, color: textMutedColor(b)),
            title: Text('关于', style: TextStyle(color: textColor(b))),
            subtitle: Text('${AppConfig.appName} 客户端 v${AppConfig.appVersion}',
                style: TextStyle(color: textMutedColor(b))),
          ),
        ],
      ),
    );
  }
}

/// 主题模式单选项（自绘：InkWell + 单选圈，永远可点击切换）
class _ThemeOption extends StatelessWidget {
  final String label;
  final String subtitle;
  final AppThemeMode value;
  final AppThemeMode current;
  final Brightness brightness;
  final ValueChanged<AppThemeMode> onTap;

  const _ThemeOption({
    required this.label,
    required this.subtitle,
    required this.value,
    required this.current,
    required this.brightness,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final selected = value == current;
    return InkWell(
      onTap: () => onTap(value),
      mouseCursor: SystemMouseCursors.click, // 悬停显示手指
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            // 单选圈
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? kPrimary : textFaintColor(brightness),
                  width: 2,
                ),
              ),
              child: selected
                  ? Center(
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: kPrimary,
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                          color: textColor(brightness))),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 12, color: textMutedColor(brightness))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 内容区通用脚手架（带标题栏）
class _PageScaffold extends StatelessWidget {
  final String title; // 页面标题
  final Widget child; // 页面内容
  final List<Widget>? actions; // 标题栏右侧按钮

  const _PageScaffold({required this.title, required this.child, this.actions});

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 页面标题 + 右侧按钮
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: textColor(b),
                  ),
                ),
              ),
              if (actions != null) ...actions!,
            ],
          ),
        ),
        // 页面内容
        Expanded(child: child),
      ],
    );
  }
}

/// 通知铃铛图标（头像上方）：有未读时右上角显示红色角标（带数字）
///
/// 用户头像：有 URL 时显示图片，加载失败 fallback 到昵称首字
class _UserAvatar extends StatelessWidget {
  final String? avatarUrl;
  final String nickname;
  final double size;

  const _UserAvatar({
    required this.avatarUrl,
    required this.nickname,
    this.size = 36,
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final initial = _initialText(nickname);

    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: primarySoftColor(b),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          fontSize: size * 0.4,
          fontWeight: FontWeight.w600,
          color: kPrimary,
        ),
      ),
    );

    if (avatarUrl == null || avatarUrl!.isEmpty) {
      return placeholder;
    }

    return ClipOval(
      child: Image.network(
        avatarUrl!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // 加载中显示首字占位
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return placeholder;
        },
        // 加载失败 fallback 到首字
        errorBuilder: (context, error, stackTrace) => placeholder,
      ),
    );
  }

  /// 取昵称首字（最多2字），处理空字符串
  String _initialText(String name) {
    final s = name.trim();
    if (s.isEmpty) return '?';
    if (s.length <= 2) return s;
    return s.substring(0, 2);
  }
}
