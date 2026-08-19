import 'dart:io';

import 'package:flutter/material.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../../core/api_client.dart';
import '../../core/app_config.dart';
import '../../core/app_theme.dart';
import '../../widgets/bubble_menu.dart';
import '../../widgets/notify.dart';
import '../../widgets/report_dialog.dart';
import '../../widgets/user_avatar.dart';
import '../home/home_page.dart';
import '../home/masonry_grid.dart';
import '../home/skeleton_grid.dart';
import 'profile_widgets.dart';

/// 他人主页（点用户头像进入）
///
/// 隐私规则：对方将动态/收藏设为「仅自己」时接口返回 `visible=0`，展示锁占位。
class UserProfilePage extends StatefulWidget {
  /// 目标用户 ID
  final int targetUid;

  /// 初始昵称
  final String nickname;

  /// 初始头像
  final String avatar;

  /// 是否以内嵌模式展示（内容区覆盖，保留左侧导航栏）
  final bool embedded;

  /// 内嵌模式下返回回调（由宿主清空覆盖层）
  final VoidCallback? onBack;

  const UserProfilePage({
    super.key,
    required this.targetUid,
    required this.nickname,
    required this.avatar,
    this.embedded = false,
    this.onBack,
  });

  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  int _tab = 0; // 0=动态 1=收藏
  List<Map<String, dynamic>> _posts = [];
  List<Map<String, dynamic>> _favorites = [];
  bool _loadingPosts = true;
  bool _loadingFavs = true;
  bool _postsVisible = true; // visible=0 表示对方设了隐私
  bool _favsVisible = true;
  bool _failedPosts = false;
  bool _failedFavs = false;

  /// 对方已拉黑我（或我拉黑了对方）：主页内容全部不可见
  bool _blocked = false;

  /// 关注状态
  bool _isFollowing = false;
  bool _isMutual = false;
  bool _followBusy = false;

  @override
  void initState() {
    super.initState();
    _loadPosts();
    _loadFavorites();
    _loadFollowStatus();
  }

  /// 拉取关注状态（我是否关注他 / 是否互相关注）
  Future<void> _loadFollowStatus() async {
    try {
      final resp = await ApiClient.instance
          .getFollowStatus(widget.targetUid)
          .timeout(const Duration(seconds: 15));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (!mounted || json['code'] != 0) return;
      final data = (json['data'] ?? {}) as Map<String, dynamic>;
      setState(() {
        _isFollowing = (data['is_following'] ?? false) == true;
        _isMutual = (data['is_mutual'] ?? false) == true;
      });
    } catch (_) {
      // 静默失败，不阻塞页面
    }
  }

  /// 关注 / 取消关注（切换）
  Future<void> _toggleFollow() async {
    if (_followBusy) return;
    setState(() => _followBusy = true);
    try {
      final resp = await ApiClient.instance
          .toggleFollow(widget.targetUid)
          .timeout(const Duration(seconds: 15));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (!mounted) return;
      if (json['code'] != 0) {
        NotifyStack.warning(json['msg']?.toString() ?? '操作失败', title: '提示');
        return;
      }
      final data = (json['data'] ?? {}) as Map<String, dynamic>;
      setState(() {
        _isFollowing = (data['is_following'] ?? false) == true;
        _isMutual = (data['is_mutual'] ?? false) == true;
      });
      NotifyStack.success(
        _isFollowing ? '已关注' : '已取消关注',
        title: '提示',
      );
    } catch (_) {
      if (mounted) {
        NotifyStack.warning('操作失败，请稍后重试', title: '提示');
      }
    } finally {
      if (mounted) setState(() => _followBusy = false);
    }
  }

  Future<void> _loadPosts() async {
    setState(() {
      _loadingPosts = true;
      _posts = [];
      _postsVisible = true;
      _failedPosts = false;
    });
    try {
      final resp = await ApiClient.instance.getMyPosts(
        targetUid: widget.targetUid,
        page: 1,
        pageSize: 12,
      );
      final json = ApiClient.safeJsonDecode(resp.body);
      if (!mounted) return;
      if (json['code'] != 0) {
        NotifyStack.warning(json['msg']?.toString() ?? '加载失败', title: '提示');
        setState(() {
          _loadingPosts = false;
          _failedPosts = true;
        });
        return;
      }
      final data = (json['data'] as Map<String, dynamic>?) ?? {};
      final list = (data['list'] as List<dynamic>?) ?? [];
      setState(() {
        _posts =
            list.map((e) => (e as Map<String, dynamic>?) ?? {}).toList();
        _postsVisible = (data['visible'] ?? 1) == 1;
        // 拉黑互不可见：任一接口返回 blocked=1 即整体不可见
        if ((data['blocked'] ?? 0) == 1) _blocked = true;
        _loadingPosts = false;
      });
    } catch (e) {
      if (!mounted) return;
      NotifyStack.warning('动态加载失败，请稍后重试', title: '提示');
      setState(() {
        _loadingPosts = false;
        _failedPosts = true;
      });
    }
  }

  Future<void> _loadFavorites() async {
    setState(() {
      _loadingFavs = true;
      _favorites = [];
      _favsVisible = true;
      _failedFavs = false;
    });
    try {
      final resp = await ApiClient.instance.getMyFavorites(
        targetUid: widget.targetUid,
        page: 1,
        pageSize: 12,
      );
      final json = ApiClient.safeJsonDecode(resp.body);
      if (!mounted) return;
      if (json['code'] != 0) {
        NotifyStack.warning(json['msg']?.toString() ?? '加载失败', title: '提示');
        setState(() {
          _loadingFavs = false;
          _failedFavs = true;
        });
        return;
      }
      final data = (json['data'] as Map<String, dynamic>?) ?? {};
      final list = (data['list'] as List<dynamic>?) ?? [];
      setState(() {
        _favorites =
            list.map((e) => (e as Map<String, dynamic>?) ?? {}).toList();
        _favsVisible = (data['visible'] ?? 1) == 1;
        // 拉黑互不可见：任一接口返回 blocked=1 即整体不可见
        if ((data['blocked'] ?? 0) == 1) _blocked = true;
        _loadingFavs = false;
      });
    } catch (e) {
      if (!mounted) return;
      NotifyStack.warning('收藏加载失败，请稍后重试', title: '提示');
      setState(() {
        _loadingFavs = false;
        _failedFavs = true;
      });
    }
  }

  /// 拉黑关系占位标签（不能关注，展示"已被拉黑"）
  Widget _buildBlockedTag(Brightness b) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      decoration: BoxDecoration(
        color: bgSoftColor(b),
        borderRadius: BorderRadius.circular(kRadiusFull),
      ),
      child: Text(
        '已被拉黑',
        style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: textFaintColor(b)),
      ),
    );
  }

  /// 关注按钮（互相关注 → "互相关注"；已关注 → "已关注"；未关注 → "关注"）
  /// 已关注/互相关注：胶囊 + 左侧导航栏背景色（bgSoftColor）；未关注：kPrimary 蓝底
  Widget _buildFollowButton(Brightness b) {
    final String label;
    final Color bg;
    final Color fg;
    if (_isMutual) {
      label = '互相关注';
      bg = bgSoftColor(b);
      fg = textColor(b);
    } else if (_isFollowing) {
      label = '已关注';
      bg = bgSoftColor(b);
      fg = textColor(b);
    } else {
      label = '关注';
      bg = kPrimary;
      fg = Colors.white;
    }
    return InkWell(
      onTap: _followBusy ? null : _toggleFollow,
      mouseCursor: SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(kRadiusFull),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(kRadiusFull),
        ),
        child: _followBusy
            ? SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: fg,
                ),
              )
            : Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
      ),
    );
  }

  /// 举报该用户
  void _reportUser() {
    showDialog(
      context: context,
      builder: (_) => ReportDialog(
        targetUid: widget.targetUid,
      ),
    );
  }

  /// 标题栏：与帖子详情页等二级页面一致（embedded：高 48、水平 8px、
  /// macOS 风格返回按钮 40x40/kRadiusMd 圆角/arrow_back_ios_new_rounded 16px、
  /// 标题 15px/w600），标题为「昵称的主页」；右上角省略号气泡 = 举报
  Widget _buildTitleBar(Brightness b, BuildContext context) {
    final title = Text(
      '${widget.nickname}的主页',
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: textColor(b),
      ),
    );
    if (widget.embedded) {
      // 布局与"我的"页 PageScaffold 完全一致：Expanded(title) + 末尾省略号。
      // width: double.infinity 强制撑满 cross axis —— 根因修复：原 SizedBox 未设宽，
      // 在 Column(crossAxisAlignment: start) 下收缩为内容宽 → Row 不撑满 →
      // Expanded/Spacer 失效 → 省略号紧跟标题（看起来"前移"，与弹出层无关）。
      return SizedBox(
        height: 48,
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // macOS 风格返回按钮
              SizedBox(
                width: 40,
                height: 40,
                child: InkWell(
                  borderRadius: BorderRadius.circular(kRadiusMd),
                  onTap: () {
                    if (widget.onBack != null) {
                      widget.onBack!();
                    } else {
                      Navigator.of(context).maybePop();
                    }
                  },
                  mouseCursor: SystemMouseCursors.click,
                  hoverColor: bgHoverColor(b),
                  child: Center(
                    // 图标下移 1px，与 15px 标题文字视觉中线对齐（Material 箭头基线偏上）
                    child: Transform.translate(
                      offset: const Offset(0, 1),
                      child: Icon(Icons.arrow_back_ios_new_rounded,
                          size: 16, color: textMutedColor(b)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              // 标题占满中间空隙（同 PageScaffold），省略号被推到最右
              Expanded(child: title),
              // 右上角省略号：气泡弹出举报
              BubbleMenu(
                width: 140,
                items: [
                  BubbleMenuItem(
                    label: '举报',
                    icon: Icons.flag_outlined,
                    color: kDanger,
                    onTap: _reportUser,
                  ),
                ],
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child:
                      Icon(Icons.more_horiz, size: 22, color: textColor(b)),
                ),
              ),
            ],
          ),
        ),
      );
    }
    // 全屏模式（理论不触发，他人主页默认 embedded）
    return Padding(
      padding: EdgeInsets.fromLTRB(24, Platform.isWindows ? 5 : 20, 24, 4),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: InkWell(
              borderRadius: BorderRadius.circular(kRadiusMd),
              onTap: () => Navigator.of(context).pop(),
              mouseCursor: SystemMouseCursors.click,
              hoverColor: bgHoverColor(b),
              child: Icon(Icons.arrow_back,
                  size: 18, color: textMutedColor(b)),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(child: title),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Scaffold(
      backgroundColor: bgColor(b),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTitleBar(b, context),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    // 他人主页暂无分页加载（骨架迭代）
                    return false;
                  },
                  child: SilkySingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    scrollSpeed: 1.6,
                    silkyScrollDuration: const Duration(milliseconds: 600),
                    animationCurve: Curves.easeOutCubic,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                          minHeight: constraints.maxHeight - 32),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // ===== 用户信息卡（头像 + 昵称 + UID，无编辑入口） =====
                          Card(
                            elevation: 0,
                            color: bgHoverColor(b),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(kRadiusBtn),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Row(
                                children: [
                                  UserAvatar(
                                    avatarUrl: widget.avatar.isEmpty
                                        ? null
                                        : AppConfig.resolveUrl(widget.avatar),
                                    nickname: widget.nickname,
                                    size: 56,
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                widget.nickname,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 18,
                                                  fontWeight:
                                                      FontWeight.w600,
                                                  color: textColor(b),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'UID：${widget.targetUid}',
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: textMutedColor(b),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  // 关注 / 已关注 按钮（互相关注显示"互相关注"；
                                  // 拉黑关系时禁用并显示"已被拉黑"）
                                  const SizedBox(width: 12),
                                  _blocked
                                      ? _buildBlockedTag(b)
                                      : _buildFollowButton(b),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          // ===== 动态 / 收藏 tab =====
                          Row(
                            children: [
                              ProfileTab(
                                label: '动态',
                                count: _posts.length,
                                selected: _tab == 0,
                                onTap: () => setState(() => _tab = 0),
                              ),
                              const SizedBox(width: 8),
                              ProfileTab(
                                label: '收藏',
                                count: _favorites.length,
                                selected: _tab == 1,
                                onTap: () => setState(() => _tab = 1),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          // ===== tab 内容 =====
                          _buildTabContent(b, constraints),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabContent(Brightness b, BoxConstraints constraints) {
    final isPosts = _tab == 0;
    final loading = isPosts ? _loadingPosts : _loadingFavs;
    final failed = isPosts ? _failedPosts : _failedFavs;
    final list = isPosts ? _posts : _favorites;
    final visible = isPosts ? _postsVisible : _favsVisible;
    final columns = _profileColumns(constraints.maxWidth);

    // 拉黑互不可见：动态/收藏等所有记录不可见
    if (_blocked) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.block_rounded,
                size: 40, color: textFaintColor(b).withValues(alpha: 0.6)),
            const SizedBox(height: 12),
            Text(
              '你们之间存在拉黑关系，无法查看 TA 的内容',
              style: TextStyle(fontSize: 14, color: textMutedColor(b)),
            ),
          ],
        ),
      );
    }

    if (loading) {
      return SkeletonGrid(columns: columns);
    }
    if (failed) {
      return FavRetry(
        label: isPosts ? '动态加载失败' : '收藏加载失败',
        onRetry: () => isPosts ? _loadPosts() : _loadFavorites(),
      );
    }
    if (!visible) {
      // 对方设了隐私
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 48),
        decoration: BoxDecoration(
          color: bgHoverColor(b),
          borderRadius: BorderRadius.circular(kRadiusMd),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 40, color: textMutedColor(b)),
            const SizedBox(height: 12),
            Text(
              isPosts ? '对方将「动态」设为仅自己可见' : '对方将「收藏」设为仅自己可见',
              style: TextStyle(fontSize: 14, color: textMutedColor(b)),
            ),
          ],
        ),
      );
    }
    if (list.isEmpty) {
      return EmptyFavorites(
        b: b,
        icon: isPosts ? Icons.dynamic_feed_outlined : Icons.bookmark_border,
        title: isPosts ? '还没有发布任何动态' : '还没有收藏任何帖子',
        subtitle: '',
      );
    }
    return MasonryGrid(
      posts: list,
      columns: columns,
      onPostTap: (p) => _openPostInContent(p),
    );
  }

  /// 列数算法（与个人中心一致）
  int _profileColumns(double width) {
    const minCardWidth = 240.0;
    const gap = 12.0;
    final n = ((width + gap) / (minCardWidth + gap)).floor();
    return n.clamp(1, 6).toInt();
  }

  /// 点击帖子卡片 → 在内容区打开详情
  void _openPostInContent(Map<String, dynamic> p) {
    final id = (p['id'] as num?)?.toInt() ?? 0;
    if (id <= 0) return;
    HomePageState.current?.openPostFullInContent(p, id);
  }
}
