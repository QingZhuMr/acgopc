import 'dart:async';

import 'package:flutter/material.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../core/app_theme.dart';
import '../services/chat_service.dart';
import '../services/chat_store.dart';
import '../services/ws_service.dart';
import '../utils/net_image.dart';
import '../widgets/notify.dart';

/// 消息页（左侧导航栏「消息」入口）
///
/// 左侧：好友列表（互相关注的用户），分页加载；右侧：聊天界面。
/// 聊天基于 E2EE（X25519 + AES-GCM），密文走服务器，本地 SQLite 存明文。
///
/// 样式遵循 docs/UI规范.md：颜色一律用 app_theme.dart 函数/常量。
class MessagePage extends StatefulWidget {
  final int currentUserId;

  const MessagePage({super.key, required this.currentUserId});

  @override
  State<MessagePage> createState() => _MessagePageState();
}

class _MessagePageState extends State<MessagePage> {
  final List<Map<String, dynamic>> _friends = [];
  int _page = 1;
  bool _loading = false;
  bool _loadingMore = false;
  bool _allLoaded = false;
  bool _loadFailed = false;

  /// 左侧视图：0=会话 1=好友
  int _viewMode = 0;

  /// 本地会话列表（最近消息 + 未读）
  List<Map<String, dynamic>> _conversations = [];

  /// 当前选中好友
  Map<String, dynamic>? _selectedFriend;

  /// 聊天消息（本地 SQLite 明文，倒序存储 → 展示时反转）
  List<Map<String, dynamic>> _messages = [];

  /// 会话好友公钥（发消息用）
  String? _peerPublicKey;

  /// 对方是否在线（绿点/灰点）
  bool _peerOnline = false;

  final TextEditingController _inputCtrl = TextEditingController();
  bool _sending = false;

  StreamSubscription<Map<String, dynamic>>? _chatSub;
  StreamSubscription<Map<String, dynamic>>? _chatReadSub;

  @override
  void initState() {
    super.initState();
    _loadFriends();
    _loadConversations();
    // 全局监听聊天新消息：刷新会话列表 + 未读
    _chatReadSub = WsService.instance.onChatRead.listen((read) {
      if (!mounted) return;
      final readMsgId = (read['msg_id'] as num?)?.toInt() ?? 0;
      final readerId = (read['user_id'] as num?)?.toInt() ?? 0;
      if (readMsgId > 0) {
        // 对方已读我的消息：更新本地已读状态
        final chatId = read['chat_id']?.toString() ?? '';
        ChatStore.instance.markMessagesReadByMsgIds(chatId, readerId, readMsgId);
        if (chatId.isNotEmpty && _selectedFriend != null) {
          _loadLocalMessages();
        }
      }
    });
  }

  @override
  void dispose() {
    _chatSub?.cancel();
    _chatReadSub?.cancel();
    _inputCtrl.dispose();
    super.dispose();
  }

  /// 加载本地会话列表
  Future<void> _loadConversations() async {
    final rows = await ChatStore.instance.getConversations();
    if (!mounted) return;
    setState(() => _conversations = rows);
  }

  Future<void> _loadFriends() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final resp = await ApiClient.instance
          .getFriends(page: 1, pageSize: 50)
          .timeout(const Duration(seconds: 15));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (!mounted) return;
      if (json['code'] != 0) {
        NotifyStack.warning(json['msg']?.toString() ?? '加载失败', title: '提示');
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
        return;
      }
      final data = (json['data'] ?? {}) as Map<String, dynamic>;
      final list = (data['list'] ?? []) as List;
      setState(() {
        _friends.clear();
        _friends.addAll(list.map((e) => Map<String, dynamic>.from(e)));
        _page = 1;
        _allLoaded = !(data['has_more'] ?? false);
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      }
    }
  }

  Future<void> _loadMoreFriends() async {
    if (_loadingMore || _allLoaded) return;
    setState(() => _loadingMore = true);
    try {
      final resp = await ApiClient.instance
          .getFriends(page: _page + 1, pageSize: 50)
          .timeout(const Duration(seconds: 15));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (!mounted) return;
      if (json['code'] == 0) {
        final data = (json['data'] ?? {}) as Map<String, dynamic>;
        final list = (data['list'] ?? []) as List;
        setState(() {
          _friends.addAll(list.map((e) => Map<String, dynamic>.from(e)));
          _page++;
          _allLoaded = !(data['has_more'] ?? false);
          _loadingMore = false;
        });
      } else {
        setState(() => _loadingMore = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// 选中好友 → 初始化聊天
  Future<void> _selectFriend(Map<String, dynamic> friend) async {
    setState(() {
      _selectedFriend = friend;
      _messages = [];
      _peerPublicKey = null;
      _peerOnline = (friend['online'] ?? false) == true;
    });
    _chatSub?.cancel();
    // 监听 WS 新消息：刷新会话列表 + 当前会话重新加载
    _chatSub = WsService.instance.onChatMessage.listen((msg) {
      if (!mounted) return;
      final peerId = (msg['sender_id'] as num?)?.toInt() ?? 0;
      final selectedUid = (_selectedFriend?['user_id'] as num?)?.toInt() ?? 0;
      if (peerId == selectedUid) {
        _loadLocalMessages();
        _reportReadUpTo(msg);
      }
      _loadConversations();
    });

    try {
      await ChatService.instance.init(widget.currentUserId);
      // 拉对方公钥
      final keys = await ApiClient.instance
          .getChatKeys([(friend['user_id'] as num?)?.toInt() ?? 0]);
      final json = ApiClient.safeJsonDecode(keys.body);
      if (json['code'] == 0) {
        final keyMap = (json['data'] ?? {})['keys'] as Map? ?? {};
        _peerPublicKey = keyMap['${friend['user_id']}']?.toString();
      }
      // 拉历史
      final peerId = (friend['user_id'] as num?)?.toInt() ?? 0;
      await ChatService.instance.pullHistory(peerId: peerId);
      // 打开会话：清零本地未读 + 标记本地消息已读 + 上报服务器
      final myUid = widget.currentUserId;
      final chatId =
          '${myUid < peerId ? myUid : peerId}_${myUid < peerId ? peerId : myUid}';
      await ChatStore.instance.clearUnread(chatId);
      await ChatStore.instance.markChatRead(chatId, myUid);
      _reportReadUpTo(null);
      _loadConversations();
      _loadLocalMessages();
    } catch (_) {
      _loadLocalMessages();
    }
  }

  /// 上报已读：把当前会话对方发来的最大消息 id 发给服务器
  Future<void> _reportReadUpTo(Map<String, dynamic>? justReceived) async {
    final friend = _selectedFriend;
    if (friend == null) return;
    final peerId = (friend['user_id'] as num?)?.toInt() ?? 0;
    if (peerId <= 0) return;
    // 找当前会话中对方发来的最大 msg_id
    final myUid = widget.currentUserId;
    final chatId = '${myUid < peerId ? myUid : peerId}_${myUid < peerId ? peerId : myUid}';
    final rows = await ChatStore.instance.getMessages(chatId, limit: 500);
    int maxMsgId = 0;
    for (final r in rows) {
      final sender = (r['sender_id'] as num?)?.toInt() ?? 0;
      final msgId = (r['msg_id'] as num?)?.toInt() ?? 0;
      if (sender != myUid && msgId > maxMsgId) maxMsgId = msgId;
    }
    final justId = (justReceived?['id'] as num?)?.toInt() ?? 0;
    if (justId > maxMsgId) maxMsgId = justId;
    if (maxMsgId <= 0) return;
    // 静默上报
    try {
      await ApiClient.instance
          .markChatRead(peerId: peerId, msgId: maxMsgId)
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  Future<void> _loadLocalMessages() async {
    final friend = _selectedFriend;
    if (friend == null) return;
    final myUid = widget.currentUserId;
    final peerId = (friend['user_id'] as num?)?.toInt() ?? 0;
    final chatId = '${myUid < peerId ? myUid : peerId}_${myUid < peerId ? peerId : myUid}';
    final rows = await ChatStore.instance.getMessages(chatId, limit: 200);
    if (!mounted) return;
    setState(() {
      _messages = rows.reversed.toList();
    });
  }

  /// 手动重发失败消息（复用原 client_msg_id 保证幂等）
  Future<void> _retryMessage(Map<String, dynamic> m) async {
    final clientMsgId = m['client_msg_id']?.toString() ?? '';
    final plaintext = m['plaintext']?.toString() ?? '';
    final peerId = (m['receiver_id'] as num?)?.toInt() ?? 0;
    if (clientMsgId.isEmpty || plaintext.isEmpty || peerId <= 0) return;
    // 标记发送中
    await ChatStore.instance.updateSendStatus(
        clientMsgId: clientMsgId, sendStatus: 0);
    if (mounted) await _loadLocalMessages();
    final result = await ChatService.instance.sendMessage(
      receiverId: peerId,
      plaintext: plaintext,
      peerPublicKey: _peerPublicKey,
      forceClientMsgId: clientMsgId,
    );
    if (!mounted) return;
    if (!result.ok) {
      NotifyStack.warning(result.error, title: '提示');
    }
    await _loadLocalMessages();
    await _loadConversations();
  }

  /// 发送消息（乐观更新 + 异步发送，幂等 client_msg_id）
  Future<void> _sendMessage() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    final friend = _selectedFriend;
    if (friend == null) return;
    final peerId = (friend['user_id'] as num?)?.toInt() ?? 0;
    setState(() => _sending = true);

    // 先生成幂等 client_msg_id（乐观消息与实际发送共用，避免两条记录）
    final clientMsgId =
        '${widget.currentUserId}_${DateTime.now().millisecondsSinceEpoch}';

    // 乐观更新：先展示本地消息
    final myUid = widget.currentUserId;
    final chatId = '${myUid < peerId ? myUid : peerId}_${myUid < peerId ? peerId : myUid}';
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await ChatStore.instance.upsertMessage(
      chatId: chatId,
      msgId: 0,
      clientMsgId: clientMsgId,
      senderId: myUid,
      receiverId: peerId,
      msgType: 1,
      plaintext: text,
      ciphertext: '',
      nonce: '',
      ephemeralPub: '',
      sendStatus: 0,
      createTime: now,
    );
    _inputCtrl.clear();
    await _loadLocalMessages();

    final result = await ChatService.instance.sendMessage(
      receiverId: peerId,
      plaintext: text,
      peerPublicKey: _peerPublicKey,
      forceClientMsgId: clientMsgId,
    );
    if (!mounted) return;
    if (!result.ok) {
      NotifyStack.warning(result.error, title: '提示');
    }
    setState(() => _sending = false);
    await _loadLocalMessages();
    await _loadConversations();
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Scaffold(
      // 聊天内容页用主背景色
      backgroundColor: bgColor(b),
      body: Row(
        children: [
          // ===== 左侧好友列表（无分割线）：颜色比聊天区深（用 bgSoft，同左侧导航栏） =====
          Container(
            width: 260,
            color: bgSoftColor(b),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 会话 / 好友 视图切换
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: Row(
                    children: [
                      _viewSwitch(b, 0, '会话'),
                      const SizedBox(width: 4),
                      _viewSwitch(b, 1, '好友'),
                    ],
                  ),
                ),
                Expanded(
                  child: _viewMode == 0
                      ? _buildConversationList(b)
                      : _buildFriendList(b),
                ),
              ],
            ),
          ),
          // ===== 右侧聊天区 =====
          Expanded(
            child: _buildChatArea(b),
          ),
        ],
      ),
    );
  }

  /// 视图切换胶囊按钮
  Widget _viewSwitch(Brightness b, int mode, String label) {
    final selected = _viewMode == mode;
    return InkWell(
      onTap: () {
        if (_viewMode == mode) return;
        setState(() => _viewMode = mode);
        if (mode == 1) _loadFriends();
      },
      mouseCursor: SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(kRadiusFull),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? primarySoftColor(b) : Colors.transparent,
          borderRadius: BorderRadius.circular(kRadiusFull),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? kPrimary : textSecondaryColor(b),
          ),
        ),
      ),
    );
  }

  /// 会话列表（本地驱动：最近消息 + 未读）
  Widget _buildConversationList(Brightness b) {
    if (_conversations.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_rounded, size: 40, color: textFaintColor(b)),
            const SizedBox(height: 12),
            Text(
              '还没有会话',
              style: TextStyle(fontSize: 14, color: textSecondaryColor(b)),
            ),
            const SizedBox(height: 4),
            Text(
              '去「好友」里找好友开始聊天吧',
              style: TextStyle(fontSize: 12, color: textMutedColor(b)),
            ),
          ],
        ),
      );
    }
    return SilkyListView(
      children: [
        for (final c in _conversations) _buildConversationItem(b, c),
      ],
      scrollSpeed: 1.6,
      silkyScrollDuration: const Duration(milliseconds: 600),
      animationCurve: Curves.easeOutCubic,
    );
  }

  /// 会话项：头像 + 昵称 + 最后消息 + 未读 + 时间
  Widget _buildConversationItem(Brightness b, Map<String, dynamic> c) {
    final peerId = (c['peer_id'] as num?)?.toInt() ?? 0;
    final nickname = c['peer_nickname']?.toString() ?? '好友';
    final avatar = c['peer_avatar']?.toString() ?? '';
    final lastText = c['last_msg_text']?.toString() ?? '';
    final unread = (c['unread_count'] as num?)?.toInt() ?? 0;
    final lastTime = (c['last_msg_time'] as num?)?.toInt() ?? 0;
    final selected = _selectedFriend?['user_id'] == peerId;

    final friend = {
      'user_id': peerId,
      'nickname': nickname,
      'avatar': avatar,
    };
    return InkWell(
      onTap: () => _selectFriend(friend),
      hoverColor: bgHoverColor(b),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        color: selected ? primarySoftColor(b) : Colors.transparent,
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
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
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
                      if (lastTime > 0)
                        Text(
                          _timeText(lastTime),
                          style: TextStyle(
                              fontSize: 11, color: textFaintColor(b)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          lastText,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 12,
                            color: textMutedColor(b),
                          ),
                        ),
                      ),
                      if (unread > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: kDanger,
                            borderRadius: BorderRadius.circular(kRadiusFull),
                          ),
                          child: Text(
                            unread > 99 ? '99+' : '$unread',
                            style: const TextStyle(
                                fontSize: 10,
                                color: Colors.white,
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
    );
  }

  Widget _buildFriendList(Brightness b) {
    if (_loading && _friends.isEmpty) {
      return Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: kPrimary),
      );
    }
    if (_loadFailed && _friends.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败', style: TextStyle(fontSize: 13, color: textMutedColor(b))),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _loadFriends,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_friends.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_rounded,
                size: 40, color: textFaintColor(b)),
            const SizedBox(height: 12),
            Text(
              '还没有好友',
              style: TextStyle(fontSize: 14, color: textSecondaryColor(b)),
            ),
            const SizedBox(height: 4),
            Text(
              '互相关注后即可成为好友',
              style: TextStyle(fontSize: 12, color: textMutedColor(b)),
            ),
          ],
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels >= n.metrics.maxScrollExtent - 80) {
          _loadMoreFriends();
        }
        return false;
      },
      child: SilkyListView(
        children: [
          for (final friend in _friends) _buildFriendItem(b, friend),
          if (!_allLoaded)
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
        scrollSpeed: 1.6,
        silkyScrollDuration: const Duration(milliseconds: 600),
        animationCurve: Curves.easeOutCubic,
      ),
    );
  }

  Widget _buildFriendItem(Brightness b, Map<String, dynamic> friend) {
    final selected = _selectedFriend?['user_id'] ==
        (friend['user_id'] as num?)?.toInt();
    final avatar = friend['avatar']?.toString() ?? '';
    final nickname = friend['nickname']?.toString() ?? '';
    return InkWell(
      onTap: () => _selectFriend(friend),
      hoverColor: bgHoverColor(b),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        color: selected ? primarySoftColor(b) : Colors.transparent,
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
            const SizedBox(width: 10),
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
          ],
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

  /// 右侧聊天区
  Widget _buildChatArea(Brightness b) {
    final friend = _selectedFriend;
    if (friend == null) {
      return Center(
        child: Icon(
          Icons.chat_bubble_rounded,
          size: 64,
          color: textFaintColor(b),
        ),
      );
    }
    final nickname = friend['nickname']?.toString() ?? '';
    final avatar = friend['avatar']?.toString() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 聊天对象标题栏（无分割线，主背景色）
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: bgColor(b),
          child: Row(
            children: [
              ClipOval(
                child: avatar.isNotEmpty
                    ? NetImage(
                        url: AppConfig.resolveUrl(avatar),
                        width: 32,
                        height: 32,
                        fit: BoxFit.cover,
                        loadingSize: 14,
                      )
                    : _avatarPlaceholder(b, nickname),
              ),
              const SizedBox(width: 10),
              Text(
                nickname,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: textColor(b),
                ),
              ),
              // 在线状态小圆点：绿=在线 灰=离线
              const SizedBox(width: 6),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _peerOnline ? kSuccess : textFaintColor(b),
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
        // 消息区
        Expanded(
          child: _buildMessageList(b),
        ),
        // 输入区（无分割线，主背景色）
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: bgColor(b),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: bgHoverColor(b),
                    borderRadius: BorderRadius.circular(kRadiusMd),
                  ),
                  child: TextField(
                    controller: _inputCtrl,
                    onSubmitted: (_) => _sendMessage(),
                    style: TextStyle(fontSize: 14, color: textColor(b)),
                    decoration: InputDecoration(
                      hintText: '发送消息…',
                      hintStyle:
                          TextStyle(fontSize: 14, color: textFaintColor(b)),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 发送按钮
              InkWell(
                onTap: _sending ? null : _sendMessage,
                mouseCursor: SystemMouseCursors.click,
                borderRadius: BorderRadius.circular(kRadiusFull),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: kPrimary,
                    borderRadius: BorderRadius.circular(kRadiusFull),
                  ),
                  child: _sending
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : Icon(Icons.send_rounded,
                          size: 16, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 消息列表（气泡）
  Widget _buildMessageList(Brightness b) {
    if (_messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 40, color: textFaintColor(b)),
            const SizedBox(height: 12),
            Text(
              '和好友打个招呼吧',
              style: TextStyle(fontSize: 14, color: textSecondaryColor(b)),
            ),
          ],
        ),
      );
    }
    return SilkyListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        for (final m in _messages) _buildMessageBubble(b, m),
      ],
      scrollSpeed: 1.6,
      silkyScrollDuration: const Duration(milliseconds: 600),
      animationCurve: Curves.easeOutCubic,
    );
  }

  Widget _buildMessageBubble(Brightness b, Map<String, dynamic> m) {
    final senderId = (m['sender_id'] as num?)?.toInt() ?? 0;
    final isMine = senderId == widget.currentUserId;
    final plaintext = m['plaintext']?.toString() ?? '';
    final createTime = (m['create_time'] as num?)?.toInt() ?? 0;
    final timeText = _timeText(createTime);
    final sendStatus = (m['send_status'] as num?)?.toInt() ?? 1;

    final bubbleColor = isMine ? kPrimary : bgHoverColor(b);
    final textColorB = isMine ? Colors.white : textColor(b);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment:
            isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMine) ...[
            // 对方头像
            ClipOval(
              child: _peerAvatar(b),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isMine
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                Container(
                  constraints: const BoxConstraints(maxWidth: 420),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: bubbleColor,
                    borderRadius: BorderRadius.circular(kRadiusMd),
                  ),
                  child: Text(
                    plaintext,
                    style: TextStyle(fontSize: 14, color: textColorB, height: 1.4),
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      timeText,
                      style: TextStyle(fontSize: 11, color: textFaintColor(b)),
                    ),
                    if (isMine && sendStatus == 0) ...[
                      const SizedBox(width: 4),
                      Icon(Icons.schedule, size: 12, color: textFaintColor(b)),
                    ] else if (isMine && sendStatus == 2) ...[
                      const SizedBox(width: 4),
                      // 失败消息可点击重发
                      InkWell(
                        onTap: () => _retryMessage(m),
                        mouseCursor: SystemMouseCursors.click,
                        borderRadius: BorderRadius.circular(4),
                        child: Tooltip(
                          message: '发送失败，点击重发',
                          child: Icon(Icons.error_outline,
                              size: 12, color: kDanger),
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
    );
  }

  Widget _peerAvatar(Brightness b) {
    final friend = _selectedFriend;
    final avatar = friend?['avatar']?.toString() ?? '';
    final nickname = friend?['nickname']?.toString() ?? '';
    return avatar.isNotEmpty
        ? NetImage(
            url: AppConfig.resolveUrl(avatar),
            width: 32,
            height: 32,
            fit: BoxFit.cover,
            loadingSize: 14,
          )
        : Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
                color: primarySoftColor(b), shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Text(
              nickname.isEmpty
                  ? '?'
                  : (nickname.length <= 2 ? nickname : nickname.substring(0, 2)),
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: kPrimary),
            ),
          );
  }

  String _timeText(int ts) {
    if (ts <= 0) return '';
    final now = DateTime.now();
    final t = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      final hh = t.hour.toString().padLeft(2, '0');
      final mm = t.minute.toString().padLeft(2, '0');
      return '$hh:$mm';
    }
    return '${t.month}-${t.day}';
  }
}
