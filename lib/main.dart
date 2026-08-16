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
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:window_manager/window_manager.dart';

import 'api_client.dart';
import 'app_config.dart';
import 'app_service.dart';
import 'app_theme.dart';
import 'device_service.dart';
import 'login_page.dart';
import 'maintenance.dart';
import 'notification_center.dart';
import 'notification_page.dart';
import 'notify.dart';
import 'post_detail_page.dart';
import 'publish_post_page.dart';
import 'secure_storage.dart';
import 'splash_page.dart';
import 'theme_controller.dart';
import 'updater.dart';
import 'utils/net_image.dart';
import 'ws_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化窗口管理器：隐藏系统标题栏，由 Flutter 自绘顶栏
  await windowManager.ensureInitialized();

  // 初始化应用服务（单实例 + 关闭驻留）；失败说明已有实例运行
  // 注意：单实例锁必须最先判定，绝不能阻塞或漏判，避免多开
  if (!await AppService.instance.init()) {
    // 已有实例在运行：必须显式 exit，否则 Flutter 引擎进程不会自动退出
    exit(0);
  }
  // 全程序统一安全最小窗口尺寸（登录窗口与主窗口共用）
  const Size kMinWindowSize = Size(900, 640);
  const options = WindowOptions(
    size: Size(1080, 720),
    center: true,
    minimumSize: kMinWindowSize,
    // 隐藏原生标题栏（保留可拖拽区域由自绘顶栏承担）
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
  // 当前选中的导航索引（0=首页，1=个人中心，2=设置）
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    // 监听通知中心（未读数变化时刷新铃铛角标）
    NotificationCenter.instance.addListener(_onNotifyChanged);
  }

  @override
  void dispose() {
    NotificationCenter.instance.removeListener(_onNotifyChanged);
    super.dispose();
  }

  void _onNotifyChanged() {
    if (mounted) setState(() {});
  }

  /// 打开通知中心页（铃铛入口）
  Future<void> _openNotificationPage() async {
    final uid = _HomePageState._resolveUid(widget.user);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NotificationPage(
          currentUserId: uid,
          onChanged: () => NotificationCenter.instance.fetchUnreadForce(),
        ),
      ),
    );
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

  late final List<_NavItem> _navItems = [
    _NavItem(Icons.space_dashboard_rounded, '广场', _HomeView(user: widget.user)),
    _NavItem(
      Icons.person_outline,
      '个人中心',
      _ProfileView(
        user: widget.user,
        onLogout: widget.onLogout,
        onUserChanged: (_) {
          // 个人中心修改资料（昵称/头像）后触发刷新，让左侧头像等同步更新。
          // _ProfileView 会直接更新共享的 user map，这里只需触发 rebuild。
          if (mounted) setState(() {});
        },
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

  /// 导航栏固定宽度（与顶栏左侧分色宽度一致）
  static const double _railWidth = 72;

  /// 当前登录用户昵称
  String get _userNickname {
    final n = widget.user['nickname'] as String?;
    if (n != null && n.isNotEmpty) return n;
    return (widget.user['phone'] as String?) ?? '用户';
  }

  /// 当前登录用户头像 URL（相对路径自动拼后端域名）
  String? get _userAvatar {
    final raw = widget.user['avatar'] as String?;
    if (raw == null || raw.isEmpty) return null;
    return AppConfig.resolveUrl(raw);
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Scaffold(
      // 内容页背景标准色
      backgroundColor: bgColor(b),
      body: Column(
        children: [
          // ========== 自绘顶栏（左右分色 + 窗口控制按钮） ==========
          _TitleBar(
            navWidth: _railWidth,
            brightness: b,
          ),
          // ========== 下方主体：左侧导航 + 右侧内容 ==========
          Expanded(
            child: Row(
              children: [
                // 左侧导航栏（副区块背景，无边框，窄栏，自绘精确对齐）
                Container(
                  width: _railWidth,
                  color: bgSoftColor(b),
                  child: Column(
                    children: [
                      // 顶部留白：让首页图标中心与右侧内容页标题中心(≈74px)精确对齐
                      const SizedBox(height: 10),
                      // 首页图标按钮（48px 高，中心 = 40 + 10 + 24 = 74px）
                      SizedBox(
                        width: 68,
                        height: 48,
                        child: Material(
                          // 不显示背景框，只靠图标变色标识选中态
                          color: Colors.transparent,
                          child: Tooltip(
                            message: '广场',
                            child: InkWell(
                              onTap: () => setState(() => _currentIndex = 0),
                              mouseCursor: SystemMouseCursors.click, // 悬停显示手指
                              child: Icon(
                                Icons.space_dashboard_rounded,
                                size: 22,
                                color: _currentIndex == 0
                                    ? kPrimary
                                    : textMutedColor(b),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const Spacer(),
                      // 通知铃铛（有未读时右上角红色角标，带数字）—— 头像上方
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: _NotificationBell(
                          unread: NotificationCenter.instance.unread,
                          onTap: _openNotificationPage,
                        ),
                      ),
                      // 个人中心入口（当前登录用户头像，点击进入个人中心页）
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Tooltip(
                          message: '个人中心',
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click, // 悬停显示手指
                            child: GestureDetector(
                              onTap: () => setState(() => _currentIndex = 1),
                              child: _UserAvatar(
                                avatarUrl: _userAvatar,
                                nickname: _userNickname,
                                size: 36,
                              ),
                            ),
                          ),
                        ),
                      ),
                      // 底部固定设置按钮（图标 + tooltip，不显示文字）
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: IconButton(
                          tooltip: '设置',
                          icon: Icon(
                            Icons.settings_outlined,
                            size: 22,
                            color: _currentIndex == 2
                                ? kPrimary
                                : textMutedColor(b),
                          ),
                          onPressed: () => setState(() => _currentIndex = 2),
                        ),
                      ),
                    ],
                  ),
                ),

                // 右侧内容区（无分割线，无边框）
                Expanded(
                  child: IndexedStack(
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
                children: [
                  // 可拖拽区域（撑满，可拖动窗口）
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (_) => windowManager.startDragging(),
                      child: const SizedBox.expand(),
                    ),
                  ),
                  // 窗口控制按钮
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
class _WinButton extends StatelessWidget {
  final IconData icon;
  final bool isClose;
  final VoidCallback onTap;

  const _WinButton({
    required this.icon,
    this.isClose = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return SizedBox(
      width: 46,
      height: 60,
      child: InkWell(
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click, // 悬停显示手指
        hoverColor: isClose ? const Color(0xFFE81123) : bgHoverColor(b),
        child: Icon(
          icon,
          size: 16,
          color: isClose ? null : textMutedColor(b),
        ),
      ),
    );
  }
}

/// 广场视图（帖子列表，小红书风格）
class _HomeView extends StatefulWidget {
  final Map<String, dynamic> user;

  const _HomeView({required this.user});

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
              borderRadius: BorderRadius.circular(20)),
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
                borderRadius: BorderRadius.circular(20),
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
            borderRadius: BorderRadius.circular(12),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              decoration: BoxDecoration(
                color: bgColor(b),
                borderRadius: BorderRadius.circular(12),
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
    return NetImage(
      url: url,
      width: double.infinity,
      height: height,
      fit: BoxFit.cover,
      cacheWidth: 480, // 限制解码尺寸，降低内存与解码开销，提升滚动流畅度
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
            borderRadius: BorderRadius.circular(12),
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
                  borderRadius: BorderRadius.circular(5),
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
            borderRadius: BorderRadius.circular(5),
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

  const _ProfileView({
    required this.user,
    required this.onLogout,
    required this.onUserChanged,
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
  bool _favLoading = true;
  bool _favLoadingMore = false;
  bool _favAllLoaded = false;
  bool _favLoadFailed = false;

  @override
  void initState() {
    super.initState();
    // 监听钱包余额推送（充值到账后 WS 实时刷新熊爪余额）
    WsService.instance.onWallet = _onWalletPushed;
    // 加载我的收藏列表
    _loadFavorites();
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
            borderRadius: BorderRadius.circular(10),
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
                      borderRadius: BorderRadius.circular(10),
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
                                borderRadius: BorderRadius.circular(6),
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
                        Icon(Icons.bookmark_border,
                            size: 18, color: kPrimary),
                        const SizedBox(width: 6),
                        Text('我的收藏',
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
              borderRadius: BorderRadius.circular(12),
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
                              borderRadius: BorderRadius.circular(18),
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
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                            color: textFaintColor(b).withValues(alpha: .3)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
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
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;

      // 读取原图 bytes（裁剪对话框用）
      final Uint8List sourceBytes;
      if (file.bytes != null) {
        sourceBytes = file.bytes!;
      } else if (file.path != null) {
        sourceBytes = File(file.path!).readAsBytesSync();
      } else {
        return;
      }

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
              borderRadius: BorderRadius.circular(12),
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
        borderRadius: BorderRadius.circular(12),
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
        borderRadius: BorderRadius.circular(6),
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
        borderRadius: BorderRadius.circular(12),
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
                    borderRadius: BorderRadius.circular(6),
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
          borderRadius: BorderRadius.circular(8),
          borderSide:
              BorderSide(color: textFaintColor(brightness).withValues(alpha: .3)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
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
              borderRadius: BorderRadius.circular(8),
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
              borderRadius: BorderRadius.circular(8),
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
/// 未读数 > 0 时显示红点+数字；数字超过 99 显示 "99+"。
class _NotificationBell extends StatelessWidget {
  final int unread;
  final VoidCallback onTap;

  const _NotificationBell({required this.unread, required this.onTap});

  /// 角标显示文本
  String get _badgeText {
    if (unread <= 0) return '';
    return unread > 99 ? '99+' : '$unread';
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final hasUnread = unread > 0;
    final badgeText = _badgeText;
    return SizedBox(
      width: 48,
      height: 40,
      child: Tooltip(
        message: '通知${hasUnread ? '（$badgeText 条未读）' : ''}',
        child: Material(
          color: Colors.transparent,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            mouseCursor: SystemMouseCursors.click, // 悬停显示手指
            onTap: onTap,
            hoverColor: bgHoverColor(b),
            child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                Icons.notifications_none_rounded,
                size: 22,
                color: textMutedColor(b),
              ),
              // 未读角标（右上角）
              if (hasUnread)
                Positioned(
                  top: 2,
                  right: 3,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: badgeText.length > 2 ? 4 : 5,
                      vertical: 1.5,
                    ),
                    constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                    decoration: BoxDecoration(
                      color: kDanger,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: bgSoftColor(b), width: 1.5),
                    ),
                    child: Text(
                      badgeText,
                      style: const TextStyle(
                        fontSize: 9,
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        height: 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          ),
        ),
      ),
    );
  }
}

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
