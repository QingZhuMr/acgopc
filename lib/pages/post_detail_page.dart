import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:silky_scroll/silky_scroll.dart';
import 'package:window_manager/window_manager.dart';

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../core/app_theme.dart';
import '../widgets/notify.dart';
import '../widgets/pick_images.dart';
import '../widgets/sticker_panel.dart';
import '../utils/net_image.dart';
import '../utils/time_format.dart';

/// 帖子详情页（广场动态内容页，参考小红书 PC 端）
///
/// 布局（自上而下）：
///   标题栏（返回 + 标题 + 拖拽区 + 窗口控制）
///   主体 Row：
///     - 左：图片轮播（多图自动轮播 ~4s，单图静止；底部圆点指示器）
///     - 右：上=帖子内容区，中=评论区（楼中楼最多显示 5 条，超出折叠展开），
///           下=评论输入框（表情按钮 + emoji/表情包面板）
class PostDetailPage extends StatefulWidget {
  /// 帖子概要数据（列表卡片带来的，用于立即渲染头部，详情返回后刷新）
  final Map<String, dynamic> postBrief;
  final int postId;
  /// 当前登录用户 id（用于判断帖子/评论是否自己的，决定显示"删除"还是"举报"）
  final int currentUserId;

  /// 是否以内嵌模式展示（macOS 内容区 tab）：无窗口按钮
  final bool embedded;

  /// 内嵌模式下点击返回按钮的回调（macOS 用，由宿主清空内容区覆盖层）
  final VoidCallback? onBack;

  /// 需要定位的评论 id（加载后滚动到该评论位置；楼中楼传其父顶层评论 id）
  final int? focusCommentId;

  /// 是否定位到"最新发布"的评论（true 时发布后由页面内部记录新评论 id 并定位）
  final bool focusNewComment;

  const PostDetailPage({
    super.key,
    required this.postBrief,
    required this.postId,
    this.currentUserId = 0,
    this.embedded = false,
    this.onBack,
    this.focusCommentId,
    this.focusNewComment = false,
  });

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

/// 回复目标（楼中楼）
class _ReplyTarget {
  final int commentId; // 顶层评论 id（parent_id）
  final int replyToUid;
  final String replyToName;
  const _ReplyTarget(this.commentId, this.replyToUid, this.replyToName);
}

/// 待发评论图片（字节 + 文件名）
class _PendingImage {
  final Uint8List bytes;
  final String filename;
  const _PendingImage(this.bytes, this.filename);
}

class _PostDetailPageState extends State<PostDetailPage> {
  static const int _childDefaultShow = 1; // 楼中楼默认展示条数（小红书/抖音式折叠）
  static const int _childExpandStep = 5; // 每次点"展开更多"增加的条数
  static const Duration _carouselInterval = Duration(seconds: 4); // 轮播间隔（小红书风格）

  // 帖子数据
  Map<String, dynamic>? _post;
  bool _loading = true;
  String? _loadError;

  // 评论数据
  final List<Map<String, dynamic>> _comments = [];
  int _commentTotal = 0;
  int _page = 1;
  bool _loadingComments = false;
  bool _allCommentsLoaded = false;

  // 输入
  final TextEditingController _inputCtrl = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  _ReplyTarget? _replyTarget;
  bool _sending = false;
  bool _showPanel = false; // emoji 表情面板开关
  // 评论待发图片（字节 + 文件名 + 本地预览）
  final List<_PendingImage> _pendingImages = [];

  // 输入框展开状态（小红书式：默认收起为"说点什么..."按钮 + 帖子级点赞/收藏）
  bool _inputExpanded = false;

  // 帖子级互动状态（点赞 / 收藏）
  bool _postLiked = false;
  int _postLikeCount = 0;
  bool _postFavorited = false;
  int _postFavoriteCount = 0;

  // 楼中楼展开进度（顶层评论 id → 当前已展示条数，默认 1 条，点"展开更多"每次 +5）
  final Map<int, int> _childShowCount = {};

  // 评论区滚动控制器（用于按评论 id 定位滚动）
  final ScrollController _commentScrollCtrl = ScrollController();

  // 顶层评论 id → GlobalKey（用于 Scrollable.ensureVisible 定位）
  final Map<int, GlobalKey> _commentKeys = {};

  // 待定位评论 id（顶层评论 id；加载完成后滚动到它）
  int? _pendingFocusCommentId;

  // 轮播（无限循环：initialPage 取一个大的中间值，保证首尾都能向前/后翻）
  static const int _carouselBase = 100000;
  final PageController _pageCtrl = PageController(initialPage: _carouselBase);
  Timer? _carouselTimer;
  int _current = 0; // 取模后的当前图片下标（0 ~ n-1）
  int _pageIndex = _carouselBase; // PageView 实际无限下标（用于循环定位）
  bool _carouselPaused = false;

  @override
  void initState() {
    super.initState();
    // 先用列表带来的摘要渲染，详情返回后再用完整数据覆盖
    _post = widget.postBrief;
    _syncPostInteractions(widget.postBrief);
    // 记录待定位评论（外部传入的 focusCommentId）
    _pendingFocusCommentId = widget.focusCommentId;
    _loadPost();
  }

  /// 从帖子数据同步互动状态（详情接口返回后也调用）
  void _syncPostInteractions(Map<String, dynamic> post) {
    _postLiked = (post['is_liked'] as bool?) ?? false;
    _postLikeCount = (post['like_count'] as num?)?.toInt() ?? 0;
    _postFavorited = (post['is_favorited'] as bool?) ?? false;
    _postFavoriteCount = (post['favorite_count'] as num?)?.toInt() ?? 0;
  }

  @override
  void dispose() {
    _carouselTimer?.cancel();
    _pageCtrl.dispose();
    _inputCtrl.dispose();
    _inputFocus.dispose();
    _commentScrollCtrl.dispose();
    super.dispose();
  }

  /// 加载帖子详情 + 第一页评论
  Future<void> _loadPost() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final resp = await ApiClient.instance
          .getPostDetail(postId: widget.postId, page: 1, pageSize: 20);
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] != 0) {
        if (mounted) {
          setState(() {
            _loading = false;
            _loadError = json['msg']?.toString() ?? '加载失败';
          });
        }
        return;
      }
      final data = json['data'] as Map<String, dynamic>? ?? {};
      final post = data['post'] as Map<String, dynamic>? ?? {};
      final list = (data['comments'] as List<dynamic>?) ?? [];
      if (!mounted) return;
      setState(() {
        _post = post;
        _syncPostInteractions(post);
        _comments
          ..clear()
          ..addAll(list.map((e) => (e as Map<String, dynamic>?) ?? {}));
        _commentTotal = (data['comment_total'] as num?)?.toInt() ?? 0;
        _page = 1;
        _allCommentsLoaded = _comments.length >= _commentTotal;
        _loading = false;
        _current = 0;
        _pageIndex = _carouselBase;
      });
      // 无限循环：始终定位到大的中间初始页，保证首尾都能向前/后翻
      if (_pageCtrl.hasClients && _pageCtrl.page?.round() != _carouselBase) {
        _pageCtrl.jumpToPage(_carouselBase);
      }
      _startCarouselIfNeeded();
      // 若存在待定位评论，滚动到对应位置
      _tryFocusComment();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = '加载失败：$e';
        });
      }
    }
  }

  /// 加载更多顶层评论
  Future<void> _loadMoreComments() async {
    if (_loadingComments || _allCommentsLoaded) return;
    setState(() => _loadingComments = true);
    try {
      final resp = await ApiClient.instance.getPostDetail(
          postId: widget.postId, page: _page + 1, pageSize: 20);
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] == 0) {
        final data = json['data'] as Map<String, dynamic>? ?? {};
        final list = (data['comments'] as List<dynamic>?) ?? [];
        if (!mounted) return;
        setState(() {
          _comments.addAll(list.map((e) => (e as Map<String, dynamic>?) ?? {}));
          _page += 1;
          _allCommentsLoaded = _comments.length >= _commentTotal;
        });
      } else {
        _allCommentsLoaded = true;
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingComments = false);
    }
  }

  // ==================== 轮播 ====================

  List<String> get _images {
    final list = (_post?['images'] as List<dynamic>?) ?? const [];
    return list.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
  }

  void _startCarouselIfNeeded() {
    _carouselTimer?.cancel();
    _carouselTimer = null;
    final images = _images;
    if (images.length <= 1) return; // 单图不轮播
    _carouselTimer = Timer.periodic(_carouselInterval, (_) {
      // 鼠标悬停时暂停轮播
      if (!mounted || !_pageCtrl.hasClients || _carouselPaused) return;
      _pageCtrl.animateToPage(
        _pageIndex + 1,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    });
  }

  /// 鼠标悬停：暂停轮播；移开：恢复轮播
  void _setCarouselPaused(bool paused) {
    if (_carouselPaused == paused) return;
    setState(() => _carouselPaused = paused);
  }

  /// 箭头切换（支持循环）：dir = 1 下一张，-1 上一张（基于 PageView 实际下标）
  void _navCarousel(int dir) {
    final images = _images;
    if (images.length <= 1) return;
    _pageCtrl.animateToPage(
      _pageIndex + dir,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
    );
  }

  /// 点击图片放大预览（全屏，支持缩放/翻页）
  void _showImagePreview(int index) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => _ImagePreviewDialog(
        images: _images,
        initialIndex: index,
      ),
    );
  }

  // ==================== 评论交互 ====================

  /// 点击"回复"：设置回复目标并展开输入框
  void _startReply(int commentId, int replyToUid, String replyToName) {
    setState(() {
      _replyTarget = _ReplyTarget(commentId, replyToUid, replyToName);
      _showPanel = false;
      _inputExpanded = true;
    });
    _inputFocus.requestFocus();
  }

  /// 点击"说点什么..."：展开输入框（覆盖按钮与点赞收藏位）
  void _expandInput() {
    setState(() {
      _inputExpanded = true;
      _showPanel = false;
    });
    _inputFocus.requestFocus();
  }

  /// 点击"取消"：收起输入框（往下消失），回到"说点什么..."按钮态
  void _cancelInput() {
    _inputFocus.unfocus();
    setState(() {
      _inputExpanded = false;
      _showPanel = false;
      _replyTarget = null;
      _pendingImages.clear();
    });
    _inputCtrl.clear();
  }

  /// 帖子级点赞 / 取消点赞（切换）
  Future<void> _togglePostLike() async {
    try {
      final resp = await ApiClient.instance.togglePostLike(postId: widget.postId);
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] == 0 && mounted) {
        setState(() {
          _postLiked = (json['data']?['is_liked'] as bool?) ?? !_postLiked;
          _postLikeCount = (json['data']?['like_count'] as num?)?.toInt() ?? _postLikeCount;
        });
      }
    } catch (_) {}
  }

  /// 帖子级收藏 / 取消收藏（切换，★ 星标）
  Future<void> _togglePostFavorite() async {
    try {
      final resp = await ApiClient.instance.togglePostFavorite(postId: widget.postId);
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] == 0 && mounted) {
        setState(() {
          _postFavorited = (json['data']?['is_favorited'] as bool?) ?? !_postFavorited;
          _postFavoriteCount =
              (json['data']?['favorite_count'] as num?)?.toInt() ?? _postFavoriteCount;
        });
      }
    } catch (_) {}
  }

  /// 评论点赞 / 取消点赞（切换），[setComment] 用新数据更新列表中的该评论
  Future<void> _toggleCommentLike(
    Map<String, dynamic> comment,
    void Function(Map<String, dynamic>) setComment,
  ) async {
    final commentId = (comment['id'] as num?)?.toInt() ?? 0;
    if (commentId <= 0) return;
    try {
      final resp = await ApiClient.instance.toggleCommentLike(commentId: commentId);
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] == 0 && mounted) {
        final d = (json['data'] as Map<String, dynamic>?) ?? {};
        setComment({
          ...comment,
          'is_liked': (d['is_liked'] as bool?) ?? !(comment['is_liked'] as bool? ?? false),
          'like_count': (d['like_count'] as num?)?.toInt() ?? (comment['like_count'] as num?)?.toInt() ?? 0,
        });
      }
    } catch (_) {}
  }

  // ==================== 删除 / 举报 ====================

  /// 删除自己的帖子（确认后删除，成功退出详情页回广场）
  Future<void> _deletePost() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除帖子'),
        content: const Text('确定删除这篇帖子吗？删除后不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: textMutedColor(Theme.of(ctx).brightness))),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: kDanger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final resp = await ApiClient.instance.deletePost(postId: widget.postId);
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] != 0) {
        if (mounted) {
          NotifyStack.warning(json['msg']?.toString() ?? '删除失败', title: '提示');
        }
        return;
      }
      if (!mounted) return;
      NotifyStack.success('已删除', title: '提示');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) NotifyStack.warning('删除失败：$e', title: '提示');
    }
  }

  /// 删除自己的评论 / 楼中楼
  Future<void> _deleteComment(int commentId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除评论'),
        content: const Text('确定删除这条评论吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: textMutedColor(Theme.of(ctx).brightness))),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: kDanger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final resp = await ApiClient.instance.deleteComment(commentId: commentId);
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] != 0) {
        if (mounted) {
          NotifyStack.warning(json['msg']?.toString() ?? '删除失败', title: '提示');
        }
        return;
      }
      if (!mounted) return;
      NotifyStack.success('已删除', title: '提示');
      await _loadPost(); // 刷新评论列表
    } catch (e) {
      if (mounted) NotifyStack.warning('删除失败：$e', title: '提示');
    }
  }

  /// 举报帖子或评论（打开举报弹窗）
  Future<void> _reportContent({int? postId, int commentId = 0}) async {
    final pid = postId ?? widget.postId;
    await showDialog(
      context: context,
      builder: (_) => _ReportDialog(
        postId: pid,
        commentId: commentId,
      ),
    );
  }

  /// 发送评论 / 回复（可带图片）
  Future<void> _send() async {
    final content = _inputCtrl.text.trim();
    if (content.isEmpty && _pendingImages.isEmpty) {
      NotifyStack.warning('说点什么吧', title: '提示');
      return;
    }
    if (_sending) return;
    setState(() => _sending = true);
    try {
      final resp = await ApiClient.instance.postComment(
        postId: widget.postId,
        content: content,
        parentId: _replyTarget?.commentId ?? 0,
        replyToUid: _replyTarget?.replyToUid ?? 0,
        images: _pendingImages
            .map((p) => PostImage(p.bytes, p.filename))
            .toList(),
      );
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] != 0) {
        if (mounted) {
          NotifyStack.warning(json['msg']?.toString() ?? '评论失败', title: '提示');
        }
        return;
      }
      if (!mounted) return;
      // 记录待定位评论：楼中楼定位到父顶层评论；一级评论优先用返回的新评论 id，否则定位到第一条
      final newCommentId = (json['data']?['comment_id'] as num?)?.toInt();
      final topCommentId = _replyTarget?.commentId ?? 0;
      if (topCommentId > 0) {
        _pendingFocusCommentId = topCommentId; // 楼中楼：定位父评论块
      } else if (newCommentId != null && newCommentId > 0) {
        _pendingFocusCommentId = newCommentId; // 一级评论：定位新评论
      }
      // 清空输入，收起输入框，刷新评论列表
      _inputCtrl.clear();
      setState(() {
        _replyTarget = null;
        _showPanel = false;
        _inputExpanded = false;
        _pendingImages.clear();
      });
      NotifyStack.success('评论成功', title: '提示');
      await _loadPost();
    } catch (e) {
      if (mounted) NotifyStack.warning('评论失败：$e', title: '提示');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 选择评论图片（最多 1 张，重新选择覆盖之前的）
  Future<void> _pickImages() async {
    if (_pendingImages.length >= 1) {
      NotifyStack.warning('评论最多上传1张图片', title: '提示');
      return;
    }
    final picked = await pickImages(allowMultiple: false);
    if (picked.isEmpty) return;
    final img = picked.single;
    if (img.bytes.length > 10 * 1024 * 1024) {
      NotifyStack.warning('图片超过 10MB，请压缩后上传', title: '提示');
      return;
    }
    final data = img.bytes;
    final name = img.name.isNotEmpty
        ? img.name
        : 'comment_${DateTime.now().millisecondsSinceEpoch}.png';
    // 重新选择覆盖之前的图片
    setState(() {
      _pendingImages.clear();
      _pendingImages.add(_PendingImage(data, name));
    });
  }

  /// 移除待发图片
  void _removePendingImage(int index) {
    if (index < 0 || index >= _pendingImages.length) return;
    setState(() => _pendingImages.removeAt(index));
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Scaffold(
      backgroundColor: bgColor(b),
      body: Column(
        children: [
          _buildTitleBar(b),
          Expanded(child: _buildBody(b)),
        ],
      ),
    );
  }

  /// 标题栏：返回 + 标题 + 拖拽区 + 窗口控制（参考发布页）
  /// macOS 使用原生标题栏：仅保留返回按钮 + 标题，移除拖拽区与窗口控制
  Widget _buildTitleBar(Brightness b) {
    final title = Text(
      '动态详情',
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: textColor(b),
      ),
    );
    // macOS 内嵌模式：保留返回按钮（返回上一层），无红黄绿安全区、无窗口按钮
    if (widget.embedded) {
      return SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
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
                  child: Icon(Icons.arrow_back_ios_new_rounded,
                      size: 16, color: textMutedColor(b)),
                ),
              ),
              title,
              const Spacer(),
            ],
          ),
        ),
      );
    }
    final back = SizedBox(
      width: 46,
      height: 40,
      child: InkWell(
        onTap: () => Navigator.of(context).pop(),
        mouseCursor: SystemMouseCursors.click, // 悬停显示手指
        hoverColor: bgHoverColor(b),
        child: Icon(Icons.arrow_back, size: 18, color: textMutedColor(b)),
      ),
    );
    if (Platform.isMacOS) {
      return SizedBox(
        height: 40,
        child: Row(
          children: [
            // 红黄绿按钮安全距离
            SizedBox(
              width: kMacTrafficLightWidth,
              child: Container(color: bgColor(b)),
            ),
            // macOS 风格返回按钮（更细箭头 + 圆角 hover，与安全区间距合理）
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: SizedBox(
                width: 40,
                height: 40,
                child: InkWell(
                  borderRadius: BorderRadius.circular(kRadiusMd),
                  onTap: () => Navigator.of(context).pop(),
                  mouseCursor: SystemMouseCursors.click,
                  hoverColor: bgHoverColor(b),
                  child: Icon(Icons.arrow_back_ios_new_rounded,
                      size: 16, color: textMutedColor(b)),
                ),
              ),
            ),
            title,
            // 拖拽区（整个标题栏空白处可拖动窗口）
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => windowManager.startDragging(),
              ),
            ),
          ],
        ),
      );
    }
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          back,
          title,
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => windowManager.startDragging(),
            ),
          ),
          _WinButton(icon: Icons.remove, onTap: () => windowManager.minimize()),
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
              icon: Icons.close, isClose: true, onTap: () => windowManager.close()),
        ],
      ),
    );
  }

  Widget _buildBody(Brightness b) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    if (_loadError != null || _post == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: textFaintColor(b)),
            const SizedBox(height: 12),
            Text(_loadError ?? '帖子不存在', style: TextStyle(color: textMutedColor(b))),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _loadPost, child: const Text('重试')),
          ],
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 左：图片轮播（与右侧 5:5 均分）
        Expanded(child: _buildImageArea(b)),
        // 分割线
        Container(width: 1, color: b == Brightness.dark ? DarkColors.border : LightColors.border),
        // 右：内容 + 评论 + 输入框
        Expanded(child: _buildRightPanel(b)),
      ],
    );
  }

  /// 左：图片轮播（多图自动轮播，单图静止，圆点指示器；点击图片放大）
  Widget _buildImageArea(Brightness b) {
    final images = _images;
    if (images.isEmpty) {
      // 纯文本帖子：用算法封面（与广场帖子流一致的"假图片"）
      return _TextCover(
        content: _post?['content']?.toString() ?? '',
        height: double.infinity,
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click, // 点击图片放大查看
      onEnter: (_) => _setCarouselPaused(true),
      onExit: (_) => _setCarouselPaused(false),
      child: Container(
      color: b == Brightness.dark ? const Color(0xFF19191E) : const Color(0xFF0F0F12),
      child: Stack(
        children: [
          Positioned.fill(
            // 无限循环 PageView：itemCount 无穷大，index 对图片数取模
            child: PageView.builder(
              controller: _pageCtrl,
              physics: images.length > 1 ? const PageScrollPhysics() : const NeverScrollableScrollPhysics(),
              onPageChanged: (i) {
                setState(() {
                  _pageIndex = i;
                  _current = i % images.length;
                });
                _startCarouselIfNeeded(); // 手动翻页后重置计时
              },
              itemCount: null, // 无限循环
              itemBuilder: (context, i) {
                final real = i % images.length;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // 点击图片放大查看
                  onTap: () => _showImagePreview(real),
                  child: Center(
                    child: NetImage(
                      url: images[real],
                      fit: BoxFit.contain,
                      width: double.infinity,
                      height: double.infinity,
                      bgColor: Colors.transparent,
                      spinnerColor: Colors.white54,
                      errorIconColor: Colors.white38,
                      errorIconSize: 48,
                    ),
                  ),
                );
              },
            ),
          ),
          // 左右切换箭头（多图时显示，支持循环，小红书风格浮动按钮）
          if (images.length > 1) ...[
            Positioned(
              left: 10,
              top: 0,
              bottom: 0,
              child: Center(
                child: _NavArrow(
                  icon: Icons.chevron_left,
                  onTap: () => _navCarousel(-1),
                ),
              ),
            ),
            Positioned(
              right: 10,
              top: 0,
              bottom: 0,
              child: Center(
                child: _NavArrow(
                  icon: Icons.chevron_right,
                  onTap: () => _navCarousel(1),
                ),
              ),
            ),
          ],
          // 圆点指示器
          if (images.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 14,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < images.length; i++)
                    Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == _current
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.4),
                      ),
                    ),
                ],
              ),
            ),
          // 图片数量角标（多图时显示 1/N，小红书风格）
          if (images.length > 1)
            Positioned(
              top: 12,
              right: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(kRadiusBtn),
                ),
                child: Text(
                  '${_current + 1}/${images.length}',
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                ),
              ),
            ),
        ],
        ),
      ),
    );
  }

  /// 右：内容 + 评论 + 输入框（emoji 表情面板紧贴输入框上方）
  Widget _buildRightPanel(Brightness b) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 评论区
        Expanded(child: _buildCommentList(b)),
        // emoji 表情面板（紧贴底部输入框，带出现/收起动画）
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: _showPanel
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: EmojiPanel(
                    onEmoji: (e) {
                      final idx = _inputCtrl.selection.baseOffset;
                      final text = _inputCtrl.text;
                      final newText = idx >= 0 && idx <= text.length
                          ? text.replaceRange(idx, idx, e)
                          : text + e;
                      _inputCtrl.text = newText;
                      _inputCtrl.selection = TextSelection.collapsed(
                          offset: (idx >= 0 ? idx : text.length) + e.length);
                      _inputFocus.requestFocus();
                    },
                  ),
                )
              : const SizedBox.shrink(),
        ),
        // 底部输入区（带展开/收起动画）
        _buildInputBar(b),
      ],
    );
  }

  /// 评论区列表（正文作为列表顶部 item，随评论一起滚动）
  Widget _buildCommentList(Brightness b) {
    return SilkyListView(
      controller: _commentScrollCtrl,
      padding: const EdgeInsets.only(bottom: 8),
      scrollSpeed: 1.6,
      silkyScrollDuration: const Duration(milliseconds: 600),
      animationCurve: Curves.easeOutCubic,
      children: [
        // ===== 帖子内容区 =====
        _buildPostHeader(b),
        _buildPostContent(b),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text(
                '评论 $_commentTotal',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: textColor(b),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        // ===== 顶层评论 =====
        if (_comments.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Text('还没有评论，来抢沙发～',
                  style: TextStyle(fontSize: 13, color: textFaintColor(b))),
            ),
          )
        else
          for (final c in _comments)
            KeyedSubtree(
              key: _commentKeys[c['id']] ??= GlobalKey(),
              child: _CommentItem(
            comment: c,
            childShowCount: _childShowCount[c['id']] ?? _childDefaultShow,
            currentUserId: widget.currentUserId,
            onReply: () => _startReply(
              (c['id'] as num?)?.toInt() ?? 0,
              (c['user_id'] as num?)?.toInt() ?? 0,
              c['nickname']?.toString() ?? '',
            ),
            onReplyChild: (child) => _startReply(
              (c['id'] as num?)?.toInt() ?? 0,
              (child['user_id'] as num?)?.toInt() ?? 0,
              child['nickname']?.toString() ?? '',
            ),
            onLike: () => _toggleCommentLike(c, (updated) {
              final i = _comments.indexWhere((e) => e['id'] == c['id']);
              if (i >= 0) setState(() => _comments[i] = updated);
            }),
            onLikeChild: (child) => _toggleCommentLike(child, (updated) {
              setState(() {
                final i = _comments.indexWhere((e) => e['id'] == c['id']);
                if (i < 0) return;
                final children = (_comments[i]['children'] as List<dynamic>?) ?? [];
                for (var j = 0; j < children.length; j++) {
                  if (children[j]['id'] == child['id']) {
                    children[j] = updated;
                    break;
                  }
                }
                _comments[i]['children'] = children;
              });
            }),
            onDeleteComment: (commentId) => _deleteComment(commentId),
            onReportComment: (commentId) =>
                _reportContent(postId: widget.postId, commentId: commentId),
            onExpandMore: () {
              setState(() {
                final id = c['id'];
                _childShowCount[id] =
                    (_childShowCount[id] ?? _childDefaultShow) + _childExpandStep;
              });
            },
              ),
            ),
        // ===== 加载更多 =====
        if (!_allCommentsLoaded)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: _loadingComments
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : TextButton(
                      onPressed: _loadMoreComments,
                      child: const Text('加载更多评论'),
                    ),
            ),
          ),
      ],
    );
  }

  /// 滚动定位到指定顶层评论（用 GlobalKey 的 Scrollable.ensureVisible）
  void _scrollToComment(int topCommentId) {
    final key = _commentKeys[topCommentId];
    if (key?.currentContext == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = key?.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        alignment: 0.2,
      );
    });
  }

  /// 在评论加载完成后，若存在待定位评论，展开其楼中楼并滚动定位。
  /// [target] 可以是顶层评论 id 或楼中楼子评论 id，自动解析其父顶层评论 id。
  void _tryFocusComment() {
    final target = _pendingFocusCommentId;
    if (target == null) return;
    _pendingFocusCommentId = null;
    // 解析目标评论的父顶层评论 id（若 target 是楼中楼子评论）
    var topCommentId = target;
    for (final c in _comments) {
      if (c['id'] == target) {
        topCommentId = (c['id'] as num?)?.toInt() ?? target;
        break;
      }
      final children = (c['children'] as List<dynamic>?) ?? [];
      for (final child in children) {
        if ((child['id'] as num?)?.toInt() == target) {
          topCommentId = (c['id'] as num?)?.toInt() ?? target;
          break;
        }
      }
      if (topCommentId != target) break;
    }
    final exists = _comments.any((c) => c['id'] == topCommentId);
    if (!exists) return;
    setState(() {
      _childShowCount[topCommentId] = 1 << 30; // 全部展开该评论的楼中楼，确保子评论可构建
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToComment(topCommentId);
    });
  }

  /// 帖子头部：头像 + 昵称 + 时间
  Widget _buildPostHeader(Brightness b) {
    final post = _post!;
    final nickname = post['nickname']?.toString() ?? '匿名用户';
    final avatar = post['avatar']?.toString() ?? '';
    final createText = post['create_time_text']?.toString() ?? '';
    final location = post['location']?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        children: [
          _AvatarBox(url: avatar.isEmpty ? null : AppConfig.resolveUrl(avatar),
              nickname: nickname, size: 36),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  nickname,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: textColor(b),
                  ),
                ),
                if (createText.isNotEmpty)
                  Text(
                    formatTimeWithLocation(createText, location: location),
                    style: TextStyle(fontSize: 14, color: textFaintColor(b)),
                  ),
              ],
            ),
          ),
          _PostMoreButton(
            isMine: (post['user_id'] as num?)?.toInt() == widget.currentUserId,
            onDelete: _deletePost,
            onReport: () => _reportContent(postId: widget.postId),
          ),
        ],
      ),
    );
  }

  /// 帖子正文（全文，含表情包解析）
  Widget _buildPostContent(Brightness b) {
    final content = _post?['content']?.toString() ?? '';
    if (content.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: SelectableText.rich(
        _buildRichText(b, content, stickerSize: 64),
        style: TextStyle(fontSize: 16, color: textBodyColor(b), height: 1.7),
      ),
    );
  }

  /// 底部输入区（小红书式）：
  ///   - 默认态：一行 "说点什么..." 胶囊按钮 + 帖子级点赞/收藏（★）
  ///   - 展开态：两行高输入框（随行数增高，最多 8 行滚动）+ 下排
  ///     左=表情按钮、右=取消+发送；表情面板贴在输入框上方
  Widget _buildInputBar(Brightness b) {
    return Container(
      decoration: BoxDecoration(
        color: bgColor(b),
        border: Border(
          top: BorderSide(color: b == Brightness.dark ? DarkColors.border : LightColors.border),
        ),
      ),
      padding: EdgeInsets.fromLTRB(12, 8, 12, 10),
      // 评论框出现/收起动画：默认态（一行按钮）与展开态（两行输入框）间平滑过渡
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
        alignment: Alignment.topCenter,
        child: _inputExpanded ? _buildExpandedInput(b) : _buildCollapsedInput(b),
      ),
    );
  }

  /// 默认态：说点什么... + 点赞 + 收藏
  Widget _buildCollapsedInput(Brightness b) {
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: _expandInput,
            mouseCursor: SystemMouseCursors.click, // 悬停显示手指
            borderRadius: BorderRadius.circular(kRadiusCard),
            child: Container(
              height: 36,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: bgHoverColor(b),
                borderRadius: BorderRadius.circular(kRadiusCard),
              ),
              child: Text(
                '说点什么...',
                style: TextStyle(fontSize: 13, color: textFaintColor(b)),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        _PostActionButton(
          icon: _postLiked ? Icons.favorite : Icons.favorite_border,
          iconColor: _postLiked ? kDanger : textMutedColor(b),
          count: _postLikeCount,
          tooltip: '点赞',
          onTap: _togglePostLike,
        ),
        _PostActionButton(
          icon: _postFavorited ? Icons.star_rounded : Icons.star_border_rounded,
          iconColor: _postFavorited ? kWarning : textMutedColor(b),
          count: _postFavoriteCount,
          tooltip: '收藏',
          onTap: _togglePostFavorite,
        ),
      ],
    );
  }

  /// 展开态：两行高输入框（随行数增高，最多 8 行滚动）+ 表情 / 取消 / 发送
  Widget _buildExpandedInput(Brightness b) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      opacity: 1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
        TextField(
          controller: _inputCtrl,
          focusNode: _inputFocus,
          maxLength: 500,
          minLines: 2,
          maxLines: 8,
          style: TextStyle(fontSize: 13, color: textColor(b), height: 1.5),
          decoration: InputDecoration(
            hintText: _replyTarget != null
                ? '@${_replyTarget!.replyToName}'
                : '说点什么...',
            hintStyle: TextStyle(fontSize: 13, color: textFaintColor(b)),
            isDense: true,
            counterText: '',
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            filled: true,
            fillColor: bgHoverColor(b),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(kRadiusBtn),
              borderSide: BorderSide.none,
            ),
          ),
          onSubmitted: (_) => _send(),
        ),
        // 已选图片预览行（评论框与表情按钮之间）
        if (_pendingImages.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SizedBox(
              height: 56,
              child: SilkyListView.separated(
                scrollDirection: Axis.horizontal,
                scrollSpeed: 1.6,
                silkyScrollDuration: const Duration(milliseconds: 600),
                animationCurve: Curves.easeOutCubic,
                itemCount: _pendingImages.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, i) {
                  final p = _pendingImages[i];
                  return Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(kRadiusMd),
                        child: Image.memory(
                          p.bytes,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                        ),
                      ),
                      Positioned(
                        top: 2,
                        right: 2,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click, // 悬停显示手指
                          child: GestureDetector(
                            onTap: () => _removePendingImage(i),
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.6),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.close,
                                  size: 12, color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        const SizedBox(height: 6),
        Row(
          children: [
            // 上传图片按钮
            IconButton(
              onPressed: _pickImages,
              tooltip: '上传图片',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.image_outlined, size: 20),
              color: textMutedColor(b),
            ),
            // emoji 表情按钮
            IconButton(
              onPressed: () {
                setState(() => _showPanel = !_showPanel);
                _inputFocus.requestFocus();
              },
              tooltip: '表情',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                _showPanel ? Icons.emoji_emotions : Icons.emoji_emotions_outlined,
                size: 20,
                color: _showPanel ? kPrimary : textMutedColor(b),
              ),
            ),
            const Spacer(),
            // 取消
            TextButton(
              onPressed: _cancelInput,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                minimumSize: const Size(0, 30),
              ),
              child: Text('取消',
                  style: TextStyle(fontSize: 13, color: textMutedColor(b))),
            ),
            const SizedBox(width: 8),
            // 发送
            SizedBox(
              height: 30,
              child: FilledButton(
                onPressed: _sending ? null : _send,
                style: FilledButton.styleFrom(
                  backgroundColor: kPrimary,
                  disabledBackgroundColor: kPrimary.withValues(alpha: 0.4),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(kRadiusBtn)),
                ),
                child: _sending
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('发送',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ],
      ),
    );
  }

  /// 构建富文本（帖子正文/评论不再渲染表情包，[sticker:id] 按原始标签文本显示）
  TextSpan _buildRichText(Brightness b, String text, {double stickerSize = 18}) {
    return TextSpan(text: text);
  }
}

/// 主贴省略号按钮：自己的帖子=删除，别人的=举报（浮动小菜单）
class _PostMoreButton extends StatelessWidget {
  final bool isMine;
  final VoidCallback onDelete;
  final VoidCallback onReport;

  const _PostMoreButton({
    required this.isMine,
    required this.onDelete,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return _MoreButton(
      iconSize: 20,
      isMine: isMine,
      onDelete: onDelete,
      onReport: onReport,
      iconColor: textFaintColor(b),
    );
  }
}

/// 评论/楼中楼省略号按钮：自己的=删除，别人的=举报（浮动小菜单）
class _CommentMoreButton extends StatelessWidget {
  final bool isMine;
  final double iconSize;
  final VoidCallback onDelete;
  final VoidCallback onReport;

  const _CommentMoreButton({
    required this.isMine,
    required this.onDelete,
    required this.onReport,
    this.iconSize = 16,
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return _MoreButton(
      iconSize: iconSize,
      isMine: isMine,
      onDelete: onDelete,
      onReport: onReport,
      iconColor: textFaintColor(b),
    );
  }
}

/// 通用省略号按钮：点击弹出浮动小菜单（删除 / 举报）
class _MoreButton extends StatelessWidget {
  final double iconSize;
  final bool isMine;
  final VoidCallback onDelete;
  final VoidCallback onReport;
  final Color iconColor;

  const _MoreButton({
    required this.iconSize,
    required this.isMine,
    required this.onDelete,
    required this.onReport,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return PopupMenuButton<String>(
      tooltip: '更多',
      position: PopupMenuPosition.under,
      color: bgColor(b),
      onSelected: (v) {
        if (v == 'delete') {
          onDelete();
        } else if (v == 'report') {
          onReport();
        }
      },
      itemBuilder: (ctx) => isMine
          ? [
              PopupMenuItem(
                value: 'delete',
                height: 30,
                padding: EdgeInsets.zero,
                // 撑满菜单项宽度让文字居中
                child: SizedBox(
                  width: 72,
                  child: const Text('删除',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: kDanger)),
                ),
              ),
            ]
          : [
              PopupMenuItem(
                value: 'report',
                height: 30,
                padding: EdgeInsets.zero,
                child: const SizedBox(
                  width: 72,
                  child: Text('举报',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
      child: MouseRegion(
        cursor: SystemMouseCursors.click, // 悬停显示手指
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Icon(Icons.more_horiz, size: iconSize, color: iconColor),
        ),
      ),
    );
  }
}

/// 可回复区域：鼠标悬停/按下时显示次色调胶囊背景，文字不变色。
///
/// [builder] 接收交互状态（isHover / isPressed），用于决定是否叠加
/// "回复"文字变蓝等细粒度反馈；评论主体文字保持原色。
/// 评论内容区：仅承载"鼠标悬停显示次色调胶囊背景"的视觉反馈动画，
/// 本身不响应点击，发起回复必须点"回复"文字按钮（[_ReplyTextButton]）。
class _ReplyArea extends StatefulWidget {
  final Widget Function(bool hovered) builder;

  const _ReplyArea({required this.builder});

  @override
  State<_ReplyArea> createState() => _ReplyAreaState();
}

class _ReplyAreaState extends State<_ReplyArea> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    // 用"目标色 alpha=0"代替 Colors.transparent：
    // Colors.transparent 是全透明黑（RGB=0），动画中间帧会叠出半透明黑 → hover 时先闪一帧很暗
    final hoverBg = bgHoverColor(b);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      // 悬停时胶囊背景平滑显现/消失（仅 alpha 渐变，RGB 恒定 → 不变暗）
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: _hovered ? hoverBg : hoverBg.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(kRadiusMd),
        ),
        child: widget.builder(_hovered),
      ),
    );
  }
}

/// "回复"文字：仅当鼠标悬停到文字本身时才变蓝
class _ReplyTextButton extends StatefulWidget {
  final VoidCallback onTap;
  final double fontSize;

  const _ReplyTextButton({required this.onTap, this.fontSize = 11});

  @override
  State<_ReplyTextButton> createState() => _ReplyTextButtonState();
}

class _ReplyTextButtonState extends State<_ReplyTextButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: Text(
          '回复',
          style: TextStyle(
            fontSize: widget.fontSize,
            color: _pressed
                ? const Color(0xFF0A6BD1)
                : (_hovered ? const Color(0xFF7AB8FF) : textMutedColor(b)),
            fontWeight:
                (_hovered || _pressed) ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

/// 单条顶层评论（含楼中楼）
class _CommentItem extends StatelessWidget {
  static const int _childExpandStep = 5; // 每次点"展开更多"增加的条数（与 state 侧同步）

  final Map<String, dynamic> comment;
  final int childShowCount;
  final int currentUserId;
  final VoidCallback onReply;
  final ValueChanged<Map<String, dynamic>> onReplyChild;
  final VoidCallback onLike;
  final ValueChanged<Map<String, dynamic>> onLikeChild;
  final ValueChanged<int> onDeleteComment;
  final ValueChanged<int> onReportComment;
  final VoidCallback onExpandMore;

  const _CommentItem({
    required this.comment,
    required this.childShowCount,
    required this.currentUserId,
    required this.onReply,
    required this.onReplyChild,
    required this.onLike,
    required this.onLikeChild,
    required this.onDeleteComment,
    required this.onReportComment,
    required this.onExpandMore,
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final nickname = comment['nickname']?.toString() ?? '匿名用户';
    final avatar = comment['avatar']?.toString() ?? '';
    final content = comment['content']?.toString() ?? '';
    final timeText = comment['create_time_text']?.toString() ?? '';
    final location = comment['location']?.toString() ?? '';
    final isLiked = (comment['is_liked'] as bool?) ?? false;
    final likeCount = (comment['like_count'] as num?)?.toInt() ?? 0;
    final _commentImages = ((comment['images'] as List<dynamic>?) ?? [])
        .map((e) => e.toString())
        .where((s) => s.isNotEmpty)
        .toList();
    final children =
        ((comment['children'] as List<dynamic>?) ?? [])
            .map((e) => (e as Map<String, dynamic>?) ?? {})
            .toList();
    final showCount =
        childShowCount > children.length ? children.length : childShowCount;
    final hidden = children.length - showCount;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头像独立左列（不参与 hover 胶囊、不参与回复点击）
              _AvatarBox(
                url: avatar.isEmpty ? null : AppConfig.resolveUrl(avatar),
                nickname: nickname,
                size: 32,
              ),
              const SizedBox(width: 8),
              // 右侧：昵称(同行右"...") / 内容 / 时间 / 回复·点赞
              Expanded(
                child: _ReplyArea(
                  builder: (_) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 昵称 + 右侧"..."菜单
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              nickname,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: textMutedColor(b),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          // 右侧"..."（更多菜单：自己的=删除，别人的=举报）
                          _CommentMoreButton(
                            isMine: (comment['user_id'] as num?)?.toInt() ==
                                currentUserId,
                            onDelete: () => onDeleteComment(
                                (comment['id'] as num?)?.toInt() ?? 0),
                            onReport: () => onReportComment(
                                (comment['id'] as num?)?.toInt() ?? 0),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      // 顶层评论内容（支持表情包）
                      SelectableText.rich(
                        _buildRichText(b, content),
                        style: TextStyle(
                          fontSize: 16,
                          color: textBodyColor(b),
                          height: 1.6,
                        ),
                      ),
                      // 评论图片（可点击放大 + 下载）
                      if (_commentImages.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        _buildCommentImages(context, b, _commentImages),
                      ],
                      const SizedBox(height: 6),
                      // 时间（在点赞·回复 上面一行）
                      Text(formatTimeWithLocation(timeText, location: location),
                          style: TextStyle(
                              fontSize: 14, color: textFaintColor(b))),
                      // 点赞·回复 同一行
                      Row(
                        children: [
                          _ReplyTextButton(onTap: onReply, fontSize: 14),
                          const Spacer(),
                          _CommentLikeButton(
                            isLiked: isLiked,
                            count: likeCount,
                            onTap: onLike,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          // 楼中楼（与主背景同步，不额外加次色调背景）
          if (children.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(left: 36, top: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < showCount && i < children.length; i++)
                    _buildChild(context, b, children[i]),
                  if (hidden > 0)
                    InkWell(
                      onTap: onExpandMore,
                      mouseCursor: SystemMouseCursors.click, // 悬停显示手指
                      borderRadius: BorderRadius.circular(kRadiusSm),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          hidden > _childExpandStep
                              ? '展开 $_childExpandStep 条回复 ▾'
                              : '展开全部 $hidden 条回复 ▾',
                          style: TextStyle(fontSize: 14, color: kPrimary),
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

  /// 楼中楼子评论：3 行布局（昵称 / @xxx 内容 / 时间·回复 + 最右点赞）
  ///
  /// @ 规则：回层主（reply_to_uid == 顶层 user_id）无 @，回楼中楼有 @
  Widget _buildChild(BuildContext context, Brightness b, Map<String, dynamic> child) {
    final replyToName = child['reply_to_name']?.toString() ?? '';
    final content = child['content']?.toString() ?? '';
    final nickname = child['nickname']?.toString() ?? '';
    final timeText = child['create_time_text']?.toString() ?? '';
    final location = child['location']?.toString() ?? '';
    final topUid = (comment['user_id'] as num?)?.toInt() ?? 0;
    final replyToUid = (child['reply_to_uid'] as num?)?.toInt() ?? 0;
    final showAt = replyToUid > 0 && replyToUid != topUid && replyToName.isNotEmpty;
    final isLiked = (child['is_liked'] as bool?) ?? false;
    final likeCount = (child['like_count'] as num?)?.toInt() ?? 0;
    final childImages = ((child['images'] as List<dynamic>?) ?? [])
        .map((e) => e.toString())
        .where((s) => s.isNotEmpty)
        .toList();
    final childAvatar = child['avatar']?.toString() ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头像独立左列（小红书风格：头像和昵称/内容/时间不在同一垂直线对齐）
          _AvatarBox(
            url: childAvatar.isEmpty ? null : AppConfig.resolveUrl(childAvatar),
            nickname: nickname,
            size: 22,
          ),
          const SizedBox(width: 6),
          // 内容列（hover 显示次色调胶囊动画，发起回复只走"回复"文字按钮）
          Expanded(
            child: _ReplyArea(
              builder: (_) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 行1：昵称 + 最右侧省略号（自己的=删除，别人的=举报）
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          nickname,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: textMutedColor(b),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      _CommentMoreButton(
                        isMine: (child['user_id'] as num?)?.toInt() ==
                            currentUserId,
                        iconSize: 14,
                        onDelete: () => onDeleteComment(
                            (child['id'] as num?)?.toInt() ?? 0),
                        onReport: () => onReportComment(
                            (child['id'] as num?)?.toInt() ?? 0),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  // 行2：@xxx 内容（回层主无 @）
                  RichText(
                    text: TextSpan(
                      style: TextStyle(
                        fontSize: 15,
                        color: textBodyColor(b),
                        height: 1.6,
                      ),
                      children: [
                        if (showAt)
                          TextSpan(
                            text: '@$replyToName ',
                          ),
                        ..._richSpans(b, content),
                      ],
                    ),
                  ),
                  // 楼中楼图片（可点击放大 + 下载）
                  if (childImages.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    _buildCommentImages(context, b, childImages),
                  ],
                  const SizedBox(height: 6),
                  // 时间（在点赞·回复 上面一行）
                  Text(formatTimeWithLocation(timeText, location: location),
                      style: TextStyle(
                          fontSize: 14, color: textFaintColor(b))),
                  // 点赞·回复 同一行
                  Row(
                    children: [
                      _ReplyTextButton(
                          onTap: () => onReplyChild(child), fontSize: 14),
                      const Spacer(),
                      _CommentLikeButton(
                        isLiked: isLiked,
                        count: likeCount,
                        onTap: () => onLikeChild(child),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 评论图片行（小红书风格：横向一排，点击放大 + 下载）
  Widget _buildCommentImages(
      BuildContext context, Brightness b, List<String> images) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final url in images)
          MouseRegion(
            cursor: SystemMouseCursors.click, // 点击图片放大查看
            child: GestureDetector(
              onTap: () => showDialog(
                context: context,
                barrierColor: Colors.black87,
                builder: (_) =>
                    _ImagePreviewDialog(images: images, initialIndex: images.indexOf(url)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(kRadiusMd),
                child: NetImage(
                  url: url,
                  width: 96,
                  height: 96,
                  fit: BoxFit.cover,
                  loadingSize: 16,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 解析内容为富文本 spans（评论/楼中楼不再渲染表情包，[sticker:id] 按标签显示）
  List<InlineSpan> _richSpans(Brightness b, String text) {
    return [TextSpan(text: text)];
  }

  TextSpan _buildRichText(Brightness b, String text) {
    return TextSpan(
      style: TextStyle(fontSize: 15, color: textBodyColor(b), height: 1.5),
      children: _richSpans(b, text),
    );
  }
}

/// 评论点赞按钮（三态）：
///   - 未点赞无数字：空心灰图标
///   - 未点赞有数字：空心灰图标 + 数字
///   - 已点赞：实心红图标 + 数字（数字保持原色，不变红）
class _CommentLikeButton extends StatelessWidget {
  final bool isLiked;
  final int count;
  final VoidCallback onTap;

  const _CommentLikeButton({
    required this.isLiked,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return InkWell(
      onTap: onTap,
      mouseCursor: SystemMouseCursors.click, // 悬停显示手指
      borderRadius: BorderRadius.circular(kRadiusMd),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isLiked ? Icons.favorite : Icons.favorite_border,
              size: 15,
              color: isLiked ? kDanger : textMutedColor(b),
            ),
            if (count > 0) ...[
              const SizedBox(width: 3),
              Text(
                '$count',
                style: TextStyle(fontSize: 11, color: textMutedColor(b)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 帖子级互动按钮（点赞 / 收藏★）：图标 + 数字（无数字时不显示）
class _PostActionButton extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final int count;
  final String tooltip;
  final VoidCallback onTap;

  const _PostActionButton({
    required this.icon,
    required this.iconColor,
    required this.count,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click, // 悬停显示手指
        borderRadius: BorderRadius.circular(kRadiusMd),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: iconColor),
              if (count > 0) ...[
                const SizedBox(width: 4),
                Text(
                  '$count',
                  style: TextStyle(fontSize: 12, color: textMutedColor(b)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 举报弹窗：选择原因 + 可选补充说明，提交后调用服务端举报接口
class _ReportDialog extends StatefulWidget {
  final int postId;
  final int commentId;

  const _ReportDialog({required this.postId, this.commentId = 0});

  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  static const List<(String, String)> _reasons = [
    ('spam', '垃圾广告'),
    ('porn', '色情低俗'),
    ('abuse', '人身攻击'),
    ('ad', '恶意营销'),
    ('infringe', '侵犯权益'),
    ('other', '其他'),
  ];

  String _reason = 'spam';
  final _contentCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _contentCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      final resp = await ApiClient.instance.report(
        postId: widget.postId,
        commentId: widget.commentId,
        reason: _reason,
        content: _contentCtrl.text.trim(),
      );
      final json = ApiClient.safeJsonDecode(resp.body);
      if (!mounted) return;
      if (json['code'] != 0) {
        NotifyStack.warning(json['msg']?.toString() ?? '举报失败', title: '提示');
        return;
      }
      NotifyStack.success('举报成功，我们会尽快处理', title: '提示');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) NotifyStack.warning('举报失败：$e', title: '提示');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return AlertDialog(
      backgroundColor: bgColor(b),
      title: const Text('举报'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('请选择举报原因：'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final (val, label) in _reasons)
                  ChoiceChip(
                    label: Text(label),
                    selected: _reason == val,
                    onSelected: (_) => setState(() => _reason = val),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _contentCtrl,
              maxLength: 500,
              maxLines: 3,
              style: TextStyle(fontSize: 13, color: textColor(b)),
              decoration: InputDecoration(
                hintText: '补充说明（选填）',
                hintStyle: TextStyle(fontSize: 13, color: textFaintColor(b)),
                isDense: true,
                filled: true,
                fillColor: bgHoverColor(b),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(kRadiusMd),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('取消', style: TextStyle(color: textMutedColor(b))),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          style: FilledButton.styleFrom(backgroundColor: kPrimary),
          child: _submitting
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Text('提交举报'),
        ),
      ],
    );
  }
}

/// 头像（网络图 + 首字兜底，与主页 _UserAvatar 同款）
class _AvatarBox extends StatelessWidget {
  final String? url;
  final String nickname;
  final double size;

  const _AvatarBox({required this.url, required this.nickname, this.size = 36});

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final text = nickname.trim();
    final initial = text.isEmpty ? '?' : (text.length <= 2 ? text : text.substring(0, 2));
    final placeholder = Container(
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
    if (url == null || url!.isEmpty) return placeholder;
    return ClipOval(
      child: Image.network(
        url!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        loadingBuilder: (c, child, progress) => progress == null ? child : placeholder,
        errorBuilder: (c, e, s) => placeholder,
      ),
    );
  }
}

/// 窗口控制按钮（最小化 / 最大化 / 关闭）
class _WinButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool isClose;

  const _WinButton({required this.icon, required this.onTap, this.isClose = false});

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return SizedBox(
      width: 46,
      height: 40,
      child: InkWell(
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click, // 悬停显示手指
        hoverColor: isClose ? kDanger.withValues(alpha: 0.15) : bgHoverColor(b),
        child: Icon(icon, size: 16, color: textMutedColor(b)),
      ),
    );
  }
}

/// 全屏图片预览：黑色背景 + 支持缩放（滚轮/拖拽）+ 左右翻页 + 点击关闭
class _ImagePreviewDialog extends StatefulWidget {
  final List<String> images;
  final int initialIndex;

  const _ImagePreviewDialog({required this.images, required this.initialIndex});

  @override
  State<_ImagePreviewDialog> createState() => _ImagePreviewDialogState();
}

class _ImagePreviewDialogState extends State<_ImagePreviewDialog> {
  late final PageController _pageCtrl = PageController(initialPage: widget.initialIndex);
  late int _current = widget.initialIndex;

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageCtrl,
            onPageChanged: (i) => setState(() => _current = i),
            itemCount: widget.images.length,
            itemBuilder: (context, i) => MouseRegion(
              cursor: SystemMouseCursors.click, // 点击空白关闭
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).pop(), // 点击空白关闭
                child: Center(
                  child: InteractiveViewer(
                    maxScale: 4,
                    child: NetImage(
                      url: widget.images[i],
                      fit: BoxFit.contain,
                      bgColor: Colors.transparent,
                      spinnerColor: Colors.white54,
                      errorIconColor: Colors.white38,
                      errorIconSize: 48,
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 顶部：页码 + 下载 + 关闭按钮
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_current + 1}/${widget.images.length}',
                        style: const TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    ),
                    IconButton(
                      onPressed: () => _downloadCurrent(),
                      tooltip: '下载',
                      icon: const Icon(Icons.download_rounded, color: Colors.white, size: 22),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      tooltip: '关闭',
                      icon: const Icon(Icons.close, color: Colors.white, size: 22),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 下载当前图片到系统默认下载目录（Windows：用户主目录\Downloads）
  Future<void> _downloadCurrent() async {
    final url = AppConfig.resolveUrl(widget.images[_current]);
    if (url.isEmpty) return;
    final saved = await downloadImageToDownloads(url);
    if (!mounted) return;
    if (saved != null) {
      NotifyStack.success('已保存到：$saved', title: '下载成功');
    } else {
      NotifyStack.warning('下载失败', title: '提示');
    }
  }
}

/// 下载图片字节到 Windows 默认下载目录（用户主目录\Downloads）
///
/// 返回保存后的完整路径；失败返回 null。目录不存在则自动创建。
Future<String?> downloadImageToDownloads(String url) async {
  try {
    final resp = await http.get(Uri.parse(url));
    if (resp.statusCode != 200) return null;
    final bytes = resp.bodyBytes;
    if (bytes.isEmpty) return null;

    // 解析默认下载目录
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    var downloads = '$home${Platform.pathSeparator}Downloads';
    if (!Directory(downloads).existsSync()) {
      // OneDrive 重定向等场景兜底：用用户主目录
      downloads = home;
    }
    if (!Directory(downloads).existsSync()) {
      try {
        Directory(downloads).createSync(recursive: true);
      } catch (_) {
        return null;
      }
    }

    // 生成唯一文件名：原文件名 + 时间戳，避免覆盖
    final name = _fileNameFromUrl(url);
    final base = name.contains('.') ? name : '$name.png';
    final dot = base.lastIndexOf('.');
    final stem = dot > 0 ? base.substring(0, dot) : base;
    final ext = dot > 0 ? base.substring(dot) : '';
    final file = File('$downloads${Platform.pathSeparator}${stem}_${DateTime.now().millisecondsSinceEpoch}$ext');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  } catch (_) {
    return null;
  }
}

/// 从 URL 提取文件名（含扩展名），无扩展名返回默认名
String _fileNameFromUrl(String url) {
  try {
    final path = Uri.parse(url).pathSegments;
    if (path.isNotEmpty) {
      final last = path.last;
      if (last.isNotEmpty) return last;
    }
  } catch (_) {}
  return 'image.png';
}

/// 图片轮播左右切换箭头（小红书风格：半透明黑底浮动按钮）
class _NavArrow extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _NavArrow({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.35),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        mouseCursor: SystemMouseCursors.click, // 悬停显示手指
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 26, color: Colors.white),
        ),
      ),
    );
  }
}

/// 纯文本帖子的算法封面（与广场帖子流 _TextCover 同款：确定性纯色背景 + 内容文字）
class _TextCover extends StatelessWidget {
  final String content;
  final double height;

  const _TextCover({required this.content, required this.height});

  // 小红书风柔和浅色背景（均配深色文字，保证「背景色不与文字冲突」）
  static const List<Color> _bgColors = [
    Color(0xFFF6A5A5),
    Color(0xFFF2B98D),
    Color(0xFFF0D18A),
    Color(0xFFA9D3A9),
    Color(0xFF8FC7C9),
    Color(0xFF9BB8E8),
    Color(0xFFBFA3E3),
    Color(0xFFE3A3C2),
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
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Text(
        '“$excerpt”',
        maxLines: 8,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: _fgColors[idx],
          fontSize: 20,
          fontWeight: FontWeight.w600,
          height: 1.6,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
