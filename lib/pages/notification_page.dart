import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:window_manager/window_manager.dart';

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../core/app_theme.dart';
import '../widgets/notify.dart';
import 'post_detail_page.dart';

/// 帖子回复通知中心页
///
/// 通过左侧导航栏头像上方的铃铛进入。展示"他人评论了我的帖子 / 回复了我的评论"通知，
/// 支持：
///   - 点击通知跳转到所在帖子详情
///   - 忽略（仅未读显示，标为已读并移出列表）
///   - 一键全部已读
///   - 未读通知高亮，进入后自动全部已读
class NotificationPage extends StatefulWidget {
  /// 当前登录用户 id（用于跳转帖子详情时判断权限）
  final int currentUserId;

  /// 通知页关闭后回调（用于刷新导航栏铃铛角标）
  final VoidCallback? onChanged;

  /// 是否以内嵌模式展示（macOS 侧边栏 tab）：不渲染返回按钮/窗口顶栏
  final bool embedded;

  /// 打开帖子详情回调（macOS 内容区覆盖用，保留左侧导航栏）；非 macOS 为 null 则走 push
  final void Function(int postId, String postContent, int? commentId)? onOpenPost;

  /// 打开他人主页回调（type=3 被关注通知点击跳关注人主页）
  final void Function(int uid, String nickname, String avatar)? onOpenUserProfile;

  const NotificationPage({
    super.key,
    this.currentUserId = 0,
    this.onChanged,
    this.embedded = false,
    this.onOpenPost,
    this.onOpenUserProfile,
  });

  @override
  State<NotificationPage> createState() => _NotificationPageState();
}

class _NotificationPageState extends State<NotificationPage> {
  final List<Map<String, dynamic>> _notifications = [];
  int _page = 1;
  bool _loading = true; // 首次加载：显示加载态
  bool _loadingMore = false; // 加载更多
  bool _allLoaded = false;
  int _unread = 0;
  bool _changed = false; // 是否有未读被消费，关闭时回调通知角标刷新

  @override
  void initState() {
    super.initState();
    _loadFirst();
  }

  Future<void> _loadFirst() async {
    setState(() {
      _loading = true;
      _page = 1;
      _notifications.clear();
      _allLoaded = false;
    });
    try {
      final resp = await ApiClient.instance
          .getNotificationList(page: 1, pageSize: 20)
          .timeout(const Duration(seconds: 10));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] == 0) {
        final data = json['data'] as Map<String, dynamic>? ?? {};
        final list = (data['list'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .toList();
        if (mounted) {
          setState(() {
            _notifications.addAll(list);
            _unread = (data['unread_count'] as num?)?.toInt() ?? 0;
            _allLoaded = list.length < 20;
            _loading = false;
          });
        }
      } else {
        if (mounted) setState(() => _loading = false);
        _toast(json['msg'] as String? ?? '加载失败');
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
      _toast('网络异常，请重试');
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _allLoaded) return;
    _loadingMore = true;
    final next = _page + 1;
    try {
      final resp = await ApiClient.instance
          .getNotificationList(page: next, pageSize: 20)
          .timeout(const Duration(seconds: 10));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] == 0) {
        final data = json['data'] as Map<String, dynamic>? ?? {};
        final list = (data['list'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .toList();
        if (mounted) {
          setState(() {
            _notifications.addAll(list);
            _page = next;
            _allLoaded = list.length < 20;
          });
        }
      } else {
        _allLoaded = true;
      }
    } catch (_) {
      _allLoaded = true;
    } finally {
      _loadingMore = false;
    }
  }

  /// 打开帖子详情（点击通知）
  Future<void> _openPost(Map<String, dynamic> n) async {
    final postId = (n['post_id'] as num?)?.toInt() ?? 0;
    if (postId <= 0) return;
    final commentId = (n['comment_id'] as num?)?.toInt();
    // 双端统一：通过回调在内容区打开帖子（保留左侧导航栏，不遮盖）
    if (widget.onOpenPost != null) {
      widget.onOpenPost!(postId, n['post_content']?.toString() ?? '', commentId);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PostDetailPage(
          postBrief: {'id': postId, 'content': n['post_content'] ?? ''},
          postId: postId,
          currentUserId: widget.currentUserId,
          focusCommentId: (commentId != null && commentId > 0) ? commentId : null,
        ),
      ),
    );
  }

  /// 忽略（删除）单条通知
  Future<void> _ignoreOne(Map<String, dynamic> n) async {
    final id = (n['id'] as num?)?.toInt() ?? 0;
    if (id <= 0) return;
    try {
      await ApiClient.instance
          .readNotification(id: id)
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
    if (mounted) {
      setState(() {
        _notifications.removeWhere((e) => e['id'] == id);
        _unread = _unread > 0 ? _unread - 1 : 0;
        _changed = true;
      });
    }
    _toast('已忽略该通知');
  }

  /// 一键全部已读
  Future<void> _readAll() async {
    if (_unread <= 0) {
      _toast('暂无未读通知');
      return;
    }
    try {
      await ApiClient.instance
          .readAllNotifications()
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
    if (mounted) {
      setState(() {
        for (final n in _notifications) {
          n['is_read'] = 1;
        }
        _unread = 0;
        _changed = true;
      });
    }
    _toast('已全部标为已读');
  }

  /// 点击单条通知：标记该条已读 + 跳转帖子
  Future<void> _onTapNotify(Map<String, dynamic> n) async {
    final id = (n['id'] as num?)?.toInt() ?? 0;
    final isRead = (n['is_read'] as num?)?.toInt() ?? 0;
    // 未读则先标记已读
    if (id > 0 && isRead == 0) {
      try {
        await ApiClient.instance
            .readNotification(id: id)
            .timeout(const Duration(seconds: 8));
      } catch (_) {}
      if (mounted) {
        setState(() {
          n['is_read'] = 1;
          _unread = _unread > 0 ? _unread - 1 : 0;
          _changed = true;
        });
      }
    }
    // type=3 被关注通知：跳关注人主页
    final type = (n['type'] as num?)?.toInt() ?? 0;
    if (type == 3) {
      final fromUid = (n['from_uid'] as num?)?.toInt() ?? 0;
      final fromName = n['from_nickname']?.toString() ?? '';
      final fromAvatar = n['from_avatar']?.toString() ?? '';
      final cb = widget.onOpenUserProfile;
      if (fromUid > 0 && cb != null) {
        cb(fromUid, fromName, fromAvatar);
        return;
      }
    }
    await _openPost(n);
  }

  void _toast(String msg) {
    if (!mounted) return;
    NotifyStack.info(msg, title: '通知');
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Scaffold(
      backgroundColor: bgColor(b),
      body: Column(
        children: [
          // 自绘顶栏（返回 + 标题 + 操作按钮 + 拖拽区 + 窗口控制）
          // macOS 内嵌模式：用简洁标题行（无返回/窗口按钮，保留标题 + 全部已读）
          widget.embedded ? _buildEmbeddedBar(b) : _buildTitleBar(b),
          // 内容区
          Expanded(child: _buildBody(b)),
        ],
      ),
    );
  }

  /// 简洁标题行（侧边栏 tab 内嵌用）：无返回按钮/窗口按钮，保留标题 + 未读角标 + 全部已读
  /// 间距规范：Win 端标题距顶 5px（比 macOS 的 20 上移 15px）；
  /// 标题与下一行内容间距 20px（本行 bottom 4 + 内容区自带顶部 padding 16 = 20）；
  /// 左右边距 24px，与 _PageScaffold（我的/设置页）标题行一致
  Widget _buildEmbeddedBar(Brightness b) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, Platform.isWindows ? 5 : 20, 24, 4),
      child: Row(
        children: [
          Text(
            '通知',
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.w600, color: textColor(b)),
          ),
          if (_unread > 0)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: kDanger,
                borderRadius: BorderRadius.circular(kRadiusFull),
              ),
              child: Text(
                '$_unread',
                style: const TextStyle(
                    fontSize: 11,
                    color: Colors.white,
                    fontWeight: FontWeight.w600),
              ),
            ),
          const Spacer(),
          TextButton.icon(
            onPressed: _readAll,
            style: TextButton.styleFrom(foregroundColor: kPrimary),
            icon: const Icon(Icons.done_all_rounded, size: 16),
            label: const Text('全部已读', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  /// 顶栏：返回 + 标题 + 未读角标 + 「全部已读」+ 拖拽区 + 窗口控制
  /// macOS 使用原生标题栏：仅保留返回/标题/全部已读，移除拖拽区与窗口控制
  Widget _buildTitleBar(Brightness b) {
    final leading = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(width: 8),
        IconButton(
          tooltip: '返回',
          icon: Icon(Icons.arrow_back_ios_new_rounded,
              size: 18, color: textMutedColor(b)),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        const SizedBox(width: 4),
        Text(
          '通知',
          style: TextStyle(
              fontSize: 20, fontWeight: FontWeight.w600, color: textColor(b)),
        ),
        if (_unread > 0)
          Container(
            margin: const EdgeInsets.only(left: 8),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: kDanger,
              borderRadius: BorderRadius.circular(kRadiusFull),
            ),
            child: Text(
              '$_unread',
              style: const TextStyle(
                  fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
      ],
    );
    final readAllBtn = TextButton.icon(
      onPressed: _readAll,
      style: TextButton.styleFrom(foregroundColor: kPrimary),
      icon: const Icon(Icons.done_all_rounded, size: 16),
      label: const Text('全部已读', style: TextStyle(fontSize: 13)),
    );
    // macOS：预留红黄绿按钮安全距离，去掉窗口控制按钮，保留功能按钮 + 拖拽区
    if (Platform.isMacOS) {
      return SizedBox(
        height: 40,
        child: Row(
          children: [
            SizedBox(
              width: kMacTrafficLightWidth,
              child: Container(color: bgColor(b)),
            ),
            leading,
            // 拖拽区（撑满，可拖动窗口）
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => windowManager.startDragging(),
                child: const SizedBox.expand(),
              ),
            ),
            readAllBtn,
          ],
        ),
      );
    }
    return SizedBox(
      height: 60,
      child: Row(
        children: [
          leading,
          // 拖拽区（撑满，可拖动窗口）
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => windowManager.startDragging(),
              child: const SizedBox.expand(),
            ),
          ),
          // 一键已读按钮
          readAllBtn,
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
    );
  }

  Widget _buildBody(Brightness b) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: kPrimary, strokeWidth: 2.5),
      );
    }
    if (_notifications.isEmpty) {
      return _buildEmpty(b);
    }
    return SilkyListView.builder(
      // 顶部 16：配合标题行 bottom 4 构成「标题与下一行间距 20px」规范
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      scrollSpeed: 1.6,
      silkyScrollDuration: const Duration(milliseconds: 600),
      animationCurve: Curves.easeOutCubic,
      itemCount: _notifications.length + (_allLoaded ? 0 : 1),
      itemBuilder: (context, index) {
        if (index >= _notifications.length) {
          // 底部加载更多
          Future.microtask(_loadMore);
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    color: kPrimary, strokeWidth: 2),
              ),
            ),
          );
        }
        return _buildNotifyItem(b, _notifications[index]);
      },
    );
  }

  Widget _buildEmpty(Brightness b) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.notifications_none_rounded,
              size: 64, color: textFaintColor(b)),
          const SizedBox(height: 12),
          Text(
            '暂无通知',
            style: TextStyle(fontSize: 14, color: textMutedColor(b)),
          ),
        ],
      ),
    );
  }

  Widget _buildNotifyItem(Brightness b, Map<String, dynamic> n) {
    final isRead = (n['is_read'] as num?)?.toInt() == 1;
    final type = (n['type'] as num?)?.toInt() ?? 1;
    final fromName = (n['from_nickname'] as String?) ?? '有人';
    final commentContent = (n['comment_content'] as String?) ?? '';
    final postContent = (n['post_content'] as String?) ?? '';
    final timeText = (n['create_time_text'] as String?) ?? '';
    final avatar = (n['from_avatar'] as String?) ?? '';

    // 标题文案（type=3 被关注）
    final title = type == 3
        ? '$fromName 关注了你'
        : (type == 2 ? '$fromName 回复了你' : '$fromName 评论了你的帖子');

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: isRead ? bgColor(b) : primarySoftColor(b),
        borderRadius: BorderRadius.circular(kRadiusBtn),
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadiusBtn),
          mouseCursor: SystemMouseCursors.click, // 悬停显示手指
          onTap: () => _onTapNotify(n),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 触发者头像
                _NotifyAvatar(avatar: avatar, name: fromName, size: 40),
                const SizedBox(width: 12),
                // 中部：标题 + 内容
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          if (!isRead)
                            Container(
                              width: 8,
                              height: 8,
                              margin: const EdgeInsets.only(right: 6),
                              decoration: const BoxDecoration(
                                color: kDanger,
                                shape: BoxShape.circle,
                              ),
                            ),
                          Expanded(
                            child: Text(
                              title,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight:
                                    isRead ? FontWeight.w500 : FontWeight.w600,
                                // 未读标题醒目，已读变灰
                                color: isRead
                                    ? textMutedColor(b)
                                    : textColor(b),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            timeText,
                            style: TextStyle(
                                fontSize: 12, color: textFaintColor(b)),
                          ),
                        ],
                      ),
                      if (commentContent.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          commentContent,
                          style: TextStyle(
                            fontSize: 13,
                            // 未读正文正常色，已读降为弱化色
                            color: isRead
                                ? textFaintColor(b)
                                : textSecondaryColor(b),
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      // 次级小字：所在帖子内容
                      if (postContent.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: bgHoverColor(b),
                            borderRadius: BorderRadius.circular(kRadiusSm),
                          ),
                          child: Text(
                            '帖子：$postContent',
                            style: TextStyle(
                              fontSize: 12,
                              // 未读帖子内容正常灰，已读更淡
                              color: isRead
                                  ? textFaintColor(b)
                                  : textMutedColor(b),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // 忽略按钮（仅未读显示：忽略 = 标为已读并移出列表）
                if (!isRead) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: '忽略该通知',
                    icon: Icon(Icons.close_rounded,
                        size: 18, color: textFaintColor(b)),
                    onPressed: () => _ignoreOne(n),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    // 关闭时若有未读被消费，通知外层刷新角标
    if (_changed) widget.onChanged?.call();
    super.dispose();
  }
}

/// 通知触发者头像（有 URL 显示图片，失败回退首字）
class _NotifyAvatar extends StatelessWidget {
  final String avatar;
  final String name;
  final double size;

  const _NotifyAvatar({
    required this.avatar,
    required this.name,
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final initial = _initialText(name);
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

    final url = avatar.isEmpty ? null : AppConfig.resolveUrl(avatar);
    if (url == null || url.isEmpty) return placeholder;

    return ClipOval(
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : placeholder,
        errorBuilder: (context, error, stackTrace) => placeholder,
      ),
    );
  }

  String _initialText(String name) {
    final s = name.trim();
    if (s.isEmpty) return '?';
    if (s.length <= 2) return s;
    return s.substring(0, 2);
  }
}

/// 窗口控制按钮（与主页面顶栏样式一致）
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
