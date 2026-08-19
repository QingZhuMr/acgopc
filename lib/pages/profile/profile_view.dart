import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../../core/api_client.dart';
import '../../core/app_config.dart';
import '../../core/app_theme.dart';
import '../../services/ws_service.dart';
import '../../utils/image_transcoder.dart';
import '../../utils/text_sanitize.dart';
import '../../widgets/bubble_menu.dart';
import '../../widgets/notify.dart';
import '../../widgets/page_scaffold.dart';
import '../../widgets/pick_images.dart';
import '../../widgets/text_input_menu.dart';
import '../../widgets/user_avatar.dart';
import '../home/home_page.dart';
import '../home/masonry_grid.dart';
import '../home/skeleton_grid.dart';
import '../post_detail_page.dart';
import 'avatar_crop.dart';
import 'profile_widgets.dart';

/// 个人中心视图
class ProfileView extends StatefulWidget {
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

  const ProfileView({
    required this.user,
    required this.onLogout,
    required this.onUserChanged,
    this.active = true,
  });

  @override
  State<ProfileView> createState() => ProfileViewState();
}

class ProfileViewState extends State<ProfileView> {
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

  /// 关注 / 粉丝计数（我的页面展示）
  int _followCount = 0;
  int _followerCount = 0;
  bool _followCountsLoaded = false;

  /// 加载关注/粉丝计数
  Future<void> _loadFollowCounts() async {
    if (_followCountsLoaded) return;
    try {
      final resp = await ApiClient.instance
          .getFollowCounts()
          .timeout(const Duration(seconds: 15));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (!mounted || json['code'] != 0) return;
      final data = (json['data'] ?? {}) as Map<String, dynamic>;
      setState(() {
        _followCount = (data['following'] as num?)?.toInt() ?? 0;
        _followerCount = (data['followers'] as num?)?.toInt() ?? 0;
        _followCountsLoaded = true;
      });
    } catch (_) {
      // 静默失败
    }
  }

  /// 打开关系列表页（内容区覆盖，保留左侧导航栏；默认 tab 由入口决定：0=互相关注 1=关注 2=粉丝）
  void _openRelationList(int initialTab) {
    HomePageState.current?.openRelationList(initialTab);
  }

  /// 用户 UID（用户 id）
  String get _uid {
    final raw = _user['id'];
    if (raw == null) return '';
    return raw.toString();
  }

  // ===== 个人中心 tab：0=动态，1=收藏，2=历史 =====
  int _profileTab = 0;

  // ===== 我的动态（只显示我发布的帖子） =====
  final List<Map<String, dynamic>> _myPosts = [];
  int _myPage = 1;
  bool _myLoading = false;
  bool _myLoadingMore = false;
  bool _myAllLoaded = false;
  bool _myLoadFailed = false;

  // ===== 我的收藏 =====
  final List<Map<String, dynamic>> _favorites = [];
  int _favPage = 1;
  bool _favLoading = false;
  bool _favLoadingMore = false;
  bool _favAllLoaded = false;
  bool _favLoadFailed = false;

  // ===== 浏览历史（最多 120 条，服务端跨设备同步） =====
  final List<Map<String, dynamic>> _browseHistory = [];
  bool _hisLoading = false;
  bool _hisLoadFailed = false;
  bool _hisDeleting = false;

  // ===== 对话框加载态 =====
  /// 编辑资料保存中
  bool _savingProfile = false;

  /// 更改密码提交中
  bool _savingPwd = false;

  @override
  void initState() {
    super.initState();
    // 监听钱包余额推送（充值到账后 WS 实时刷新熊爪余额）
    WsService.instance.onWallet = _onWalletPushed;
    // 加载关注/粉丝计数
    _loadFollowCounts();
    // 加载当前 tab 数据（首次进入个人中心，默认「动态」）
    if (widget.active) _loadProfileData();
  }

  @override
  void didUpdateWidget(covariant ProfileView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 从其他 tab 切回个人中心（active 由 false → true）时刷新当前 tab 数据，
    // 保证「广场里发帖/收藏」后切回来能看到最新数据（按需拉取，无轮询开销）。
    if (widget.active && !oldWidget.active) {
      _followCountsLoaded = false;
      _loadFollowCounts();
      _loadProfileData();
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
    return PageScaffold(
      title: '我的',
      actions: [
        // 右上角省略号：更多操作（更改密码 / 退出账户）——气泡样式
        BubbleMenu(
          width: 120,
          itemHeight: 40,
          items: [
            BubbleMenuItem(
              label: '隐私设置',
              icon: Icons.privacy_tip_outlined,
              color: null,
              onTap: () {
                // 内容区覆盖式打开隐私设置页（保留左侧导航栏，不遮挡）
                HomePageState.current?.openPrivacySettings();
              },
            ),
            BubbleMenuItem(
              label: '更改密码',
              icon: Icons.lock_outline,
              color: kPrimary,
              onTap: _openChangePasswordDialog,
            ),
            BubbleMenuItem(
              label: '退出账户',
              icon: Icons.logout,
              color: kDanger,
              onTap: _confirmLogout,
            ),
          ],
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(Icons.more_horiz, size: 22, color: textColor(b)),
          ),
        ),
      ],
      child: LayoutBuilder(
        builder: (context, constraints) {
          return NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
                if (_profileTab == 0) {
                  _loadMoreMyPosts();
                } else {
                  _loadMoreFavorites();
                }
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
                              UserAvatar(
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
                                        StatusBadge(banned: _banned),
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
                              // 关注 / 粉丝入口（熊爪数左侧）
                              CountEntry(
                                label: '关注',
                                count: _followCount,
                                onTap: () => _openRelationList(1),
                              ),
                              const SizedBox(width: 16),
                              CountEntry(
                                label: '粉丝',
                                count: _followerCount,
                                onTap: () => _openRelationList(2),
                              ),
                              const SizedBox(width: 16),
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
                  // ===== 个人中心 tab：动态 / 收藏 / 历史（胶囊切换） =====
                  Padding(
                    padding: const EdgeInsets.only(left: 2, bottom: 12),
                    child: Row(
                      children: [
                        ProfileTab(
                          label: '动态',
                          count: _myPosts.length,
                          selected: _profileTab == 0,
                          onTap: () => _switchTab(0),
                        ),
                        const SizedBox(width: 4),
                        ProfileTab(
                          label: '收藏',
                          count: _favorites.length,
                          selected: _profileTab == 1,
                          onTap: () => _switchTab(1),
                        ),
                        const SizedBox(width: 4),
                        ProfileTab(
                          label: '历史',
                          count: _browseHistory.length,
                          selected: _profileTab == 2,
                          onTap: () => _switchTab(2),
                        ),
                      ],
                    ),
                  ),
                  // ===== 我的动态（只显示我发布的帖子，瀑布流样式同收藏） =====
                  if (_profileTab == 0) ...[
                    if (_myLoading && _myPosts.isEmpty)
                      const SkeletonGrid(columns: 3)
                    else if (_myLoadFailed && _myPosts.isEmpty)
                      FavRetry(label: '动态加载失败', onRetry: _loadMyPosts)
                    else if (_myPosts.isEmpty)
                      EmptyFavorites(
                        b: b,
                        icon: Icons.dynamic_feed_outlined,
                        title: '还没有发布任何动态',
                        subtitle: '去广场点击发帖，分享你的生活吧',
                      )
                    else
                      MasonryGrid(
                        posts: _myPosts,
                        columns: _favColumns(constraints.maxWidth),
                        onPostTap: (p) => _openMyPost(p),
                        onContextMenu: (p) => _myPostMenuItems(p),
                      ),
                    if (_myLoadingMore)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                        ),
                      )
                    else if (!_myAllLoaded && _myPosts.isNotEmpty)
                      const SizedBox(height: 24),
                  ]
                  // ===== 我的收藏（小红书/抖音风格双列瀑布流） =====
                  else if (_profileTab == 1) ...[
                    if (_favLoading && _favorites.isEmpty)
                      const SkeletonGrid(columns: 3)
                    else if (_favLoadFailed && _favorites.isEmpty)
                      FavRetry(onRetry: _loadFavorites)
                    else if (_favorites.isEmpty)
                      EmptyFavorites(b: b)
                    else
                      MasonryGrid(
                        posts: _favorites,
                        columns: _favColumns(constraints.maxWidth),
                        onPostTap: (p) => _openFavPost(p),
                        onContextMenu: (p) => _favMenuItems(p),
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
                  ]
                  // ===== 浏览历史（服务端跨设备，最多 120 条） =====
                  else ...[
                    if (_hisLoading && _browseHistory.isEmpty)
                      const SkeletonGrid(columns: 3)
                    else if (_hisLoadFailed && _browseHistory.isEmpty)
                      FavRetry(label: '历史加载失败', onRetry: _loadBrowseHistory)
                    else if (_browseHistory.isEmpty)
                      EmptyFavorites(
                        b: b,
                        icon: Icons.history_rounded,
                        title: '还没有浏览历史',
                        subtitle: '打开帖子详情后会自动记录在这里',
                      )
                    else ...[
                      // 清空按钮（右上）
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton.icon(
                            onPressed: _hisDeleting
                                ? null
                                : _clearBrowseHistory,
                            icon: Icon(Icons.delete_outline,
                                size: 16,
                                color: _hisDeleting
                                    ? textFaintColor(b)
                                    : kDanger),
                            label: Text(
                              _hisDeleting ? '清空中…' : '清空历史',
                              style: TextStyle(
                                  fontSize: 13, color: kDanger),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      // 按访问日期分组：今天 / 昨天 / 更早（与 formatRelativeTime 自然日一致）
                      ..._buildBrowseHistoryGroups(b, constraints),
                    ],
                  ],
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

  // ===== 我的动态 / 收藏：tab 切换与加载 =====

  /// 切换个人中心 tab（0=动态，1=收藏），首次进入该 tab 且无数据时加载
  void _switchTab(int idx) {
    if (_profileTab == idx) return;
    setState(() => _profileTab = idx);
    if (idx == 0 && _myPosts.isEmpty && !_myLoading && !_myLoadFailed) {
      _loadMyPosts();
    } else if (idx == 1 &&
        _favorites.isEmpty &&
        !_favLoading &&
        !_favLoadFailed) {
      _loadFavorites();
    } else if (idx == 2 &&
        _browseHistory.isEmpty &&
        !_hisLoading &&
        !_hisLoadFailed) {
      _loadBrowseHistory();
    }
  }

  /// 加载当前 tab 数据（进入个人中心 / 从其他 tab 切回时调用）
  void _loadProfileData() {
    if (_profileTab == 0) {
      _loadMyPosts();
    } else if (_profileTab == 1) {
      _loadFavorites();
    } else {
      _loadBrowseHistory();
    }
  }

  // ===== 我的动态：加载 =====

  /// 加载我的动态第一页
  Future<void> _loadMyPosts() async {
    if (_myLoading) return;
    setState(() {
      _myLoading = true;
      _myLoadFailed = false;
      _myPage = 1;
    });
    if (!mounted) return;
    try {
      final resp = await ApiClient.instance
          .getMyPosts(page: 1, pageSize: 12)
          .timeout(const Duration(seconds: 15));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (resp.statusCode == 200 && json['code'] == 0) {
        final list = ((json['data'] ?? {})['list'] ?? []) as List;
        setState(() {
          _myPosts.clear();
          _myPosts.addAll(list.map((e) => Map<String, dynamic>.from(e)));
          _myPage = 1;
          _myAllLoaded = list.length < 12;
          _myLoading = false;
        });
      } else {
        setState(() {
          _myLoading = false;
          _myLoadFailed = true;
        });
      }
    } catch (_) {
      setState(() {
        _myLoading = false;
        _myLoadFailed = true;
      });
    }
  }

  /// 加载更多动态（触底自动加载）
  Future<void> _loadMoreMyPosts() async {
    if (_myLoading || _myLoadingMore || _myAllLoaded || _myPosts.isEmpty) {
      return;
    }
    setState(() => _myLoadingMore = true);
    try {
      final resp = await ApiClient.instance
          .getMyPosts(page: _myPage + 1, pageSize: 12)
          .timeout(const Duration(seconds: 15));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (resp.statusCode == 200 && json['code'] == 0) {
        final list = ((json['data'] ?? {})['list'] ?? []) as List;
        setState(() {
          _myPage++;
          _myPosts.addAll(list.map((e) => Map<String, dynamic>.from(e)));
          _myAllLoaded = list.length < 12;
          _myLoadingMore = false;
        });
      } else {
        setState(() => _myLoadingMore = false);
      }
    } catch (_) {
      setState(() => _myLoadingMore = false);
    }
  }

  /// 动态卡片右键菜单项（删除自己的动态；统一用 BubbleMenu 气泡弹出）
  List<BubbleMenuItem> _myPostMenuItems(Map<String, dynamic> p) {
    final id = (p['id'] as num?)?.toInt() ?? 0;
    return [
      if (id > 0)
        BubbleMenuItem.delete('删除动态', onTap: () => _deleteMyPost(id)),
    ];
  }

  /// 删除自己的动态（确认后删除，成功后从列表移除）
  Future<void> _deleteMyPost(int postId) async {
    final b = Theme.of(context).brightness;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: bgColor(b),
        title: const Text('删除动态'),
        content: const Text('确定要删除这条动态吗？删除后不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: textMutedColor(b))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kDanger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final resp = await ApiClient.instance
          .deletePost(postId: postId)
          .timeout(const Duration(seconds: 15));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (resp.statusCode == 200 && json['code'] == 0) {
        if (mounted) {
          setState(() {
            _myPosts.removeWhere((p) => (p['id'] as num?)?.toInt() == postId);
          });
          NotifyStack.success('动态已删除', title: '提示');
        }
      } else {
        if (mounted) {
          NotifyStack.warning(json['msg']?.toString() ?? '删除失败', title: '提示');
        }
      }
    } catch (_) {
      if (mounted) {
        NotifyStack.warning('删除失败，请稍后重试', title: '提示');
      }
    }
  }

  /// 点击动态卡片 → 打开帖子详情
  Future<void> _openMyPost(Map<String, dynamic> p) async {
    final id = (p['id'] as num?)?.toInt() ?? 0;
    if (id <= 0) return;
    // 双端统一：在内容区打开帖子详情（保留左侧导航栏，不遮盖）
    if (HomePageState.current?.mounted == true) {
      HomePageState.current!.openPostFullInContent(p, id);
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
    // 从详情页返回后刷新动态列表（点赞状态可能变化）
    _loadMyPosts();
  }

  // ===== 我的收藏：加载 =====

  /// 计算收藏瀑布流列数（复用首页瀑布流算法：卡片最小宽约 240，间距 12）
  int _favColumns(double width) {
    const minCardWidth = 240.0;
    const gap = 12.0;
    final n = ((width + gap) / (minCardWidth + gap)).floor();
    return n.clamp(1, 6).toInt();
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

  /// 加载浏览历史（最多 120 条，全量一次性拉取）
  Future<void> _loadBrowseHistory() async {
    if (_hisLoading) return;
    setState(() {
      _hisLoading = true;
      _hisLoadFailed = false;
    });
    if (!mounted) return;
    try {
      final resp = await ApiClient.instance
          .getBrowseHistory()
          .timeout(const Duration(seconds: 15));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (resp.statusCode == 200 && json['code'] == 0) {
        final list = ((json['data'] ?? {})['list'] ?? []) as List;
        setState(() {
          _browseHistory.clear();
          _browseHistory
              .addAll(list.map((e) => Map<String, dynamic>.from(e)));
          _hisLoading = false;
        });
      } else {
        setState(() {
          _hisLoading = false;
          _hisLoadFailed = true;
        });
      }
    } catch (_) {
      setState(() {
        _hisLoading = false;
        _hisLoadFailed = true;
      });
    }
  }

  /// 浏览历史按访问日期分组（今天 / 昨天 / 更早）
  ///
  /// 分组判定与 `formatRelativeTime` 的自然日一致；组内保持服务端返回顺序
  /// （按 browse_at 倒序，重复访问已在服务端去重置顶 → 以最新访问时间为准）。
  List<({String label, List<Map<String, dynamic>> items})> _groupBrowseHistory() {
    final n = DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    final groups = <String, List<Map<String, dynamic>>>{
      '今天': [],
      '昨天': [],
      '更早': [],
    };
    for (final p in _browseHistory) {
      final browseAt = (p['browse_at'] as num?)?.toInt() ?? 0;
      if (browseAt <= 0) {
        groups['更早']!.add(p); // 无时间归"更早"
        continue;
      }
      final t = DateTime.fromMillisecondsSinceEpoch(browseAt * 1000);
      final tDay = DateTime(t.year, t.month, t.day);
      final dayDiff = today.difference(tDay).inDays;
      if (dayDiff <= 0) {
        groups['今天']!.add(p); // 今天（含未来/无时区偏差）
      } else if (dayDiff == 1) {
        groups['昨天']!.add(p); // 昨天
      } else {
        groups['更早']!.add(p); // 更早
      }
    }
    // 只保留非空分组，顺序固定：今天 → 昨天 → 更早
    return [
      for (final label in ['今天', '昨天', '更早'])
        if (groups[label]!.isNotEmpty)
          (label: label, items: groups[label]!),
    ];
  }

  /// 渲染浏览历史分组（每组：日期标题 + 瀑布流）
  List<Widget> _buildBrowseHistoryGroups(
      Brightness b, BoxConstraints constraints) {
    final groups = _groupBrowseHistory();
    final widgets = <Widget>[];
    for (final g in groups) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 10),
          child: Text(
            g.label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: textMutedColor(b),
            ),
          ),
        ),
      );
      widgets.add(
        MasonryGrid(
          posts: g.items,
          columns: _favColumns(constraints.maxWidth),
          onPostTap: (p) => _openHistoryPost(p),
          onContextMenu: (p) => _historyMenuItems(p),
        ),
      );
      widgets.add(const SizedBox(height: 12));
    }
    return widgets;
  }

  /// 清空浏览历史（弹确认框）
  Future<void> _clearBrowseHistory() async {
    if (_hisDeleting) return;
    final b = Theme.of(context).brightness;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: bgColor(b),
        title: const Text('清空浏览历史'),
        content: const Text('确定要清空全部浏览历史吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: textMutedColor(b))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kDanger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _hisDeleting = true);
    try {
      final resp = await ApiClient.instance
          .clearBrowseHistory()
          .timeout(const Duration(seconds: 15));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (resp.statusCode == 200 && json['code'] == 0) {
        setState(() {
          _browseHistory.clear();
          _hisDeleting = false;
        });
      } else {
        if (mounted) {
          NotifyStack.warning(
              json['msg']?.toString() ?? '清空失败', title: '提示');
        }
        setState(() => _hisDeleting = false);
      }
    } catch (_) {
      if (mounted) {
        NotifyStack.warning('清空失败，请稍后重试', title: '提示');
      }
      setState(() => _hisDeleting = false);
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

  /// 收藏卡片右键菜单项（取消收藏；统一用 BubbleMenu 气泡弹出）
  List<BubbleMenuItem> _favMenuItems(Map<String, dynamic> p) {
    final id = (p['id'] as num?)?.toInt() ?? 0;
    return [
      if (id > 0)
        BubbleMenuItem(
          label: '取消收藏',
          icon: Icons.star_border_rounded,
          onTap: () => _unfavoritePost(id),
        ),
    ];
  }

  /// 取消收藏（走已有 togglePostFavorite 接口）
  Future<void> _unfavoritePost(int postId) async {
    try {
      final resp = await ApiClient.instance
          .togglePostFavorite(postId: postId)
          .timeout(const Duration(seconds: 15));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (resp.statusCode == 200 && json['code'] == 0) {
        final faved = (json['data'] ?? {})['is_favorited'] as bool? ?? false;
        if (!faved && mounted) {
          setState(() {
            _favorites.removeWhere(
                (p) => (p['id'] as num?)?.toInt() == postId);
          });
          NotifyStack.success('已取消收藏', title: '提示');
        }
      } else {
        if (mounted) {
          NotifyStack.warning(json['msg']?.toString() ?? '操作失败', title: '提示');
        }
      }
    } catch (_) {
      if (mounted) {
        NotifyStack.warning('操作失败，请稍后重试', title: '提示');
      }
    }
  }

  /// 点击收藏卡片 → 打开帖子详情
  Future<void> _openFavPost(Map<String, dynamic> p) async {
    final id = (p['id'] as num?)?.toInt() ?? 0;
    if (id <= 0) return;
    // 双端统一：在内容区打开帖子详情（保留左侧导航栏，不遮盖）
    if (HomePageState.current?.mounted == true) {
      HomePageState.current!.openPostFullInContent(p, id);
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

  /// 历史卡片右键菜单项（删除该记录；统一用 BubbleMenu 气泡弹出）
  List<BubbleMenuItem> _historyMenuItems(Map<String, dynamic> p) {
    final id = (p['id'] as num?)?.toInt() ?? 0;
    return [
      if (id > 0)
        BubbleMenuItem.delete(
            '删除该记录', onTap: () => _deleteHistoryRecord(id)),
    ];
  }

  /// 删除单条浏览历史（服务端 + 本地）
  Future<void> _deleteHistoryRecord(int postId) async {
    try {
      final resp = await ApiClient.instance
          .deleteBrowseHistory(postId)
          .timeout(const Duration(seconds: 15));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (resp.statusCode == 200 && json['code'] == 0) {
        if (mounted) {
          setState(() {
            _browseHistory.removeWhere(
                (p) => (p['id'] as num?)?.toInt() == postId);
          });
          NotifyStack.success('已删除该记录', title: '提示');
        }
      } else {
        if (mounted) {
          NotifyStack.warning(json['msg']?.toString() ?? '操作失败', title: '提示');
        }
      }
    } catch (_) {
      if (mounted) {
        NotifyStack.warning('操作失败，请稍后重试', title: '提示');
      }
    }
  }

  /// 点击历史卡片 → 打开帖子详情（返回后刷新浏览时间排序）
  Future<void> _openHistoryPost(Map<String, dynamic> p) async {
    final id = (p['id'] as num?)?.toInt() ?? 0;
    if (id <= 0) return;
    if (HomePageState.current?.mounted == true) {
      HomePageState.current!.openPostFullInContent(p, id);
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
    // 从详情页返回后刷新浏览历史（新的浏览会置顶）
    _loadBrowseHistory();
  }

  // ===== 编辑资料 =====

  Future<void> _openEditDialog() async {
    final b = Theme.of(context).brightness;
    final nameCtrl = TextEditingController(text: _nickname);

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
                              child: EditAvatarPreview(
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
                  TextInputBubbleMenu(
                    controller: nameCtrl,
                    child: TextField(
                      controller: nameCtrl,
                      // 禁用系统右键菜单（统一用气泡方案）
                      contextMenuBuilder: (_, __) => const SizedBox.shrink(),
                      // 过滤粘贴/输入的非法 UTF-16 代理项（防渲染崩溃）
                      inputFormatters: const [Utf16SanitizeTextInputFormatter()],
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
                onPressed: _savingProfile
                    ? null
                    : () => _saveProfile(ctx, setDialogState, nameCtrl),
                child: _savingProfile
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

  /// 选择头像图片并裁剪：选图 → 打开裁剪对话框 → 裁剪 PNG → 转码 jpg → 本地预览
  Future<void> _pickAndCropAvatar(StateSetter setDialogState) async {
    try {
      final picked = await pickImages(allowMultiple: false);
      if (picked.isEmpty) return;
      final file = picked.single;

      // 读取原图 bytes（裁剪对话框用）
      final Uint8List sourceBytes = file.bytes;

      // 头像不支持 GIF 动图（未来可作为会员特权）
      if (ImageTranscoder.isGif(sourceBytes)) {
        NotifyStack.warning('头像暂不支持GIF动图，请选择静态图片', title: '提示');
        return;
      }

      // 原始图片 ≤5MB 限制
      if (sourceBytes.length > 5 * 1024 * 1024) {
        NotifyStack.warning('头像图片不能超过5MB', title: '提示');
        return;
      }

      // 打开裁剪对话框
      final cropped = await AvatarCropDialog.show(context, sourceBytes);
      if (cropped == null || !mounted) return;

      // 裁剪成功：统一转码 jpg 再存本地预览（上传/存储都按 JPEG）
      final t = await ImageTranscoder.toJpeg(
          bytes: Uint8List.fromList(cropped), name: 'avatar_cropped.png');
      if (t == null || !mounted) return;
      _selectedAvatarBytes = t.bytes;
      _selectedAvatarName = t.name;
      // 用对话框的 setDialogState 刷新头像预览（对话框是独立 StatefulBuilder，
      // 用 ProfileView 的 setState 不会触发它 rebuild）
      setDialogState(() {});
    } catch (_) {}
  }

  /// 保存资料：若选了新头像先上传，再更新昵称
  Future<void> _saveProfile(
    BuildContext dialogCtx,
    StateSetter setDialogState,
    TextEditingController nameCtrl,
  ) async {
    final nickname = nameCtrl.text.trim();
    if (nickname.isEmpty) {
      NotifyStack.warning('昵称不能为空');
      return;
    }

    // 保存按钮进入加载态
    setDialogState(() => _savingProfile = true);

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
      setState(() => _savingProfile = false);
    }
  }

  /// 打开更改密码对话框
  Future<void> _openChangePasswordDialog() async {
    final b = Theme.of(context).brightness;
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();

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
                  PwdField(
                    label: '原密码',
                    controller: oldCtrl,
                    brightness: b,
                  ),
                  const SizedBox(height: 12),
                  PwdField(
                    label: '新密码',
                    controller: newCtrl,
                    brightness: b,
                  ),
                  const SizedBox(height: 12),
                  PwdField(
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
                onPressed: _savingPwd
                    ? null
                    : () => _savePassword(
                        ctx, setDialogState, oldCtrl, newCtrl, confirmCtrl),
                child: _savingPwd
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

    setDialogState(() => _savingPwd = true); // 进入加载态
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
    } finally {
      setDialogState(() => _savingPwd = false);
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
