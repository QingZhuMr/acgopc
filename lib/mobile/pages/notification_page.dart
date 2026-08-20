import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/app_config.dart';
import '../../core/app_theme.dart';
import '../../services/notification_store.dart';
import '../theme/mobile_theme.dart';
import '../widgets/mobile_top_bar.dart';

/// 移动端系统通知列表页
///
/// 规格（`docs/移动端UI规范.md` §4.3 / `docs/UI规范.md` §11）：
///  - 顶部安全区返回栏 + "通知"标题 + 未读数 + 全部已读；
///  - 分页加载 + 下拉刷新 + 触底加载更多；
///  - 每条：触发者头像 + 标题（type 文案）+ 评论/帖子内容 + 时间 + 未读红点；
///  - 点击标记已读（未读数即时递减），关闭时若有变化通知外层刷新未读；
///  - 左滑露出删除按钮（自绘，互斥展开）+ 长按多选批量删除（2026-08-20 新增）；
///  - 顶栏为浮动玻璃（Stack 上层悬浮，盖住滚动内容，位置恒定，模式切换不位移）。
class MobileNotificationPage extends StatefulWidget {
  const MobileNotificationPage({super.key, required this.user, this.onChanged});

  final Map<String, dynamic> user;

  /// 关闭时若有未读变化，通知外层刷新角标/未读
  final VoidCallback? onChanged;

  @override
  State<MobileNotificationPage> createState() => _MobileNotificationPageState();
}

class _MobileNotificationPageState extends State<MobileNotificationPage> {
  List<Map<String, dynamic>> _items = [];
  int _unread = 0;
  int _page = 0;
  bool _allLoaded = false;
  bool _loading = true;
  bool _loadingMore = false;
  bool _changed = false;
  final Set<int> _readIds = {};

  // ===== 滑动删除 + 长按多选（2026-08-20 新增） =====
  /// 当前展开删除按钮的通知 id（互斥：同时只展开一条）
  int? _openId;
  /// 是否处于多选模式（长按进入）
  bool _selectMode = false;
  /// 多选模式下勾选的通知 id 集合
  final Set<int> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    // 按账号打开通知缓存库
    final uid = (widget.user['id'] as num?)?.toInt() ?? 0;
    if (uid > 0) {
      unawaited(NotificationStore.instance.openForUser(uid));
    }
    _initCached();
    _refresh();
  }

  /// 先读本地缓存秒出，再等网络刷新覆盖
  Future<void> _initCached() async {
    final cached = await NotificationStore.instance.loadCached();
    if (cached == null || !mounted) return;
    setState(() {
      _items = cached.items;
      _unread = cached.unread;
      _loading = false;
    });
  }

  @override
  void dispose() {
    if (_changed) widget.onChanged?.call();
    super.dispose();
  }

  Future<void> _refresh() async {
    _page = 0;
    _allLoaded = false;
    await Future.wait([_loadUnread(), _loadPage()]);
    if (mounted) {
      setState(() => _loading = false);
      // 网络成功后统一落第一页缓存（含最新未读数）
      if (_page == 1 && _items.isNotEmpty) {
        unawaited(NotificationStore.instance
            .saveFirstPage(_items, _unread)
            .catchError((_) {}));
      }
    }
  }

  Future<void> _loadUnread() async {
    try {
      final resp = await ApiClient.instance
          .getNotificationUnreadCount()
          .timeout(const Duration(seconds: 8));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] == 0 && mounted) {
        final data = json['data'] as Map<String, dynamic>? ?? {};
        final count = (data['unread_count'] as num?)?.toInt() ?? 0;
        setState(() => _unread = count);
        // 未读数单独落缓存（失败静默）
        unawaited(NotificationStore.instance.saveUnread(count).catchError((_) {}));
      }
    } catch (_) {
      // 未读拉取失败不影响列表
    }
  }

  Future<void> _loadPage() async {
    try {
      final resp = await ApiClient.instance
          .getNotificationList(page: _page + 1, pageSize: 20)
          .timeout(const Duration(seconds: 10));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] == 0) {
        final data = json['data'] as Map<String, dynamic>? ?? {};
        final list = (data['list'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .toList();
        if (mounted) {
          setState(() {
            if (_page == 0) {
              _items = list;
            } else {
              _items.addAll(list);
            }
            _page++;
            _allLoaded = list.length < 20;
          });
          // 落缓存：仅追加后续页（第一页由 _refresh 网络成功后统一覆盖）
          if (_page > 1) {
            unawaited(NotificationStore.instance
                .appendPage(list)
                .catchError((_) {}));
          }
        }
      } else if (mounted) {
        setState(() => _allLoaded = true);
      }
    } catch (_) {
      if (mounted) setState(() => _allLoaded = true);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _allLoaded) return;
    _loadingMore = true;
    await _loadPage();
    _loadingMore = false;
  }

  /// 点击通知：标记已读 + 未读数即时递减
  /// （移动端帖子详情页暂未实现，带 post_id 的跳转后续接入）
  Future<void> _markRead(Map<String, dynamic> n) async {
    final id = (n['id'] as num?)?.toInt() ?? 0;
    if (id <= 0 || _readIds.contains(id)) return;
    final isRead = (n['is_read'] as num?)?.toInt() ?? 0;
    if (isRead == 0) {
      setState(() {
        _readIds.add(id);
        n['is_read'] = 1;
        if (_unread > 0) _unread--;
        _changed = true;
      });
      try {
        await ApiClient.instance.readNotification(id: id);
      } catch (_) {
        // 标记已读失败不影响主流程
      }
      // 同步缓存：该通知标已读
      unawaited(NotificationStore.instance.markRead(id).catchError((_) {}));
    }
  }

  Future<void> _readAll() async {
    if (_items.isEmpty) return;
    try {
      final resp = await ApiClient.instance
          .readAllNotifications()
          .timeout(const Duration(seconds: 8));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] == 0 && mounted) {
        setState(() {
          for (final e in _items) {
            e['is_read'] = 1;
          }
          _readIds.addAll(_items.map((e) => (e['id'] as num?)?.toInt() ?? 0));
          _unread = 0;
          _changed = true;
        });
        // 同步缓存：全部置已读 + 未读数清零
        unawaited(NotificationStore.instance.markAllRead().catchError((_) {}));
      }
    } catch (_) {
      // 失败静默
    }
  }

  // ===== 长按多选 =====

  /// 长按进入多选模式并勾选该条（同时收起已展开的删除按钮）
  void _enterSelectMode(int id) {
    setState(() {
      _openId = null;
      _selectMode = true;
      _selectedIds.add(id);
    });
  }

  /// 退出多选模式
  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selectedIds.clear();
      _openId = null;
    });
  }

  /// 列表项点击：多选模式切换勾选，普通模式标记已读
  void _onTapNotify(Map<String, dynamic> n) {
    final id = (n['id'] as num?)?.toInt() ?? 0;
    if (_selectMode) {
      setState(() {
        if (!_selectedIds.add(id)) _selectedIds.remove(id);
      });
      return;
    }
    _markRead(n);
  }

  // ===== 删除 =====

  /// 滑动删除单条：本地先移除（含未读递减），再异步删服务端 + 缓存
  Future<void> _deleteOne(Map<String, dynamic> n) async {
    final id = (n['id'] as num?)?.toInt() ?? 0;
    if (id <= 0) return;
    final isRead = (n['is_read'] as num?)?.toInt() == 1;
    if (mounted) {
      setState(() {
        _items.removeWhere((e) => (e['id'] as num?)?.toInt() == id);
        if (!isRead && _unread > 0) _unread--;
        _openId = null;
        _changed = true;
      });
    }
    // 同步缓存删除
    unawaited(NotificationStore.instance.deleteByIds([id]).catchError((_) {}));
    // 异步删服务端（失败静默，本地已移除）
    try {
      await ApiClient.instance.deleteNotifications(ids: [id]);
    } catch (_) {}
  }

  /// 多选批量删除：本地先移除（统计被删未读数递减），再异步删服务端 + 缓存
  Future<void> _deleteMany(Set<int> ids) async {
    if (ids.isEmpty) return;
    final idList = ids.toList();
    var removedUnread = 0;
    if (mounted) {
      setState(() {
        for (final e in _items) {
          final eid = (e['id'] as num?)?.toInt() ?? 0;
          if (idList.contains(eid) && (e['is_read'] as num?)?.toInt() != 1) {
            removedUnread++;
          }
        }
        _items.removeWhere(
            (e) => idList.contains((e['id'] as num?)?.toInt() ?? 0));
        _unread = _unread > removedUnread ? _unread - removedUnread : 0;
        _selectMode = false;
        _selectedIds.clear();
        _openId = null;
        _changed = true;
      });
    }
    // 同步缓存删除
    unawaited(NotificationStore.instance
        .deleteByIds(idList)
        .catchError((_) {}));
    // 异步删服务端（失败静默）
    try {
      await ApiClient.instance.deleteNotifications(ids: idList);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Stack(
              children: [
                // ===== 内容列表：在浮动顶栏下层滚动（内容可从顶栏下方穿过） =====
                Positioned.fill(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      // 触底前加载更多
                      if (n.metrics.pixels >=
                          n.metrics.maxScrollExtent - 120) {
                        _loadMore();
                      }
                      return false;
                    },
                    child: RefreshIndicator(
                      onRefresh: _refresh,
                      child: CustomScrollView(
                        physics: const AlwaysScrollableScrollPhysics(
                            parent: BouncingScrollPhysics()),
                        slivers: [
                          // 顶部占位：预留浮动顶栏高度，避免首条被遮
                          const SliverToBoxAdapter(
                              child: SizedBox(height: MobileTopBar.totalHeight)),
                          if (_loading)
                            const _SkeletonList()
                          else if (_items.isEmpty)
                            const SliverFillRemaining(
                              hasScrollBody: false,
                              child: _EmptyView(),
                            )
                          else ...[
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(4, 4, 4, 24),
                              sliver: SliverList.builder(
                                itemCount: _items.length,
                                itemBuilder: (context, i) {
                                  final n = _items[i];
                                  final id =
                                      (n['id'] as num?)?.toInt() ?? 0;
                                  return _NotifyTile(
                                    notify: n,
                                    selected: _selectMode &&
                                        _selectedIds.contains(id),
                                    selectMode: _selectMode,
                                    open: _openId == id,
                                    onOpenChange: (open) => setState(
                                        () => _openId = open ? id : null),
                                    onTap: () => _onTapNotify(n),
                                    onLongPress: () => _enterSelectMode(id),
                                    onDelete: () => _deleteOne(n),
                                  );
                                },
                              ),
                            ),
                            SliverToBoxAdapter(
                              child: _allLoaded
                                  ? const SizedBox(height: 24)
                                  : Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 16),
                                      child: Center(
                                        child: SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2.2),
                                        ),
                                      ),
                                    ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                // ===== 浮动顶栏：通用组件，高层级悬浮，盖住滚动内容，位置恒定 =====
                Align(
                  alignment: Alignment.topCenter,
                  child: MobileTopBar(
                    title: _selectMode
                        ? '已选 ${_selectedIds.length} 项'
                        : (_unread > 0 ? '通知 ($_unread)' : '通知'),
                    onBack: _selectMode
                        ? _exitSelectMode
                        : () => Navigator.of(context).maybePop(),
                    actions: _selectMode
                        ? [
                            CupertinoButton(
                              padding: EdgeInsets.zero,
                              onPressed: _exitSelectMode,
                              child: Text('取消',
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: textMutedColor(
                                          Theme.of(context).brightness))),
                            ),
                            const SizedBox(width: 16),
                            CupertinoButton(
                              padding: EdgeInsets.zero,
                              onPressed: _selectedIds.isEmpty
                                  ? null
                                  : () => _deleteMany(_selectedIds),
                              child: Text('删除',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: _selectedIds.isEmpty
                                        ? textFaintColor(
                                            Theme.of(context).brightness)
                                        : kDanger,
                                  )),
                            ),
                          ]
                        : (_unread > 0
                            ? [
                                CupertinoButton(
                                  padding: EdgeInsets.zero,
                                  onPressed: _readAll,
                                  child: Text('全部已读',
                                      style: TextStyle(
                                          fontSize: 13, color: kPrimary)),
                                ),
                              ]
                            : []),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 通知条目：左滑露出删除按钮（自绘，互斥展开）+ 长按进入多选勾选
///
/// 结构：Stack = 底层右侧红色删除按钮 + 上层内容（GestureDetector 水平拖拽平移）。
/// 手势：左滑超过阈值展开删除按钮；已展开时点击内容收回；多选模式禁用滑动。
class _NotifyTile extends StatefulWidget {
  const _NotifyTile({
    required this.notify,
    required this.onTap,
    required this.onLongPress,
    required this.onDelete,
    required this.onOpenChange,
    this.selected = false,
    this.selectMode = false,
    this.open = false,
  });

  final Map<String, dynamic> notify;

  /// 点击（多选模式由父级切换勾选，普通模式标记已读）
  final VoidCallback onTap;
  /// 长按进入多选
  final VoidCallback onLongPress;
  /// 点击删除按钮
  final VoidCallback onDelete;
  /// 展开状态变化（父级维护互斥）
  final ValueChanged<bool> onOpenChange;

  /// 多选模式下是否已勾选
  final bool selected;
  /// 多选模式（禁用滑动）
  final bool selectMode;
  /// 是否展开删除按钮（由父级 _openId 驱动）
  final bool open;

  @override
  State<_NotifyTile> createState() => _NotifyTileState();
}

class _NotifyTileState extends State<_NotifyTile>
    with SingleTickerProviderStateMixin {
  /// 右侧删除按钮宽度（px）
  static const double _actionWidth = 72;

  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: widget.open ? 1 : 0,
  );

  bool _dragging = false;
  double _startPixels = 0;
  double _accDx = 0;

  @override
  void didUpdateWidget(covariant _NotifyTile old) {
    super.didUpdateWidget(old);
    // 父级互斥：本条目展开状态变化时跟随
    if (widget.open != old.open) _animateTo(widget.open ? 1 : 0);
    // 进入多选模式强制收回
    if (widget.selectMode && !old.selectMode && _ctrl.value > 0) {
      _animateTo(0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _animateTo(double v) {
    _ctrl.animateTo(v, curve: Curves.easeOutCubic);
  }

  void _onDragStart(DragStartDetails d) {
    if (widget.selectMode) return;
    _dragging = true;
    _ctrl.stop();
    _startPixels = _ctrl.value * _actionWidth;
    _accDx = 0;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (!_dragging) return;
    _accDx += d.primaryDelta ?? 0;
    final pixels = (_startPixels - _accDx).clamp(0.0, _actionWidth);
    _ctrl.value = pixels / _actionWidth;
  }

  void _onDragEnd(DragEndDetails d) {
    if (!_dragging) return;
    _dragging = false;
    final open = _ctrl.value > 0.45;
    if (open != widget.open) widget.onOpenChange(open);
    _animateTo(open ? 1 : 0);
  }

  /// 点击内容：已展开则收回，否则交给父级
  void _handleTap() {
    if (_ctrl.value > 0.05) {
      widget.onOpenChange(false);
      _animateTo(0);
      return;
    }
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _onDragStart,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: _onDragEnd,
        child: Stack(
          children: [
            // 底层：右侧删除按钮（内容左移后露出；胶囊圆形按钮，仅图标）
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: _actionWidth,
                  height: double.infinity,
                  child: Center(
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: Material(
                        color: kDanger,
                        shape: const CircleBorder(),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: widget.onDelete,
                          child: const Center(
                            child: Icon(Icons.delete_outline_rounded,
                                color: Colors.white, size: 20),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 上层：内容随手势平移
            AnimatedBuilder(
              animation: _ctrl,
              builder: (context, _) => Transform.translate(
                offset: Offset(-_ctrl.value * _actionWidth, 0),
                child: _buildContent(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final b = Theme.of(context).brightness;
    final notify = widget.notify;
    final type = (notify['type'] as num?)?.toInt() ?? 0;
    final fromName = notify['from_nickname']?.toString() ?? '';
    final avatar = notify['from_avatar']?.toString() ?? '';
    final commentContent = notify['comment_content']?.toString() ?? '';
    final postContent = notify['post_content']?.toString() ?? '';
    final isRead = (notify['is_read'] as num?)?.toInt() == 1;
    final time = _timeText((notify['create_time'] as num?)?.toInt() ?? 0);
    final title = _titleOf(notify);

    // 内容层必须不透明：否则未滑动时底层删除按钮会透出（已读无底色尤其明显）
    final bg = MobileTheme.pageBackground(b);
    return Material(
      color: widget.selected
          ? Color.alphaBlend(kPrimary.withValues(alpha: 0.10), bg)
          : (isRead ? bg : Color.alphaBlend(primarySoftColor(b), bg)),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: _handleTap,
        // 多选模式下长按无意义，禁用
        onLongPress: widget.selectMode ? null : widget.onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.selectMode) ...[
                _SelectCircle(selected: widget.selected),
                const SizedBox(width: 10),
              ],
              _NotifyAvatar(avatar: avatar, name: fromName),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (!isRead) ...[
                          Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.only(right: 6),
                            decoration: const BoxDecoration(
                              color: kDanger,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: isRead
                                  ? FontWeight.w500
                                  : FontWeight.w600,
                              color: isRead
                                  ? textMutedColor(b)
                                  : textColor(b),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(time,
                            style: TextStyle(
                                fontSize: 12, color: textFaintColor(b))),
                      ],
                    ),
                    if (commentContent.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        commentContent,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: isRead
                              ? textFaintColor(b)
                              : textSecondaryColor(b),
                        ),
                      ),
                    ],
                    // 次级小字：所在帖子内容（type=6 的 post_content 是星球名已在标题展示）
                    if (postContent.isNotEmpty &&
                        type != 6 &&
                        type != 7 &&
                        type != 8) ...[
                      const SizedBox(height: 6),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: bgHoverColor(b),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '帖子：$postContent',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: isRead
                                ? textFaintColor(b)
                                : textMutedColor(b),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 多选勾选圈：未选空心圆 / 选中实心 kPrimary + 白色对勾（AnimatedContainer 过渡）
class _SelectCircle extends StatelessWidget {
  const _SelectCircle({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? kPrimary : Colors.transparent,
        border: Border.all(
          color: selected ? kPrimary : textFaintColor(b),
          width: 1.5,
        ),
      ),
      child: selected
          ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
          : null,
    );
  }
}

/// 通知触发者头像（网络图 + 加载中占位 + 失败首字占位）
class _NotifyAvatar extends StatelessWidget {
  const _NotifyAvatar({required this.avatar, required this.name});

  final String avatar;
  final String name;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final initial = name.isNotEmpty ? name.characters.first : '?';
    final placeholder = Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: primarySoftColor(b),
        shape: BoxShape.circle,
      ),
      child: SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: kPrimary),
      ),
    );
    final url = avatar.isNotEmpty ? AppConfig.resolveUrl(avatar) : '';
    return ClipOval(
      child: SizedBox(
        width: 44,
        height: 44,
        child: url.isEmpty
            ? _AvatarFallback(name: initial)
            : Image.network(
                url,
                fit: BoxFit.cover,
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : placeholder,
                errorBuilder: (_, __, ___) => _AvatarFallback(name: initial),
              ),
      ),
    );
  }
}

class _AvatarFallback extends StatelessWidget {
  const _AvatarFallback({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [kPrimary.withValues(alpha: 0.9), kPrimary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Text(
        name,
        style: const TextStyle(
            color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 通知标题文案（type 与桌面端一致）
String _titleOf(Map<String, dynamic> n) {
  final type = (n['type'] as num?)?.toInt() ?? 0;
  final fromName = n['from_nickname']?.toString() ?? '';
  final postContent = n['post_content']?.toString() ?? '';
  switch (type) {
    case 3:
      return '$fromName 关注了你';
    case 4:
      return '$fromName 赞了你的动态';
    case 5:
      return '$fromName 收藏了你的动态';
    case 2:
      return '$fromName 回复了你';
    case 6:
      return postContent.isNotEmpty
          ? '$fromName 在$postContent星球和你配对了'
          : '$fromName 和你配对了';
    case 7:
      return '$fromName 解除了与你的绑定关系';
    case 8:
      return '$fromName 长期未上线，绑定已自动解除';
    default:
      return '$fromName 评论了你的动态';
  }
}

/// 时间文案：今天 HH:mm / 昨天 HH:mm / 今年 M月d日 / 更早 yyyy-MM-dd
String _timeText(int ts) {
  if (ts <= 0) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  final hm =
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  if (diff == 0) return hm;
  if (diff == 1) return '昨天 $hm';
  if (t.year == now.year) return '${t.month}月${t.day}日';
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

/// 空状态：无通知时展示（外层 RefreshIndicator 已支持下拉刷新）
class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    final muted = textMutedColor(Theme.of(context).brightness);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.notifications_none_rounded,
              size: 64, color: muted.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text('暂无通知',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text('评论、回复与系统消息会出现在这里',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: muted)),
        ],
      ),
    );
  }
}

/// 骨架屏（平滑加载）：网络请求期间以脉动灰条占位，替代转圈菊花，
/// 让列表结构先出现、数据到达后再平滑填充。
class _SkeletonList extends StatefulWidget {
  const _SkeletonList();

  @override
  State<_SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<_SkeletonList>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final base = bgHoverColor(b);
    Widget bar(double w, double h) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: base,
            borderRadius: BorderRadius.circular(6),
          ),
        );
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) => SliverOpacity(
        opacity: 0.5 + 0.5 * _ctrl.value,
        sliver: SliverList.builder(
          itemCount: 9,
          itemBuilder: (context, i) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration:
                      BoxDecoration(color: base, shape: BoxShape.circle),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          bar(140, 13),
                          const SizedBox(width: 8),
                          bar(52, 10),
                        ],
                      ),
                      const SizedBox(height: 9),
                      bar(double.infinity, 12),
                      const SizedBox(height: 7),
                      bar(180, 12),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
