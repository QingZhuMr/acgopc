import 'dart:io';

import 'package:flutter/material.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../core/app_theme.dart';
import '../utils/net_image.dart';
import '../widgets/notify.dart';
import 'post_detail_page.dart';

/// 他人个人中心页（也可用于查看自己的公开主页）
///
/// 由帖子详情页点击头像/昵称/@昵称进入（内容区覆盖，保留左侧导航栏）。
/// 内容：用户信息卡（头像 + 昵称）+ 动态 / 收藏双 tab。
///
/// 隐私规则：对方将动态/收藏设为「仅自己」时，对应 tab 返回空 list + visible=0，
/// 页面展示「对方设置了隐私」占位。
///
/// 样式遵循 docs/UI规范.md：可滚动区域用 SilkyListView，颜色一律用
/// app_theme.dart 的函数/常量，禁硬编码。
class UserProfilePage extends StatefulWidget {
  /// 目标用户 ID
  final int targetUid;

  /// 初始昵称（点击入口带来的，用于立即渲染，详情返回后刷新）
  final String nickname;

  /// 初始头像（同上）
  final String avatar;

  /// 是否以内嵌模式展示（内容区覆盖，保留左侧导航栏）
  final bool embedded;

  /// 内嵌模式下点击返回按钮的回调（由宿主清空内容区覆盖层）
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
  ApiClient get _api => ApiClient.instance;

  int _tab = 0; // 0=动态 1=收藏

  /// 动态列表
  List<Map<String, dynamic>> _posts = [];

  /// 收藏列表
  List<Map<String, dynamic>> _favorites = [];

  bool _loadingPosts = true;
  bool _loadingFavs = true;

  bool _postsVisible = true; // visible=0 表示对方设了隐私
  bool _favsVisible = true;

  @override
  void initState() {
    super.initState();
    _loadPosts();
    _loadFavorites();
  }

  /// 拉取目标用户动态（target_uid）
  Future<void> _loadPosts() async {
    setState(() {
      _loadingPosts = true;
      _posts = [];
      _postsVisible = true;
    });
    try {
      final resp = await _api.getMyPosts(
        targetUid: widget.targetUid,
        page: 1,
        pageSize: 12,
      );
      final json = ApiClient.safeJsonDecode(resp.body);
      if (!mounted) return;
      if (json['code'] != 0) {
        NotifyStack.warning(json['msg']?.toString() ?? '加载失败', title: '提示');
        setState(() => _loadingPosts = false);
        return;
      }
      final data = (json['data'] as Map<String, dynamic>?) ?? {};
      final list = (data['list'] as List<dynamic>?) ?? [];
      setState(() {
        _posts = list.map((e) => (e as Map<String, dynamic>?) ?? {}).toList();
        _postsVisible = (data['visible'] ?? 1) == 1;
        _loadingPosts = false;
      });
    } catch (e) {
      if (!mounted) return;
      NotifyStack.warning('动态加载失败，请稍后重试', title: '提示');
      setState(() => _loadingPosts = false);
    }
  }

  /// 拉取目标用户收藏（target_uid）
  Future<void> _loadFavorites() async {
    setState(() {
      _loadingFavs = true;
      _favorites = [];
      _favsVisible = true;
    });
    try {
      final resp = await _api.getMyFavorites(
        targetUid: widget.targetUid,
        page: 1,
        pageSize: 12,
      );
      final json = ApiClient.safeJsonDecode(resp.body);
      if (!mounted) return;
      if (json['code'] != 0) {
        NotifyStack.warning(json['msg']?.toString() ?? '加载失败', title: '提示');
        setState(() => _loadingFavs = false);
        return;
      }
      final data = (json['data'] as Map<String, dynamic>?) ?? {};
      final list = (data['list'] as List<dynamic>?) ?? [];
      setState(() {
        _favorites = list.map((e) => (e as Map<String, dynamic>?) ?? {}).toList();
        _favsVisible = (data['visible'] ?? 1) == 1;
        _loadingFavs = false;
      });
    } catch (e) {
      if (!mounted) return;
      NotifyStack.warning('收藏加载失败，请稍后重试', title: '提示');
      setState(() => _loadingFavs = false);
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
          Expanded(
            child: SilkyListView(
              padding: const EdgeInsets.all(16),
              scrollSpeed: 1.6,
              silkyScrollDuration: const Duration(milliseconds: 600),
              animationCurve: Curves.easeOutCubic,
              children: [
                _buildUserCard(b),
                const SizedBox(height: 12),
                _buildTabBar(b),
                const SizedBox(height: 12),
                ..._buildTabContent(b),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 用户信息卡：头像 + 昵称
  Widget _buildUserCard(Brightness b) {
    final avatarUrl = widget.avatar.isEmpty ? null : AppConfig.resolveUrl(widget.avatar);
    return Row(
      children: [
        ClipOval(
          child: avatarUrl != null
              ? Image.network(
                  avatarUrl,
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      _placeholder(b, 56),
                )
              : _placeholder(b, 56),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            widget.nickname,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: textColor(b),
            ),
          ),
        ),
      ],
    );
  }

  Widget _placeholder(Brightness b, double size) {
    final text = widget.nickname.trim();
    final initial =
        text.isEmpty ? '?' : (text.length <= 2 ? text : text.substring(0, 2));
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: primarySoftColor(b), shape: BoxShape.circle),
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
  }

  /// 动态 / 收藏 tab（胶囊切换）
  Widget _buildTabBar(Brightness b) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: bgHoverColor(b),
        borderRadius: BorderRadius.circular(kRadiusBtn),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _tabItem(b, 0, '动态', _posts.length),
          _tabItem(b, 1, '收藏', _favorites.length),
        ],
      ),
    );
  }

  Widget _tabItem(Brightness b, int index, String label, int count) {
    final selected = _tab == index;
    return InkWell(
      onTap: () => setState(() => _tab = index),
      mouseCursor: SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(kRadiusBtn),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Text(
          '$label $count',
          style: TextStyle(
            fontSize: 14,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected
                ? kPrimary
                : textSecondaryColor(b),
          ),
        ),
      ),
    );
  }

  /// tab 内容：加载中 / 隐私占位 / 空态 / 列表
  List<Widget> _buildTabContent(Brightness b) {
    final isPosts = _tab == 0;
    final loading = isPosts ? _loadingPosts : _loadingFavs;
    final list = isPosts ? _posts : _favorites;
    final visible = isPosts ? _postsVisible : _favsVisible;

    if (loading) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: 24),
          child: Center(
            child: CircularProgressIndicator(strokeWidth: 2, color: kPrimary),
          ),
        ),
      ];
    }

    // 对方设了隐私
    if (!visible) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: 24),
          child: Column(
            children: [
              Icon(Icons.lock_outline, size: 40, color: textFaintColor(b)),
              const SizedBox(height: 12),
              Text(
                isPosts ? '对方将「动态」设为仅自己可见' : '对方将「收藏」设为仅自己可见',
                style: TextStyle(fontSize: 14, color: textSecondaryColor(b)),
              ),
            ],
          ),
        ),
      ];
    }

    // 空态
    if (list.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: 24),
          child: Column(
            children: [
              Icon(
                isPosts ? Icons.dynamic_feed_outlined : Icons.star_border_rounded,
                size: 40,
                color: textFaintColor(b),
              ),
              const SizedBox(height: 12),
              Text(
                isPosts ? '还没有发布任何动态' : '还没有收藏任何帖子',
                style: TextStyle(fontSize: 14, color: textSecondaryColor(b)),
              ),
            ],
          ),
        ),
      ];
    }

    // 帖子卡片列表（简洁版）
    return [
      for (final p in list) _buildPostCard(b, p),
    ];
  }

  /// 简洁帖子卡片：内容摘要 + 图片 + 时间
  Widget _buildPostCard(Brightness b, Map<String, dynamic> p) {
    final content = p['content']?.toString() ?? '';
    final timeText = p['create_time_text']?.toString() ?? '';
    final images = ((p['images'] as List<dynamic>?) ?? [])
        .map((e) => e.toString())
        .where((s) => s.isNotEmpty)
        .toList();
    final commentCount = (p['comment_count'] as num?)?.toInt() ?? 0;
    final likeCount = (p['like_count'] as num?)?.toInt() ?? 0;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      color: bgHoverColor(b),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadiusCard)),
      child: InkWell(
        onTap: () {
          // 点击帖子 → 打开帖子详情
          final pid = (p['id'] as num?)?.toInt() ?? 0;
          if (pid <= 0) return;
          _openPost(pid, p);
        },
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(kRadiusCard),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (content.isNotEmpty)
                Text(
                  content,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: textColor(b),
                    height: 1.5,
                  ),
                ),
              if (content.isNotEmpty && images.isNotEmpty) const SizedBox(height: 8),
              if (images.isNotEmpty)
                Row(
                  children: [
                    for (final url in images.take(3))
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(kRadiusSm),
                          child: NetImage(
                            url: AppConfig.resolveUrl(url),
                            width: 72,
                            height: 72,
                            fit: BoxFit.cover,
                            loadingSize: 14,
                          ),
                        ),
                      ),
                  ],
                ),
              if (images.isNotEmpty || content.isNotEmpty) const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.thumb_up_alt_outlined,
                      size: 14, color: textMutedColor(b)),
                  const SizedBox(width: 4),
                  Text('$likeCount',
                      style: TextStyle(fontSize: 12, color: textMutedColor(b))),
                  const SizedBox(width: 12),
                  Icon(Icons.chat_bubble_outline_rounded,
                      size: 14, color: textMutedColor(b)),
                  const SizedBox(width: 4),
                  Text('$commentCount',
                      style: TextStyle(fontSize: 12, color: textMutedColor(b))),
                  const Spacer(),
                  Text(
                    timeText,
                    style: TextStyle(fontSize: 12, color: textMutedColor(b)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 打开帖子详情（内容区覆盖；若自身也是覆盖层则用 Navigator 全屏）
  void _openPost(int pid, Map<String, dynamic> post) {
    // 简化：使用页面自身 context 打开全屏详情（他人主页内不叠覆盖）
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PostDetailPage(
          postBrief: post,
          postId: pid,
          currentUserId: 0,
        ),
      ),
    );
  }

  /// 标题栏（embedded 与全屏模式，遵守双端顶距规范）
  Widget _buildTitleBar(Brightness b, BuildContext context) {
    if (widget.embedded) {
      return SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
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
                  child: Icon(Icons.arrow_back_ios_new_rounded,
                      size: 16, color: textMutedColor(b)),
                ),
              ),
              Text(
                widget.nickname,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: textColor(b),
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
      );
    }

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
              child:
                  Icon(Icons.arrow_back, size: 18, color: textMutedColor(b)),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              widget.nickname,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: textColor(b),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
