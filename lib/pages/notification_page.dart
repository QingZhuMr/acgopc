import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:window_manager/window_manager.dart';

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../core/app_theme.dart';
import '../services/notification_store.dart';
import '../widgets/bubble_menu.dart';
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

  /// 打开关系列表页回调（type=3 关注折叠点击 → 我的粉丝列表 tab=2）
  final void Function(int initialTab)? onOpenRelationList;

  const NotificationPage({
    super.key,
    this.currentUserId = 0,
    this.onChanged,
    this.embedded = false,
    this.onOpenPost,
    this.onOpenUserProfile,
    this.onOpenRelationList,
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

  /// 多选删除模式
  bool _selectMode = false;
  final Set<int> _selectedIds = {}; // 选中通知的 id（聚合取第一个 id 代表）

  @override
  void initState() {
    super.initState();
    _loadFirst();
  }

  Future<void> _loadFirst() async {
    // 1) 先读本地缓存秒出（上次拉取的列表 + 未读数）
    final cached = await NotificationStore.instance.loadCached();
    if (cached != null && mounted) {
      setState(() {
        _notifications
          ..clear()
          ..addAll(cached.items);
        _unread = cached.unread;
        _loading = false;
        _page = 1;
        _allLoaded = false;
      });
    } else {
      if (mounted) {
        setState(() {
          _loading = true;
          _page = 1;
          _notifications.clear();
          _allLoaded = false;
        });
      }
    }
    // 2) 网络拉取最新，成功后覆盖列表 + 落缓存
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
            _notifications
              ..clear()
              ..addAll(list);
            _unread = (data['unread_count'] as num?)?.toInt() ?? 0;
            _allLoaded = list.length < 20;
            _loading = false;
          });
        }
        // 覆盖缓存（后台写入，不影响 UI）
        unawaited(NotificationStore.instance
            .saveFirstPage(list, _unread)
            .catchError((_) {}));
      } else {
        // 有缓存时静默失败（保留缓存内容），无缓存才提示
        if (mounted && cached == null) setState(() => _loading = false);
        if (cached == null) _toast(json['msg'] as String? ?? '加载失败');
      }
    } catch (_) {
      if (mounted && cached == null) setState(() => _loading = false);
      if (cached == null) _toast('网络异常，请重试');
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
        // 追加缓存
        unawaited(
            NotificationStore.instance.appendPage(list).catchError((_) {}));
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

  /// 删除通知（单条/聚合条目）：调用批量删除接口后从列表移除
  Future<void> _deleteOne(Map<String, dynamic> n) async {
    final ids = _idList(n);
    if (ids.isEmpty) return;
    await _deleteIds(ids);
    // 同步删除缓存
    unawaited(NotificationStore.instance.deleteByIds(ids).catchError((_) {}));
    if (mounted) {
      final isRead = (n['is_read'] as num?)?.toInt() ?? 0;
      setState(() {
        _notifications.removeWhere((e) => _idList(e).toSet().containsAll(ids));
        if (isRead == 0) {
          _unread = _unread > ids.length ? _unread - ids.length : 0;
        }
        _changed = true;
      });
    }
    _toast('已删除通知');
  }

  /// 批量删除（多选模式）：ids 为通知 id 集合
  Future<void> _deleteMany(List<int> ids) async {
    if (ids.isEmpty) return;
    final idSet = ids.toSet();
    await _deleteIds(ids);
    // 同步删除缓存
    unawaited(NotificationStore.instance.deleteByIds(ids).catchError((_) {}));
    if (mounted) {
      setState(() {
        _notifications.removeWhere(
            (e) => _idList(e).any((id) => idSet.contains(id)));
        _unread = 0; // 简化：删除后刷新未读
        _changed = true;
      });
    }
    _toast('已删除所选通知');
  }

  /// 调后端批量删除接口
  Future<void> _deleteIds(List<int> ids) async {
    try {
      await ApiClient.instance
          .deleteNotifications(ids: ids)
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
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
    // 同步缓存：全部置已读 + 未读数清零
    unawaited(NotificationStore.instance.markAllRead().catchError((_) {}));
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

  /// 点击单条通知：标记聚合内所有 id 已读 + 跳转
  Future<void> _onTapNotify(Map<String, dynamic> n) async {
    final ids = _idList(n);
    final isRead = (n['is_read'] as num?)?.toInt() ?? 0;
    // 未读则先标记聚合内所有通知已读
    if (ids.isNotEmpty && isRead == 0) {
      try {
        for (final id in ids) {
          await ApiClient.instance
              .readNotification(id: id)
              .timeout(const Duration(seconds: 8));
        }
      } catch (_) {}
      // 同步缓存：聚合内所有 id 均标已读
      for (final id in ids) {
        unawaited(NotificationStore.instance.markRead(id).catchError((_) {}));
      }
      if (mounted) {
        setState(() {
          n['is_read'] = 1;
          _unread = _unread > ids.length ? _unread - ids.length : 0;
          _changed = true;
        });
      }
    }
    // type=3 被关注通知：聚合 → 跳我的粉丝列表；单条 → 跳关注人主页
    final type = (n['type'] as num?)?.toInt() ?? 0;
    final count = (n['count'] as num?)?.toInt() ?? 1;
    if (type == 3) {
      final relationCb = widget.onOpenRelationList;
      if (count > 1 && relationCb != null) {
        relationCb(2); // 我的粉丝列表 tab=2
        return;
      }
      final fromUid = (n['from_uid'] as num?)?.toInt() ?? 0;
      final fromName = n['from_nickname']?.toString() ?? '';
      final fromAvatar = n['from_avatar']?.toString() ?? '';
      final cb = widget.onOpenUserProfile;
      if (fromUid > 0 && cb != null) {
        cb(fromUid, fromName, fromAvatar);
        return;
      }
    }
    // type=6/7/8 配对成功 / 解除绑定 / 自动解除绑定通知 → 跳对方主页
    if (type == 6 || type == 7 || type == 8) {
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

  /// 取通知条目对应的通知 id 列表（聚合条目用 id_list，单条为 [id]）
  List<int> _idList(Map<String, dynamic> n) {
    final idList = n['id_list'];
    if (idList is List && idList.isNotEmpty) {
      return idList
          .map((e) => (e as num?)?.toInt() ?? 0)
          .where((e) => e > 0)
          .toList();
    }
    final id = (n['id'] as num?)?.toInt() ?? 0;
    return id > 0 ? [id] : [];
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
  /// 间距规范：pad 顶栏 0px；Win 端标题距顶 5px（比 macOS 的 20 上移 15px）；
  /// 标题与下一行内容间距 20px（本行 bottom 4 + 内容区自带顶部 padding 16 = 20）；
  /// 左右边距 24px，与 _PageScaffold（我的/设置页）标题行一致
  Widget _buildEmbeddedBar(Brightness b) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, AppConfig.topBarGap, 24, 4),
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
          if (_selectMode) ...[
            TextButton.icon(
              onPressed: () => setState(() {
                _selectMode = false;
                _selectedIds.clear();
              }),
              style: TextButton.styleFrom(foregroundColor: textMutedColor(b)),
              icon: const Icon(Icons.close_rounded, size: 16),
              label: const Text('取消', style: TextStyle(fontSize: 13)),
            ),
            TextButton.icon(
              onPressed: _selectedIds.isEmpty
                  ? null
                  : () => _deleteMany(_selectedIds.toList()),
              style: TextButton.styleFrom(
                  foregroundColor:
                      _selectedIds.isEmpty ? textFaintColor(b) : kDanger),
              icon: const Icon(Icons.delete_rounded, size: 16),
              label: Text(
                '删除所选${_selectedIds.isEmpty ? '' : '(${_selectedIds.length})'}',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ] else
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
    final readAllBtn = _selectMode
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton.icon(
                onPressed: () => setState(() {
                  _selectMode = false;
                  _selectedIds.clear();
                }),
                style:
                    TextButton.styleFrom(foregroundColor: textMutedColor(b)),
                icon: const Icon(Icons.close_rounded, size: 16),
                label: const Text('取消', style: TextStyle(fontSize: 13)),
              ),
              TextButton.icon(
                onPressed: _selectedIds.isEmpty
                    ? null
                    : () => _deleteMany(_selectedIds.toList()),
                style: TextButton.styleFrom(
                    foregroundColor:
                        _selectedIds.isEmpty ? textFaintColor(b) : kDanger),
                icon: const Icon(Icons.delete_rounded, size: 16),
                label: Text(
                  '删除所选${_selectedIds.isEmpty ? '' : '(${_selectedIds.length})'}',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          )
        : TextButton.icon(
            onPressed: _readAll,
            style: TextButton.styleFrom(foregroundColor: kPrimary),
            icon: const Icon(Icons.done_all_rounded, size: 16),
            label: const Text('全部已读', style: TextStyle(fontSize: 13)),
          );
    // pad：无窗口顶栏，高度 0px（内容直接顶到屏幕顶部；系统返回键/手势可返回）
    if (AppConfig.isPad) return const SizedBox.shrink();
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

  /// 条目标识（聚合条目取 id_list 第一个）
  int _itemKey(Map<String, dynamic> n) {
    final ids = _idList(n);
    return ids.isNotEmpty ? ids.first : ((n['id'] as num?)?.toInt() ?? 0);
  }

  Widget _buildNotifyItem(Brightness b, Map<String, dynamic> n) {
    final isRead = (n['is_read'] as num?)?.toInt() == 1;
    final type = (n['type'] as num?)?.toInt() ?? 1;
    final fromName = (n['from_nickname'] as String?) ?? '有人';
    final commentContent = (n['comment_content'] as String?) ?? '';
    final postContent = (n['post_content'] as String?) ?? '';
    final timeText = (n['create_time_text'] as String?) ?? '';
    final avatar = (n['from_avatar'] as String?) ?? '';
    final key = _itemKey(n);
    final selected = _selectedIds.contains(key);

    // 标题文案（type=3 被关注；聚合条目 from_nickname 已含"xxx、xxx等N人"）
    String title;
    switch (type) {
      case 3:
        title = '$fromName 关注了你';
        break;
      case 4:
        title = '$fromName 赞了你的动态';
        break;
      case 5:
        title = '$fromName 收藏了你的动态';
        break;
      case 2:
        title = '$fromName 回复了你';
        break;
      case 6:
        // post_content 存的是星球名（配对成功）
        title = postContent.isNotEmpty
            ? '$fromName 在$postContent星球和你配对了'
            : '$fromName 和你配对了';
        break;
      case 7:
        title = '$fromName 解除了与你的绑定关系';
        break;
      case 8:
        // 自动解除绑定：绑定对象长期未上线（补偿信息在 comment_content 展示）
        title = '$fromName 长期未上线，绑定已自动解除';
        break;
      default:
        title = '$fromName 评论了你的动态';
    }

    // 右键菜单：多选 / 删除本条
    final menuItems = <BubbleMenuItem>[
      BubbleMenuItem(
        label: _selectMode ? '退出多选' : '多选删除',
        icon: _selectMode
            ? Icons.check_circle_outline_rounded
            : Icons.library_add_check_rounded,
        onTap: () => setState(() {
          if (_selectMode) {
            _selectMode = false;
            _selectedIds.clear();
          } else {
            _selectMode = true;
            _selectedIds.add(key);
          }
        }),
      ),
      BubbleMenuItem(
        label: '删除',
        icon: Icons.delete_outline_rounded,
        onTap: () => _deleteOne(n),
      ),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: BubbleMenu(
        triggerOnRightClick: true,
        items: menuItems,
        child: Material(
          color: selected
              ? primarySoftColor(b)
              : (isRead ? bgColor(b) : primarySoftColor(b)),
          borderRadius: BorderRadius.circular(kRadiusBtn),
          child: InkWell(
            borderRadius: BorderRadius.circular(kRadiusBtn),
            mouseCursor: SystemMouseCursors.click, // 悬停显示手指
            onTap: () {
              if (_selectMode) {
                setState(() {
                  if (selected) {
                    _selectedIds.remove(key);
                  } else {
                    _selectedIds.add(key);
                  }
                });
              } else {
                _onTapNotify(n);
              }
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 多选模式：左侧选择框
                  if (_selectMode) ...[
                    Icon(
                      selected
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 18,
                      color: selected ? kPrimary : textFaintColor(b),
                    ),
                    const SizedBox(width: 8),
                  ],
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
                                  fontWeight: isRead
                                      ? FontWeight.w500
                                      : FontWeight.w600,
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
                        // 次级小字：所在帖子内容（type=6 的 post_content 是星球名已在标题展示，type=7/8 无内容）
                        if (postContent.isNotEmpty && type != 6 && type != 7 && type != 8) ...[
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
                  // 多选模式：删除所选按钮；普通模式：无操作（右键删除）
                  if (_selectMode) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: '删除所选',
                      icon: Icon(Icons.delete_rounded,
                          size: 18, color: kDanger),
                      onPressed: () => _deleteMany(_selectedIds.toList()),
                    ),
                  ],
                ],
              ),
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
