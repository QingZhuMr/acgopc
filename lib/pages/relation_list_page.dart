import 'package:flutter/material.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../core/app_theme.dart';
import '../utils/net_image.dart';
import '../widgets/notify.dart';
import '../widgets/secondary_title_bar.dart';

/// 关系列表页（二级页面规范：高 48 标题栏 + 15px/w600 标题 + macOS 风格返回按钮）
///
/// 三个 tab：互相关注（好友）/ 关注 / 粉丝；默认 tab 由入口决定
/// （点击"关注"进入默认关注 tab，点击"粉丝"进入默认粉丝 tab，点击好友数进入互相关注 tab）。
///
/// 数据源：
/// - 互相关注：`/api/user/friends`
/// - 关注：`/api/user/following`
/// - 粉丝：`/api/user/followers`
class RelationListPage extends StatefulWidget {
  /// 初始 tab：0=互相关注 1=关注 2=粉丝
  final int initialTab;

  /// 点击用户 → 打开他人主页（由宿主 `_HomePageState` 传入，内容区覆盖）
  final void Function(int uid, String nickname, String avatar)? onOpenUserProfile;

  /// 是否以内嵌模式展示（内容区覆盖，保留左侧导航栏）
  final bool embedded;

  /// 内嵌模式下点击返回按钮的回调（由宿主清空内容区覆盖层）
  final VoidCallback? onBack;

  const RelationListPage({
    super.key,
    this.initialTab = 1,
    this.onOpenUserProfile,
    this.embedded = false,
    this.onBack,
  });

  @override
  State<RelationListPage> createState() => _RelationListPageState();
}

class _RelationListPageState extends State<RelationListPage> {
  late int _tab;

  final List<Map<String, dynamic>> _friends = [];
  final List<Map<String, dynamic>> _following = [];
  final List<Map<String, dynamic>> _followers = [];

  final Map<int, bool> _loading = {0: false, 1: false, 2: false};
  final Map<int, bool> _loadingMore = {0: false, 1: false, 2: false};
  final Map<int, bool> _allLoaded = {0: false, 1: false, 2: false};
  final Map<int, bool> _failed = {0: false, 1: false, 2: false};
  final Map<int, int> _page = {0: 1, 1: 1, 2: 1};

  /// 关注切换中的 uid
  final Set<int> _followBusy = {};

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab.clamp(0, 2);
    // 预加载当前 tab
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCurrent());
  }

  List<Map<String, dynamic>> get _currentList => switch (_tab) {
        0 => _friends,
        1 => _following,
        2 => _followers,
        _ => _following,
      };

  Future<void> _loadCurrent() async {
    final tab = _tab;
    if (_loading[tab] == true) return;
    setState(() {
      _loading[tab] = true;
      _failed[tab] = false;
    });
    try {
      final resp = await _fetch(tab, page: 1);
      final json = ApiClient.safeJsonDecode(resp.body);
      if (!mounted) return;
      if (json['code'] != 0) {
        NotifyStack.warning(json['msg']?.toString() ?? '加载失败', title: '提示');
        setState(() {
          _loading[tab] = false;
          _failed[tab] = true;
        });
        return;
      }
      final data = (json['data'] ?? {}) as Map<String, dynamic>;
      final list = (data['list'] ?? []) as List;
      setState(() {
        _currentListFor(tab).clear();
        _currentListFor(tab).addAll(list.map((e) => Map<String, dynamic>.from(e)));
        _page[tab] = 1;
        _allLoaded[tab] = !(data['has_more'] ?? false);
        _loading[tab] = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading[tab] = false;
        _failed[tab] = true;
      });
    }
  }

  Future<void> _loadMore() async {
    final tab = _tab;
    if (_loadingMore[tab] == true || _allLoaded[tab] == true) return;
    setState(() => _loadingMore[tab] = true);
    try {
      final resp = await _fetch(tab, page: _page[tab]! + 1);
      final json = ApiClient.safeJsonDecode(resp.body);
      if (!mounted) return;
      if (json['code'] == 0) {
        final data = (json['data'] ?? {}) as Map<String, dynamic>;
        final list = (data['list'] ?? []) as List;
        setState(() {
          _currentListFor(tab)
              .addAll(list.map((e) => Map<String, dynamic>.from(e)));
          _page[tab] = _page[tab]! + 1;
          _allLoaded[tab] = !(data['has_more'] ?? false);
          _loadingMore[tab] = false;
        });
      } else {
        setState(() => _loadingMore[tab] = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loadingMore[tab] = false);
    }
  }

  List<Map<String, dynamic>> _currentListFor(int tab) => switch (tab) {
        0 => _friends,
        1 => _following,
        2 => _followers,
        _ => _following,
      };

  Future<dynamic> _fetch(int tab, {required int page}) {
    switch (tab) {
      case 0:
        return ApiClient.instance.getFriends(page: page, pageSize: 20);
      case 1:
        return ApiClient.instance.getFollowing(page: page, pageSize: 20);
      default:
        return ApiClient.instance.getFollowers(page: page, pageSize: 20);
    }
  }

  /// 关注/取关（切换）
  Future<void> _toggleFollow(int targetUid) async {
    if (_followBusy.contains(targetUid)) return;
    setState(() => _followBusy.add(targetUid));
    try {
      final resp = await ApiClient.instance
          .toggleFollow(targetUid)
          .timeout(const Duration(seconds: 15));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (!mounted) return;
      if (json['code'] != 0) {
        NotifyStack.warning(json['msg']?.toString() ?? '操作失败', title: '提示');
        return;
      }
      final data = (json['data'] ?? {}) as Map<String, dynamic>;
      final isFollowing = (data['is_following'] ?? false) == true;
      // 更新当前列表里该用户的关注状态
      setState(() {
        for (final u in _currentList) {
          if ((u['user_id'] as num?)?.toInt() == targetUid) {
            u['is_following'] = isFollowing;
          }
        }
      });
      NotifyStack.success(isFollowing ? '已关注' : '已取消关注', title: '提示');
    } catch (_) {
      if (mounted) NotifyStack.warning('操作失败，请稍后重试', title: '提示');
    } finally {
      if (mounted) setState(() => _followBusy.remove(targetUid));
    }
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
          Expanded(child: _buildBody(b)),
        ],
      ),
    );
  }

  /// 标题栏：统一复用 SecondaryTitleBar（二级页面通用嵌入式标题栏）
  Widget _buildTitleBar(Brightness b, BuildContext context) {
    return SecondaryTitleBar(
      title: Text(
        '我的关注',
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: textColor(b),
        ),
      ),
      onBack: widget.onBack ?? () => Navigator.of(context).maybePop(),
    );
  }

  Widget _buildBody(Brightness b) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 三个 tab：互相关注 / 关注 / 粉丝
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              _tabItem(b, 0, '互相关注'),
              const SizedBox(width: 8),
              _tabItem(b, 1, '关注'),
              const SizedBox(width: 8),
              _tabItem(b, 2, '粉丝'),
            ],
          ),
        ),
        Expanded(child: _buildList(b)),
      ],
    );
  }

  Widget _tabItem(Brightness b, int index, String label) {
    final selected = _tab == index;
    return InkWell(
      onTap: () {
        if (_tab == index) return;
        setState(() => _tab = index);
        if (_currentListFor(index).isEmpty && _failed[index] != true) {
          _loadCurrent();
        }
      },
      mouseCursor: SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(kRadiusFull),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? primarySoftColor(b) : Colors.transparent,
          borderRadius: BorderRadius.circular(kRadiusFull),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? kPrimary : textSecondaryColor(b),
          ),
        ),
      ),
    );
  }

  Widget _buildList(Brightness b) {
    final tab = _tab;
    final loading = _loading[tab] ?? false;
    final failed = _failed[tab] ?? false;
    final list = _currentListFor(tab);

    if (loading && list.isEmpty) {
      return Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: kPrimary),
      );
    }
    if (failed && list.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败',
                style: TextStyle(fontSize: 13, color: textMutedColor(b))),
            const SizedBox(height: 8),
            TextButton(onPressed: _loadCurrent, child: const Text('重试')),
          ],
        ),
      );
    }
    if (list.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.people_outline_rounded,
                size: 40, color: textFaintColor(b)),
            const SizedBox(height: 12),
            Text(
              switch (tab) {
                0 => '还没有互相关注的好友',
                1 => '还没有关注任何人',
                _ => '还没有粉丝',
              },
              style: TextStyle(fontSize: 14, color: textSecondaryColor(b)),
            ),
          ],
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels >= n.metrics.maxScrollExtent - 80) {
          _loadMore();
        }
        return false;
      },
      child: SilkyListView(
        scrollSpeed: 1.6,
        silkyScrollDuration: const Duration(milliseconds: 600),
        animationCurve: Curves.easeOutCubic,
        children: [
          for (final u in list) _buildUserItem(b, u),
          if (_allLoaded[tab] != true)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildUserItem(Brightness b, Map<String, dynamic> u) {
    final uid = (u['user_id'] as num?)?.toInt() ?? 0;
    final nickname = u['nickname']?.toString() ?? '';
    final avatar = u['avatar']?.toString() ?? '';
    // 互相关注 tab 全部是好友，恒为互关；其余 tab 按接口 is_mutual
    final isMutual = _tab == 0 || (u['is_mutual'] ?? false) == true;
    // 已关注：互关/关注 tab 恒为已关注；粉丝 tab 仅互关才算已关注
    final isFollowing = _tab != 2 || isMutual;
    // 右侧按钮：互相关注 tab 不显示任何操作按钮（全是好友，无关注/取关意义）
    final showFollowBtn = _tab != 0;
    final busy = _followBusy.contains(uid);

    return InkWell(
      onTap: () {
        // 点击用户 → 打开他人主页（由宿主回调，内容区覆盖）
        widget.onOpenUserProfile?.call(uid, nickname, avatar);
      },
      mouseCursor: SystemMouseCursors.click,
      hoverColor: bgHoverColor(b),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            ClipOval(
              child: avatar.isNotEmpty
                  ? NetImage(
                      url: AppConfig.resolveUrl(avatar),
                      width: 40,
                      height: 40,
                      fit: BoxFit.cover,
                      loadingSize: 16,
                    )
                  : _avatarPlaceholder(b, nickname),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                nickname,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: textColor(b),
                ),
              ),
            ),
            if (isMutual) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: primarySoftColor(b),
                  borderRadius: BorderRadius.circular(kRadiusFull),
                ),
                child: Text(
                  '互相关注',
                  style: TextStyle(
                      fontSize: 11, color: kPrimary, fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(width: 8),
            ],
            // 互相关注 tab 无操作按钮；其余 tab 显示 已关注/关注 按钮
            if (showFollowBtn) _followButton(b, uid, isFollowing, busy),
          ],
        ),
      ),
    );
  }

  Widget _followButton(Brightness b, int uid, bool isFollowing, bool busy) {
    final label = isFollowing ? '已关注' : '关注';
    final bg = isFollowing ? bgSoftColor(b) : kPrimary;
    final fg = isFollowing ? textColor(b) : Colors.white;
    return InkWell(
      onTap: busy ? null : () => _toggleFollow(uid),
      mouseCursor: SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(kRadiusFull),
      child: Container(
        // 与左侧「互相关注」胶囊高度一致（vertical 3 + 11px 字号）
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(kRadiusFull),
        ),
        child: busy
            ? const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  // 已关注不加粗（与互相关注胶囊同权重）
                  fontWeight: FontWeight.w400,
                  color: fg,
                ),
              ),
      ),
    );
  }

  Widget _avatarPlaceholder(Brightness b, String nickname) {
    final text = nickname.trim();
    final initial =
        text.isEmpty ? '?' : (text.length <= 2 ? text : text.substring(0, 2));
    return Container(
      width: 40,
      height: 40,
      decoration:
          BoxDecoration(color: primarySoftColor(b), shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
            fontSize: 15, fontWeight: FontWeight.w600, color: kPrimary),
      ),
    );
  }
}
