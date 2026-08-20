import 'dart:async';

import 'package:flutter/material.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import '../../utils/text_sanitize.dart';
import '../../widgets/notify.dart';
import '../../widgets/text_input_menu.dart';
import '../post_detail_page.dart';
import '../publish_post_page.dart';
import 'masonry_grid.dart';
import 'skeleton_grid.dart';

/// 广场视图（帖子列表，小红书风格）
class HomeView extends StatefulWidget {
  final Map<String, dynamic> user;

  /// macOS 发帖/详情回调（由主窗口处理内容区覆盖）；非 macOS 为 null 则走原 push
  final VoidCallback? onOpenPublish;
  final void Function(Map<String, dynamic> post, int id)? onOpenPost;

  const HomeView({
    super.key,
    required this.user,
    this.onOpenPublish,
    this.onOpenPost,
  });

  @override
  State<HomeView> createState() => HomeViewState();
}

class HomeViewState extends State<HomeView>
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
      if (mounted) {
        setState(() {
          _loading = false;
          _refreshing = false;
        });
      }
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
          currentUserMap: widget.user,
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
              child: TextInputBubbleMenu(
                controller: _searchCtrl,
                child: TextField(
                controller: _searchCtrl,
                onChanged: _onSearchChanged,
                textInputAction: TextInputAction.search,
                textAlignVertical: TextAlignVertical.center,
                // 禁用系统右键菜单（统一用气泡方案）
                contextMenuBuilder: (_, __) => const SizedBox.shrink(),
                // 过滤粘贴/输入的非法 UTF-16 代理项（防渲染崩溃）
                inputFormatters: const [Utf16SanitizeTextInputFormatter()],
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
            child: SkeletonGrid(columns: columns),
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
                MasonryGrid(
                  posts: _posts,
                  columns: columns,
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
