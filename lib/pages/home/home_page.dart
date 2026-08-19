import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/app_config.dart';
import '../../core/app_theme.dart';
import '../../services/chat_store.dart';
import '../../services/notification_center.dart';
import '../../services/theme_controller.dart';
import '../../widgets/title_bar.dart';
import '../message_page.dart';
import '../notification_page.dart';
import '../planet_page.dart';
import '../post_detail_page.dart';
import '../privacy_settings_page.dart';
import '../publish_post_page.dart';
import '../relation_list_page.dart';
import '../profile/profile_view.dart';
import '../profile/user_profile_page.dart';
import '../settings/settings_view.dart';
import 'home_view.dart';
import 'widgets/sidebar.dart';

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
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  /// 当前挂载的实例（macOS 用于 WS 推送在内容区打开帖子，保留左侧导航栏）
  static HomePageState? current;

  // 当前选中的导航索引（0=消息，1=广场，2=遇见，3=个人中心）
  // 默认登录后进「消息」页
  int _currentIndex = 0;

  /// 消息页 GlobalKey（聊天离线通知点击跳转会话用）
  final GlobalKey<MessagePageState> _messagePageKey =
      GlobalKey<MessagePageState>();

  /// 聊天未读总消息数（左侧导航「消息」角标）
  int _messageUnread = 0;

  /// 内容区覆盖页（发帖/详情内嵌展示，保留左侧导航栏，无返回按钮）
  Widget? _macOverlay;

  /// 通知 tab 索引（0=消息 1=广场 2=遇见 3=我的，通知=4）
  int get _notificationIndex => 4;

  /// 设置 tab 索引（通知=4，设置=5）
  int get _settingsIndex => 5;

  @override
  void initState() {
    super.initState();
    // 记录当前实例（WS 推送在内容区打开帖子用）
    HomePageState.current = this;
    // 监听通知中心（未读数变化时刷新铃铛角标）
    NotificationCenter.instance.addListener(_onNotifyChanged);
    // 监听聊天未读变化（收到消息/打开会话清零/跨端已读 → 刷新消息 tab 角标）
    ChatStore.instance.chatUnreadTick.addListener(_onChatUnreadChanged);
    // 启动兜底清理：清除当前账号库中不属于本账号的串号脏数据
    // （已登录场景无需重新登录，重启应用即可触发）
    final uid = _resolveUid(widget.user);
    if (uid > 0) {
      unawaited(ChatStore.instance.pruneForeignData(uid));
    }
  }

  @override
  void dispose() {
    if (HomePageState.current == this) HomePageState.current = null;
    NotificationCenter.instance.removeListener(_onNotifyChanged);
    ChatStore.instance.chatUnreadTick.removeListener(_onChatUnreadChanged);
    super.dispose();
  }

  /// 在内容区打开帖子（WS 推送/简单跳转用，保留左侧导航栏）
  void openPostInContent(int postId, String postContent, int? commentId) {
    if (!mounted) return;
    // 浏览历史由 _showPostOverlay 统一记录（此处走 _showPostFromNoticeOverlay，
    // 该方法内部最终也会调用 _showPostOverlay）
    _showPostFromNoticeOverlay(postId, postContent, commentId);
  }

  /// 在内容区打开帖子（完整帖子数据，保留左侧导航栏）
  void openPostFullInContent(Map<String, dynamic> post, int id) {
    if (!mounted) return;
    // 浏览历史由 _showPostOverlay 统一记录
    _showPostOverlay(post, id);
  }

  /// 上报浏览历史（静默，失败不影响打开帖子）
  void _recordBrowseHistory(int postId) {
    if (postId <= 0) return;
    ApiClient.instance.addBrowseHistory(postId).ignore();
  }

  void _onNotifyChanged() {
    if (mounted) setState(() {});
  }

  /// 聊天未读变化：重新汇总所有会话未读，刷新左侧「消息」角标
  void _onChatUnreadChanged() {
    if (!mounted) return;
    ChatStore.instance.totalUnread().then((n) {
      if (!mounted || n == _messageUnread) return;
      setState(() => _messageUnread = n);
    });
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

  // 注意：用 getter 而非 late final，确保每次 build 时 `ProfileView.active`
  // 都能随 `_currentIndex` 实时更新（切到个人中心时刷新收藏列表）。
  List<_NavItem> get _navItems => [
        // 消息入口（广场上方，圆润聊天气泡图标）
        _NavItem(
          Icons.mode_comment_rounded,
          '消息',
          MessagePage(
            key: _messagePageKey,
            currentUserId: _resolveUid(widget.user),
            // 当前用户头像（自己消息气泡组头头像）
            currentUserAvatar: widget.user['avatar']?.toString() ?? '',
            // IndexedStack 保留 State：切回消息页时靠此参数触发刷新
            active: _currentIndex == 0,
            // 聊天标题栏弹出层「进入他的主页」
            onOpenUserProfile: openUserProfile,
          ),
        ),
        _NavItem(
          Icons.space_dashboard_rounded,
          '广场',
          HomeView(
            user: widget.user,
            onOpenPublish: _showPublishOverlay,
            onOpenPost: _showPostOverlay,
          ),
        ),
        // 星球入口（广场下方、我的上方）：3D 地球展示
        _NavItem(
          Icons.public_rounded,
          '星球',
          // IndexedStack 保留 State：切回探索页时 active 置 true，
          // 触发立即静默刷新 + 启动每 60 秒轮询；离开页面自动停止
          PlanetPage(active: _currentIndex == 2),
        ),
        _NavItem(
          Icons.person_rounded,
          '我的',
          ProfileView(
            user: widget.user,
            onLogout: widget.onLogout,
            active: _currentIndex == 3,
            onUserChanged: (_) {
              // 个人中心修改资料（昵称/头像）后触发刷新，让左侧头像等同步更新。
              // ProfileView 会直接更新共享的 user map，这里只需触发 rebuild。
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
            onOpenUserProfile: openUserProfile,
            onOpenRelationList: openRelationList,
          ),
        ),
        _NavItem(
          Icons.settings_outlined,
          '',
          SettingsView(
            theme: widget.theme,
            user: widget.user,
            onLogout: widget.onLogout,
          ),
        ),
      ];

  /// 侧边栏宽度（Finder 风格：图标 + 文字），双端统一
  static const double _macRailWidth = 150;

  /// 导航栏实际宽度：双端统一 Finder 风格侧边栏（宽 150），方便统一修改
  double get _effectiveRailWidth => _macRailWidth;

  /// 切换导航 tab（同时清空内容区覆盖页）
  void _switchTab(int index) {
    setState(() {
      _macOverlay = null;
      _currentIndex = index;
    });
  }

  /// 聊天离线通知点击：切到消息 tab 并打开指定好友会话
  void openChatWithPeer(int peerId) {
    if (!mounted || peerId <= 0) return;
    if (_currentIndex != 0) {
      setState(() {
        _macOverlay = null;
        _currentIndex = 0;
      });
    }
    // 切 tab 后消息页重建/状态就绪，延迟一帧调用确保可用
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _messagePageKey.currentState?.openChatWithPeer(peerId);
    });
  }

  /// 在内容区显示发帖页覆盖（保留导航栏）
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
              onOpenUserProfile: openUserProfile,
            );
          });
        },
      );
    });
  }

  /// 在内容区显示帖子详情覆盖（保留导航栏）
  ///
  /// 所有打开帖子详情的最终入口（广场卡片、个人中心动态/收藏/历史、
  /// 他人主页、WS 推送/通知）——统一在这里记录浏览历史。
  void _showPostOverlay(Map<String, dynamic> post, int id) {
    _recordBrowseHistory(id);
    final currentUid = _resolveUid(widget.user);
    setState(() {
      _macOverlay = PostDetailPage(
        postBrief: post,
        postId: id,
        currentUserId: currentUid,
        embedded: true,
        onBack: () => setState(() => _macOverlay = null),
        onOpenUserProfile: openUserProfile,
      );
    });
  }

  /// 在内容区打开隐私设置页（保留左侧导航栏，不遮挡）
  void openPrivacySettings() {
    if (!mounted) return;
    setState(() {
      _macOverlay = PrivacySettingsPage(
        embedded: true,
        onBack: () => setState(() => _macOverlay = null),
      );
    });
  }

  /// 在内容区打开关系列表页（互相关注/关注/粉丝，保留左侧导航栏，不遮挡）
  void openRelationList(int initialTab) {
    if (!mounted) return;
    setState(() {
      _macOverlay = RelationListPage(
        initialTab: initialTab,
        embedded: true,
        onBack: () => setState(() => _macOverlay = null),
        onOpenUserProfile: openUserProfile,
      );
    });
  }

  /// 打开个人中心
  ///
  /// 目标用户 = 自己：切换左侧导航到「我的」tab（并清空内容区覆盖层）；
  /// 目标用户 = 他人：内容区覆盖打开他人主页（保留左侧导航栏，不遮挡）。
  void openUserProfile(int uid, String nickname, String avatar) {
    if (!mounted || uid <= 0) return;
    final currentUid = _resolveUid(widget.user);
    if (uid == currentUid) {
      // 自己 → 切到「我的」页面（0=消息 1=广场 2=遇见 3=我的）
      setState(() {
        _macOverlay = null;
        _currentIndex = 3;
      });
      return;
    }
    setState(() {
      _macOverlay = UserProfilePage(
        targetUid: uid,
        nickname: nickname,
        avatar: avatar,
        embedded: true,
        onBack: () => setState(() => _macOverlay = null),
      );
    });
  }

  /// 从通知打开帖子，用内容区覆盖（保留左侧导航栏，可定位到评论）
  void _showPostFromNoticeOverlay(
      int postId, String postContent, int? commentId) {
    _recordBrowseHistory(postId);
    final currentUid = _resolveUid(widget.user);
    setState(() {
      _macOverlay = PostDetailPage(
        postBrief: {'id': postId, 'content': postContent},
        postId: postId,
        currentUserId: currentUid,
        embedded: true,
        focusCommentId: (commentId != null && commentId > 0) ? commentId : null,
        onBack: () => setState(() => _macOverlay = null),
        onOpenUserProfile: openUserProfile,
      );
    });
  }

  /// 侧边栏：Finder 风格（宽栏，图标 + 文字，左对齐）
  /// Windows 顶部为应用 logo（保持原尺寸，不受右侧顶栏影响）；
  /// macOS 顶部为红黄绿安全区（容纳原生红黄绿按钮），不显示 logo
  Widget _buildMacRail(Brightness b) {
    return Column(
      children: [
        if (Platform.isMacOS)
          // macOS 红黄绿安全区：导航栏顶部留白，让原生按钮悬浮其上
          SizedBox(
            height: 20,
            child: Container(
              width: kMacTrafficLightWidth,
              color: bgSoftColor(b),
            ),
          )
        else
          // Windows 应用 logo（保持原位置/尺寸，与右侧顶栏互不影响）
          // 仅增大顶部留白让 logo 下移，底部留白固定，不推挤下方导航项
          const Padding(
            padding: EdgeInsets.fromLTRB(0, 32, 0, 12),
            child: Image(
              image: AssetImage(AppConfig.assetLogo),
              width: 40,
              height: 40,
              fit: BoxFit.contain,
            ),
          ),
        // 顶部留白：让导航项避开顶栏区域，与 Finder 侧边栏间距一致
        const SizedBox(height: 16),
        // 导航项（消息，广场上方）；未读聊天消息总数角标
        MacRailItem(
          icon: Icons.mode_comment_rounded,
          label: '消息',
          selected: _currentIndex == 0,
          brightness: b,
          badge: _messageUnread,
          onTap: () => _switchTab(0),
        ),
        // 导航项（广场）
        MacRailItem(
          icon: Icons.space_dashboard_rounded,
          label: '广场',
          selected: _currentIndex == 1,
          brightness: b,
          onTap: () => _switchTab(1),
        ),
        // 导航项（星球，广场下方、我的上方）：带土星环图标
        MacRailItem(
          icon: Icons.public_rounded,
          label: '探索',
          selected: _currentIndex == 2,
          brightness: b,
          saturnRing: true,
          onTap: () => _switchTab(2),
        ),
        // 导航项（个人中心）
        MacRailItem(
          icon: Icons.person_rounded,
          label: '我的',
          selected: _currentIndex == 3,
          brightness: b,
          onTap: () => _switchTab(3),
        ),
        const Spacer(),
        // 通知（双端统一：作为 tab 内嵌）
        MacRailItem(
          icon: Icons.notifications_none_rounded,
          label: '通知',
          selected: _currentIndex == _notificationIndex,
          brightness: b,
          badge: NotificationCenter.instance.unread,
          onTap: () => _switchTab(_notificationIndex),
        ),
        // 设置
        MacRailItem(
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

  /// 侧边栏：实心版本，所有平台统一为不透明实心背景
  Widget _buildSidebar(Brightness b) {
    final rail = _buildMacRail(b);
    return Container(
      width: _effectiveRailWidth,
      color: bgSoftColor(b),
      child: rail,
    );
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    // 实心版本：窗口整体为不透明实心背景，无玻璃效果
    return Scaffold(
      // 探索页（星球页，index 2）：顶栏/内容/底层背景三方同色，
      // 避免 Windows DPI 缩放下顶栏与内容间亚像素缝隙露出浅色背景形成分割线
      backgroundColor: _currentIndex == 2
          ? (b == Brightness.dark ? kSpaceBg : kSpaceBgDay)
          : bgColor(b),
      body: Row(
        children: [
          // 左侧导航栏（副区块背景，无边框，Finder 风格，双端一致；实心不透明）
          // 顶部为 logo（Windows）或红黄绿安全区（macOS），与右侧顶栏互不影响
          _buildSidebar(b),

          // 右侧内容区：顶部自绘顶栏 + 下方内容
          Expanded(
            child: Column(
              children: [
                // 自绘顶栏（macOS：红黄绿安全区 + 无窗口按钮；Windows：窗口按钮），仅占内容区
                // 消息页（index 0）：macOS 不显示顶栏（消息页顶到窗口顶）；
                // Windows 顶栏保留但背景用 bgSoftColor 与左侧导航栏一致
                if (!Platform.isMacOS || _currentIndex != 0)
                  TitleBar(
                    brightness: b,
                    // 消息页：bgSoftColor 与左侧导航栏一致；
                    // 探索页（星球页）：跟随星球页背景色（夜间宇宙黑/白天深蓝黑）
                    color: switch (_currentIndex) {
                      0 => bgSoftColor(b),
                      2 => b == Brightness.dark ? kSpaceBg : kSpaceBgDay,
                      _ => null,
                    },
                  ),
                // 下方内容区（无分割线，无边框；实心不透明）
                Expanded(
                  child: Container(
                    // 探索页（星球页，index 2）：顶栏与内容同为深蓝黑/宇宙黑，
                    // 容器改用同色，避免 sub-pixel 缝隙露出浅色背景形成顶栏分割线
                    color: _currentIndex == 2
                        ? (b == Brightness.dark ? kSpaceBg : kSpaceBgDay)
                        : bgColor(b),
                    child: _macOverlay != null
                        // 覆盖页（发帖/详情内嵌，保留导航栏）
                        ? _macOverlay!
                        : IndexedStack(
                            index: _currentIndex,
                            children: [
                              for (final item in _navItems) item.view,
                            ],
                          ),
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
