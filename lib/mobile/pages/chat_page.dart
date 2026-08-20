import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/app_config.dart';
import '../../core/app_theme.dart';
import '../../services/chat_image_cache.dart';
import '../../services/chat_notifier.dart';
import '../../services/chat_service.dart';
import '../../services/chat_store.dart';
import '../../services/ws_service.dart';
import '../../utils/image_transcoder.dart';
import '../../utils/net_image.dart';
import '../../widgets/sticker_panel.dart';
import '../theme/mobile_theme.dart';
import '../widgets/mobile_top_bar.dart';
import '../widgets/mobile_toast.dart';
import '../../widgets/pick_images.dart';
import 'chat_bubble.dart';

/// 移动端聊天详情页
class MobileChatPage extends StatefulWidget {
  /// 会话信息：peer_id / peer_nickname / peer_avatar / peer_username / online
  final Map<String, dynamic> peer;

  /// 当前登录用户 id
  final int currentUserId;

  /// 当前登录用户头像
  final String? myAvatar;

  const MobileChatPage({
    super.key,
    required this.peer,
    required this.currentUserId,
    this.myAvatar,
  });

  @override
  State<MobileChatPage> createState() => _MobileChatPageState();
}

class _MobileChatPageState extends State<MobileChatPage> {
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();

  late final int _myUid = widget.currentUserId;
  late final int _peerId = (widget.peer['peer_id'] as num).toInt();
  late final String _chatId =
      '${_myUid < _peerId ? _myUid : _peerId}_${_myUid < _peerId ? _peerId : _myUid}';

  final List<Map<String, dynamic>> _messages = [];
  final Map<String, dynamic> _msgIdIndex = {};

  bool _loading = true;
  bool _hasMore = true;
  bool _loadingMore = false;
  String? _peerPublicKey;

  Map<String, dynamic>? _quoteTarget;
  bool _quoteVisible = false;
  bool _showStickerPanel = false;
  int _panelTab = 0;

  final List<StreamSubscription<dynamic>> _subs = [];

  String get _peerNickname =>
      widget.peer['peer_nickname']?.toString() ?? '好友';
  String get _peerAvatar => widget.peer['peer_avatar']?.toString() ?? '';
  String get _myAvatar => widget.myAvatar ?? '';

  int get _nowSec =>
      (DateTime.now().millisecondsSinceEpoch +
              ChatService.serverTimeOffsetSec * 1000)
          ~/
          1000;

  @override
  void initState() {
    super.initState();
    ChatNotifier.instance.setCurrentChat(_peerId);
    _inputFocusNode.addListener(_onInputFocusChanged);
    _init();
  }

  void _onInputFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ChatNotifier.instance.clearCurrentChat();
    for (final s in _subs) {
      s.cancel();
    }
    _inputFocusNode.removeListener(_onInputFocusChanged);
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  // ===================== 初始化 =====================
  Future<void> _init() async {
    unawaited(_initBackground());
    _subs.add(WsService.instance.onChatMessage.listen(_onWsMessage));
    _subs.add(WsService.instance.onChatRead.listen(_onWsRead));
    _subs.add(WsService.instance.onChatReadSync.listen(_onWsReadSync));
    _subs.add(WsService.instance.onChatRecall.listen(_onWsRecall));
    _subs.add(WsService.instance.onChatClear.listen(_onWsClear));

    await _loadLocalMessages();
    if (!mounted) return;
    setState(() => _loading = false);
    // 倒序列表首帧 offset 0 = 底部（最新消息），无需滚动定位（根治二次定位跳动）

    await ChatStore.instance.clearUnread(_chatId);
    unawaited(_markAllRead());
  }

  Future<void> _initBackground() async {
    try {
      final resp = await ApiClient.instance.getChatKeys([_peerId]);
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] == 0) {
        final keyMap = (json['data'] ?? {})['keys'] as Map? ?? {};
        _peerPublicKey = keyMap['$_peerId']?.toString();
      }
    } catch (_) {}

    try {
      // 拉取远端历史/补漏。进入页面时 _init 已加载本地消息并定位到底部，
      // 这里拉到的远端消息大多是本地已有的历史；仅当本地消息数确实增加才
      // 静默刷新列表，且不再二次滚动到底部（修复「进页面定位一次、拉完历史
      // 又定位一次」导致的明显二次跳动）。
      final beforeCount = _messages.length;
      await ChatService.instance.pullHistory(peerId: _peerId);
      if (!mounted) return;
      final afterCount =
          (await ChatStore.instance.getMessages(_chatId, limit: 200)).length;
      if (afterCount != beforeCount) {
        await _loadLocalMessages();
      }
    } catch (_) {}

    unawaited(_markAllRead());
  }

  // ===================== 本地加载 =====================
  Future<void> _loadLocalMessages() async {
    final list = await ChatStore.instance.getMessages(_chatId, limit: 200);
    if (!mounted) return;
    // sqflite 返回只读 QueryRow，需转成可变 Map，否则 _onWsRead/_onWsRecall
    // 里 m['read_status']=1 / m['recalled']=1 会抛「Unsupported operation: read-only」
    // getMessages 返回 id DESC（最新在前）。倒序列表（reverse:true）+ DESC 数据：
    // index 0 = 最新消息渲染在底部，进入页面天然定位到最新，无需滚动定位。
    final desc = list.map((e) => Map<String, dynamic>.from(e)).toList();
    setState(() {
      _messages
        ..clear()
        ..addAll(desc);
      _rebuildIndex();
      _hasMore = list.length >= 200;
    });
  }

  void _rebuildIndex() {
    _msgIdIndex.clear();
    for (final m in _messages) {
      _msgIdIndex[m['client_msg_id'].toString()] = m;
      final id = m['msg_id'];
      if (id is num && id.toInt() != 0) {
        _msgIdIndex['msg_${id.toInt()}'] = m;
      }
    }
  }

  Future<void> _loadOlderMessages() async {
    if (_loadingMore || !_hasMore) return;
    _loadingMore = true;
    try {
      // 倒序列表：最旧一条在末尾（index = length-1）
      final oldest = _messages.isNotEmpty ? _messages.last : null;
      final beforeId = (oldest?['msg_id'] as num?)?.toInt() ?? 0;
      if (beforeId > 0) {
        final count = await ChatService.instance
            .pullHistory(peerId: _peerId, beforeId: beforeId);
        if (count > 0) await _loadLocalMessages();
      }
    } catch (_) {}
    if (mounted) _loadingMore = false;
  }

  // ===================== WS 事件 =====================
  bool _isPeerMessage(Map<String, dynamic> m) {
    final sender = (m['sender_id'] as num?)?.toInt();
    final receiver = (m['receiver_id'] as num?)?.toInt();
    final chatId = m['chat_id']?.toString();
    return chatId == _chatId ||
        (sender == _peerId && receiver == _myUid) ||
        (sender == _myUid && receiver == _peerId);
  }

  Future<void> _onWsMessage(Map<String, dynamic> raw) async {
    final m = raw['message'] is Map<String, dynamic>
        ? raw['message'] as Map<String, dynamic>
        : raw;
    if (!_isPeerMessage(m) || !mounted) return;
    // 复用统一解密入库（与 app 级全局订阅一致；upsertMessage 幂等，重复调用无副作用）。
    // 修复：此前自实现 _storeIncoming 直接取 plaintext（WS 推送的是密文 body/nonce/
    // ephemeral_pub，无 plaintext 字段）导致空气泡，且把对方消息错标 send_status=2
    // → 红色感叹号。统一走 ChatService 解密，send_status 恒为 1。
    // 性能：onIncomingMessage 返回解密后的消息，直接增量 append，避免每条消息全量重载。
    final msg = await ChatService.instance.onIncomingMessage(m);
    if (!mounted || msg == null) return;
    final key = msg['client_msg_id'].toString();
    if (_msgIdIndex.containsKey(key)) return;
    final msgId = (msg['msg_id'] as num?)?.toInt() ?? 0;
    if (msgId != 0 && _msgIdIndex.containsKey('msg_$msgId')) return;
    setState(() {
      // 倒序列表：最新消息插入头部（index 0 = 视觉底部）
      _messages.insert(0, msg);
      _msgIdIndex[key] = msg;
      if (msgId != 0) _msgIdIndex['msg_$msgId'] = msg;
    });
    // 在底部才跟随贴底；往上翻历史时不打扰（reverse 列表 offset 0 = 底部）
    if (_scrollCtrl.hasClients && _scrollCtrl.offset <= 1) {
      _scrollToBottom();
    }
    unawaited(_markAllRead());
  }

  void _onWsRead(Map<String, dynamic> raw) {
    if (!mounted) return;
    final chatId = raw['chat_id']?.toString();
    if (chatId != null && chatId != _chatId) return;
    final peerId = (raw['peer_id'] as num?)?.toInt();
    if (peerId != null && peerId != _peerId) return;
    final readMsgId = (raw['msg_id'] as num?)?.toInt();
    if (readMsgId == null) return;
    bool changed = false;
    for (final m in _messages) {
      if ((m['sender_id'] as num?)?.toInt() == _myUid &&
          (m['msg_id'] as num?)?.toInt() != 0 &&
          (m['msg_id'] as num?)!.toInt() <= readMsgId &&
          (m['read_status'] as num?)?.toInt() != 1) {
        m['read_status'] = 1;
        changed = true;
      }
    }
    if (changed) setState(() {});
  }

  void _onWsReadSync(Map<String, dynamic> raw) {
    _onWsRead(raw);
  }

  void _onWsRecall(Map<String, dynamic> raw) {
    if (!mounted) return;
    final chatId = raw['chat_id']?.toString();
    if (chatId != null && chatId != _chatId) return;
    final msgId = (raw['msg_id'] as num?)?.toInt();
    if (msgId == null) return;
    bool changed = false;
    for (final m in _messages) {
      if ((m['msg_id'] as num?)?.toInt() == msgId &&
          (m['recalled'] as num?)?.toInt() != 1) {
        m['recalled'] = 1;
        changed = true;
      }
    }
    if (changed) setState(() {});
    unawaited(ChatStore.instance.markRecalled(msgId));
  }

  void _onWsClear(Map<String, dynamic> raw) {
    if (!mounted) return;
    final chatId = raw['chat_id']?.toString();
    if (chatId != null && chatId != _chatId) return;
    setState(() {
      _messages.clear();
      _msgIdIndex.clear();
    });
  }

  // ===================== 已读上报 =====================
  Future<void> _markAllRead() async {
    try {
      // 清除本机未读角标：在对话页内收到对方消息时，onIncomingMessage 会让
      // unread_count +1，若不清零，返回列表页仍残留未读气泡（问题：看过了还红点）。
      await ChatStore.instance.clearUnread(_chatId);
      int maxPeerMsgId = 0;
      for (final m in _messages) {
        if ((m['sender_id'] as num?)?.toInt() == _peerId) {
          final id = (m['msg_id'] as num?)?.toInt() ?? 0;
          if (id > maxPeerMsgId) maxPeerMsgId = id;
        }
      }
      if (maxPeerMsgId <= 0) return;
      await ApiClient.instance.markChatRead(peerId: _peerId, msgId: maxPeerMsgId);
      await ChatStore.instance.markChatRead(_chatId, _myUid);
      if (mounted) setState(() {});
    } catch (_) {}
  }

  // ===================== 发送 =====================
  Future<void> _sendMessage([String? overrideText]) async {
    final text = (overrideText ?? _inputCtrl.text).trim();
    if (text.isEmpty && _quoteTarget == null) return;
    // 纯文本直接发送，引用时把 reply_to 拼入文本前缀
    final body = _quoteTarget != null && _quoteTarget!['msg_id'] != null
        ? '[reply:${_quoteTarget!['msg_id']}] $text'
        : text;
    await _sendMessageCore(body, msgType: 1);
    if (mounted && overrideText == null) _inputCtrl.clear();
    if (mounted && _quoteVisible) _cancelQuote();
  }

  Future<void> _sendMessageCore(String body,
      {int msgType = 1, String? imageLocalPath}) async {
    if (!mounted) return;
    // 确保公钥已加载（_initBackground 可能还在异步拉取）
    if (_peerPublicKey == null || _peerPublicKey!.isEmpty) {
      try {
        final resp = await ApiClient.instance.getChatKeys([_peerId]);
        final json = ApiClient.safeJsonDecode(resp.body);
        if (json['code'] == 0) {
          final keyMap = (json['data'] ?? {})['keys'] as Map? ?? {};
          _peerPublicKey = keyMap['$_peerId']?.toString();
        }
      } catch (_) {}
    }
    final clientMsgId = '${_myUid}_${DateTime.now().millisecondsSinceEpoch}';
    final now = _nowSec;
    final msg = <String, dynamic>{
      'msg_id': 0,
      'client_msg_id': clientMsgId,
      'sender_id': _myUid,
      'receiver_id': _peerId,
      'msg_type': msgType,
      'seq': 0,
      'plaintext': body,
      'ciphertext': '',
      'nonce': '',
      'ephemeral_pub': '',
      'signature': '',
      'create_time': now,
      'send_status': 0,
      'read_status': 0,
      'recalled': 0,
      if (imageLocalPath != null) 'image_local_path': imageLocalPath,
    };
    setState(() {
      // 倒序列表：最新消息插入头部（index 0 = 视觉底部）
      _messages.insert(0, msg);
      _msgIdIndex[clientMsgId] = msg;
    });
    _scrollToBottom();

    try {
      await ChatStore.instance.upsertMessage(
        chatId: _chatId,
        msgId: 0,
        clientMsgId: clientMsgId,
        senderId: _myUid,
        receiverId: _peerId,
        msgType: msgType,
        seq: 0,
        plaintext: body,
        ciphertext: '',
        nonce: '',
        ephemeralPub: '',
        signature: '',
        sendStatus: 0,
        createTime: _nowSec,
        imageLocalPath: imageLocalPath ?? '',
        readStatus: 0,
      );
    } catch (_) {}

    final result = await ChatService.instance.sendMessage(
      receiverId: _peerId,
      plaintext: body,
      msgType: msgType,
      imageLocalPath: imageLocalPath ?? '',
      peerPublicKey: _peerPublicKey,
      forceClientMsgId: clientMsgId,
    );
    if (!mounted) return;
    if (result.ok) {
      await ChatStore.instance.updateSendStatus(
          clientMsgId: clientMsgId, sendStatus: 1, msgId: result.msgId);
      setState(() {
        msg['send_status'] = 1;
        msg['msg_id'] = result.msgId;
        if (result.msgId != 0) _msgIdIndex['msg_${result.msgId}'] = msg;
      });
      // 状态从「发送中」变「已发送」会微调气泡尺寸，再次贴底消除底部空隙
      _scrollToBottom();
    } else {
      await ChatStore.instance
          .updateSendStatus(clientMsgId: clientMsgId, sendStatus: 2);
      if (!mounted) return;
      setState(() => msg['send_status'] = 2);
      MobileToast.error(
          context, result.error.isEmpty ? '发送失败' : result.error);
    }
  }

  Future<void> _pickAndSendImages() async {
    try {
      final imgs = await pickImages(allowMultiple: true);
      if (imgs.isEmpty || !mounted) return;
      for (final img in imgs) {
        if (!mounted) return;
        final t = await ImageTranscoder.toJpeg(bytes: img.bytes, name: img.name);
        if (t == null) continue;
        await _sendImageBytes(t.bytes, t.name);
      }
    } catch (_) {}
  }

  Future<void> _sendImageBytes(Uint8List bytes, String name) async {
    try {
      final resp = await ApiClient.instance
          .uploadChatImage(bytes, filename: name)
          .timeout(const Duration(seconds: 20));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] != 0 || !mounted) return;
      final url = (json['data'] ?? {})['url']?.toString() ?? '';
      if (url.isEmpty) return;
      final localPath = await ChatImageCache.ensureCached(url, bytes: bytes);
      await _sendMessageCore(jsonEncode({'url': url}),
          msgType: 2, imageLocalPath: localPath);
    } catch (_) {}
  }

  void _sendSticker(StickerItem s) {
    if (s.url.isEmpty) return;
    _sendMessageCore(
      jsonEncode({'url': s.url, 'w': s.width, 'h': s.height}),
      msgType: 3,
    );
  }

  // ===================== 引用 =====================
  void _startQuote(Map<String, dynamic> m) {
    final id = (m['msg_id'] as num?)?.toInt() ?? 0;
    final nickname =
        (m['sender_id'] as num?)?.toInt() == _myUid ? '我' : _peerNickname;
    setState(() {
      _quoteTarget = {
        'id': id,
        'nickname': nickname,
        'msg_type': m['msg_type'] ?? 1,
        'preview': _quotePreview(m),
      };
      _quoteVisible = true;
    });
  }

  void _cancelQuote() {
    setState(() {
      _quoteTarget = null;
      _quoteVisible = false;
    });
  }

  String _quotePreview(Map<String, dynamic> m) {
    if ((m['recalled'] as num?)?.toInt() == 1) return '该消息已撤回';
    final msgType = (m['msg_type'] as num?)?.toInt() ?? 1;
    if (msgType == 2) return '[图片]';
    if (msgType == 3) return '[表情]';
    return m['plaintext']?.toString() ?? '';
  }

  // ===================== 撤回 =====================
  bool _canRecall(Map<String, dynamic> m) {
    if ((m['sender_id'] as num?)?.toInt() != _myUid) return false;
    if ((m['recalled'] as num?)?.toInt() == 1) return false;
    final createTime = (m['create_time'] as num?)?.toInt() ?? 0;
    return _nowSec - createTime <= 2 * 60 * 1000;
  }

  Future<void> _recallMessage(Map<String, dynamic> m) async {
    final msgId = (m['msg_id'] as num?)?.toInt() ?? 0;
    if (msgId <= 0) return;
    try {
      final resp = await ApiClient.instance
          .recallChatMessage(peerId: _peerId, msgId: msgId)
          .timeout(const Duration(seconds: 8));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] != 0 || !mounted) return;
      setState(() => m['recalled'] = 1);
      await ChatStore.instance.markRecalled(msgId);
    } catch (_) {}
  }

  Future<void> _retryMessage(Map<String, dynamic> m) async {
    final clientMsgId = m['client_msg_id']?.toString();
    if (clientMsgId == null) return;
    await ChatStore.instance
        .updateSendStatus(clientMsgId: clientMsgId, sendStatus: 0);
    if (!mounted) return;
    setState(() => m['send_status'] = 0);
    final result = await ChatService.instance.sendMessage(
      receiverId: _peerId,
      plaintext: m['plaintext']?.toString() ?? '',
      msgType: (m['msg_type'] as num?)?.toInt() ?? 1,
      imageLocalPath: m['image_local_path']?.toString() ?? '',
      peerPublicKey: _peerPublicKey,
      forceClientMsgId: clientMsgId,
    );
    if (!mounted) return;
    if (result.ok) {
      await ChatStore.instance.updateSendStatus(
          clientMsgId: clientMsgId, sendStatus: 1, msgId: result.msgId);
      setState(() {
        m['send_status'] = 1;
        m['msg_id'] = result.msgId;
      });
    } else {
      await ChatStore.instance
          .updateSendStatus(clientMsgId: clientMsgId, sendStatus: 2);
      setState(() => m['send_status'] = 2);
    }
  }

  // ===================== 转发 / 添加表情 / 删除 =====================

  /// 转发消息（表情/图片/文本）：微信式底部卡片，多选目标 + 附言后批量发送
  Future<void> _forwardMessage(Map<String, dynamic> m) async {
    final body = m['plaintext']?.toString() ?? '';
    if (body.isEmpty) return;
    final msgType = (m['msg_type'] as num?)?.toInt() ?? 1;
    final friends = await _loadFriendList();
    final convs = (await ChatStore.instance.getConversations())
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    if (!mounted) return;
    if (friends.isEmpty && convs.isEmpty) {
      MobileToast.error(context, '暂无好友可转发');
      return;
    }
    // 文本消息：输入框预填原文本（可编辑）；图片/表情：预填空
    final initialNote = msgType == 1 ? body : '';
    final result = await showModalBottomSheet<
        ({List<Map<String, dynamic>> targets, String note})>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ForwardSheet(
        friends: friends,
        conversations: convs,
        initialNote: initialNote,
      ),
    );
    if (result == null || !mounted) return;
    if (result.targets.isEmpty) return;
    final note = result.note.trim();
    var okCount = 0;
    for (final t in result.targets) {
      final targetUid = (t['user_id'] as num?)?.toInt() ?? 0;
      if (targetUid <= 0) continue;
      // 文本：发附言（预填原文本，可编辑）；图片/表情：先发附言文字再发原媒体
      if (msgType == 1) {
        final text = note.isEmpty ? body : note;
        if (await _sendForward(targetUid, text, 1)) okCount++;
      } else {
        if (note.isNotEmpty) {
          await _sendForward(targetUid, note, 1);
        }
        if (await _sendForward(targetUid, body, msgType)) okCount++;
      }
    }
    if (!mounted) return;
    if (okCount > 0) {
      MobileToast.success(context, '已转发给 ${result.targets.length} 个会话');
    } else {
      MobileToast.error(context, '转发失败');
    }
  }

  /// 转发单条消息，返回是否成功
  Future<bool> _sendForward(int targetUid, String text, int msgType) async {
    final r = await ChatService.instance.sendMessage(
      receiverId: targetUid,
      plaintext: text,
      msgType: msgType,
    );
    return r.ok;
  }

  /// 拉取好友列表（转发选择用），失败返回空列表
  Future<List<Map<String, dynamic>>> _loadFriendList() async {
    final out = <Map<String, dynamic>>[];
    try {
      var page = 1;
      var hasMore = true;
      while (hasMore && page <= 5) {
        final resp = await ApiClient.instance
            .getFriends(page: page, pageSize: 100)
            .timeout(const Duration(seconds: 10));
        final json = ApiClient.safeJsonDecode(resp.body);
        final data = json['data'];
        if (data is! Map) break;
        final list = data['list'];
        if (list is List) {
          for (final e in list) {
            if (e is Map) out.add(Map<String, dynamic>.from(e));
          }
        }
        hasMore = data['has_more'] == true || data['has_more'] == 1;
        page++;
      }
    } catch (_) {}
    return out;
  }

  /// 添加到表情：收藏对方表情到自己的表情库
  Future<void> _addSticker(Map<String, dynamic> m) async {
    final url = ChatImageCache.parseUrl(m['plaintext']?.toString() ?? '');
    if (url.isEmpty) return;
    try {
      final resp = await ApiClient.instance
          .addSticker(url: url)
          .timeout(const Duration(seconds: 10));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (!mounted) return;
      if (json['code'] == 0) {
        MobileToast.success(context, '已添加到表情包');
      } else {
        MobileToast.error(context, json['msg']?.toString() ?? '添加失败');
      }
    } catch (_) {
      if (mounted) MobileToast.error(context, '添加失败');
    }
  }

  /// 删除消息（仅本设备）：删库 + 移出 UI + 刷新会话摘要
  Future<void> _deleteMessage(Map<String, dynamic> m) async {
    final clientMsgId = m['client_msg_id']?.toString() ?? '';
    if (clientMsgId.isNotEmpty) {
      await ChatStore.instance.deleteMessageByClientMsgId(clientMsgId);
    }
    if (!mounted) return;
    setState(() {
      _messages.remove(m);
      _rebuildIndex();
    });
    // 删除后会话最后一条消息可能变化，刷新会话摘要
    unawaited(ChatStore.instance.syncConversationsFromMessages(_myUid));
  }

  // ===================== 滚动 =====================
  /// 回到消息列表底部。倒序列表（reverse:true）下 offset 0 = 底部（最新消息），
  /// 直接 jumpTo(0) 即精确贴底，无需「收敛滚动」（offset 0 不依赖惰性布局，
  /// 也彻底消除了进入页面/收发消息时的二次定位跳动）。
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      _scrollCtrl.jumpTo(0);
    });
  }

  // ===================== 时间分组 =====================
  /// 时间戳归一化为秒：历史数据曾误存毫秒值（13 位），> 1e11 视为毫秒并除 1000。
  int _normTime(int t) => t > 100000000000 ? t ~/ 1000 : t;

  String? _timeLabelFor(int index) {
    final cur = _messages[index];
    final curT = _normTime((cur['create_time'] as num?)?.toInt() ?? 0);
    if (curT <= 0) return null;
    final curD = DateTime.fromMillisecondsSinceEpoch(curT * 1000);
    // 最新消息（index 0，视觉最底部）不显示时间标签（微信/QQ 同款）
    if (index == 0) return null;
    // 倒序列表：最早一条（index = length-1，视觉最顶部）必显示时间标签
    if (index == _messages.length - 1) return _fmtGroupTime(curD);
    // 与「视觉上方」那条（index+1，更早）比较
    final next = _messages[index + 1];
    final nextT = _normTime((next['create_time'] as num?)?.toInt() ?? 0);
    if (nextT <= 0) return null;
    final nextD = DateTime.fromMillisecondsSinceEpoch(nextT * 1000);
    final diff = curD.difference(nextD).abs();
    final crossDay = !(curD.year == nextD.year &&
        curD.month == nextD.month &&
        curD.day == nextD.day);
    if (diff.inMinutes < 5 && !crossDay) return null;
    return _fmtGroupTime(curD);
  }

  String _fmtGroupTime(DateTime d) {
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }
    final yesterday = now.subtract(const Duration(days: 1));
    if (d.year == yesterday.year &&
        d.month == yesterday.month &&
        d.day == yesterday.day) {
      return '昨天 ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }
    final hm =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    if (d.year == now.year) {
      return '${d.month}月${d.day}日 $hm';
    }
    return '${d.year}年${d.month}月${d.day}日 $hm';
  }

  // ===================== UI =====================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MobileTheme.pageBackground(Theme.of(context).brightness),
      body: Column(
        children: [
          _buildTopBar(),
          Expanded(child: _buildBody()),
          _buildInputBar(),
          if (_showStickerPanel) _buildPanel(),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return MobileTopBar(
      title: _peerNickname,
      onBack: () => Navigator.of(context).maybePop(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    return GestureDetector(
      onTap: () {
        setState(() => _showStickerPanel = false);
        FocusScope.of(context).unfocus();
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          // 倒序列表：视觉顶部 = maxScrollExtent（更早历史），接近顶部时加载更早
          if (n.metrics.pixels >= n.metrics.maxScrollExtent - 40 &&
              n is ScrollUpdateNotification) {
            _loadOlderMessages();
          }
          return false;
        },
        child: ListView.builder(
          controller: _scrollCtrl,
          // 原生 ListView 的 reverse：滚轮/触摸/惯性方向由 Flutter 正确计算
          // （手指上滑=看更早、下滑=回最新）。SilkyScroll 包装层无 reverse 概念，
          // 会反向操作 offset，故聊天列表不用 silky。
          reverse: true, // 倒序：index 0（最新）渲染在底部，天然定位最新消息
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          itemCount: _messages.length,
          itemBuilder: (ctx, i) {
            final m = _messages[i];
            final isMine = (m['sender_id'] as num?)?.toInt() == _myUid;
            final recalled = (m['recalled'] as num?)?.toInt() == 1;
            final msgType = (m['msg_type'] as num?)?.toInt() ?? 1;
            final isSticker = msgType == 3;
            return ChatBubble(
              message: m,
              isMine: isMine,
              peerNickname: _peerNickname,
              peerAvatar: _peerAvatar,
              myAvatar: _myAvatar,
              nowSec: _nowSec,
              timeLabel: _timeLabelFor(i),
              groupHead: _isGroupHead(i),
              onQuote: () => _startQuote(m),
              onRecall: (!recalled && isMine && _canRecall(m))
                  ? () => _recallMessage(m)
                  : null,
              onRetry: () => _retryMessage(m),
              // 转发：所有类型（文本/图片/表情）都可转发
              onForward: () => _forwardMessage(m),
              // 添加到表情：仅对方发的表情（自己的表情库已有，无需收藏）
              onAddSticker:
                  (isSticker && !isMine) ? () => _addSticker(m) : null,
              // 删除：所有类型（本设备删除）
              onDelete: () => _deleteMessage(m),
            );
          },
        ),
      ),
    );
  }

  bool _isGroupHead(int i) {
    // 倒序列表：最早一条（index = length-1，视觉最顶部）必是组头（显示头像）
    if (i == _messages.length - 1) return true;
    // 时间胶囊打断：当前消息与「视觉上方」（更早）之间插了时间标签 → 强制重出头像
    if (_timeLabelFor(i) != null) return true;
    final next = _messages[i + 1];
    return (next['sender_id'] as num?)?.toInt() !=
        (_messages[i]['sender_id'] as num?)?.toInt();
  }

  // ===================== 输入区 =====================
  Widget _buildInputBar() {
    final b = Theme.of(context).brightness;
    final dark = b == Brightness.dark;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: MobileTheme.pageBackground(b),
          border: Border(
            top: BorderSide(
              color: dark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.06),
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            IconButton(
              onPressed: _pickAndSendImages,
              icon: Icon(
                Icons.image_outlined,
                color: textColor(b),
                size: 26,
              ),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: _togglePanel,
              icon: Icon(
                _showStickerPanel
                    ? Icons.keyboard_alt_outlined
                    : Icons.emoji_emotions_outlined,
                color: textColor(b),
                size: 26,
              ),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            ),
            const SizedBox(width: 4),
            Expanded(child: _buildTextField()),
          ],
        ),
      ),
    );
  }

  void _togglePanel() {
    if (_showStickerPanel) {
      setState(() => _showStickerPanel = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        FocusScope.of(context).requestFocus(_inputFocusNode);
      });
    } else {
      FocusScope.of(context).unfocus();
      setState(() => _showStickerPanel = true);
    }
  }

  Widget _buildTextField() {
    final b = Theme.of(context).brightness;
    final dark = b == Brightness.dark;
    final focused = _inputFocusNode.hasFocus;
    final radius = BorderRadius.circular(22);
    final borderColor = focused
        ? kPrimary
        : dark
            ? const Color(0x26FFFFFF)
            : const Color(0x1A000000);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_quoteVisible && _quoteTarget != null) _buildQuotePreview(),
        Container(
          constraints: const BoxConstraints(minHeight: 40),
          decoration: BoxDecoration(
            color: bgSoftColor(b),
            borderRadius: radius,
            border: Border.all(
              color: borderColor,
              width: 1,
            ),
          ),
          child: TextField(
            controller: _inputCtrl,
            focusNode: _inputFocusNode,
            minLines: 1,
            maxLines: 4,
            keyboardType: TextInputType.multiline,
            textAlignVertical: TextAlignVertical.center,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _sendMessage(),
            onTap: () {
              if (_showStickerPanel) {
                setState(() => _showStickerPanel = false);
              }
            },
            decoration: InputDecoration(
              hintText: '发消息…',
              hintStyle: TextStyle(
                color: dark
                    ? Colors.white.withValues(alpha: 0.35)
                    : Colors.black.withValues(alpha: 0.35),
              ),
              filled: false,
              isCollapsed: true,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              errorBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            ),
            style: TextStyle(fontSize: 14, color: textColor(b)),
          ),
        ),
      ],
    );
  }

  Widget _buildQuotePreview() {
    final q = _quoteTarget!;
    final b = Theme.of(context).brightness;
    final dark = b == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: kPrimary, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '回复 ${q['nickname']}',
                  style: TextStyle(
                    fontSize: 12,
                    color: kPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  q['preview']?.toString() ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: dark
                        ? Colors.white.withValues(alpha: 0.5)
                        : Colors.black.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
          InkWell(
            onTap: _cancelQuote,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.close_rounded,
                size: 16,
                color: dark
                    ? Colors.white.withValues(alpha: 0.5)
                    : Colors.black.withValues(alpha: 0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPanel() {
    final b = Theme.of(context).brightness;
    return Container(
      height: 260,
      decoration: BoxDecoration(
        color: MobileTheme.pageBackground(b),
        border: Border(
          top: BorderSide(
            color: b == Brightness.dark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.06),
          ),
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                _tabButton(0, Icons.emoji_emotions_outlined, '表情'),
                const SizedBox(width: 4),
                _tabButton(1, Icons.face_retouching_natural_outlined, '贴纸'),
              ],
            ),
          ),
          Expanded(
            child: _panelTab == 0
                ? EmojiPanel(
                    onEmoji: (e) {
                      final t = _inputCtrl.text + e;
                      _inputCtrl.value = TextEditingValue(
                        text: t,
                        selection: TextSelection.collapsed(offset: t.length),
                      );
                    },
                  )
                : StickerPanel(
                    onEmoji: (e) {},
                    onSticker: (s) => _sendSticker(s),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _tabButton(int idx, IconData icon, String label) {
    final b = Theme.of(context).brightness;
    final active = _panelTab == idx;
    return InkWell(
      onTap: () => setState(() => _panelTab = idx),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? kPrimary.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(icon,
                size: 18, color: active ? kPrimary : textColor(b)),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                  fontSize: 13,
                  color: active ? kPrimary : textColor(b),
                )),
          ],
        ),
      ),
    );
  }
}

/// 转发目标选择器（微信式底部卡片）：
/// 顶部「最近聊天」横向滚动多选 + 下方「好友」列表多选 + 底部附言输入框与发送按钮。
/// 卡片从下往上滑出（`showModalBottomSheet` 默认），下滑/点遮罩关闭（从上往下收起）。
class _ForwardSheet extends StatefulWidget {
  final List<Map<String, dynamic>> friends;
  final List<Map<String, dynamic>> conversations;
  final String initialNote;

  const _ForwardSheet({
    required this.friends,
    required this.conversations,
    required this.initialNote,
  });

  @override
  State<_ForwardSheet> createState() => _ForwardSheetState();
}

class _ForwardSheetState extends State<_ForwardSheet> {
  final TextEditingController _noteCtrl = TextEditingController();
  final FocusNode _noteFocus = FocusNode();
  final Set<int> _selected = {};
  bool _showEmoji = false;

  @override
  void initState() {
    super.initState();
    _noteCtrl.text = widget.initialNote;
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    _noteFocus.dispose();
    super.dispose();
  }

  /// 最近聊天（有本地会话记录的）
  List<Map<String, dynamic>> get _recent => widget.conversations
      .where((c) => ((c['peer_id'] as num?)?.toInt() ?? 0) > 0)
      .toList();

  /// 好友列表（排除已出现在最近聊天里的，避免重复）
  List<Map<String, dynamic>> get _friendList {
    final recentUids =
        _recent.map((c) => (c['peer_id'] as num?)?.toInt() ?? 0).toSet();
    return widget.friends.where((f) {
      final uid = (f['user_id'] as num?)?.toInt() ?? 0;
      return uid > 0 && !recentUids.contains(uid);
    }).toList();
  }

  int _uidOf(Map<String, dynamic> c) =>
      (c['peer_id'] as num?)?.toInt() ?? (c['user_id'] as num?)?.toInt() ?? 0;

  void _toggle(int uid) {
    setState(() {
      if (!_selected.remove(uid)) _selected.add(uid);
    });
  }

  /// 切换 emoji 面板：展开时收起键盘，收起时恢复键盘焦点
  void _toggleEmoji() {
    if (_showEmoji) {
      setState(() => _showEmoji = false);
      _noteFocus.requestFocus();
    } else {
      _noteFocus.unfocus();
      setState(() => _showEmoji = true);
    }
  }

  /// 在附言输入框光标处插入 emoji
  void _insertEmoji(String e) {
    final text = _noteCtrl.text;
    final sel = _noteCtrl.selection;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final newText = text.replaceRange(start, end, e);
    _noteCtrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + e.length),
    );
  }

  void _send() {
    if (_selected.isEmpty) return;
    final targets = <Map<String, dynamic>>[];
    for (final c in _recent) {
      final uid = _uidOf(c);
      if (_selected.contains(uid)) {
        targets.add({
          'user_id': uid,
          'nickname': c['peer_nickname']?.toString() ?? '',
          'avatar': c['peer_avatar']?.toString() ?? '',
        });
      }
    }
    for (final f in _friendList) {
      final uid = (f['user_id'] as num?)?.toInt() ?? 0;
      if (_selected.contains(uid)) targets.add(f);
    }
    Navigator.of(context).pop((targets: targets, note: _noteCtrl.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final screenH = MediaQuery.of(context).size.height;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        height: screenH * 0.72,
        decoration: BoxDecoration(
          color: MobileTheme.pageBackground(b),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              _buildHeader(b),
              if (_recent.isNotEmpty) _buildRecent(b),
              _buildList(b),
              if (_showEmoji) _buildEmojiPanel(),
              _buildBottomBar(b),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(Brightness b) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(
                '选择发送给',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: textColor(b),
                ),
              ),
              const Spacer(),
              if (_selected.isNotEmpty)
                Text(
                  '已选 ${_selected.length}',
                  style: TextStyle(fontSize: 13, color: kPrimary),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRecent(Brightness b) {
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _recent.length,
        separatorBuilder: (_, __) => const SizedBox(width: 16),
        itemBuilder: (ctx, i) {
          final c = _recent[i];
          final uid = _uidOf(c);
          final name = c['peer_nickname']?.toString() ?? '好友';
          final avatar = c['peer_avatar']?.toString() ?? '';
          return _RecentItem(
            avatar: avatar,
            name: name,
            selected: _selected.contains(uid),
            onTap: () => _toggle(uid),
          );
        },
      ),
    );
  }

  Widget _buildList(Brightness b) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              '好友',
              style: TextStyle(fontSize: 13, color: textFaintColor(b)),
            ),
          ),
          Expanded(
            child: _friendList.isEmpty
                ? Center(
                    child: Text(
                      '暂无更多好友',
                      style: TextStyle(fontSize: 13, color: textFaintColor(b)),
                    ),
                  )
                : ListView.builder(
                    itemCount: _friendList.length,
                    itemBuilder: (ctx, i) {
                      final f = _friendList[i];
                      final uid = (f['user_id'] as num?)?.toInt() ?? 0;
                      final name = f['nickname']?.toString() ?? '好友';
                      final avatar = f['avatar']?.toString() ?? '';
                      final selected = _selected.contains(uid);
                      return ListTile(
                        leading: _avatar(avatar, name),
                        title: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 15, color: textColor(b)),
                        ),
                        trailing: _CheckDot(selected: selected),
                        onTap: () => _toggle(uid),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(Brightness b) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: MobileTheme.pageBackground(b),
        border: Border(
          top: BorderSide(
            color: Colors.black.withValues(alpha: 0.06),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(20),
              ),
              child: TextField(
                controller: _noteCtrl,
                focusNode: _noteFocus,
                maxLines: 1,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                style: TextStyle(fontSize: 15, color: textColor(b)),
                decoration: InputDecoration(
                  hintText: '说点什么...',
                  hintStyle:
                      TextStyle(fontSize: 15, color: textFaintColor(b)),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.fromLTRB(8, 10, 8, 10),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 表情按钮：点击展开/收起 emoji 面板（仅内置 emoji，不含表情包）
          _iconBtn(
            b,
            _showEmoji ? Icons.keyboard_alt_outlined : Icons.emoji_emotions_outlined,
            _toggleEmoji,
          ),
          // 表情面板展开时键盘已收起，另留发送入口（否则只能靠 send 键）
          if (_showEmoji) ...[
            const SizedBox(width: 8),
            _iconBtn(
              b,
              Icons.send_rounded,
              _selected.isEmpty ? null : _send,
              active: _selected.isNotEmpty,
            ),
          ],
        ],
      ),
    );
  }

  /// emoji 面板（通用封装 EmojiPanel，仅内置 emoji，不含表情包）
  Widget _buildEmojiPanel() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: EmojiPanel(onEmoji: _insertEmoji),
    );
  }

  /// 圆形图标按钮（表情 / 发送）
  Widget _iconBtn(Brightness b, IconData icon, VoidCallback? onTap,
      {bool active = true}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active
              ? kPrimary.withValues(alpha: 0.12)
              : kPrimary.withValues(alpha: 0.04),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: 22,
          color: active ? kPrimary : textFaintColor(b),
        ),
      ),
    );
  }

  Widget _avatar(String url, String name) {
    if (url.isEmpty) {
      return CircleAvatar(
        radius: 20,
        backgroundColor: kPrimary.withValues(alpha: 0.15),
        child: Text(
          name.isEmpty ? '?' : name.characters.first,
          style: const TextStyle(
            color: kPrimary,
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
      );
    }
    return ClipOval(
      child: SizedBox(
        width: 40,
        height: 40,
        child: NetImage(url: AppConfig.resolveUrl(url), fit: BoxFit.cover),
      ),
    );
  }
}

/// 最近聊天横向条目（头像 + 昵称 + 右上角勾选圈）
class _RecentItem extends StatelessWidget {
  final String avatar;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  const _RecentItem({
    required this.avatar,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 56,
        child: Column(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                _buildAvatar(),
                Positioned(
                  right: -4,
                  top: -4,
                  child: _CheckDot(selected: selected, small: true),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: textColor(b)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar() {
    final Widget inner;
    if (avatar.isEmpty) {
      inner = CircleAvatar(
        radius: 24,
        backgroundColor: kPrimary.withValues(alpha: 0.15),
        child: Text(
          name.isEmpty ? '?' : name.characters.first,
          style: const TextStyle(
            color: kPrimary,
            fontWeight: FontWeight.w600,
            fontSize: 18,
          ),
        ),
      );
    } else {
      inner = ClipOval(
        child: SizedBox(
          width: 48,
          height: 48,
          child:
              NetImage(url: AppConfig.resolveUrl(avatar), fit: BoxFit.cover),
        ),
      );
    }
    return inner;
  }
}

/// 勾选圈（多选状态指示）：选中=主色实心白勾，未选中=灰描边
class _CheckDot extends StatelessWidget {
  final bool selected;
  final bool small;

  const _CheckDot({required this.selected, this.small = false});

  @override
  Widget build(BuildContext context) {
    final size = small ? 18.0 : 22.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? kPrimary : Colors.transparent,
        border: selected
            ? null
            : Border.all(color: Colors.black.withValues(alpha: 0.25), width: 1.5),
      ),
      child: selected
          ? Icon(Icons.check, size: small ? 13 : 16, color: Colors.white)
          : null,
    );
  }
}
