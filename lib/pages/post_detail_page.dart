import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:window_manager/window_manager.dart';

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../core/app_theme.dart';
import '../widgets/bubble_menu.dart';
import '../widgets/cached_avatar.dart';
import '../widgets/notify.dart';
import '../widgets/pick_images.dart';
import '../widgets/sticker_panel.dart';
import '../utils/image_download.dart';
import '../utils/image_transcoder.dart';
import '../utils/net_image.dart';
import '../utils/time_format.dart';
import '../utils/text_sanitize.dart';
import '../widgets/report_dialog.dart';
import '../widgets/text_input_menu.dart';

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

  /// 点击头像/昵称/@昵称 → 打开对方个人中心（由宿主 _HomePageState 传入，
  /// 以内容区覆盖方式打开、保留左侧导航栏；null 时降级为 Navigator 全屏）
  final void Function(int uid, String nickname, String avatar)? onOpenUserProfile;

  const PostDetailPage({
    super.key,
    required this.postBrief,
    required this.postId,
    this.currentUserId = 0,
    this.embedded = false,
    this.onBack,
    this.focusCommentId,
    this.focusNewComment = false,
    this.onOpenUserProfile,
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
  // 顶层评论总数（分页基于顶层评论；楼中楼挂载在顶层评论 children 里，不参与分页）
  int _topTotal = 0;
  int _page = 1;
  bool _loadingComments = false;
  bool _allCommentsLoaded = false;

  // 输入
  final TextEditingController _inputCtrl = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  _ReplyTarget? _replyTarget;
  bool _sending = false;
  bool _showPanel = false; // emoji 表情气泡是否打开（图标高亮联动）

  /// emoji 表情气泡 GlobalKey：点击 emoji 后自动收起
  final GlobalKey<BubbleMenuState> _emojiMenuKey =
      GlobalKey<BubbleMenuState>();
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

  // 左侧图片区是否展开（默认展开；点击分割线按钮收起/展开）
  bool _showImagePanel = true;

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
        // 顶层评论总数用于判断是否还有更多；兼容旧接口（无该字段时退化为按全部评论数判断）
        _topTotal =
            (data['comment_top_total'] as num?)?.toInt() ?? _commentTotal;
        _page = 1;
        _allCommentsLoaded = _comments.length >= _topTotal;
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
          _allCommentsLoaded = _comments.length >= _topTotal;
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

  /// 帖子级点赞 / 取消点赞（切换）：先本地乐观渲染，接口失败再回滚并提示
  Future<void> _togglePostLike() async {
    if (!mounted) return;
    final prevLiked = _postLiked;
    final prevCount = _postLikeCount;
    // 乐观更新：立即切换状态与数字，不等接口返回，提升点击响应
    setState(() {
      _postLiked = !prevLiked;
      _postLikeCount = prevCount + (_postLiked ? 1 : -1);
    });
    try {
      final resp = await ApiClient.instance.togglePostLike(postId: widget.postId);
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] == 0 && mounted) {
        setState(() {
          _postLiked = (json['data']?['is_liked'] as bool?) ?? _postLiked;
          _postLikeCount =
              (json['data']?['like_count'] as num?)?.toInt() ?? _postLikeCount;
        });
      } else {
        throw Exception('点赞失败');
      }
    } catch (_) {
      if (!mounted) return;
      // 失败回滚并提示
      setState(() {
        _postLiked = prevLiked;
        _postLikeCount = prevCount;
      });
      NotifyStack.warning('点赞失败，请稍后重试', title: '提示');
    }
  }

  /// 帖子级收藏 / 取消收藏（切换，★ 星标）：先本地乐观渲染，接口失败再回滚并提示
  Future<void> _togglePostFavorite() async {
    if (!mounted) return;
    final prevFavorited = _postFavorited;
    final prevCount = _postFavoriteCount;
    // 乐观更新：立即切换状态与数字，不等接口返回，提升点击响应
    setState(() {
      _postFavorited = !prevFavorited;
      _postFavoriteCount = prevCount + (_postFavorited ? 1 : -1);
    });
    try {
      final resp =
          await ApiClient.instance.togglePostFavorite(postId: widget.postId);
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] == 0 && mounted) {
        setState(() {
          _postFavorited = (json['data']?['is_favorited'] as bool?) ?? _postFavorited;
          _postFavoriteCount =
              (json['data']?['favorite_count'] as num?)?.toInt() ?? _postFavoriteCount;
        });
      } else {
        throw Exception('收藏失败');
      }
    } catch (_) {
      if (!mounted) return;
      // 失败回滚并提示
      setState(() {
        _postFavorited = prevFavorited;
        _postFavoriteCount = prevCount;
      });
      NotifyStack.warning('收藏失败，请稍后重试', title: '提示');
    }
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
      builder: (_) => ReportDialog(
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
    // 客户端统一转码：webp/png/bmp → jpg；GIF 保留动画
    final t = await ImageTranscoder.toJpeg(bytes: img.bytes, name: img.name);
    if (t == null) {
      if (mounted) NotifyStack.warning('图片格式不支持', title: '提示');
      return;
    }
    final data = t.bytes;
    final name = t.name.isNotEmpty
        ? t.name
        : 'comment_${DateTime.now().millisecondsSinceEpoch}.jpg';
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalW = constraints.maxWidth;
        // 图片区宽度：展开时占一半，收起时缩到 0
        final imgW = _showImagePanel ? totalW / 2 : 0.0;
        // 右侧可用宽（图片区 + 折叠按钮之后）
        final rightAvailW = totalW - imgW - 22;
        // 右侧内容最大宽度限制（720px，用于输入框/emoji/评论区内容居中）
        const maxPanelW = 720.0;
        final panelW = rightAvailW < maxPanelW ? rightAvailW : maxPanelW;
        return Stack(
          children: [
            // 左侧图片区（宽度带动画）
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              left: 0,
              top: 0,
              bottom: 0,
              width: imgW,
              child: ClipRect(child: _buildImageArea(b)),
            ),
            // 折叠按钮（跟随图片区右侧边缘）
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              left: imgW - 1,
              top: 0,
              bottom: 0,
              width: 22,
              child: _buildCollapseButton(b),
            ),
            // 右侧内容 + 评论 + emoji + 输入框（横跨右侧全宽：滚动条贴最右；内容内部居中受限）
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              left: imgW + 21,
              top: 0,
              bottom: 0,
              right: 0,
              child: _buildRightPanel(b, panelW),
            ),
          ],
        );
      },
    );
  }

  /// 折叠左侧图片区的按钮：位于分割线处，展开时箭头朝左（◀ 收起），收起时箭头朝右（▶ 展开）
  Widget _buildCollapseButton(Brightness b) {
    return GestureDetector(
      onTap: () => setState(() => _showImagePanel = !_showImagePanel),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          color: bgColor(b),
          alignment: Alignment.center,
          child: AnimatedRotation(
            duration: const Duration(milliseconds: 300),
            // 收起时旋转 180°（0.5 圈）使左箭头变右箭头
            turns: _showImagePanel ? 0 : 0.5,
            child: Icon(
              Icons.chevron_left,
              size: 16,
              color: textMutedColor(b),
            ),
          ),
        ),
      ),
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
      // 白天模式用白天背景色，夜晚用暗色（放大的背景色不变，仍保持深色）
      color: b == Brightness.dark ? const Color(0xFF19191E) : bgColor(b),
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

  /// 右：内容 + 评论（横跨右侧全宽，滚动条贴最右；内容居中受限）
  Widget _buildRightPanel(Brightness b, double panelW) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 评论区（SilkyListView 全宽，滚动条贴最右；内容项最大宽度受限居中）
        Expanded(child: _buildCommentList(b, panelW)),
        // emoji 表情面板已改为表情按钮右上弹 BubbleMenu 气泡（见 _buildExpandedInput）
        // 底部输入框（分割线 + 内容自适应；增高时向上增长，评论区 Expanded 自动让位）
        _buildInputBar(b, panelW),
      ],
    );
  }

  /// 评论区列表（正文作为列表顶部 item，随评论一起滚动）
  Widget _buildCommentList(Brightness b, double panelW) {
    return SilkyListView(
      controller: _commentScrollCtrl,
      padding: const EdgeInsets.only(bottom: 8),
      scrollSpeed: 1.6,
      silkyScrollDuration: const Duration(milliseconds: 600),
      animationCurve: Curves.easeOutCubic,
      children: [
        // ===== 帖子内容区（聊天气泡：头像左右按本人/他人切换，气泡包昵称+正文+时间） =====
        _limitW(panelW, _buildPostBubble(b)),
        const SizedBox(height: 8),
        _limitW(
          panelW,
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
          for (var _ci = 0; _ci < _comments.length; _ci++)
            Builder(builder: (ctx) {
              final c = _comments[_ci];
              // 抖音式头像合并：连续同作者且前一条无楼中楼时隐藏头像
              final prev = _ci > 0 ? _comments[_ci - 1] : null;
              final prevChildren = ((prev?['children'] as List<dynamic>?) ?? []);
              final showAvatar = _ci == 0 ||
                  (prev?['user_id'] as num?)?.toInt() !=
                      (c['user_id'] as num?)?.toInt() ||
                  prevChildren.isNotEmpty;
              return _limitW(
                panelW,
                KeyedSubtree(
              key: _commentKeys[c['id']] ??= GlobalKey(),
              child: _CommentItem(
            comment: c,
            showAvatar: showAvatar,
            childShowCount: _childShowCount[c['id']] ?? _childDefaultShow,
            currentUserId: widget.currentUserId,
            onUserTap: () => _openUserProfile(
              (c['user_id'] as num?)?.toInt() ?? 0,
              c['nickname']?.toString() ?? '',
              c['avatar']?.toString() ?? '',
            ),
            onUserTapChild: (child) {
              final childUid = (child['user_id'] as num?)?.toInt() ?? 0;
              // 点击楼中楼回复者头像/昵称：打开回复者主页
              _openUserProfile(
                childUid,
                child['nickname']?.toString() ?? '',
                child['avatar']?.toString() ?? '',
              );
            },
            onUserTapAt: (replyToUid, replyToName) {
              // 点击 @昵称：打开被@者主页（无头像数据，用首字兜底）
              _openUserProfile(replyToUid, replyToName, '');
            },
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
              );
            }),
        // ===== 加载更多 =====
        if (!_allCommentsLoaded)
          _limitW(
            panelW,
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
          ),
      ],
    );
  }

  /// 限制内容宽度并水平居中（用于评论区内容项最大宽度约束）
  Widget _limitW(double panelW, Widget child) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: panelW),
        child: child,
      ),
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

  /// 帖子聊天气泡：头像左右按本人/他人切换，气泡包昵称 + 正文 + 时间/定位
  /// 本人：头像在右，无省略号，删除按钮放定位右侧（红字）；他人：头像在左，省略号(举报)
  Widget _buildPostBubble(Brightness b) {
    final post = _post!;
    final nickname = post['nickname']?.toString() ?? '匿名用户';
    final avatar = post['avatar']?.toString() ?? '';
    final createText = post['create_time_text']?.toString() ?? '';
    final location = post['location']?.toString() ?? '';
    final content = post['content']?.toString() ?? '';
    final isMine = (post['user_id'] as num?)?.toInt() == widget.currentUserId;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: _ChatBubble(
        isMine: isMine,
        avatarUrl: avatar.isEmpty ? null : AppConfig.resolveUrl(avatar),
        nickname: nickname,
        avatarSize: 36,
        // 主贴昵称在气泡上方：大小不变、加粗，颜色用文字色（本人与他人一致）
        nicknameAbove: true,
        nicknameStyle: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: b == Brightness.light ? Colors.black : Colors.white,
        ),
        contentWidget: content.isEmpty
            ? const SizedBox.shrink()
            : SelectableText.rich(
                _buildRichText(b, content, stickerSize: 64),
                // 禁用系统右键菜单：复制已合并进统一气泡菜单，避免双弹窗
                contextMenuBuilder: (context, editableTextState) =>
                    const SizedBox.shrink(),
                // 本人蓝底气泡：选中背景用黑色（默认蓝选中在蓝底上看不清）
                selectionColor: isMine ? Colors.black : null,
                style: TextStyle(
                    fontSize: 16,
                    color: isMine
                        ? Colors.white
                        : (b == Brightness.light ? Colors.black : Colors.white),
                    height: 1.7),
              ),
        timeText: formatTimeWithLocation(createText, location: location),
        hasLike: false,
        copyText: content,
        // 点击主贴气泡：拉起评论（展开底部输入框聚焦）
        onReply: _expandInput,
        onDelete: isMine ? _deletePost : null,
        onReport: !isMine
            ? () => _reportContent(postId: widget.postId)
            : null,
        // 点击作者头像/昵称 → 打开作者主页
        onUserTap: () => _openUserProfile(
          (post['user_id'] as num?)?.toInt() ?? 0,
          nickname,
          avatar,
        ),
      ),
    );
  }

  /// 打开他人/自己主页（通过宿主 `_HomePageState` 内容区覆盖，保留左侧导航栏）
  void _openUserProfile(int uid, String nickname, String avatar) {
    if (uid <= 0) return;
    final cb = widget.onOpenUserProfile;
    if (cb != null) {
      cb(uid, nickname, avatar);
    }
  }

  /// 底部输入区（小红书式）：
  ///   - 默认态：一行 "说点什么..." 胶囊按钮 + 帖子级点赞/收藏（★）
  ///   - 展开态：两行高输入框（随行数增高，最多 8 行滚动）+ 下排
  ///     左=表情按钮、右=取消+发送；表情面板贴在输入框上方
  Widget _buildInputBar(Brightness b, double panelW) {
    // 分割线横跨右侧可用全宽，内容居中并限制在面板宽度内
    // 左侧 15px 内分割线从右往左渐变消失（避免与折叠按钮占位冲突）
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          decoration: BoxDecoration(
            color: bgColor(b),
            border: Border(
              top: BorderSide(color: b == Brightness.dark ? DarkColors.border : LightColors.border),
            ),
          ),
          // 评论框出现/收起动画：默认态（一行按钮）与展开态（两行输入框）间平滑过渡
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: panelW),
              child: Padding(
                padding: EdgeInsets.fromLTRB(12, 8, 22, 10),
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeInOut,
                  alignment: Alignment.topCenter,
                  child: _inputExpanded ? _buildExpandedInput(b) : _buildCollapsedInput(b),
                ),
              ),
            ),
          ),
        ),
        // 顶部左右两侧 15px 渐变遮罩：让分割线在两端对称渐变消失（看起来与两边等宽）
        Positioned(
          left: 0,
          top: 0,
          width: 15,
          height: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [bgColor(b), bgColor(b).withValues(alpha: 0)],
              ),
            ),
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          width: 15,
          height: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerRight,
                end: Alignment.centerLeft,
                colors: [bgColor(b), bgColor(b).withValues(alpha: 0)],
              ),
            ),
          ),
        ),
      ],
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
        const SizedBox(width: 12),
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
        TextInputBubbleMenu(
          controller: _inputCtrl,
          child: TextField(
            controller: _inputCtrl,
            focusNode: _inputFocus,
            maxLength: 2000, // 2000 字限制
            minLines: 2,
            maxLines: 6, // 超过 6 行内部滚动，不再增高
            // 禁用系统右键菜单（统一用气泡方案）
            contextMenuBuilder: (_, __) => const SizedBox.shrink(),
            // 过滤粘贴/输入的非法 UTF-16 代理项（防渲染崩溃）
            inputFormatters: const [Utf16SanitizeTextInputFormatter()],
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
            // emoji 表情按钮（BubbleMenu 气泡弹出面板，仅 emoji 无表情包；
            // 点击 emoji 插入后自动收起，微信式）
            BubbleMenu(
              key: _emojiMenuKey,
              width: 340,
              // emoji 面板高 190 + 气泡三角/内边距占位
              panelHeight: 209,
              content: EmojiPanel(
                transparent: true,
                onEmoji: (e) {
                  final idx = _inputCtrl.selection.baseOffset;
                  final text = _inputCtrl.text;
                  final newText = idx >= 0 && idx <= text.length
                      ? text.replaceRange(idx, idx, e)
                      : text + e;
                  _inputCtrl.value = TextEditingValue(
                    text: newText,
                    selection: TextSelection.collapsed(
                        offset: (idx >= 0 ? idx : text.length) + e.length),
                  );
                  _inputFocus.requestFocus();
                  _emojiMenuKey.currentState?.close();
                },
              ),
              onOpenChange: (open) {
                if (_showPanel != open) {
                  setState(() => _showPanel = open);
                }
                if (open) _inputFocus.requestFocus();
              },
              child: IconButton(
                onPressed: () {},
                tooltip: '表情',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  _showPanel
                      ? Icons.emoji_emotions
                      : Icons.emoji_emotions_outlined,
                  size: 20,
                  color: _showPanel ? kPrimary : textMutedColor(b),
                ),
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
    // 渲染兜底：清洗非法 UTF-16 代理项（防 TextSpan 崩溃）
    return TextSpan(text: sanitizeUtf16(text));
  }
}

/// 通用省略号按钮：点击弹出浮动小菜单（删除 / 举报）
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

  /// 点击顶层评论人头像/昵称 → 打开对方主页
  final VoidCallback? onUserTap;

  /// 点击楼中楼回复者头像/昵称 → 打开对方主页（参数为楼中楼评论数据）
  final ValueChanged<Map<String, dynamic>>? onUserTapChild;

  /// 点击楼中楼里 @昵称 → 打开被@者主页（参数为 被@者uid + 被@者昵称）
  final void Function(int replyToUid, String replyToName)? onUserTapAt;

  /// 是否显示本条顶层评论头像（连续同作者合并）
  final bool showAvatar;

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
    this.onUserTap,
    this.onUserTapChild,
    this.onUserTapAt,
    this.showAvatar = true,
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
    final isMine = (comment['user_id'] as num?)?.toInt() == currentUserId;
    final showCount =
        childShowCount > children.length ? children.length : childShowCount;
    final hidden = children.length - showCount;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 聊天气泡评论（头像左右按本人/他人切换，点气泡回复，爱心跟随头像侧）
          _ChatBubble(
            isMine: isMine,
            avatarUrl: avatar.isEmpty ? null : AppConfig.resolveUrl(avatar),
            nickname: nickname,
            contentWidget: SelectableText.rich(
              _buildRichText(
                b,
                content,
                color: isMine
                    ? Colors.white
                    : (b == Brightness.light ? Colors.black : Colors.white),
              ),
              // 禁用系统右键菜单：复制已合并进统一气泡菜单，避免双弹窗
              contextMenuBuilder: (context, editableTextState) =>
                  const SizedBox.shrink(),
              // 本人蓝底气泡：选中背景用黑色
              selectionColor: isMine ? Colors.black : null,
              style: TextStyle(
                fontSize: 16,
                color: isMine
                    ? Colors.white
                    : (b == Brightness.light ? Colors.black : Colors.white),
                height: 1.6,
              ),
            ),
            imagesWidget: _commentImages.isNotEmpty
                ? _buildCommentImages(context, b, _commentImages)
                : null,
            timeText: formatTimeWithLocation(timeText, location: location),
            hasLike: true,
            isLiked: isLiked,
            likeCount: likeCount,
            copyText: content,
            onLike: onLike,
            onReply: onReply,
            onDelete: isMine
                ? () => onDeleteComment((comment['id'] as num?)?.toInt() ?? 0)
                : null,
            onReport: !isMine
                ? () => onReportComment((comment['id'] as num?)?.toInt() ?? 0)
                : null,
            showAvatar: showAvatar,
            onUserTap: onUserTap,
          ),
          // 楼中楼（与主背景同步，不额外加次色调背景）
          // 左侧用 padding 缩进（保持嵌套视觉），右侧 padding 0 使省略号/爱心与顶层评论右对齐
          if (children.isNotEmpty)
            Container(
              padding: const EdgeInsets.fromLTRB(46, 4, 0, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < showCount && i < children.length; i++)
                    Builder(builder: (ctx) {
                      // 楼中楼内连续同作者合并头像
                      final prevChild =
                          i > 0 ? children[i - 1] : null;
                      final childShowAvatar = i == 0 ||
                          (prevChild?['user_id'] as num?)?.toInt() !=
                              (children[i]['user_id'] as num?)?.toInt();
                      return _buildChild(context, b, children[i],
                          showAvatar: childShowAvatar);
                    }),
                  // 展开按钮：居中显示（用 Row 抵消楼中楼左缩进，使其相对评论项整行居中）
                  if (hidden > 0)
                    Row(
                      children: [
                        const SizedBox(width: 46), // 抵消楼中楼容器左缩进，使居中
                        Expanded(
                          child: Center(
                            child: InkWell(
                              onTap: onExpandMore,
                              mouseCursor: SystemMouseCursors.click,
                              borderRadius: BorderRadius.circular(kRadiusSm),
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 4),
                                child: Text(
                                  hidden > _childExpandStep
                                      ? '展开 $_childExpandStep 条回复 ▾'
                                      : '展开全部 $hidden 条回复 ▾',
                                  style:
                                      TextStyle(fontSize: 14, color: kPrimary),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 46),
                      ],
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
  Widget _buildChild(
    BuildContext context,
    Brightness b,
    Map<String, dynamic> child, {
    bool showAvatar = true,
  }) {
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

    final childMine =
        (child['user_id'] as num?)?.toInt() == currentUserId;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      // 聊天气泡楼中楼评论（头像左右按本人/他人切换，点气泡回复，爱心跟随头像侧）
      child: _ChatBubble(
        isMine: childMine,
        avatarUrl: childAvatar.isEmpty ? null : AppConfig.resolveUrl(childAvatar),
        nickname: nickname,
        avatarSize: 26,
        level: 1, // 楼中楼：气泡样式与顶层区分
        // 楼中楼昵称在气泡上方：小两号、不加粗、颜色与时间一致（本人与他人一致）
        nicknameAbove: true,
        nicknameStyle: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w400,
          color: textFaintColor(b),
        ),
        contentWidget: SelectableText.rich(
          TextSpan(
            style: TextStyle(
              fontSize: 15,
              color: childMine
                  ? Colors.white
                  : (b == Brightness.light ? Colors.black : Colors.white),
              height: 1.6,
            ),
            children: [
              // @昵称可点击：跳被@者主页（仅非本人且存在时）
              if (showAt)
                WidgetSpan(
                  alignment: PlaceholderAlignment.baseline,
                  baseline: TextBaseline.alphabetic,
                  child: InkWell(
                    onTap: onUserTapAt != null
                        ? () => onUserTapAt!(replyToUid, replyToName)
                        : null,
                    mouseCursor: SystemMouseCursors.click,
                    child: Text(
                      '@$replyToName ',
                      style: TextStyle(
                        color: childMine
                            ? Colors.white.withValues(alpha: 0.85)
                            : (b == Brightness.light ? Colors.black : Colors.white),
                      ),
                    ),
                  ),
                ),
              ..._richSpans(b, content),
            ],
          ),
          // 禁用系统右键菜单：复制已合并进统一气泡菜单，避免双弹窗
          contextMenuBuilder: (context, editableTextState) =>
              const SizedBox.shrink(),
          // 本人蓝底气泡：选中背景用黑色
          selectionColor: childMine ? Colors.black : null,
        ),
        imagesWidget: childImages.isNotEmpty
            ? _buildCommentImages(context, b, childImages)
            : null,
        timeText: formatTimeWithLocation(timeText, location: location),
        hasLike: true,
        isLiked: isLiked,
        likeCount: likeCount,
        copyText: content,
        onLike: () => onLikeChild(child),
        onReply: () => onReplyChild(child),
        onDelete: childMine
            ? () => onDeleteComment((child['id'] as num?)?.toInt() ?? 0)
            : null,
        onReport: !childMine
            ? () => onReportComment((child['id'] as num?)?.toInt() ?? 0)
            : null,
        showAvatar: showAvatar,
        // 楼中楼回复者头像/昵称 → 打开对方主页
        onUserTap: onUserTapChild != null ? () => onUserTapChild!(child) : null,
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
    // 渲染兜底：清洗非法 UTF-16 代理项（防 TextSpan 崩溃）
    return [TextSpan(text: sanitizeUtf16(text))];
  }

  TextSpan _buildRichText(Brightness b, String text, {Color? color}) {
    return TextSpan(
      style: TextStyle(fontSize: 15, color: color ?? textBodyColor(b), height: 1.5),
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

  /// 已点赞时图标颜色（默认 kDanger）；null 用默认
  final Color? activeColor;

  /// 未点赞时图标/数字颜色（默认 textMutedColor）；null 用默认
  final Color? idleColor;

  const _CommentLikeButton({
    required this.isLiked,
    required this.count,
    required this.onTap,
    this.activeColor,
    this.idleColor,
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final heartColor = isLiked
        ? (activeColor ?? kDanger)
        : (idleColor ?? textMutedColor(b));
    final textColor = isLiked
        ? (activeColor ?? textMutedColor(b))
        : (idleColor ?? textMutedColor(b));
    return InkWell(
      onTap: onTap,
      mouseCursor: SystemMouseCursors.click, // 悬停显示手指
      borderRadius: BorderRadius.circular(kRadiusMd),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        // 固定宽度容器：右对齐后容器左边缘 x 固定 → 爱心图标（左对齐）在所有评论项中完全垂直对齐，
        // 点赞数字宽度变化不影响爱心位置
        child: SizedBox(
          width: 44,
          height: 20,
          child: Row(
            mainAxisSize: MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 爱心固定在最左（x 固定）
              SizedBox(
                width: 16,
                height: 16,
                child: Center(
                  child: Icon(
                    isLiked ? Icons.favorite : Icons.favorite_border,
                    size: 16,
                    color: heartColor,
                  ),
                ),
              ),
              if (count > 0) ...[
                const SizedBox(width: 3),
                // 数字格式化：>=1000 显示 k（如 1k / 1.2k / 10k）
                Expanded(
                  child: Text(
                    _formatCount(count),
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    softWrap: false,
                    style: TextStyle(fontSize: 11, color: textColor),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 点赞数格式化：>=1000 用 k（保留1位小数，去末尾0），如 1k / 1.2k / 10k / 1.2k
  static String _formatCount(int n) {
    if (n < 1000) return '$n';
    final v = n / 1000.0;
    // 整数则不带小数（如 1000 -> 1k，10000 -> 10k）
    if (v == v.roundToDouble()) return '${v.round()}k';
    // 带一位小数并去末尾 0（如 1200 -> 1.2k，1300 -> 1.3k）
    final s = v.toStringAsFixed(1);
    return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s}k';
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
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: iconColor),
              if (count > 0) ...[
                const SizedBox(width: 6),
                Text(
                  '$count',
                  style: TextStyle(fontSize: 13, color: textMutedColor(b)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 聊天气泡评论组件（抖音/小红书风格）
///
/// - 头像位置：本人(isMine)在右侧，他人(他人)在左侧
/// - 气泡小三角对准头像（头像左→三角朝左；头像右→三角朝右）
/// - 气泡包裹：昵称 + 内容 + 图片 + 时间/定位 + 省略号(他人)/删除(自己)
/// - 点击气泡发起回复
/// - 爱心在气泡外，跟随头像侧（isMine 时爱心被挤压到气泡左侧）
class _ChatBubble extends StatelessWidget {
  final bool isMine;
  final String? avatarUrl;
  final String nickname;
  final Widget contentWidget;
  final Widget? imagesWidget;
  final String timeText;
  final bool hasLike;
  final bool isLiked;
  final int likeCount;
  final VoidCallback? onLike;
  final VoidCallback onReply;
  final VoidCallback? onDelete; // 自己
  final VoidCallback? onReport; // 他人

  /// 右键菜单「复制」的文本内容（空则不显示复制项）。
  /// 用于把 SelectableText 的系统右键复制菜单合并进统一气泡菜单
  final String copyText;

  /// 点击头像/昵称 → 打开对方个人中心
  final VoidCallback? onUserTap;
  final double avatarSize;

  /// 层级：0=顶层评论/主贴；1=楼中楼（用于气泡样式区分）
  final int level;

  /// 是否显示头像（连续同作者评论只显示第一条的头像，抖音式合并）
  final bool showAvatar;

  /// 昵称是否显示在气泡上方（楼中楼/主贴）；false=昵称在气泡内
  final bool nicknameAbove;

  /// 气泡上方昵称的样式（楼中楼小两号不加粗；主贴原大小加粗）
  final TextStyle? nicknameStyle;

  const _ChatBubble({
    required this.isMine,
    required this.nickname,
    required this.contentWidget,
    required this.timeText,
    required this.onReply,
    this.avatarUrl,
    this.imagesWidget,
    this.hasLike = false,
    this.isLiked = false,
    this.likeCount = 0,
    this.onLike,
    this.onDelete,
    this.onReport,
    this.copyText = '',
    this.onUserTap,
    this.avatarSize = 32,
    this.level = 0,
    this.showAvatar = true,
    this.nicknameAbove = false,
    this.nicknameStyle,
  });

  @override
  Widget build(BuildContext context) {
    // 昵称在气泡内时，头像下移使其垂直中心与昵称对齐；昵称在气泡上方时头像下移 4px
    final avatarTop =
        nicknameAbove ? 2.5 : (16 - avatarSize / 2).clamp(0.0, double.infinity);
    // 头像：可点击跳对方个人中心（hover 小手）
    final avatar = Padding(
      padding: EdgeInsets.only(top: avatarTop),
      child: InkWell(
        onTap: onUserTap,
        mouseCursor: onUserTap != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        customBorder: const CircleBorder(),
        child: _AvatarBox(
          url: avatarUrl,
          nickname: nickname,
          size: avatarSize,
        ),
      ),
    );
    // 气泡：点击回复（带按压缩放动画）；右键弹删除/举报菜单（本人=删除，他人=举报）
    // 右键菜单统一用全局 BubbleMenu 气泡（内容宽度一致居中、宽窄不一左对齐）
    // 「复制」项合并了 SelectableText 的系统右键菜单（系统菜单已禁用，避免双弹窗）
    final bubble = BubbleMenu(
      triggerOnRightClick: true,
      items: [
        if (copyText.isNotEmpty)
          BubbleMenuItem(
            label: '复制',
            icon: Icons.copy_rounded,
            onTap: () {
              Clipboard.setData(ClipboardData(text: copyText));
              NotifyStack.success('已复制', title: '提示');
            },
          ),
        if (isMine)
          BubbleMenuItem.delete('删除', onTap: onDelete)
        else
          BubbleMenuItem.report('举报', onTap: onReport),
      ],
      child: _PressableBubble(
        onTap: onReply,
        child: _ChatBubbleBody(
        isMine: isMine,
        nickname: nickname,
        contentWidget: contentWidget,
        imagesWidget: imagesWidget,
        timeText: timeText,
        hasLike: hasLike,
        isLiked: isLiked,
        likeCount: likeCount,
        onLike: onLike,
        onDelete: onDelete,
        onReport: onReport,
        onUserTap: onUserTap,
        // 昵称在气泡上方时，气泡内不显示昵称；头像合并（showAvatar=false）时也隐藏
        showNickname: showAvatar && !nicknameAbove,
        avatarSize: avatarSize,
        level: level,
        ),
      ),
    );

    // 主体行：isMine -> [气泡, 头像] ；他人 -> [头像, 气泡]
    // showAvatar=false（连续同作者合并）时用占位宽度替代头像，保持气泡对齐
    // 本人气泡左缩进到头像右侧（左边缘与他人气泡对齐），且按内容宽不撑满
    final mainRow = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!isMine) ...[
          if (showAvatar) avatar else SizedBox(width: avatarSize),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: isMine
              ? Padding(
                  padding: EdgeInsets.only(left: avatarSize + 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: bubble,
                  ),
                )
              : bubble,
        ),
        if (isMine) ...[
          const SizedBox(width: 8),
          if (showAvatar) avatar else SizedBox(width: avatarSize),
        ],
      ],
    );

    // 昵称在气泡上方：头像与昵称同一行（顶部对齐），气泡在昵称下方
    if (nicknameAbove) {
      final b = Theme.of(context).brightness;
      // 昵称可点击跳对方个人中心（hover 小手）
      final nameLine = InkWell(
        onTap: onUserTap,
        mouseCursor: onUserTap != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(
            nickname,
            overflow: TextOverflow.ellipsis,
            style: nicknameStyle ??
                TextStyle(fontSize: 14, color: textMutedColor(b)),
          ),
        ),
      );
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头像（顶部与昵称对齐；合并时占位）
          if (!isMine) ...[
            if (showAvatar) avatar else SizedBox(width: avatarSize),
            const SizedBox(width: 8),
          ],
          // 昵称 + 气泡（昵称在气泡上方；本人昵称右对齐、气泡左缩进对齐他人，合并时昵称隐藏）
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showAvatar)
                  isMine
                      ? Align(
                          alignment: Alignment.centerRight,
                          child: nameLine,
                        )
                      : nameLine
                else
                  const SizedBox.shrink(),
                if (showAvatar) const SizedBox(height: 4),
                isMine
                    ? Padding(
                        padding: EdgeInsets.only(left: avatarSize + 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: bubble,
                        ),
                      )
                    : bubble,
              ],
            ),
          ),
          if (isMine) ...[
            const SizedBox(width: 8),
            if (showAvatar) avatar else SizedBox(width: avatarSize),
          ],
        ],
      );
    }
    return mainRow;
  }

}

/// 可按压气泡：按下时轻微缩放动画，左键点击触发回复；
/// 右键菜单由外层 BubbleMenu 统一处理（见调用处）
class _PressableBubble extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;

  const _PressableBubble({
    required this.child,
    required this.onTap,
  });

  @override
  State<_PressableBubble> createState() => _PressableBubbleState();
}

class _PressableBubbleState extends State<_PressableBubble> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _pressed ? 0.97 : 1.0,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: MouseRegion(
        // 气泡整体 hover 显示小手（内容文本区域由 SelectableText 显示 I-beam，优先级更高）
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: widget.child,
        ),
      ),
    );
  }
}

/// 气泡本体：昵称 + 内容 + 图片 + 时间/定位 + 点赞（同排）
/// 本人气泡 = 蓝色底 + 白色文字；他人气泡 = 次色调底 + 主题文字色
/// 无删除按钮/省略号：删除(本人)/举报(他人)统一走「右键气泡」弹出
class _ChatBubbleBody extends StatelessWidget {
  final bool isMine;
  final String nickname;
  final Widget contentWidget;
  final Widget? imagesWidget;
  final String timeText;
  final bool hasLike;
  final bool isLiked;
  final int likeCount;
  final VoidCallback? onLike;
  final VoidCallback? onDelete;
  final VoidCallback? onReport;

  /// 点击昵称 → 打开对方个人中心
  final VoidCallback? onUserTap;
  final bool showNickname;
  final double avatarSize;
  final int level;

  const _ChatBubbleBody({
    required this.isMine,
    required this.nickname,
    required this.contentWidget,
    required this.timeText,
    required this.imagesWidget,
    required this.hasLike,
    required this.isLiked,
    required this.likeCount,
    required this.onLike,
    required this.onDelete,
    required this.onReport,
    required this.onUserTap,
    required this.showNickname,
    this.avatarSize = 32,
    this.level = 0,
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    // 本人气泡：蓝色底 + 白字。
    // 他人气泡：白天顶层与楼中楼同色（次色调）；夜晚顶层与楼中楼也同色（更深一档）
    final bubbleBg = isMine
        ? kPrimary
        : (b == Brightness.light ? bgSoftColor(b) : bgHoverColor(b));
    // 他人气泡文字：白天纯黑 / 夜晚纯白；本人气泡文字：白色
    final bubbleTextColor = isMine
        ? Colors.white
        : (b == Brightness.light ? Colors.black : Colors.white);
    final nicknameColor = isMine
        ? Colors.white.withValues(alpha: 0.92)
        : bubbleTextColor;
    final timeColor = isMine
        ? Colors.white.withValues(alpha: 0.72)
        : bubbleTextColor.withValues(alpha: 0.85);
    final likeColor = isMine
        ? (isLiked ? Colors.white : Colors.white.withValues(alpha: 0.85))
        : (isLiked ? kDanger : bubbleTextColor);

    // 无投影、无边框的纯色圆角气泡
    final bubble = CustomPaint(
      painter: _ChatBubblePainter(bg: bubbleBg),
      child: Padding(
        // 楼中楼他人气泡左侧加大内边距，避免内容紧贴气泡边缘
        padding: EdgeInsets.fromLTRB(
          (!isMine && level > 0) ? 16 : 12,
          8,
          12,
          8,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 昵称行（无省略号；删除/举报走右键气泡；昵称可点击跳对方个人中心）
            if (showNickname)
              InkWell(
                onTap: onUserTap,
                mouseCursor: onUserTap != null
                    ? SystemMouseCursors.click
                    : SystemMouseCursors.basic,
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    nickname,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: nicknameColor,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            if (showNickname) const SizedBox(height: 2),
            contentWidget,
            if (imagesWidget != null) ...[
              const SizedBox(height: 6),
              imagesWidget!,
            ],
            const SizedBox(height: 6),
            // 时间/定位 + 点赞 同一行（无删除按钮）
            Row(
              children: [
                Expanded(
                  child: Text(
                    timeText,
                    style: TextStyle(fontSize: 13, color: timeColor),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (hasLike)
                  _CommentLikeButton(
                    isLiked: isLiked,
                    count: likeCount,
                    onTap: onLike ?? () {},
                    activeColor: isLiked ? (isMine ? Colors.white : kDanger) : null,
                    idleColor: likeColor,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
    return bubble;
  }
}

/// 气泡背景绘制：圆角矩形（无小三角、无边框、无投影）
class _ChatBubblePainter extends CustomPainter {
  final Color bg; // 气泡底色（本人=蓝，他人=次色调）

  _ChatBubblePainter({required this.bg});

  @override
  void paint(Canvas canvas, Size size) {
    const radius = 12.0;
    final fill = Paint()..color = bg;
    final bodyRect = Rect.fromLTWH(0, 0, size.width, size.height);
    final bodyPath = Path()
      ..addRRect(RRect.fromRectAndRadius(bodyRect, const Radius.circular(radius)));
    canvas.drawPath(bodyPath, fill);
  }

  @override
  bool shouldRepaint(covariant _ChatBubblePainter old) {
    return old.bg != bg;
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
    // 头像磁盘缓存（作者/评论者不换头像不重复加载）
    return CachedAvatar(
      url: url!,
      size: size,
      fallbackText: nickname,
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
