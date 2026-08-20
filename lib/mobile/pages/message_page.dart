import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/app_config.dart';
import '../../core/app_theme.dart';
import '../../services/chat_store.dart';
import '../../services/ws_service.dart';
import '../theme/mobile_theme.dart';
import 'chat_page.dart';
import 'notification_page.dart';

/// 移动端消息列表页（会话列表）
///
/// 规格（`docs/移动端UI规范.md` §4.3 / `docs/UI规范.md` §11）：
///  - 复用移动端通用骨架：安全区 + 内容列限宽居中 + 回弹滚动；
///  - 数据来自共享 `ChatStore`（sqflite），监听 `chatUnreadTick` 刷新未读；
///  - 会话项：头像 + 昵称/时间行 + 预览/未读红点行。
class MobileMessagePage extends StatefulWidget {
  const MobileMessagePage({super.key, required this.user});

  final Map<String, dynamic> user;

  @override
  State<MobileMessagePage> createState() => _MobileMessagePageState();
}

class _MobileMessagePageState extends State<MobileMessagePage> {
  List<Map<String, dynamic>> _items = [];
  /// 未合并好友信息的原始会话列表（sqflite 本地数据），供 _mergeItems 重建
  List<Map<String, dynamic>> _rawItems = [];
  Map<int, Map<String, dynamic>> _friendMap = {};
  bool _loading = true;
  /// 系统通知伪会话（最近一条内容 + 未读数）。
  /// 作为一条普通会话参与时间排序（不置顶），有新通知时自然排到最上行。
  Map<String, dynamic>? _notify;

  int get _uid => int.tryParse('${widget.user['id'] ?? 0}') ?? 0;

  /// 好友在线状态实时推送订阅（WS presence）
  StreamSubscription<({int userId, bool online})>? _presenceSub;
  /// WS 断线重连订阅（重连后 presence 事件可能丢失，重拉好友在线状态）
  StreamSubscription<void>? _reconnectedSub;
  /// 会话刷新防抖（收消息时 chatUnreadTick + conversationTick 可能连发，合并为一次刷新）
  Timer? _refreshDebounce;

  @override
  void initState() {
    super.initState();
    if (_uid > 0) ChatStore.instance.openForUser(_uid);
    // 未读变化 + 会话摘要变化（含自己发消息）都触发列表刷新
    ChatStore.instance.chatUnreadTick.addListener(_onTick);
    ChatStore.instance.conversationTick.addListener(_onTick);
    // 好友在线/离线实时刷新（好友消息页里保持在线状态最新，与 PC 一致）
    _presenceSub = WsService.instance.onPresence.listen((e) {
      if (!mounted) return;
      final f = _friendMap[e.userId];
      if (f == null) return; // 非会话好友（无会话不进列表），跳过
      f['online'] = e.online;
      _mergeItems();
    });
    // WS 重连成功后补一次好友拉取（离线期间的 presence 事件已丢失）
    _reconnectedSub = WsService.instance.onReconnectedStream.listen((_) {
      unawaited(_reloadFriends());
    });
    _load();
  }

  @override
  void dispose() {
    _presenceSub?.cancel();
    _reconnectedSub?.cancel();
    _refreshDebounce?.cancel();
    ChatStore.instance.chatUnreadTick.removeListener(_onTick);
    ChatStore.instance.conversationTick.removeListener(_onTick);
    super.dispose();
  }

  /// WS 重连后重拉好友列表（昵称/头像/在线状态），失败静默保留旧数据
  Future<void> _reloadFriends() async {
    await _loadFriends();
    if (!mounted) return;
    _mergeItems();
  }

  void _onTick() {
    // 未读数 / 会话变化（新消息、已读、撤回、自己发消息）时静默刷新。
    // 防抖：chatUnreadTick + conversationTick 可能连发，合并为一次刷新
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      _load();
    });
  }

  Future<void> _load() async {
    final list = await ChatStore.instance.getConversations();
    if (!mounted) return;
    _rawItems = list;
    // 平滑加载：本地会话立即渲染（sqflite 秒出），不阻塞在拉好友/拉通知的网络上；
    // 好友昵称/头像、系统通知在后台异步补全后再重建列表。
    _mergeItems();
    if (mounted && _loading) setState(() => _loading = false);
    // 首次加载后台拉一次好友列表，按 peer_id 补真实昵称/头像
    if (_friendMap.isEmpty) {
      await _loadFriends();
      if (!mounted) return;
      _mergeItems();
    }
    _loadNotify();
  }

  /// 重建列表：本地会话 + 好友信息 + 系统通知伪会话合并后按时间排序。
  void _mergeItems() {
    final items = _rawItems.map((c) {
      final peerId = int.tryParse('${c['peer_id'] ?? 0}') ?? 0;
      final f = _friendMap[peerId];
      if (f == null) return c;
      return {
        ...c,
        if ((c['peer_nickname'] as String?)?.isNotEmpty != true &&
            (f['nickname'] as String?)?.isNotEmpty == true)
          'peer_nickname': f['nickname'],
        if ((c['peer_avatar'] as String?)?.isNotEmpty != true &&
            (f['avatar'] as String?)?.isNotEmpty == true)
          'peer_avatar': f['avatar'],
        // 在线状态从好友列表实时取（会话本地缓存无 online 字段）
        if (c['online'] == null) 'online': (f['online'] ?? false) == true,
      };
    }).toList();
    // 系统通知作为一条普通会话参与排序（不置顶），有新通知时自然排最上
    if (_notify != null) items.add(_notify!);
    items.sort((a, b) => ((b['last_msg_time'] as num?)?.toInt() ?? 0)
        .compareTo((a['last_msg_time'] as num?)?.toInt() ?? 0));
    if (mounted) setState(() => _items = items);
  }

  /// 拉取系统通知：最近一条内容 + 未读数，构造"系统通知"伪会话。
  /// 与会话一起按时间排序，有新通知时（时间最新）自动浮到最上行。
  Future<void> _loadNotify() async {
    try {
      final results = await Future.wait([
        ApiClient.instance
            .getNotificationList(page: 1, pageSize: 1)
            .timeout(const Duration(seconds: 8)),
        ApiClient.instance
            .getNotificationUnreadCount()
            .timeout(const Duration(seconds: 8)),
      ]);
      if (!mounted) return;
      final json = ApiClient.safeJsonDecode(results[0].body);
      final unreadJson = ApiClient.safeJsonDecode(results[1].body);
      final unread = unreadJson['code'] == 0
          ? ((unreadJson['data'] as Map<String, dynamic>? ?? {})
                      ['unread_count'] as num?)
                  ?.toInt() ??
              0
          : 0;
      Map<String, dynamic>? notice;
      if (json['code'] == 0) {
        final data = json['data'] as Map<String, dynamic>? ?? {};
        final list = (data['list'] as List?) ?? const [];
        if (list.isNotEmpty) {
          final n = Map<String, dynamic>.from(list.first as Map);
          notice = {
            'is_system_notice': true,
            'chat_id': '__notify__',
            'peer_nickname': '系统通知',
            'last_msg_text': _notifyPreview(n),
            'last_msg_time': (n['create_time'] as num?)?.toInt() ?? 0,
            'unread_count': unread,
          };
        }
      }
      // 未读 >0 但列表拉取失败（异常/弱网）时仍保留入口，避免遗漏
      if (notice == null && unread > 0) {
        notice = {
          'is_system_notice': true,
          'chat_id': '__notify__',
          'peer_nickname': '系统通知',
          'last_msg_text': '$unread 条未读通知',
          'last_msg_time': 0,
          'unread_count': unread,
        };
      }
      final same = (_notify == null && notice == null) ||
          (_notify != null &&
              notice != null &&
              _notify!['last_msg_text'] == notice['last_msg_text'] &&
              _notify!['last_msg_time'] == notice['last_msg_time'] &&
              _notify!['unread_count'] == notice['unread_count']);
      if (same) return;
      _notify = notice;
      _mergeItems();
    } catch (_) {
      // 通知拉取失败不影响会话列表
    }
  }

  /// 拉全好友列表缓存（昵称/头像/在线状态），失败静默（头像回退首字占位）
  Future<void> _loadFriends() async {
    final map = <int, Map<String, dynamic>>{};
    try {
      var page = 1;
      var hasMore = true;
      while (hasMore && page <= 10) {
        final resp = await ApiClient.instance
            .getFriends(page: page, pageSize: 100)
            .timeout(const Duration(seconds: 15));
        final json = ApiClient.safeJsonDecode(resp.body);
        final data = json['data'];
        final list = data is Map ? (data['list'] as List?) ?? const [] : const [];
        for (final e in list) {
          final m = Map<String, dynamic>.from(e as Map);
          final id = int.tryParse('${m['user_id'] ?? 0}') ?? 0;
          if (id > 0) map[id] = m;
        }
        hasMore = data is Map && (data['has_more'] ?? false) == true && list.isNotEmpty;
        page++;
      }
    } catch (_) {
      // 好友拉取失败不影响会话列表
    }
    _friendMap = map;
  }

  Future<void> _refresh() async {
    await ChatStore.instance.syncConversationsFromMessages(_uid);
    await _loadFriends();
    await _load();
  }

  /// 打开系统通知列表页，返回后刷新系统通知（内容/时间/未读，重新参与排序）
  Future<void> _openNotifyPage(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MobileNotificationPage(
          user: widget.user,
          onChanged: _loadNotify,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics()),
              slivers: _buildSlivers(context),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildSlivers(BuildContext context) {
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        sliver: SliverToBoxAdapter(
          child: Text('消息',
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
        ),
      ),
      if (_loading)
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        )
      else if (_items.isEmpty)
        const SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyView(),
        )
      else
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
          sliver: SliverList.builder(
            itemCount: _items.length,
            itemBuilder: (context, i) {
              final c = _items[i];
              return _ConversationTile(
                conversation: c,
                onTap: c['is_system_notice'] == true
                    ? () => _openNotifyPage(context)
                    : () => _openChat(context, c),
              );
            },
          ),
        ),
    ];
  }

  void _openChat(BuildContext context, Map<String, dynamic> c) {
    if (_uid <= 0) return;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => MobileChatPage(
          peer: c,
          currentUserId: _uid,
          myAvatar: widget.user['avatar']?.toString(),
        ),
      ),
    );
  }
}

/// 会话项：头像 + 昵称/时间 + 预览/未读红点。
/// 系统通知为一条特殊会话（is_system_notice=true）：铃铛头像、预览为最近通知内容。
class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.conversation, required this.onTap});

  final Map<String, dynamic> conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final isNotice = conversation['is_system_notice'] == true;
    final nickname =
        (conversation['peer_nickname'] as String?)?.isNotEmpty == true
            ? conversation['peer_nickname'] as String
            : (conversation['peer_username'] as String? ?? '');
    final avatar = conversation['peer_avatar'] as String?;
    // 预览：会话表 last_msg_text 已是转换后的友好文本（[图片]/[表情]/正文），
    // 老数据缺失时用 conversationPreview 从消息字段兜底推导
    final preview = (conversation['last_msg_text'] as String?)?.isNotEmpty == true
        ? conversation['last_msg_text'] as String
        : ChatStore.conversationPreview(conversation);
    final unread = (conversation['unread_count'] as int?) ?? 0;
    final time =
        _timeText((conversation['last_msg_time'] as num?)?.toInt() ?? 0);
    final muted = textMutedColor(b);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _PeerAvatar(
                avatar: avatar,
                nickname: nickname,
                isNotice: isNotice,
                online: conversation['online'] == true,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            nickname,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(time,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: muted)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: muted),
                          ),
                        ),
                        if (unread > 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFF3B30),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              unread > 99 ? '99+' : '$unread',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ],
                    ),
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

/// 会话头像：网络图 + 首字占位 + 右下角在线状态圆点（QQ 逻辑，参考 PC）
/// 系统通知显示铃铛渐变圆底（不显示在线圆点）。
class _PeerAvatar extends StatelessWidget {
  const _PeerAvatar(
      {required this.avatar,
      required this.nickname,
      this.isNotice = false,
      this.online = false});

  final String? avatar;
  final String nickname;
  final bool isNotice;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final initial = nickname.isNotEmpty ? nickname.characters.first : '?';
    // 系统通知头像：铃铛渐变圆底（与会话卡片布局一致，仅图标不同）
    if (isNotice) {
      return Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [kPrimary.withValues(alpha: 0.9), kPrimary],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.notifications_rounded,
            color: Colors.white, size: 26),
      );
    }
    // 加载中占位：主题浅色圆底 + 旋转菊花
    final loading = Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: primarySoftColor(b),
        shape: BoxShape.circle,
      ),
      child: SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2.2,
          color: kPrimary,
        ),
      ),
    );
    // 头像 + 右下角在线圆点（QQ 逻辑：圆点覆盖头像右下角一部分，带描边更清晰）
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipOval(
          child: SizedBox(
            width: 52,
            height: 52,
            child: avatar != null && avatar!.isNotEmpty
                ? Image.network(
                    AppConfig.resolveUrl(avatar),
                    fit: BoxFit.cover,
                    loadingBuilder: (context, child, progress) =>
                        progress == null ? child : loading,
                    errorBuilder: (_, __, ___) => _Fallback(name: initial),
                  )
                : _Fallback(name: initial),
          ),
        ),
        Positioned(
          right: 1,
          bottom: 1,
          child: Container(
            width: 11,
            height: 11,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // 绿=在线，灰=离线
              color: online ? kSuccess : textFaintColor(b),
              // 描边与所在页面背景一致，视觉上"切"进头像
              border: Border.all(
                  color: MobileTheme.pageBackground(b), width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback({required this.name});

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
            color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 系统通知预览文案：标题 + 评论内容（单行，会话卡样式与普通会话一致）
String _notifyPreview(Map<String, dynamic> n) {
  final type = (n['type'] as num?)?.toInt() ?? 0;
  final fromName = n['from_nickname']?.toString() ?? '';
  final postContent = n['post_content']?.toString() ?? '';
  String title;
  switch (type) {
    case 2:
      title = '$fromName 回复了你';
      break;
    case 3:
      title = '$fromName 关注了你';
      break;
    case 4:
      title = '$fromName 赞了你的动态';
      break;
    case 5:
      title = '$fromName 收藏了你的动态';
      break;
    case 6:
      title = postContent.isNotEmpty
          ? '$fromName 在$postContent星球和你配对了'
          : '$fromName 和你配对了';
      break;
    case 7:
      title = '$fromName 解除了与你的绑定关系';
      break;
    case 8:
      title = '$fromName 长期未上线，绑定已自动解除';
      break;
    default:
      title = '$fromName 评论了你的动态';
  }
  final comment = n['comment_content']?.toString() ?? '';
  return comment.isNotEmpty ? '$title：$comment' : title;
}

/// 会话时间文案：今天 HH:mm / 昨天 HH:mm / 今年 M月d日 / 更早 yyyy-MM-dd
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

/// 空状态：无会话时展示（外层 RefreshIndicator 已支持下拉刷新）
class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    final muted = textMutedColor(Theme.of(context).brightness);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined,
              size: 64, color: muted.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text('暂无消息',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text('发起聊天或收到回复后会显示在这里',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: muted)),
        ],
      ),
    );
  }
}
