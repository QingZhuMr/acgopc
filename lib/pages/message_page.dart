import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../core/app_theme.dart';
import '../services/chat_image_cache.dart';
import '../services/chat_notifier.dart';
import '../services/chat_service.dart';
import '../services/chat_store.dart';
import '../services/ws_service.dart';
import '../utils/image_download.dart';
import '../utils/image_transcoder.dart';
import '../utils/net_image.dart';
import '../utils/text_sanitize.dart';
import '../widgets/bubble_menu.dart';
import '../widgets/cached_avatar.dart';
import '../widgets/notify.dart';
import '../widgets/pick_images.dart';
import '../widgets/sticker_panel.dart';
import '../widgets/text_input_menu.dart';

/// 消息页（左侧导航栏「消息」入口）
///
/// 左侧：好友列表（互相关注的用户），分页加载；右侧：聊天界面。
/// 聊天基于 E2EE（X25519 + AES-GCM），密文走服务器，本地 SQLite 存明文。
///
/// 样式遵循 docs/UI规范.md：颜色一律用 app_theme.dart 函数/常量。
/// 标题栏省略号右侧弹出层动作
enum ChatMenuAction {
  openProfile, // 进入他的主页
  clearChat, // 清空对话记录
  searchChat, // 查找聊天记录
  removeFriend, // 取消好友
  block, // 拉黑
}

class MessagePage extends StatefulWidget {
  final int currentUserId;

  /// 当前登录用户头像（自己消息气泡头像用，可空则显示「我」占位）
  final String currentUserAvatar;

  /// 当前是否为激活页（IndexedStack 切回时用于触发刷新）
  final bool active;

  /// 打开他人主页回调（聊天右上角弹出层「进入他的主页」）
  final void Function(int uid, String nickname, String avatar)?
      onOpenUserProfile;

  const MessagePage({
    super.key,
    required this.currentUserId,
    this.currentUserAvatar = '',
    this.active = true,
    this.onOpenUserProfile,
  });

  @override
  State<MessagePage> createState() => MessagePageState();
}

class MessagePageState extends State<MessagePage> {
  final List<Map<String, dynamic>> _friends = [];
  bool _loading = false;
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
  final FocusNode _inputFocus = FocusNode();
  bool _sending = false;

  /// 左侧搜索框
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _keyword = '';

  /// 聊天记录搜索结果（会话视图搜索时）
  List<Map<String, dynamic>> _searchMsgResults = [];

  StreamSubscription<Map<String, dynamic>>? _chatSub;
  StreamSubscription<Map<String, dynamic>>? _chatReadSub;
  StreamSubscription<Map<String, dynamic>>? _chatReadSyncSub;
  StreamSubscription<Map<String, dynamic>>? _chatRecallSub;
  StreamSubscription<Map<String, dynamic>>? _chatClearSub;
  StreamSubscription<Map<String, dynamic>>? _typingSub;

  /// 对方正在输入状态
  bool _peerTyping = false;
  Timer? _peerTypingTimer;
  Timer? _typingSendDebounce;

  /// 图片缓存回填刷新（多条回填防抖）
  Timer? _imageRefreshDebounce;

  /// 会话列表刷新防抖（离线同步大量入库时合并为一次）
  Timer? _conversationRefreshDebounce;

  /// 表情面板（BubbleMenu 气泡）是否打开（图标高亮联动）
  bool _emojiPanelOpen = false;

  /// 表情气泡 GlobalKey：点击 emoji/表情包后外部调用收起气泡
  final GlobalKey<BubbleMenuState> _emojiMenuKey =
      GlobalKey<BubbleMenuState>();

  /// 输入框是否放大（微信式：右上角按钮切换 4 行 ↔ 10 行）
  bool _inputExpanded = false;

  /// 引用目标消息（设置后输入区上方显示引用条，发送时带上）
  Map<String, dynamic>? _quoteTarget;

  /// 多选删除模式
  bool _multiSelect = false;

  /// 多选选中的本地消息 id 集合
  final Set<int> _selectedMsgIds = {};

  /// 消息气泡 GlobalKey（引用点击跳转定位用，按服务器 msg_id 索引）
  final Map<int, GlobalKey> _bubbleKeys = {};

  /// 输入框 onChanged（发 typing）：节流 1s
  void _onInputChanged(String _) {
    final friend = _selectedFriend;
    if (friend == null) return;
    final peerId = (friend['user_id'] as num?)?.toInt() ?? 0;
    if (peerId <= 0) return;
    final myUid = widget.currentUserId;
    final chatId =
        '${myUid < peerId ? myUid : peerId}_${myUid < peerId ? peerId : myUid}';
    _typingSendDebounce?.cancel();
    _typingSendDebounce =
        Timer(const Duration(milliseconds: 800), () {
      WsService.instance.sendTyping(receiverId: peerId, chatId: chatId);
    });
  }

  /// 消息列表滚动控制器（正向列表：滚轮方向正常，发送/接收后粘底）
  final ScrollController _msgScrollCtrl = ScrollController();

  /// 是否在消息列表底部（offset 接近 maxScrollExtent；新消息到达自动跟随）
  bool _stickBottom = true;

  /// 是否强制回到底部（发送/重发/打开会话时置位）
  bool _forceScrollBottom = false;

  /// 上滑加载更多历史：加载中标志 / 无更早记录标志
  bool _loadingOlder = false;
  bool _noMoreOlder = false;

  /// 好友分组字母标题的 GlobalKey（字母索引条跳转用）
  final Map<String, GlobalKey> _groupKeys = {};

  @override
  void initState() {
    super.initState();
    _msgScrollCtrl.addListener(_onMsgScroll);
    // 图片缓存异步回填后刷新消息列表（展示本地图片）
    ChatStore.imageCacheTick.addListener(_onImageCacheTick);
    // 未读变化（收到消息/离线同步/跨端已读）→ 刷新会话列表与角标
    ChatStore.instance.chatUnreadTick.addListener(_onUnreadTick);
    _loadFriends();
    _loadConversations();
    // 全局监听对方输入状态：显示"正在输入…"，5 秒无新状态自动隐藏
    _typingSub = WsService.instance.onTyping.listen((typing) {
      final chatId = typing['chat_id']?.toString() ?? '';
      final friend = _selectedFriend;
      if (friend == null) return;
      final myUid = widget.currentUserId;
      final peerId = (friend['user_id'] as num?)?.toInt() ?? 0;
      final cid =
          '${myUid < peerId ? myUid : peerId}_${myUid < peerId ? peerId : myUid}';
      if (cid != chatId) return;
      setState(() => _peerTyping = true);
      _peerTypingTimer?.cancel();
      _peerTypingTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _peerTyping = false);
      });
    });
    // 全局监听会话清空：多端同步清除本地记录
    _chatClearSub = WsService.instance.onChatClear.listen((clear) async {
      final chatId = clear['chat_id']?.toString() ?? '';
      if (chatId.isEmpty) return;
      await ChatStore.instance.clearChatMessages(chatId);
      if (!mounted) return;
      final friend = _selectedFriend;
      if (friend != null) {
        final myUid = widget.currentUserId;
        final peerId = (friend['user_id'] as num?)?.toInt() ?? 0;
        final cid =
            '${myUid < peerId ? myUid : peerId}_${myUid < peerId ? peerId : myUid}';
        if (cid == chatId) {
          setState(() => _messages = []);
        }
      }
      await _loadConversations();
    });
    // 全局监听消息撤回：同步对方撤回的消息
    _chatRecallSub = WsService.instance.onChatRecall.listen((recall) async {
      final chatId = recall['chat_id']?.toString() ?? '';
      final msgId = (recall['msg_id'] as num?)?.toInt() ?? 0;
      final friend = _selectedFriend;
      if (friend == null || msgId <= 0) return;
      final myUid = widget.currentUserId;
      final peerId = (friend['user_id'] as num?)?.toInt() ?? 0;
      final cid =
          '${myUid < peerId ? myUid : peerId}_${myUid < peerId ? peerId : myUid}';
      if (cid != chatId) return;
      await ChatStore.instance.markRecalled(msgId);
      if (mounted) await _loadLocalMessages();
    });
    // 全局监听聊天新消息：刷新会话列表 + 未读
    _chatReadSub = WsService.instance.onChatRead.listen((read) {
      if (!mounted) return;
      final readMsgId = (read['msg_id'] as num?)?.toInt() ?? 0;
      final chatId = read['chat_id']?.toString() ?? '';
      if (readMsgId > 0) {
        // 对方已读我的消息：标记本地 read_status=1
        ChatStore.instance
            .markMyMessagesRead(chatId, widget.currentUserId, readMsgId);
        if (chatId.isNotEmpty && _selectedFriend != null) {
          _loadLocalMessages();
        }
      }
    });
    // 跨端已读同步：自己其他设备读了该会话 → 本地清零未读角标（多端已读一致）
    _chatReadSyncSub = WsService.instance.onChatReadSync.listen((read) {
      if (!mounted) return;
      final chatId = read['chat_id']?.toString() ?? '';
      if (chatId.isEmpty) return;
      ChatStore.instance.clearUnread(chatId);
      _loadConversations();
    });
    // 上报通知器：消息页初始活跃状态
    ChatNotifier.instance.setPageActive(widget.active);
  }

  @override
  void didUpdateWidget(MessagePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // IndexedStack 保留 State：切回消息页时重新从本地库聚合会话列表
    // （覆盖"发消息后切走再切回"场景，也兜底会话/未读的最新状态）
    if (!oldWidget.active && widget.active) {
      _loadConversations();
    }
    // 消息页活跃状态变化 → 通知器（切走消息页后收到消息恢复弹通知）
    if (oldWidget.active != widget.active) {
      ChatNotifier.instance.setPageActive(widget.active);
    }
  }

  @override
  void dispose() {
    _chatSub?.cancel();
    _chatReadSub?.cancel();
    _chatReadSyncSub?.cancel();
    _chatRecallSub?.cancel();
    _chatClearSub?.cancel();
    _typingSub?.cancel();
    // 清理通知器状态（页面销毁时不再作为"当前会话/活跃"）
    ChatNotifier.instance.clearCurrentChat();
    ChatNotifier.instance.setPageActive(false);
    _peerTypingTimer?.cancel();
    _typingSendDebounce?.cancel();
    _imageRefreshDebounce?.cancel();
    _conversationRefreshDebounce?.cancel();
    ChatStore.imageCacheTick.removeListener(_onImageCacheTick);
    _msgScrollCtrl.removeListener(_onMsgScroll);
    _msgScrollCtrl.dispose();
    _inputCtrl.dispose();
    _inputFocus.dispose();
    _searchCtrl.dispose();
    _searchFocusNode.dispose();
    ChatStore.instance.chatUnreadTick.removeListener(_onUnreadTick);
    super.dispose();
  }

  /// 图片缓存回填通知：防抖后刷新消息列表（展示本地图片）
  /// 图片固定尺寸不改变列表高度 → scroll:false，避免重复定位
  void _onImageCacheTick() {
    if (!mounted) return;
    _imageRefreshDebounce?.cancel();
    _imageRefreshDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _loadLocalMessages(scroll: false);
    });
  }

  /// 未读变化（登录后离线同步入库 / 收到新消息 / 跨端已读）：
  /// 防抖刷新会话列表（离线同步大量入库时只刷新一次）
  void _onUnreadTick() {
    if (!mounted) return;
    _conversationRefreshDebounce?.cancel();
    _conversationRefreshDebounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      _loadConversations();
    });
  }

  /// 跟踪滚动位置：是否在底部（决定新消息是否自动跟随）
  /// 滚到接近顶部时触发上滑加载更早历史
  void _onMsgScroll() {
    if (!_msgScrollCtrl.hasClients) return;
    final pos = _msgScrollCtrl.position;
    // 正向列表：offset 接近 maxScrollExtent = 底部（最新）
    _stickBottom = pos.pixels >= pos.maxScrollExtent - 24;
    // 滚到接近顶部（offset <= 40）→ 上滑加载更早历史
    if (pos.pixels <= 40 && _selectedFriend != null) {
      _loadOlderMessages();
    }
  }

  /// 上滑加载更早历史：先读本地更早记录，本地没有再拉服务器
  Future<void> _loadOlderMessages() async {
    final friend = _selectedFriend;
    if (friend == null || _loadingOlder || _noMoreOlder) return;
    if (_messages.isEmpty) return;
    final myUid = widget.currentUserId;
    final peerId = (friend['user_id'] as num?)?.toInt() ?? 0;
    final chatId =
        '${myUid < peerId ? myUid : peerId}_${myUid < peerId ? peerId : myUid}';
    // 当前最旧一条（正向列表 _messages 为 ASC，最旧在头部）：
    // 本地自增 id 作为游标；msg_id（服务器 id）用于服务器游标
    final oldest = _messages.first;
    final oldestLocalId = (oldest['id'] as num?)?.toInt() ?? 0;
    final oldestServerId = (oldest['msg_id'] as num?)?.toInt() ?? 0;
    // 记录原视口顶部消息（位置恢复兜底：插入后用 GlobalKey 定位回它）
    final anchorMsgId = (oldest['msg_id'] as num?)?.toInt() ?? 0;
    final preOffset =
        _msgScrollCtrl.hasClients ? _msgScrollCtrl.offset : 0.0;
    final preMax = _msgScrollCtrl.hasClients
        ? _msgScrollCtrl.position.maxScrollExtent
        : 0.0;
    setState(() => _loadingOlder = true);
    // 1) 本地增量读取更早记录
    final older = await ChatStore.instance
        .getMessages(chatId, beforeId: oldestLocalId, limit: 30);
    // 2) 本地没有更早且服务器还有 → 拉服务器历史落库
    if (older.isEmpty && oldestServerId > 0) {
      final pulled =
          await ChatService.instance.pullHistory(peerId: peerId, beforeId: oldestServerId);
      if (pulled == 0 && mounted) {
        setState(() {
          _loadingOlder = false;
          _noMoreOlder = true;
        });
        return;
      }
      final more = await ChatStore.instance
          .getMessages(chatId, beforeId: oldestLocalId, limit: 30);
      older.addAll(more);
    }
    if (!mounted) return;
    if (older.isEmpty) {
      setState(() {
        _loadingOlder = false;
        _noMoreOlder = true;
      });
      return;
    }
    // 3) 增量插入列表头部（older 是 DESC，需反转为旧→新），并恢复可视位置
    setState(() {
      _messages = [...older.reversed, ..._messages];
      _loadingOlder = false;
    });
    // 位置恢复兜底：优先定位到原第一条消息（GlobalKey），
    // 避免 maxScrollExtent 惰性计算不准导致跳转错位
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_msgScrollCtrl.hasClients) return;
      final anchorCtx = anchorMsgId > 0 ? _bubbleKeys[anchorMsgId]?.currentContext : null;
      if (anchorCtx != null) {
        Scrollable.ensureVisible(
          anchorCtx,
          duration: Duration.zero,
          alignment: 0, // 滚到视口顶部（原位置附近）
        );
        return;
      }
      // 兜底：按新增高度补偿（clamp 防越界）
      final added = _msgScrollCtrl.position.maxScrollExtent - preMax;
      final max = _msgScrollCtrl.position.maxScrollExtent;
      _msgScrollCtrl.jumpTo((preOffset + added).clamp(0.0, max));
    });
  }

  /// 加载本地会话列表（微信原理：会话 = 本地聊天记录，无论收发）
  Future<void> _loadConversations() async {
    // 1) 以本地聊天记录为唯一真相源，聚合出会话（含我发出的消息）
    await ChatStore.instance
        .syncConversationsFromMessages(widget.currentUserId);
    final rows = await ChatStore.instance.getConversations();
    if (!mounted) return;
    // 2) 拷贝为可变 Map（sqflite 返回只读 QueryRow，不能原地改字段）
    final list = [for (final r in rows) Map<String, dynamic>.from(r)];
    // 3) 用已加载的好友信息补全会话昵称/头像
    final friendMap = {
      for (final f in _friends) (f['user_id'] as num?)?.toInt(): f
    };
    for (final r in list) {
      final peerId = (r['peer_id'] as num?)?.toInt() ?? 0;
      final f = friendMap[peerId];
      if (f != null) {
        r['peer_nickname'] = f['nickname']?.toString() ?? '';
        r['peer_avatar'] = f['avatar']?.toString() ?? '';
      }
    }
    setState(() => _conversations = list);
  }

  /// 联系人列表（微信/QQ 风格）：一次拉全，按昵称拼音首字母分组排序
  Future<void> _loadFriends() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final all = <Map<String, dynamic>>[];
      var page = 1;
      var hasMore = true;
      // 循环拉全（联系人总数有限，page_size=50，最多 10 页兜底）
      while (hasMore && page <= 10) {
        final resp = await ApiClient.instance
            .getFriends(page: page, pageSize: 50)
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
        all.addAll(list.map((e) => Map<String, dynamic>.from(e)));
        hasMore = (data['has_more'] ?? false) == true;
        page++;
      }
      if (!mounted) return;
      setState(() {
        _friends
          ..clear()
          ..addAll(all);
        _loading = false;
      });
      // 好友信息已就绪：刷新会话列表以补全昵称/头像
      _loadConversations();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      }
    }
  }

  /// 选中好友 → 初始化聊天
  ///
  /// [force]=true：跳过「点击当前会话取消选中」逻辑（通知/跨端跳转用，重复点击保持打开）
  Future<void> _selectFriend(Map<String, dynamic> friend,
      {bool force = false}) async {
    final peerId = (friend['user_id'] as num?)?.toInt() ?? 0;
    final nickname = friend['nickname']?.toString() ?? '';
    final avatar = friend['avatar']?.toString() ?? '';
    // 空对话人兜底：无有效对端信息 → 禁止进入聊天/发送消息
    if (peerId <= 0 || (nickname.isEmpty && avatar.isEmpty)) {
      NotifyStack.warning('该对话已失效，无法发送消息', title: '提示');
      return;
    }
    // 点击当前已选中的会话：关闭对话框，取消选中（QQ微信同款；force 跳过）
    if (!force && (_selectedFriend?['user_id'] as num?)?.toInt() == peerId) {
      _chatSub?.cancel();
      setState(() {
        _selectedFriend = null;
        _messages = [];
        _peerTyping = false;
        _emojiPanelOpen = false;
        _quoteTarget = null;
        _multiSelect = false;
        _selectedMsgIds.clear();
      });
      // 上报通知器：已无当前会话
      ChatNotifier.instance.clearCurrentChat();
      return;
    }
    setState(() {
      _selectedFriend = friend;
      _messages = [];
      _peerPublicKey = null;
      _peerOnline = (friend['online'] ?? false) == true;
      // 点击好友 → 自动切回会话视图（相当于新增会话窗口）
      _viewMode = 0;
      // 新会话：重置上滑加载状态 + 输入状态 + 粘底 + 表情/引用/多选
      _loadingOlder = false;
      _noMoreOlder = false;
      _peerTyping = false;
      _emojiPanelOpen = false;
      _quoteTarget = null;
      _multiSelect = false;
      _selectedMsgIds.clear();
    });
    // 上报通知器：当前正在查看该会话（离线消息通知据此不弹窗）
    ChatNotifier.instance.setCurrentChat(peerId);
    // 打开会话：加载后定位到最新消息
    _forceScrollBottom = true;
    // 1) 立即读本地历史并显示（无网络加载过程，QQ微信体验）
    await _loadLocalMessages();
    // 2) 预建/更新会话摘要（昵称头像完整），确保会话列表出现该好友
    final myUid = widget.currentUserId;
    final chatId =
        '${myUid < peerId ? myUid : peerId}_${myUid < peerId ? peerId : myUid}';
    await ChatStore.instance.upsertConversation(
      chatId: chatId,
      peerId: peerId,
      peerNickname: nickname,
      peerAvatar: avatar,
      lastMsgText: '',
      lastMsgTime: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      unreadDelta: 0,
    );
    _loadConversations();
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

    // 3) 后台异步：初始化密钥/拉公钥/拉历史/上报已读（不阻塞本地显示）
    unawaited(() async {
      try {
        await ChatService.instance.init(widget.currentUserId);
        final keys = await ApiClient.instance
            .getChatKeys([(friend['user_id'] as num?)?.toInt() ?? 0]);
        final json = ApiClient.safeJsonDecode(keys.body);
        if (json['code'] == 0) {
          final keyMap = (json['data'] ?? {})['keys'] as Map? ?? {};
          _peerPublicKey = keyMap['${friend['user_id']}']?.toString();
        }
        // 记录拉取前本地消息数
        final beforeCount = await ChatStore.instance
            .getMessages(chatId, limit: 200)
            .then((r) => r.length);
        await ChatService.instance.pullHistory(peerId: peerId);
        final chatId2 =
            '${myUid < peerId ? myUid : peerId}_${myUid < peerId ? peerId : myUid}';
        await ChatStore.instance.clearUnread(chatId2);
        await ChatStore.instance.markChatRead(chatId2, myUid);
        _reportReadUpTo(null);
        _loadConversations();
        // 有新消息才跟随底部滚动；无新消息仅刷新显示（避免二次定位）
        final afterCount = await ChatStore.instance
            .getMessages(chatId, limit: 200)
            .then((r) => r.length);
        if (afterCount != beforeCount) {
          _loadLocalMessages();
        } else {
          _loadLocalMessages(scroll: false);
        }
      } catch (_) {
        _loadLocalMessages();
      }
    }());
  }

  /// 从通知点击跳转：打开与指定好友的会话（供 main.dart 注入的
  /// [ChatNotifier] 跳转回调调用）。数据源优先好友列表，其次本地会话缓存。
  Future<void> openChatWithPeer(int peerId) async {
    if (peerId <= 0 || !mounted) return;
    Map<String, dynamic>? friend;
    for (final f in _friends) {
      if ((f['user_id'] as num?)?.toInt() == peerId) {
        friend = f;
        break;
      }
    }
    if (friend == null) {
      final myUid = widget.currentUserId;
      final chatId =
          '${myUid < peerId ? myUid : peerId}_${myUid < peerId ? peerId : myUid}';
      final conv =
          await ChatStore.instance.getConversationByChatId(chatId);
      friend = {
        'user_id': peerId,
        'nickname': conv?['peer_nickname']?.toString() ?? '',
        'avatar': conv?['peer_avatar']?.toString() ?? '',
        'online': false,
      };
    }
    if ((friend['nickname'] ?? '').isEmpty &&
        (friend['avatar'] ?? '').isEmpty) {
      if (mounted) {
        NotifyStack.warning('未找到会话信息，请稍后重试', title: '提示');
      }
      return;
    }
    // 好友列表尚未加载时先加载（保证左侧列表数据完整）
    if (_friends.isEmpty && !_loading) _loadFriends();
    await _selectFriend(friend, force: true);
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

  Future<void> _loadLocalMessages({bool scroll = true}) async {
    final friend = _selectedFriend;
    if (friend == null) return;
    final myUid = widget.currentUserId;
    final peerId = (friend['user_id'] as num?)?.toInt() ?? 0;
    final chatId = '${myUid < peerId ? myUid : peerId}_${myUid < peerId ? peerId : myUid}';
    // getMessages 返回 id DESC（最新在前）；正向列表需反转 → 最新在末尾（底部）
    final rows = await ChatStore.instance.getMessages(chatId, limit: 200);
    if (!mounted) return;
    setState(() {
      _messages = rows.reversed.toList();
    });
    // 清理已不在显示范围内消息的气泡 GlobalKey（防长期运行内存增长）
    final currentIds = {
      for (final m in _messages) (m['msg_id'] as num?)?.toInt() ?? 0,
    };
    _bubbleKeys.removeWhere((k, _) => !currentIds.contains(k));
    // 粘底：强制（发送/重发/打开会话）或原本就在底部（新消息自动跟随）
    if (scroll && (_forceScrollBottom || _stickBottom)) {
      _scrollToBottom();
    }
  }

  /// 回到消息列表底部（正向列表 offset = maxScrollExtent = 最新消息）
  ///
  /// ListView 惰性布局：首帧 maxScrollExtent 只反映已布局部分，比真实值小，
  /// jumpTo 会停在列表中部（看起来"新消息在顶部"）。因此 jumpTo 后若
  /// maxScrollExtent 仍在增长（内容继续被布局），延迟一帧再跳，直到收敛。
  void _scrollToBottom([int attempt = 0]) {
    _forceScrollBottom = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_msgScrollCtrl.hasClients) return;
      final pos = _msgScrollCtrl.position;
      final before = pos.maxScrollExtent;
      pos.jumpTo(before);
      _stickBottom = true;
      // 内容还在增长（布局未完成）→ 收敛继续跳
      if (attempt < 8) {
        Timer(const Duration(milliseconds: 16), () {
          if (!mounted || !_msgScrollCtrl.hasClients) return;
          final now = _msgScrollCtrl.position.maxScrollExtent;
          if (now > before || before <= 0) {
            _scrollToBottom(attempt + 1);
          }
        });
      }
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
    _forceScrollBottom = true;
    if (mounted) await _loadLocalMessages();
    // 图片/表情消息需透传类型与本地缓存路径（否则重发会变纯文本）
    final result = await ChatService.instance.sendMessage(
      receiverId: peerId,
      plaintext: plaintext,
      msgType: (m['msg_type'] as num?)?.toInt() ?? 1,
      imageLocalPath: m['image_local_path']?.toString() ?? '',
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
    if (text.isEmpty || _sending || _multiSelect) return;
    final friend = _selectedFriend;
    if (friend == null) return;
    final peerId = (friend['user_id'] as num?)?.toInt() ?? 0;
    setState(() => _sending = true);

    // 引用消息：body 为 {"text":..., "reply_to":{id,nickname,msg_type,preview}}
    // 普通消息保持纯文本 body（E2EE 密文内容自包含，对端直接渲染）
    var body = text;
    final quote = _quoteTarget;
    if (quote != null) {
      final quoteMsgId = (quote['msg_id'] as num?)?.toInt() ?? 0;
      if (quoteMsgId > 0) {
        body = jsonEncode({
          'text': text,
          'reply_to': {
            'id': quoteMsgId,
            'nickname': _quoteNickname(quote),
            'msg_type': (quote['msg_type'] as num?)?.toInt() ?? 1,
            'preview': _quotePreview(quote),
          },
        });
      }
    }

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
      plaintext: body,
      ciphertext: '',
      nonce: '',
      ephemeralPub: '',
      sendStatus: 0,
      createTime: now,
    );
    _inputCtrl.clear();
    // 引用已随 body 打包，发送后清除引用条
    if (_quoteTarget != null) setState(() => _quoteTarget = null);
    _forceScrollBottom = true; // 发送消息：无论当前在哪都强制回到底部
    await _loadLocalMessages();
    // 发送瞬间即刷新会话列表（本地消息已入库，聚合即可置顶），不等接口返回
    await _loadConversations();

    final result = await ChatService.instance.sendMessage(
      receiverId: peerId,
      plaintext: body,
      peerPublicKey: _peerPublicKey,
      forceClientMsgId: clientMsgId,
    );
    if (!mounted) return;
    if (!result.ok) {
      NotifyStack.warning(result.error, title: '提示');
    }
    setState(() => _sending = false);
    await _loadLocalMessages();
    _scrollToBottom(); // 发送完成后再次贴底
    await _loadConversations(); // 状态同步后再刷一次（兜底）
  }

  /// 选图 → 客户端转码 jpg（GIF 保留）→ 上传 → 发送图片消息
  Future<void> _pickImageAndSend() async {
    final friend = _selectedFriend;
    if (friend == null) return;
    final images = await pickImages(allowMultiple: false);
    if (images.isEmpty || !mounted) return;
    // 客户端统一转码：webp/png/bmp → jpg；GIF 保留动画
    final img = images.first;
    final t = await ImageTranscoder.toJpeg(bytes: img.bytes, name: img.name);
    if (t == null) {
      if (mounted) NotifyStack.warning('图片格式不支持', title: '提示');
      return;
    }
    await _sendImageBytes(t.bytes, t.name);
  }

  /// 聊天输入框粘贴图片：读剪贴板图片 → 转 jpg → 发送
  Future<bool> _pasteClipboardImage() async {
    final bytes = await readClipboardImageBytes();
    if (bytes == null || bytes.isEmpty) return false;
    // 转码：webp 等 → jpg；GIF 保留
    final t = await ImageTranscoder.toJpeg(bytes: bytes, name: 'paste_image.png');
    if (t == null) return false;
    await _sendImageBytes(t.bytes, t.name);
    return true;
  }

  /// 上传图片字节 → 发送图片消息（选图/粘贴共用）
  Future<void> _sendImageBytes(Uint8List bytes, String name) async {
    final friend = _selectedFriend;
    if (friend == null) return;
    if (!mounted) return;
    setState(() => _sending = true);
    try {
      // 上传聊天图片，拿 URL
      final resp = await ApiClient.instance
          .uploadChatImage(bytes, filename: name)
          .timeout(const Duration(seconds: 20));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] != 0) {
        NotifyStack.warning(json['msg']?.toString() ?? '图片上传失败', title: '提示');
        return;
      }
      final url = (json['data'] ?? {})['url']?.toString() ?? '';
      if (url.isEmpty) {
        NotifyStack.warning('图片上传失败', title: '提示');
        return;
      }
      // 发送方本地立即缓存图片（云端只作中转，30 天到期清理）
      String? localPath;
      try {
        localPath = await ChatImageCache.ensureCached(url, bytes: bytes);
      } catch (_) {}
      // 消息体 = 加密的 JSON（url 元数据）
      final payload = jsonEncode({'url': url});
      final result = await ChatService.instance.sendMessage(
        receiverId: (friend['user_id'] as num?)?.toInt() ?? 0,
        plaintext: payload,
        msgType: 2,
        imageLocalPath: localPath ?? '',
        peerPublicKey: _peerPublicKey,
      );
      if (!result.ok && mounted) {
        NotifyStack.warning(result.error, title: '提示');
      }
      if (mounted) {
        await _loadLocalMessages();
        _scrollToBottom();
        await _loadConversations();
      }
    } catch (_) {
      if (mounted) NotifyStack.warning('图片发送失败', title: '提示');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 表情气泡打开/关闭状态（图标高亮联动）
  void _setEmojiPanelOpen(bool open) {
    if (_emojiPanelOpen == open) return;
    setState(() => _emojiPanelOpen = open);
  }

  /// 切换输入框放大/缩小（4 行 ↔ 10 行）
  void _toggleInputExpanded() {
    setState(() => _inputExpanded = !_inputExpanded);
  }

  /// 输入框键盘事件：Enter 发送；Ctrl/Cmd+Enter 换行；Ctrl/Cmd+V 粘贴图片；
  /// 中文输入法候选确认时不拦截
  KeyEventResult _handleInputKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter) {
      // 中文输入法组合中（拼音候选）：Enter 交给输入法确认候选词
      if (_inputCtrl.value.composing.isValid) {
        return KeyEventResult.ignored;
      }
      if (HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed) {
        // Ctrl/Cmd+Enter：换行（交给 TextField 插入换行）
        return KeyEventResult.ignored;
      }
      _sendMessage();
      return KeyEventResult.handled;
    }
    // Ctrl/Cmd+V：尝试粘贴剪贴板图片（有图则拦截发送，无图放行文本粘贴）
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      unawaited(_pasteClipboardImageOnShortcut());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Ctrl+V 快捷粘贴：有剪贴板图片则发送图片；否则回放文本粘贴给输入框
  Future<void> _pasteClipboardImageOnShortcut() async {
    final bytes = await readClipboardImageBytes();
    if (bytes == null || bytes.isEmpty || !mounted) {
      // 无图片 → 手动插入剪贴板文本（模拟系统粘贴）
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text != null && text.isNotEmpty && mounted) {
        final sel = _inputCtrl.selection;
        final newText =
            _inputCtrl.text.replaceRange(sel.start, sel.end, text);
        _inputCtrl.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: sel.start + text.length),
        );
      }
      return;
    }
    final t = await ImageTranscoder.toJpeg(bytes: bytes, name: 'paste_image.png');
    if (t == null || !mounted) return;
    await _sendImageBytes(t.bytes, t.name);
  }

  /// 点击 emoji：在光标处插入 Unicode 字符（不发送，随文本一起发送）；
  /// 插入后自动收起表情气泡（微信式）
  void _insertEmoji(String e) {
    final idx = _inputCtrl.selection.baseOffset;
    final text = _inputCtrl.text;
    final newText = idx >= 0 && idx <= text.length
        ? text.replaceRange(idx, idx, e)
        : text + e;
    _inputCtrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: idx + e.length),
    );
    _onInputChanged(newText);
    _emojiMenuKey.currentState?.close();
  }

  /// 点击表情包：直接发送表情消息（msg_type=3，body=加密的 {"url","w","h"}）；
  /// 发送后自动收起表情气泡（微信式）
  Future<void> _sendSticker(StickerItem s) async {
    final friend = _selectedFriend;
    if (friend == null || _sending) return;
    // 先收起气泡，再发送（连续发多个表情时气泡不再重复弹出）
    _emojiMenuKey.currentState?.close();
    final peerId = (friend['user_id'] as num?)?.toInt() ?? 0;
    if (peerId <= 0) return;
    final payload =
        jsonEncode({'url': s.url, 'w': s.width, 'h': s.height});
    final clientMsgId =
        '${widget.currentUserId}_${DateTime.now().millisecondsSinceEpoch}';
    final myUid = widget.currentUserId;
    final chatId =
        '${myUid < peerId ? myUid : peerId}_${myUid < peerId ? peerId : myUid}';
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // 乐观更新
    await ChatStore.instance.upsertMessage(
      chatId: chatId,
      msgId: 0,
      clientMsgId: clientMsgId,
      senderId: myUid,
      receiverId: peerId,
      msgType: 3,
      plaintext: payload,
      ciphertext: '',
      nonce: '',
      ephemeralPub: '',
      sendStatus: 0,
      createTime: now,
    );
    _forceScrollBottom = true;
    await _loadLocalMessages();
    await _loadConversations();
    final result = await ChatService.instance.sendMessage(
      receiverId: peerId,
      plaintext: payload,
      msgType: 3,
      peerPublicKey: _peerPublicKey,
      forceClientMsgId: clientMsgId,
    );
    if (!mounted) return;
    if (!result.ok) {
      NotifyStack.warning(result.error, title: '提示');
    }
    await _loadLocalMessages();
    _scrollToBottom();
    await _loadConversations();
  }

  // ===== 引用（回复） =====

  /// 解析消息体：普通文本原样返回；引用消息返回 (引用信息, 实际文本)
  /// 引用消息 body 格式：{"text":"...","reply_to":{"id","nickname","msg_type","preview"}}
  (Map<String, dynamic>?, String) _parseBody(String plaintext) {
    if (plaintext.startsWith('{')) {
      try {
        final j = jsonDecode(plaintext);
        if (j is Map && j['text'] is String && j['reply_to'] is Map) {
          return (
            Map<String, dynamic>.from(j['reply_to'] as Map),
            j['text'] as String
          );
        }
      } catch (_) {}
    }
    return (null, plaintext);
  }

  /// 被引用消息的发送者昵称（自己发的显示「我」）
  String _quoteNickname(Map<String, dynamic> m) {
    final senderId = (m['sender_id'] as num?)?.toInt() ?? 0;
    if (senderId == widget.currentUserId) return '我';
    return _selectedFriend?['nickname']?.toString() ?? '';
  }

  /// 被引用消息的内容预览（图片/表情/撤回/文本分别处理）
  String _quotePreview(Map<String, dynamic> m) {
    if ((m['recalled'] as num?)?.toInt() == 1) return '该消息已撤回';
    final msgType = (m['msg_type'] as num?)?.toInt() ?? 1;
    if (msgType == 2) return '[图片]';
    if (msgType == 3) return '[表情]';
    final body = m['plaintext']?.toString() ?? '';
    return _parseBody(body).$2;
  }

  /// 右键「回复」：设置引用目标，输入区上方显示引用条
  void _startQuote(Map<String, dynamic> m) {
    final msgId = (m['msg_id'] as num?)?.toInt() ?? 0;
    if (msgId <= 0) {
      NotifyStack.warning('该消息暂不能回复', title: '提示');
      return;
    }
    setState(() => _quoteTarget = Map<String, dynamic>.from(m));
  }

  void _cancelQuote() {
    if (_quoteTarget == null) return;
    setState(() => _quoteTarget = null);
  }

  // ===== 标题栏省略号：右侧弹出层（进主页/清空/查找/取消好友/拉黑） =====

  /// 右上角省略号 → 右侧滑入弹出层（微信风格）
  Future<void> _showChatMenu() async {
    final friend = _selectedFriend;
    if (friend == null || !mounted) return;
    final peerId = (friend['user_id'] as num?)?.toInt() ?? 0;
    final nickname = friend['nickname']?.toString() ?? '';
    final avatar = friend['avatar']?.toString() ?? '';
    if (peerId <= 0) return;
    final myUid = widget.currentUserId;
    final chatId =
        '${myUid < peerId ? myUid : peerId}_${myUid < peerId ? peerId : myUid}';

    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'close',
      barrierColor: Colors.black.withValues(alpha: 0.25),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, anim, _) => _buildChatMenuPanel(
        ctx,
        b: Theme.of(context).brightness,
        nickname: nickname,
        avatar: avatar,
        online: _peerOnline,
        onEditRemark: () {
          Navigator.of(ctx).pop();
          _editRemark(peerId);
        },
        onItem: (ChatMenuAction action) {
          Navigator.of(ctx).pop();
          switch (action) {
            case ChatMenuAction.openProfile:
              widget.onOpenUserProfile?.call(peerId, nickname, avatar);
            case ChatMenuAction.clearChat:
              _confirmClearChat(peerId, chatId);
            case ChatMenuAction.searchChat:
              _openChatSearch();
            case ChatMenuAction.removeFriend:
              _confirmRemoveFriend(peerId, chatId);
            case ChatMenuAction.block:
              _confirmBlockUser(peerId, chatId, nickname);
          }
        },
      ),
      transitionBuilder: (ctx, anim, _, child) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );
  }

  /// 右侧弹出层面板（右对齐全高，左侧圆角）
  Widget _buildChatMenuPanel(
    BuildContext ctx, {
    required Brightness b,
    required String nickname,
    required String avatar,
    required bool online,
    required VoidCallback onEditRemark,
    required void Function(ChatMenuAction) onItem,
  }) {
    return Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: bgColor(b),
        // 仅保留右上/右下圆角（面板靠右，贴边侧直角）
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(kRadiusMd),
          bottomRight: Radius.circular(kRadiusMd),
        ),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 300,
          height: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 顶部：头像 + 昵称 + 在线 + 关闭
              Container(
                padding: const EdgeInsets.fromLTRB(16, 20, 8, 16),
                color: bgHoverColor(b),
                child: Row(
                  children: [
                    _avatarWithStatus(
                      b: b,
                      avatar: avatar,
                      nickname: nickname,
                      size: 40,
                      online: online,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 昵称 + 修改备注按钮（点击弹出输入框）
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  nickname,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: textColor(b)),
                                ),
                              ),
                              const SizedBox(width: 6),
                              InkWell(
                                onTap: onEditRemark,
                                mouseCursor: SystemMouseCursors.click,
                                borderRadius: BorderRadius.circular(kRadiusSm),
                                child: Padding(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 3),
                                  child: Icon(Icons.edit_outlined,
                                      size: 15, color: textMutedColor(b)),
                                ),
                              ),
                            ],
                          ),
                          Text(
                            online ? '在线' : '离线',
                            style: TextStyle(
                                fontSize: 12, color: textMutedColor(b)),
                          ),
                        ],
                      ),
                    ),
                    InkWell(
                      onTap: () => Navigator.of(ctx).pop(),
                      mouseCursor: SystemMouseCursors.click,
                      borderRadius: BorderRadius.circular(kRadiusFull),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(Icons.close_rounded,
                            size: 18, color: textFaintColor(b)),
                      ),
                    ),
                  ],
                ),
              ),
              // 菜单项
              _chatMenuItem(b, Icons.person_outline_rounded, '访问主页',
                  () => onItem(ChatMenuAction.openProfile)),
              _chatMenuItem(
                  b, Icons.delete_outline_rounded, '清空对话记录',
                  () => onItem(ChatMenuAction.clearChat)),
              _chatMenuItem(
                  b, Icons.search_rounded, '查找聊天记录',
                  () => onItem(ChatMenuAction.searchChat)),
              const Divider(
                  height: 1, thickness: 1, color: Color(0x16000000)),
              _chatMenuItem(
                  b, Icons.person_off_outlined, '取消好友',
                  () => onItem(ChatMenuAction.removeFriend)),
              _chatMenuItem(
                  b, Icons.block_rounded, '拉黑名单',
                  () => onItem(ChatMenuAction.block),
                  color: kDanger),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chatMenuItem(Brightness b, IconData icon, String label,
      VoidCallback onTap,
      {Color? color}) {
    return InkWell(
      onTap: onTap,
      mouseCursor: SystemMouseCursors.click,
      hoverColor: bgHoverColor(b),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color ?? textColor(b)),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                  fontSize: 14,
                  color: color ?? textColor(b),
                  fontWeight: FontWeight.w400),
            ),
          ],
        ),
      ),
    );
  }

  /// 修改好友备注：输入框 → 保存 → 刷新好友列表（会话列表备注同步更新）
  Future<void> _editRemark(int peerId) async {
    final friend = _selectedFriend;
    final curRemark = friend?['remark']?.toString() ?? '';
    final ctrl = TextEditingController(text: curRemark);
    final b = Theme.of(context).brightness;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: bgColor(b),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadiusMd)),
        title: const Text('设置备注', style: TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 320,
          child: TextInputBubbleMenu(
            controller: ctrl,
            child: TextField(
              controller: ctrl,
              autofocus: true,
              maxLength: 50,
              // 禁用系统右键菜单（统一用气泡方案）
              contextMenuBuilder: (_, __) => const SizedBox.shrink(),
              // 过滤粘贴/输入的非法 UTF-16 代理项（防渲染崩溃）
              inputFormatters: const [Utf16SanitizeTextInputFormatter()],
              style: TextStyle(fontSize: 14, color: textColor(b)),
              decoration: InputDecoration(
                hintText: '输入备注名（可留空清除）',
                hintStyle:
                    TextStyle(fontSize: 14, color: textFaintColor(b)),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final remark = ctrl.text.trim();
    try {
      final resp = await ApiClient.instance
          .setRemark(peerId, remark)
          .timeout(const Duration(seconds: 10));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] != 0) {
        if (mounted) {
          NotifyStack.warning(json['msg']?.toString() ?? '保存失败', title: '提示');
        }
        return;
      }
    } catch (_) {
      if (mounted) NotifyStack.warning('网络异常，保存失败', title: '提示');
      return;
    }

    // 更新好友列表中的备注
    for (final f in _friends) {
      if ((f['user_id'] as num?)?.toInt() == peerId) {
        f['remark'] = remark;
      }
    }
    // 当前会话同步备注（会话列表预览用备注名）
    if (_selectedFriend != null &&
        (_selectedFriend!['user_id'] as num?)?.toInt() == peerId) {
      _selectedFriend!['remark'] = remark;
    }
    if (mounted) {
      NotifyStack.success(remark.isEmpty ? '已清除备注' : '备注已保存', title: '提示');
      setState(() {});
    }
    await _loadConversations();
  }

  /// 查找聊天记录：切回会话视图并聚焦搜索框
  void _openChatSearch() {
    if (!mounted) return;
    setState(() {
      _viewMode = 0;
      _keyword = '';
      _searchMsgResults = [];
      _searchCtrl.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _searchFocusNode.requestFocus());
  }

  /// 取消好友（解除双方关注）：交互提示 → 后端解除 → 本地移除好友+隐藏会话
  Future<void> _confirmRemoveFriend(int peerId, String chatId) async {
    final ok = await AppDialog.confirm(
      context,
      title: '取消好友',
      message: '将解除与该好友的相互关注关系，并从好友列表移除。\n确定取消好友吗？',
      confirmText: '取消好友',
      danger: true,
    );
    if (ok != true || !mounted) return;
    try {
      final resp = await ApiClient.instance
          .removeFriend(peerId)
          .timeout(const Duration(seconds: 10));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] != 0) {
        if (mounted) {
          NotifyStack.warning(json['msg']?.toString() ?? '操作失败', title: '提示');
        }
        return;
      }
    } catch (_) {
      if (mounted) NotifyStack.warning('网络异常，操作失败', title: '提示');
      return;
    }
    await _removePeerLocal(peerId, chatId);
    if (mounted) NotifyStack.success('已取消好友', title: '提示');
  }

  /// 拉黑：交互提示 → 后端拉黑（自动解除双方关注）→ 本地移除好友+隐藏会话
  Future<void> _confirmBlockUser(
      int peerId, String chatId, String nickname) async {
    final ok = await AppDialog.confirm(
      context,
      title: '拉黑',
      message: '拉黑后你们将互不可见：\n'
          '· 在广场看不到 TA 的帖子\n'
          '· 无法查看 TA 的主页（动态/收藏等）\n'
          '· 无法关注、无法聊天\n\n'
          '确定拉黑「$nickname」吗？',
      confirmText: '拉黑',
      danger: true,
    );
    if (ok != true || !mounted) return;
    try {
      final resp = await ApiClient.instance
          .blockUser(peerId)
          .timeout(const Duration(seconds: 10));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] != 0) {
        if (mounted) {
          NotifyStack.warning(json['msg']?.toString() ?? '拉黑失败', title: '提示');
        }
        return;
      }
    } catch (_) {
      if (mounted) NotifyStack.warning('网络异常，拉黑失败', title: '提示');
      return;
    }
    await _removePeerLocal(peerId, chatId);
    if (mounted) NotifyStack.success('已拉黑「$nickname」', title: '提示');
  }

  /// 取消好友/拉黑后的本地清理：关闭会话、从好友列表移除、隐藏本地会话
  Future<void> _removePeerLocal(int peerId, String chatId) async {
    _chatSub?.cancel();
    _friends.removeWhere((f) => (f['user_id'] as num?)?.toInt() == peerId);
    await ChatStore.instance.deleteConversation(chatId, purgeMessages: false);
    if (!mounted) return;
    setState(() {
      _selectedFriend = null;
      _messages = [];
      _peerTyping = false;
      _multiSelect = false;
      _selectedMsgIds.clear();
    });
    ChatNotifier.instance.clearCurrentChat();
    await _loadConversations();
  }

  /// 点击气泡内引用块：定位到被引用的消息（仅当前加载范围内可用）
  void _jumpToMessage(int msgId) {
    final ctx = _bubbleKeys[msgId]?.currentContext;
    if (ctx == null) {
      NotifyStack.warning('被引用的消息不在当前加载范围内', title: '提示');
      return;
    }
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      alignment: 0.5,
    );
  }

  /// 表情消息右键「添加到表情」：收藏该表情 URL 到自己的表情库
  Future<void> _addStickerFromMessage(String url) async {
    if (url.isEmpty) return;
    try {
      final resp = await ApiClient.instance
          .addSticker(url: url)
          .timeout(const Duration(seconds: 10));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] == 0) {
        if (mounted) NotifyStack.success('已添加到表情包', title: '提示');
      } else {
        if (mounted) {
          NotifyStack.warning(json['msg']?.toString() ?? '添加失败', title: '提示');
        }
      }
    } catch (_) {
      if (mounted) NotifyStack.warning('网络异常，添加失败', title: '提示');
    }
  }

  // ===== 多选删除 =====

  void _toggleSelect(int localId) {
    setState(() {
      if (!_selectedMsgIds.add(localId)) _selectedMsgIds.remove(localId);
    });
  }

  void _selectAllMessages() {
    setState(() {
      if (_selectedMsgIds.length == _messages.length) {
        _selectedMsgIds.clear();
      } else {
        _selectedMsgIds
          ..clear()
          ..addAll(_messages
              .map((m) => (m['id'] as num?)?.toInt() ?? 0)
              .where((id) => id > 0));
      }
    });
  }

  void _exitMultiSelect() {
    setState(() {
      _multiSelect = false;
      _selectedMsgIds.clear();
    });
  }

  /// 删除选中的本地消息（仅本设备，微信同款）
  Future<void> _deleteSelectedMessages() async {
    final n = _selectedMsgIds.length;
    if (n == 0) return;
    final ok = await AppDialog.confirm(
      context,
      title: '删除消息',
      message: '将删除选中的 $n 条消息（仅本设备删除，对方不受影响）。\n确定删除吗？',
      confirmText: '删除',
      danger: true,
    );
    if (ok != true || !mounted) return;
    await ChatStore.instance.deleteMessagesByLocalIds(_selectedMsgIds.toList());
    // 若被引用的消息被删除则取消引用
    final quote = _quoteTarget;
    if (quote != null) {
      final quoteLocalId = (quote['id'] as num?)?.toInt() ?? 0;
      if (_selectedMsgIds.contains(quoteLocalId)) _quoteTarget = null;
    }
    _exitMultiSelect();
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
          // ===== 左侧好友/会话列表（无分割线）：背景与输入框一致（bgHoverColor） =====
          Container(
            width: 260,
            color: bgHoverColor(b),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 会话 / 好友 视图切换
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: Row(
                    children: [
                      _viewSwitch(b, 0, '会话'),
                      const SizedBox(width: 4),
                      _viewSwitch(b, 1, '好友'),
                    ],
                  ),
                ),
                // 搜索框（大厂方案：会话搜昵称/最后消息/聊天记录，好友搜昵称）
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: _buildSearchBox(b),
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
        if (mode == 1) {
          _loadFriends();
        } else if (mode == 0) {
          // 切回会话视图：强制从本地库刷新（热更新/State 复用兜底）
          _loadConversations();
        }
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

  /// 左侧搜索框（圆角胶囊，主色调背景 + 白色前景，固定高度）
  Widget _buildSearchBox(Brightness b) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: bgColor(b), // 主背景色（不是蓝色）
        borderRadius: BorderRadius.circular(kRadiusFull),
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 15, color: textFaintColor(b)),
          const SizedBox(width: 6),
          Expanded(
            child: TextInputBubbleMenu(
              controller: _searchCtrl,
              child: TextField(
                controller: _searchCtrl,
                focusNode: _searchFocusNode,
                onChanged: _onSearchChanged,
                // 禁用系统右键菜单（统一用气泡方案）
                contextMenuBuilder: (_, __) => const SizedBox.shrink(),
                // 过滤粘贴/输入的非法 UTF-16 代理项（防渲染崩溃）
                inputFormatters: const [Utf16SanitizeTextInputFormatter()],
                style: TextStyle(fontSize: 13, color: textColor(b)),
                cursorColor: kPrimary,
                decoration: InputDecoration(
                  hintText: _viewMode == 0 ? '搜索会话/聊天记录' : '搜索好友',
                  hintStyle: TextStyle(fontSize: 13, color: textFaintColor(b)),
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
          ),
          if (_keyword.isNotEmpty)
            InkWell(
              onTap: _clearSearch,
              mouseCursor: SystemMouseCursors.click,
              borderRadius: BorderRadius.circular(kRadiusFull),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.close_rounded,
                    size: 14, color: textFaintColor(b)),
              ),
            ),
        ],
      ),
    );
  }

  void _clearSearch() {
    _searchCtrl.clear();
    setState(() {
      _keyword = '';
      _searchMsgResults = [];
    });
  }

  void _onSearchChanged(String value) {
    final kw = value.trim();
    setState(() {
      _keyword = kw;
      if (kw.isEmpty) _searchMsgResults = [];
    });
    // 会话视图：同步搜索本地聊天记录（跨会话）
    if (kw.isNotEmpty && _viewMode == 0) {
      _searchMessages(kw);
    }
  }

  Future<void> _searchMessages(String kw) async {
    final rows = await ChatStore.instance.searchMessages(kw);
    if (!mounted || _keyword != kw) return;
    setState(() => _searchMsgResults = rows);
  }

  /// 好友 uid → 好友信息（搜索/补全用）
  Map<int, Map<String, dynamic>> _friendMap() => {
        for (final f in _friends)
          if (f['user_id'] != null) (f['user_id'] as num).toInt(): f,
      };

  /// 搜索分组标题
  Widget _searchSectionTitle(Brightness b, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: textSecondaryColor(b),
        ),
      ),
    );
  }

  /// 搜索空态
  Widget _searchEmpty(Brightness b, String text) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off_rounded, size: 36, color: textFaintColor(b)),
          const SizedBox(height: 10),
          Text(
            text,
            style: TextStyle(fontSize: 13, color: textSecondaryColor(b)),
          ),
        ],
      ),
    );
  }

  /// 聊天记录搜索结果项：对端昵称 + 消息内容 + 时间，点击进入会话
  Widget _buildMessageSearchItem(Brightness b, Map<String, dynamic> m) {
    final myUid = widget.currentUserId;
    final senderId = (m['sender_id'] as num?)?.toInt() ?? 0;
    final receiverId = (m['receiver_id'] as num?)?.toInt() ?? 0;
    final peerId = senderId == myUid ? receiverId : senderId;
    final friend = _friendMap()[peerId];
    final nickname = friend?['nickname']?.toString() ?? '好友';
    final avatar = friend?['avatar']?.toString() ?? '';
    final text = m['plaintext']?.toString() ?? '';
    final createTime = (m['create_time'] as num?)?.toInt() ?? 0;
    return InkWell(
      onTap: () => _selectFriend({
        'user_id': peerId,
        'nickname': nickname,
        'avatar': avatar,
      }),
      hoverColor: bgHoverColor(b),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: textColor(b),
                          ),
                        ),
                      ),
                      Text(
                        _timeText(createTime),
                        style:
                            TextStyle(fontSize: 11, color: textFaintColor(b)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    text,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(fontSize: 12, color: textMutedColor(b)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 会话列表（本地驱动：最近消息 + 未读；搜索态显示匹配结果）
  Widget _buildConversationList(Brightness b) {
    // 搜索态：匹配会话 + 聊天记录
    if (_keyword.isNotEmpty) {
      final convs = _conversations.where((c) {
        final n = c['peer_nickname']?.toString() ?? '';
        final t = c['last_msg_text']?.toString() ?? '';
        return n.contains(_keyword) || t.contains(_keyword);
      }).toList();
      final msgs = _searchMsgResults;
      if (convs.isEmpty && msgs.isEmpty) {
        return _searchEmpty(b, '没有找到相关的会话或消息');
      }
      return SilkyListView(
        children: [
          if (convs.isNotEmpty) ...[
            _searchSectionTitle(b, '会话'),
            for (final c in convs) _buildConversationItem(b, c),
          ],
          if (msgs.isNotEmpty) ...[
            _searchSectionTitle(b, '聊天记录'),
            for (final m in msgs) _buildMessageSearchItem(b, m),
          ],
        ],
        scrollSpeed: 1.6,
        silkyScrollDuration: const Duration(milliseconds: 600),
        animationCurve: Curves.easeOutCubic,
      );
    }
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

  /// 会话项：头像 + 昵称 + 最后消息 + 未读 + 时间；右键删除会话
  Widget _buildConversationItem(Brightness b, Map<String, dynamic> c) {
    final peerId = (c['peer_id'] as num?)?.toInt() ?? 0;
    final nickname = c['peer_nickname']?.toString() ?? '';
    final avatar = c['peer_avatar']?.toString() ?? '';
    final lastText = c['last_msg_text']?.toString() ?? '';
    final unread = (c['unread_count'] as num?)?.toInt() ?? 0;
    final lastTime = (c['last_msg_time'] as num?)?.toInt() ?? 0;
    final selected = _selectedFriend?['user_id'] == peerId;

    // 空对话人兜底：无昵称无头像（已注销用户 / 历史脏数据）→ 禁止发消息
    final isEmptyPeer = peerId <= 0 || (nickname.isEmpty && avatar.isEmpty);
    // 有备注时优先显示备注（备注名替换昵称展示，微信风格），从好友列表实时取
    final remark = (_friendMap()[peerId]?['remark'] as String?) ?? '';
    final baseName = isEmptyPeer ? '已注销用户' : (nickname.isEmpty ? '好友' : nickname);
    final displayName = remark.isNotEmpty ? remark : baseName;

    final myUid = widget.currentUserId;
    final chatId =
        '${myUid < peerId ? myUid : peerId}_${myUid < peerId ? peerId : myUid}';

    // 在线状态从好友列表实时取（会话本地缓存无 online 字段）
    final peerOnline =
        (_friendMap()[peerId]?['online'] ?? false) == true;
    final friend = {
      'user_id': peerId,
      'nickname': displayName,
      'avatar': avatar,
      'online': peerOnline,
    };
    return BubbleMenu(
      triggerOnRightClick: true,
      // 宽度按最长菜单项文字自适应
      items: [
        // 删除会话（空对话人彻底删除，正常会话仅隐藏）
        BubbleMenuItem.delete('删除会话', onTap: () {
          _confirmDeleteConversation(peerId, chatId, isEmptyPeer);
        }),
      ],
      child: InkWell(
        onTap: isEmptyPeer
            ? () => NotifyStack.warning('该对话已失效，无法发送消息', title: '提示')
            : () => _selectFriend(friend),
        hoverColor: bgHoverColor(b),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? primarySoftColor(b) : Colors.transparent,
            borderRadius: BorderRadius.circular(kRadiusBtn),
          ),
          child: Row(
            children: [
              // 头像 + 右下角在线圆点（会话项在线状态从好友列表取）
              _avatarWithStatus(
                b: b,
                avatar: avatar,
                nickname: displayName,
                size: 40,
                online: (friend['online'] ?? false) == true,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          // fit:loose + 文字 ellipsis：避免时间文字浮点累计造成 1px 溢出
                          child: Text(
                            displayName,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: textColor(b),
                            ),
                          ),
                        ),
                        if (lastTime > 0) const SizedBox(width: 6),
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
      ),
    );
  }

  /// 删除会话：
  /// - 空对话人（已注销/脏数据）：彻底删除，本地聊天记录一并清除
  /// - 正常对话人：仅隐藏会话，聊天记录保留（重新收发消息后自动恢复）
  Future<void> _confirmDeleteConversation(
      int peerId, String chatId, bool purge) async {
    final ok = await AppDialog.confirm(
      context,
      title: '删除会话',
      message: purge
          ? '该对话已失效，删除后将同时清除本地聊天记录。\n确定删除吗？'
          : '删除后该会话将从列表隐藏，聊天记录仍保留。\n确定删除吗？',
      confirmText: '删除',
      danger: true,
    );
    if (ok != true || !mounted) return;
    await ChatStore.instance.deleteConversation(chatId, purgeMessages: purge);
    // 删除的是当前选中会话则清空右侧聊天区
    if (_selectedFriend?['user_id'] == peerId) {
      _chatSub?.cancel();
      setState(() {
        _selectedFriend = null;
        _messages = [];
      });
      ChatNotifier.instance.clearCurrentChat();
    }
    await _loadConversations();
  }

  /// 清空聊天记录：清本地 + 调后端清服务器缓存 + WS 多端同步
  Future<void> _confirmClearChat(int peerId, String chatId) async {
    final ok = await AppDialog.confirm(
      context,
      title: '清空聊天记录',
      message: '将同时清除本地和服务器缓存中的聊天记录（双方设备同步清空）。\n确定清空吗？',
      confirmText: '清空',
      danger: true,
    );
    if (ok != true || !mounted) return;
    try {
      await ApiClient.instance
          .clearChat(peerId: peerId)
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // 后端失败不阻塞本地清空
    }
    await ChatStore.instance.clearChatMessages(chatId);
    if (_selectedFriend?['user_id'] == peerId && mounted) {
      setState(() {
        _messages = [];
        _noMoreOlder = true;
      });
    }
    await _loadConversations();
  }

  Widget _buildFriendList(Brightness b) {
    // 搜索态：按昵称过滤联系人
    if (_keyword.isNotEmpty) {
      final kw = _keyword.toLowerCase();
      final filtered = _friends.where((f) {
        final n = f['nickname']?.toString() ?? '';
        return n.toLowerCase().contains(kw);
      }).toList();
      if (filtered.isEmpty) {
        return _searchEmpty(b, '没有找到相关好友');
      }
      return SilkyListView(
        children: [for (final friend in filtered) _buildFriendItem(b, friend)],
        scrollSpeed: 1.6,
        silkyScrollDuration: const Duration(milliseconds: 600),
        animationCurve: Curves.easeOutCubic,
      );
    }
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
    final groups = _friendGroups();
    // 为每个字母确保 GlobalKey
    for (final letter in groups.keys) {
      _groupKeys.putIfAbsent(letter, () => GlobalKey());
    }
    return Stack(
      children: [
        SilkyListView(
          children: [
            for (final entry in groups.entries) ...[
              Container(
                key: _groupKeys[entry.key],
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                alignment: Alignment.centerLeft,
                child: Text(
                  entry.key,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: textSecondaryColor(b),
                  ),
                ),
              ),
              for (final friend in entry.value) _buildFriendItem(b, friend),
            ],
          ],
          scrollSpeed: 1.6,
          silkyScrollDuration: const Duration(milliseconds: 600),
          animationCurve: Curves.easeOutCubic,
        ),
        // 右侧字母索引条（微信风格）
        Positioned(
          right: 4,
          top: 0,
          bottom: 0,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final letter in groups.keys)
                  InkWell(
                    onTap: () => _jumpToGroup(letter),
                    mouseCursor: SystemMouseCursors.click,
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      child: Text(
                        letter,
                        style: TextStyle(
                          fontSize: 10,
                          color: letter == '#'
                              ? textMutedColor(b)
                              : textSecondaryColor(b),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 好友按昵称首字母分组（A-Z + #），返回有序 Map
  Map<String, List<Map<String, dynamic>>> _friendGroups() {
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final f in _friends) {
      var letter = (f['initial']?.toString() ?? '').toUpperCase();
      if (letter.isEmpty || !RegExp(r'^[A-Z]$').hasMatch(letter)) {
        letter = '#';
      }
      groups.putIfAbsent(letter, () => []).add(f);
    }
    final keys = groups.keys.toList()..sort((a, b) {
      if (a == '#') return 1;
      if (b == '#') return -1;
      return a.compareTo(b);
    });
    return {for (final k in keys) k: groups[k]!};
  }

  /// 字母索引条点击 → 滚动到对应分组
  void _jumpToGroup(String letter) {
    final ctx = _groupKeys[letter]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      alignment: 0,
    );
  }

  Widget _buildFriendItem(Brightness b, Map<String, dynamic> friend) {
    final selected = _selectedFriend?['user_id'] ==
        (friend['user_id'] as num?)?.toInt();
    final avatar = friend['avatar']?.toString() ?? '';
    final nickname = friend['nickname']?.toString() ?? '';
    // 有备注时显示备注名（微信风格）
    final remark = friend['remark']?.toString() ?? '';
    final displayName = remark.isNotEmpty ? remark : nickname;
    return InkWell(
      onTap: () => _selectFriend(friend),
      hoverColor: bgHoverColor(b),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? primarySoftColor(b) : Colors.transparent,
          borderRadius: BorderRadius.circular(kRadiusBtn),
        ),
        child: Row(
          children: [
            // 头像 + 右下角在线圆点（QQ 逻辑）
            _avatarWithStatus(
              b: b,
              avatar: avatar,
              nickname: nickname,
              size: 40,
              online: (friend['online'] ?? false) == true,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                displayName,
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

  Widget _avatarPlaceholder(Brightness b, String nickname,
      {double size = 40}) {
    final text = nickname.trim();
    final initial =
        text.isEmpty ? '?' : (text.length <= 2 ? text : text.substring(0, 2));
    return Container(
      width: size,
      height: size,
      decoration:
          BoxDecoration(color: primarySoftColor(b), shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
            fontSize: size >= 40 ? 15 : 12,
            fontWeight: FontWeight.w600,
            color: kPrimary),
      ),
    );
  }

  /// 头像 + 右下角在线状态圆点（QQ 逻辑：圆点覆盖头像右下角一部分，
  /// 带描边更清晰）。绿=在线，灰=离线。
  Widget _avatarWithStatus({
    required Brightness b,
    required String avatar,
    required String nickname,
    required double size,
    required bool online,
  }) {
    final dotSize = size >= 40 ? 11.0 : 9.0;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // 头像磁盘缓存（好友不换头像不重复加载）
        avatar.isNotEmpty
            ? CachedAvatar(
                url: avatar,
                size: size,
                fallbackText: nickname,
              )
            : _avatarPlaceholder(b, nickname, size: size),
        // 右下角在线圆点（QQ 风格，覆盖头像边缘一部分）
        Positioned(
          right: -1,
          bottom: -1,
          child: Container(
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: online ? kSuccess : textFaintColor(b),
              // 描边与所在面板背景一致，视觉上"切"进头像
              border: Border.all(color: bgColor(b), width: 1.5),
            ),
          ),
        ),
      ],
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
              // 头像 + 右下角在线圆点（QQ 逻辑，圆点覆盖头像一角）
              _avatarWithStatus(
                b: b,
                avatar: avatar,
                nickname: nickname,
                size: 32,
                online: _peerOnline,
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    nickname,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: textColor(b),
                    ),
                  ),
                  // 对方正在输入…
                  if (_peerTyping)
                    Text(
                      '正在输入…',
                      style: TextStyle(
                          fontSize: 11, color: kPrimary),
                    ),
                ],
              ),
              const Spacer(),
              // 右上角省略号：右侧弹出层（进主页/清空/查找记录/取消好友/拉黑）
              Tooltip(
                message: '更多',
                child: InkWell(
                  onTap: _showChatMenu,
                  mouseCursor: SystemMouseCursors.click,
                  borderRadius: BorderRadius.circular(kRadiusFull),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(Icons.more_horiz_rounded,
                        size: 20, color: textSecondaryColor(b)),
                  ),
                ),
              ),
            ],
          ),
        ),
        // 消息区
        Expanded(
          child: _buildMessageList(b),
        ),
        // 底部：多选模式显示多选工具栏，否则显示输入区
        if (_multiSelect)
          _buildMultiSelectBar(b)
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            color: bgColor(b),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 引用条（右键「回复」后显示，发送/取消后消失）
                if (_quoteTarget != null) _buildQuoteInputBar(b),
                // 输入框行：占满宽度，右上角叠放大/缩小按钮（Stack）
                Stack(
                  children: [
                    // 多行输入框：视觉高度 4 行（放大 10 行），超行内部滚动；
                    // 右侧留出放大按钮空间，避免文字被遮挡
                    Container(
                      decoration: BoxDecoration(
                        // 输入框背景与左侧导航栏一致（bgSoftColor）
                        color: bgSoftColor(b),
                        borderRadius: BorderRadius.circular(kRadiusMd),
                        border: Border.all(
                          color: b == Brightness.dark
                              ? const Color(0x33FFFFFF)
                              : const Color(0x22000000),
                        ),
                      ),
                      child: Focus(
                        onKeyEvent: _handleInputKeyEvent,
                        child: TextInputBubbleMenu(
                          controller: _inputCtrl,
                          onPasteImage: () => _pasteClipboardImage(),
                          child: TextField(
                            controller: _inputCtrl,
                            focusNode: _inputFocus,
                            onChanged: _onInputChanged,
                            onSubmitted: (_) => _sendMessage(),
                            // 禁用系统右键菜单（统一用气泡方案）
                            contextMenuBuilder: (_, __) =>
                                const SizedBox.shrink(),
                            // 过滤粘贴/输入的非法 UTF-16 代理项（防渲染崩溃）
                            inputFormatters: const [
                              Utf16SanitizeTextInputFormatter()
                            ],
                            minLines: _inputExpanded ? 10 : 4,
                            maxLines: _inputExpanded ? 10 : 4,
                            keyboardType: TextInputType.multiline,
                            scrollPhysics: const ClampingScrollPhysics(),
                            style:
                                TextStyle(fontSize: 14, color: textColor(b)),
                            decoration: InputDecoration(
                              hintText: '发送消息…',
                              hintStyle: TextStyle(
                                  fontSize: 14, color: textFaintColor(b)),
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.fromLTRB(
                                  12, 10, 40, 10),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 右上角：放大/缩小按钮（叠加在输入框顶层）
                    // 默认显示贴合右上角弧边的弧线符号，鼠标悬停切换成放大/缩小图标
                    Positioned(
                      top: 2,
                      right: 2,
                      child: _InputResizeButton(
                        expanded: _inputExpanded,
                        onTap: _toggleInputExpanded,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // 工具栏行：左侧表情/图片按钮，右侧发送按钮
                Row(
                  children: [
                    // 左侧：表情（BubbleMenu 气泡）+ 图片
                    BubbleMenu(
                      key: _emojiMenuKey,
                      width: 360,
                      // 面板高度需容纳表情面板实际高度（透明模式 ~229px）
                      // + 气泡三角/内边距占位（~19px），避免内容底部溢出
                      panelHeight: 250,
                      // 表情面板：emoji 插入 + 表情包直发；
                      // transparent：去掉自身背景，气泡背景唯一（防双重背景）
                      content: StickerPanel(
                        onEmoji: _insertEmoji,
                        onSticker: (s) => _sendSticker(s),
                        transparent: true,
                      ),
                      onOpenChange: _setEmojiPanelOpen,
                      child: _inputToolButton(
                        icon: Icons.emoji_emotions_outlined,
                        tooltip: '表情',
                        highlight: _emojiPanelOpen,
                      ),
                    ),
                    const SizedBox(width: 2),
                    _inputToolButton(
                      icon: Icons.image_rounded,
                      tooltip: '发送图片',
                      onTap: _sending ? null : _pickImageAndSend,
                    ),
                    const Spacer(),
                    // 右侧：发送按钮
                    _buildSendButton(b),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 输入框内工具小按钮（图片/表情/放大缩小）
  Widget _inputToolButton({
    required IconData icon,
    String? tooltip,
    VoidCallback? onTap,
    bool highlight = false,
    // 图标透明度（放大/缩小按钮用一半透明弱化视觉，不抢输入框焦点）
    double iconOpacity = 1,
  }) {
    final b = Theme.of(context).brightness;
    final baseColor = highlight ? kPrimary : textSecondaryColor(b);
    final btn = InkWell(
      onTap: onTap,
      mouseCursor: SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(kRadiusSm),
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: highlight
              ? kPrimary.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(kRadiusSm),
        ),
        child: Icon(
          icon,
          size: 17,
          color: baseColor.withValues(alpha: iconOpacity),
        ),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip, child: btn);
  }

  /// 发送按钮（内嵌输入框右下角）：发送中显示 loading
  Widget _buildSendButton(Brightness b) {
    return InkWell(
      onTap: _sending ? null : _sendMessage,
      mouseCursor: SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(kRadiusBtn),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: kPrimary,
          borderRadius: BorderRadius.circular(kRadiusBtn),
        ),
        child: _sending
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.send_rounded, size: 14, color: Colors.white),
                  const SizedBox(width: 4),
                  Text(
                    '发送',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  /// 输入区引用条：显示「回复 昵称: 预览」+ 取消按钮
  Widget _buildQuoteInputBar(Brightness b) {
    final q = _quoteTarget;
    if (q == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        color: bgHoverColor(b),
        borderRadius: BorderRadius.circular(kRadiusMd),
      ),
      child: Row(
        children: [
          Icon(Icons.format_quote_rounded, size: 15, color: kPrimary),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '回复 ${_quoteNickname(q)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12,
                      // fontWeight: FontWeight.w600,
                      color: kPrimary),
                ),
                Text(
                  _quotePreview(q),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: textMutedColor(b)),
                ),
              ],
            ),
          ),
          InkWell(
            onTap: _cancelQuote,
            mouseCursor: SystemMouseCursors.click,
            borderRadius: BorderRadius.circular(kRadiusFull),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.close_rounded,
                  size: 15, color: textFaintColor(b)),
            ),
          ),
        ],
      ),
    );
  }

  /// 多选模式底部工具栏：已选数量 + 全选/删除/取消
  Widget _buildMultiSelectBar(Brightness b) {
    final n = _selectedMsgIds.length;
    final allSelected = _messages.isNotEmpty && n == _messages.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: bgColor(b),
      child: Row(
        children: [
          Text('已选 $n 项',
              style:
                  TextStyle(fontSize: 13, color: textSecondaryColor(b))),
          const Spacer(),
          _multiSelectAction(b, allSelected ? '取消全选' : '全选',
              () => _selectAllMessages()),
          const SizedBox(width: 6),
          _multiSelectAction(b, '删除', n > 0 ? _deleteSelectedMessages : null,
              danger: true),
          const SizedBox(width: 6),
          _multiSelectAction(b, '取消', _exitMultiSelect),
        ],
      ),
    );
  }

  Widget _multiSelectAction(Brightness b, String label, VoidCallback? onTap,
      {bool danger = false}) {
    return InkWell(
      onTap: onTap,
      mouseCursor: SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(kRadiusBtn),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: onTap == null
              ? bgHoverColor(b).withValues(alpha: 0.4)
              : bgHoverColor(b),
          borderRadius: BorderRadius.circular(kRadiusBtn),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: onTap == null
                ? textFaintColor(b)
                : (danger ? kDanger : textColor(b)),
          ),
        ),
      ),
    );
  }

  /// 多选模式：气泡前加复选框；非多选原样返回
  Widget _maybeSelectWrap(Brightness b, Widget bubble, Map<String, dynamic> m) {
    if (!_multiSelect) return bubble;
    final localId = (m['id'] as num?)?.toInt() ?? 0;
    final selected = _selectedMsgIds.contains(localId);
    return Row(
      children: [
        _selectCheckbox(b, selected),
        const SizedBox(width: 8),
        Expanded(
          child: InkWell(
            onTap: () => _toggleSelect(localId),
            child: bubble,
          ),
        ),
      ],
    );
  }

  Widget _selectCheckbox(Brightness b, bool selected) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? kPrimary : Colors.transparent,
          border: Border.all(
            color: selected
                ? kPrimary
                : textFaintColor(b).withValues(alpha: 0.7),
            width: 1.5,
          ),
        ),
        child: selected
            ? const Icon(Icons.check_rounded, size: 13, color: Colors.white)
            : null,
      ),
    );
  }

  /// 消息列表（气泡）
  Widget _buildMessageList(Brightness b) {
    if (_messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 无奈表情 + 一半透明度（表情弱化不抢注意力）
            Icon(
              Icons.sentiment_dissatisfied_rounded,
              size: 40,
              color: textMutedColor(b).withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              '你们之间的互动空空如也~',
              style: TextStyle(fontSize: 14, color: textMutedColor(b)),
            ),
          ],
        ),
      );
    }
    // 时间分组：相邻消息间隔 >=5 分钟或跨天 → 插入时间标签（微信同款）
    // 加载指示器统一在循环后 insert 到列表顶部（更早历史方向），避免重复添加
    final children = <Widget>[];
    DateTime? prevMsgTime;
    // 气泡连续分组预计算：与「前一条」连续 → 不是组头；
    // 与「后一条」连续 → 不是组尾。
    final groupHeads = List<bool>.filled(_messages.length, true);
    final groupTails = List<bool>.filled(_messages.length, true);
    // 时间标签强制断组：两条消息之间若会插入时间标签（间隔>=5分钟/跨天），
    // 即使 _canGroupMessages 因时间字段异常判成连续，也强制断开并重出头像。
    final timeBreak = List<bool>.filled(_messages.length, false); // i 与 i+1 之间断
    for (var i = 0; i < _messages.length; i++) {
      final t = (_messages[i]['create_time'] as num?)?.toInt() ?? 0;
      if (t > 0) {
        final dt = DateTime.fromMillisecondsSinceEpoch(t * 1000);
        final label = _timeGroupLabel(dt, prevMsgTime);
        if (label != null && prevMsgTime != null && i > 0) {
          timeBreak[i - 1] = true; // 当前消息前插了时间标签 → i-1 与 i 之间断
        }
        prevMsgTime = dt;
      }
    }
    for (var i = 0; i < _messages.length; i++) {
      if (i > 0 &&
          !timeBreak[i - 1] &&
          _canGroupMessages(_messages[i - 1], _messages[i])) {
        groupHeads[i] = false; // 与前一条同组 → 不是组头
      }
      if (i < _messages.length - 1 &&
          !timeBreak[i] &&
          _canGroupMessages(_messages[i], _messages[i + 1])) {
        groupTails[i] = false; // 与后一条同组 → 不是组尾
      }
    }
    for (var i = 0; i < _messages.length; i++) {
      final m = _messages[i];
      final t = (m['create_time'] as num?)?.toInt() ?? 0;
      if (t > 0) {
        final dt = DateTime.fromMillisecondsSinceEpoch(t * 1000);
        final label = _timeGroupLabel(dt, prevMsgTime);
        if (label != null) {
          children.add(Center(
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 6),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: bgHoverColor(b).withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(kRadiusFull),
              ),
              child: Text(
                label,
                style: TextStyle(fontSize: 11, color: textMutedColor(b)),
              ),
            ),
          ));
        }
        prevMsgTime = dt;
      }
      children.add(_buildMessageBubble(
        b,
        m,
        groupHead: groupHeads[i],
        groupTail: groupTails[i],
      ));
    }
    // 加载指示放列表顶部（正向列表顶部 = 更早历史）
    if (_loadingOlder) {
      children.insert(0, const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ));
    }
    // 正向列表 + SilkyListView：与全站其他列表一致的 silky 平滑惯性滚动，
    // 滚轮方向天然正确；打开会话由 _scrollToBottom 定位到底部（最新消息）
    return SilkyListView(
      controller: _msgScrollCtrl,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: children,
      scrollSpeed: 1.6,
      silkyScrollDuration: const Duration(milliseconds: 600),
      animationCurve: Curves.easeOutCubic,
    );
  }

  /// 两条相邻消息能否合并成连续气泡（微信风格）：
  /// 同一发送者、均为纯文本（msg_type=1）、都未撤回、都无引用块、
  /// 时间差 <5 分钟且同一天。[prev] 时间更早、[cur] 时间更新。
  bool _canGroupMessages(Map<String, dynamic> prev, Map<String, dynamic> cur) {
    final pSender = (prev['sender_id'] as num?)?.toInt() ?? 0;
    final cSender = (cur['sender_id'] as num?)?.toInt() ?? 0;
    if (pSender <= 0 || pSender != cSender) return false;
    final pType = (prev['msg_type'] as num?)?.toInt() ?? 1;
    final cType = (cur['msg_type'] as num?)?.toInt() ?? 1;
    if (pType != 1 || cType != 1) return false; // 仅纯文本可合并
    if (((prev['recalled'] as num?)?.toInt() ?? 0) != 0) return false;
    if (((cur['recalled'] as num?)?.toInt() ?? 0) != 0) return false;
    // 引用消息（body 为 JSON）不参与合并
    if (_parseBody(prev['plaintext']?.toString() ?? '').$1 != null) {
      return false;
    }
    if (_parseBody(cur['plaintext']?.toString() ?? '').$1 != null) {
      return false;
    }
    final pT = (prev['create_time'] as num?)?.toInt() ?? 0;
    final cT = (cur['create_time'] as num?)?.toInt() ?? 0;
    if (pT <= 0 || cT <= 0) return false;
    final pd = DateTime.fromMillisecondsSinceEpoch(pT * 1000);
    final cd = DateTime.fromMillisecondsSinceEpoch(cT * 1000);
    final crossDay = !(pd.year == cd.year && pd.month == cd.month && pd.day == cd.day);
    if (crossDay) return false;
    return cd.difference(pd).inMinutes < 5;
  }

  /// 时间分组标签：与上一条间隔 >=5 分钟或跨天返回标签文案，否则 null（不显示）
  String? _timeGroupLabel(DateTime cur, DateTime? prev) {
    if (prev != null) {
      // prev 是列表中更早的一条（DESC 顺序）：取绝对间隔
      final diff = cur.difference(prev).abs();
      final crossDay =
          !(cur.year == prev.year && cur.month == prev.month && cur.day == prev.day);
      if (diff.inMinutes < 5 && !crossDay) return null;
    }
    return _fmtGroupTime(cur);
  }

  /// 时间标签格式：今天 HH:mm / 昨天 HH:mm / M月d日 HH:mm / yyyy年M月d日 HH:mm
  String _fmtGroupTime(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(t.year, t.month, t.day);
    final days = today.difference(that).inDays;
    final hm = '${t.hour.toString().padLeft(2, '0')}'
        ':${t.minute.toString().padLeft(2, '0')}';
    if (days == 0) return hm;
    if (days == 1) return '昨天 $hm';
    if (t.year == now.year) return '${t.month}月${t.day}日 $hm';
    return '${t.year}年${t.month}月${t.day}日 $hm';
  }

  Widget _buildMessageBubble(
    Brightness b,
    Map<String, dynamic> m, {
    // 气泡连续分组标记：组内第一条（最顶）/ 最后一条（最底）。
    // 组内成员之间不显示头像、圆角互相贴合、间距收紧（微信风格）
    bool groupHead = true,
    bool groupTail = true,
  }) {
    final senderId = (m['sender_id'] as num?)?.toInt() ?? 0;
    final isMine = senderId == widget.currentUserId;
    // 渲染兜底：清洗历史遗留/异常的非法 UTF-16 代理项（防 TextSpan 崩溃）
    final plaintext = sanitizeUtf16(m['plaintext']?.toString() ?? '');
    final msgType = (m['msg_type'] as num?)?.toInt() ?? 1;
    final createTime = (m['create_time'] as num?)?.toInt() ?? 0;
    final sendStatus = (m['send_status'] as num?)?.toInt() ?? 1;
    final recalled = (m['recalled'] as num?)?.toInt() ?? 0;
    // 服务器消息 id（引用/撤回/跳转用）
    final msgId = (m['msg_id'] as num?)?.toInt() ?? 0;

    // 已撤回：居中灰字占位（微信/QQ 风格）；多选模式下仍可勾选
    if (recalled == 1) {
      Widget w = Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Text(
            isMine ? '你撤回了一条消息' : '对方撤回了一条消息',
            style: TextStyle(fontSize: 12, color: textFaintColor(b)),
          ),
        ),
      );
      if (_multiSelect) {
        w = _maybeSelectWrap(b, w, m);
      }
      return _withBubbleKey(msgId, w);
    }

    final bubbleColor = isMine ? kPrimary : bgHoverColor(b);
    final textColorB = isMine ? Colors.white : textColor(b);
    // 撤回时限以服务器时间为准（本地时钟与服务器有偏差时判定一致）
    final serverNow =
        DateTime.now().millisecondsSinceEpoch ~/ 1000 + ChatService.serverTimeOffsetSec;
    final canRecall = isMine && msgId > 0 && (serverNow - createTime) <= 300;

    // 引用消息：解析 body 取 (引用信息, 实际文本)
    final (quote, text) = _parseBody(plaintext);

    // 气泡连续：垂直间距收紧（组头/组尾正常 4px，组内 1px）
    final topPad = groupHead ? 4.0 : 1.0;
    final bottomPad = groupTail ? 4.0 : 1.0;
    // 圆角：每条气泡独立完整圆角（用户要求不贴合）
    final bigR = kRadiusMd;

    Widget bubble = Padding(
      padding: EdgeInsets.only(top: topPad, bottom: bottomPad),
      child: Row(
        mainAxisAlignment:
            isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 对方头像侧：组头显示真实头像，非组头用同宽透明占位
          // （保证连续气泡左侧对齐不占用头像区，需求 4）
          if (!isMine) ...[
            groupHead
                ? ClipOval(child: _peerAvatar(b))
                : const SizedBox(width: 32),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isMine
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                // 图片消息（msg_type=2）：body 为加密的 {"url":...}
                if (msgType == 2)
                  _buildImageBubble(b, m)
                else if (msgType == 3)
                  // 表情消息：body 为加密的 {"url","w","h"}
                  _buildStickerBubble(b, m)
                else
                  Container(
                    constraints: const BoxConstraints(maxWidth: 420),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: bubbleColor,
                      borderRadius: BorderRadius.circular(bigR),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 引用块（回复某条消息）
                        if (quote != null)
                          _buildQuoteBar(b, quote, isMine),
                        Text(
                          text,
                          style: TextStyle(
                              fontSize: 14, color: textColorB, height: 1.4),
                        ),
                      ],
                    ),
                  ),
                // 气泡下方：无时间；发送中/失败/已读未读状态（微信同款）。
                // 连续气泡仅组尾显示状态，避免每行重复"已读/未读"
                if (isMine && groupTail) ...[
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (sendStatus == 0)
                        Icon(Icons.schedule, size: 12, color: textFaintColor(b))
                      else if (sendStatus == 2)
                        // 失败消息可点击重发（多选模式下仅勾选，不触发重发）
                        InkWell(
                          onTap:
                              _multiSelect ? null : () => _retryMessage(m),
                          mouseCursor: SystemMouseCursors.click,
                          borderRadius: BorderRadius.circular(4),
                          child: Tooltip(
                            message: '发送失败，点击重发',
                            child: Icon(Icons.error_outline,
                                size: 12, color: kDanger),
                          ),
                        )
                      else
                        Text(
                          (m['read_status'] as num?)?.toInt() == 1
                              ? '已读'
                              : '未读',
                          style: TextStyle(
                              fontSize: 11, color: textFaintColor(b)),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          // 自己头像侧：组头显示真实头像，非组头用同宽透明占位
          // （保证连续气泡右侧对齐不占用头像区，需求 4）
          if (isMine) ...[
            const SizedBox(width: 8),
            groupHead
                ? ClipOval(child: _myAvatar(b))
                : const SizedBox(width: 32),
          ],
        ],
      ),
    );

    // 多选模式：气泡前加复选框，点击勾选；不弹出右键菜单
    if (_multiSelect) {
      bubble = _maybeSelectWrap(b, bubble, m);
      return _withBubbleKey(msgId, bubble);
    }

    // 右键菜单：复制 / 回复 / 多选 / 撤回（可撤回时）
    final items = <BubbleMenuItem>[
      BubbleMenuItem(
        label: '复制',
        icon: Icons.copy_rounded,
        onTap: () {
          // 引用消息复制实际文本（不复制加密 JSON 结构）
          Clipboard.setData(ClipboardData(text: text));
          if (mounted) NotifyStack.success('已复制', title: '提示');
        },
      ),
      if (msgId > 0)
        BubbleMenuItem(
          label: '回复',
          icon: Icons.reply_rounded,
          onTap: () => _startQuote(m),
        ),
      // 表情消息右键：添加到自己的表情包（收藏）。
      // 自己发的表情（自己表情包里的）无需收藏，不显示该项
      if (msgType == 3 && !isMine) ...[
        BubbleMenuItem(
          label: '添加到表情',
          icon: Icons.add_box_outlined,
          onTap: () => _addStickerFromMessage(ChatImageCache.parseUrl(plaintext)),
        ),
      ],
      // 图片消息右键：另存为（表情消息不支持另存为）
      if (msgType == 2)
        BubbleMenuItem(
          label: '另存为',
          icon: Icons.save_alt_rounded,
          onTap: () => _saveImageAs(m),
        ),
      BubbleMenuItem(
        label: '多选',
        icon: Icons.check_box_outlined,
        onTap: () {
          setState(() {
            _multiSelect = true;
            _selectedMsgIds.clear();
          });
        },
      ),
    ];
    if (canRecall) {
      items.add(BubbleMenuItem(
        label: '撤回',
        icon: Icons.undo_rounded,
        onTap: () => _recallMessage(m),
      ));
    }
    bubble = BubbleMenu(
      triggerOnRightClick: true,
      // 宽度按最长菜单项文字自适应（"添加到表情"等较长项完整显示）
      items: items,
      child: bubble,
    );
    return _withBubbleKey(msgId, bubble);
  }

  /// 给气泡挂 GlobalKey（引用点击跳转定位用）
  Widget _withBubbleKey(int msgId, Widget w) {
    if (msgId <= 0) return w;
    final key = _bubbleKeys.putIfAbsent(msgId, () => GlobalKey());
    return KeyedSubtree(key: key, child: w);
  }

  /// 气泡内引用块：左侧强调条 + 昵称 + 预览，点击跳转到被引用消息
  Widget _buildQuoteBar(
      Brightness b, Map<String, dynamic> q, bool isMine) {
    final nickname = q['nickname']?.toString() ?? '';
    final preview = q['preview']?.toString() ?? '';
    final quoteId = (q['id'] as num?)?.toInt() ?? 0;
    final nameColor = isMine ? Colors.white70 : kPrimary;
    return InkWell(
      onTap: quoteId > 0 ? () => _jumpToMessage(quoteId) : null,
      mouseCursor: SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(kRadiusSm),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 5, 10, 5),
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: (isMine ? Colors.white : bgColor(b))
              .withValues(alpha: isMine ? 0.18 : 0.55),
          borderRadius: BorderRadius.circular(kRadiusSm),
        ),
        // 引用块按内容自适应宽度（预览文本最宽 280，超出省略），
        // 气泡整体由「引用块 / 正文」较宽者决定，不强制撑满最大宽度
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 3,
              height: 28,
              decoration: BoxDecoration(
                color: nameColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    nickname,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: nameColor),
                  ),
                  Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: isMine ? Colors.white60 : textMutedColor(b),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 表情消息气泡：透明底直接透出表情图片（无气泡包裹/圆角，微信式），
  /// 不可点击放大（多选/右键菜单另处理）
  Widget _buildStickerBubble(Brightness b, Map<String, dynamic> m) {
    final body = m['plaintext']?.toString() ?? '';
    final url = ChatImageCache.parseUrl(body);
    if (url.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bgHoverColor(b),
          borderRadius: BorderRadius.circular(kRadiusMd),
        ),
        child: Text('[表情]',
            style: TextStyle(fontSize: 14, color: textColor(b))),
      );
    }
    // 尺寸：body 内含原始宽高，等比缩放，最长边不超过 120（微信式）
    var rawW = 240;
    var rawH = 240;
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        rawW = (j['w'] as num?)?.toInt() ?? rawW;
        rawH = (j['h'] as num?)?.toInt() ?? rawH;
      }
    } catch (_) {}
    final maxSide = 120.0;
    final scale = maxSide / (rawW > rawH ? rawW : rawH);
    final dispW = (rawW * scale).clamp(40.0, maxSide);
    final dispH = (rawH * scale).clamp(40.0, maxSide);
    // 无气泡/圆角包裹：直接显示表情，点击不放大（添加表情走右键菜单）
    return NetImage(
      url: url,
      width: dispW,
      height: dispH,
      fit: BoxFit.contain,
      bgColor: Colors.transparent,
      loadingSize: 20,
    );
  }

  /// 图片消息气泡：优先读本地缓存文件，无缓存才回退云端 URL
  Widget _buildImageBubble(Brightness b, Map<String, dynamic> m) {
    final body = m['plaintext']?.toString() ?? '';
    final localPath = m['image_local_path']?.toString() ?? '';
    final url = ChatImageCache.parseUrl(body);
    if (url.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bgHoverColor(b),
          borderRadius: BorderRadius.circular(kRadiusMd),
        ),
        child: Text('[图片]',
            style: TextStyle(fontSize: 14, color: textColor(b))),
      );
    }
    final hasLocal = localPath.isNotEmpty && File(localPath).existsSync();
    // 图片气泡固定 260x260，加载前后布局高度不变，无需 frameBuilder 二次定位
    final child = hasLocal
        ? Image.file(
            File(localPath),
            width: 260,
            height: 260,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, __, ___) => NetImage(
              url: AppConfig.resolveUrl(url),
              width: 260,
              height: 260,
              fit: BoxFit.cover,
              loadingSize: 24,
            ),
          )
        : NetImage(
            url: AppConfig.resolveUrl(url),
            width: 260,
            height: 260,
            fit: BoxFit.cover,
            loadingSize: 24,
          );
    return Container(
      constraints: const BoxConstraints(maxWidth: 260, maxHeight: 260),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: bgHoverColor(b),
        borderRadius: BorderRadius.circular(kRadiusMd),
      ),
      child: InkWell(
        onTap: _multiSelect ? null : () => _previewImage(m),
        mouseCursor: SystemMouseCursors.click,
        child: child,
      ),
    );
  }

  /// 图片大图预览（对话框全屏展示，优先本地缓存文件）。
  /// 支持左右切换当前聊天记录里的所有图片；底部工具栏：另存为 + 定位到聊天记录。
  void _previewImage(Map<String, dynamic> m) {
    final body = m['plaintext']?.toString() ?? '';
    final url = ChatImageCache.parseUrl(body);
    if (url.isEmpty) return;
    // 收集当前聊天记录里所有图片消息（msg_type==2），用于左右切换
    final allImages = _messages
        .where((e) => ((e['msg_type'] as num?)?.toInt() ?? 0) == 2)
        .toList();
    var curIdx = allImages.indexWhere((e) => identical(e, m) || e == m);
    if (curIdx < 0) curIdx = 0;
    if (allImages.isEmpty) {
      // 兜底：仅预览当前这一张
      allImages.add(m);
      curIdx = 0;
    }
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final cur = allImages[curIdx];
          final curBody = cur['plaintext']?.toString() ?? '';
          final curLocalPath = cur['image_local_path']?.toString() ?? '';
          final curUrl = ChatImageCache.parseUrl(curBody);
          final hasLocal =
              curLocalPath.isNotEmpty && File(curLocalPath).existsSync();
          final curMsgId = (cur['msg_id'] as num?)?.toInt() ?? 0;

          /// 左右切换图片；首/尾时提示「没有图片了」
          void step(int delta) {
            final next = curIdx + delta;
            if (next < 0 || next >= allImages.length) {
              NotifyStack.warning('没有图片了', title: '提示');
              return;
            }
            setDialogState(() => curIdx = next);
          }

          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.all(24),
            child: Stack(
              children: [
                Positioned.fill(
                  child: InkWell(
                    onTap: () => Navigator.of(ctx).pop(),
                    child: InteractiveViewer(
                      maxScale: 4,
                      child: hasLocal
                          ? Image.file(
                              File(curLocalPath),
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.medium,
                              errorBuilder: (_, __, ___) => NetImage(
                                url: AppConfig.resolveUrl(curUrl),
                                fit: BoxFit.contain,
                                loadingSize: 32,
                              ),
                            )
                          : NetImage(
                              url: AppConfig.resolveUrl(curUrl),
                              fit: BoxFit.contain,
                              loadingSize: 32,
                            ),
                    ),
                  ),
                ),
                // 左上角：图片序号（当前 / 共 N 张）
                Positioned(
                  top: 0,
                  left: 0,
                  child: Container(
                    margin: const EdgeInsets.all(8),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(kRadiusFull),
                    ),
                    child: Text(
                      '${curIdx + 1} / ${allImages.length}',
                      style: const TextStyle(fontSize: 12, color: Colors.white),
                    ),
                  ),
                ),
                // 左侧：上一张
                if (allImages.length > 1)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 72,
                    child: Center(
                      child: _previewNavButton(
                        icon: Icons.chevron_left_rounded,
                        onTap: () => step(-1),
                      ),
                    ),
                  ),
                // 右侧：下一张
                if (allImages.length > 1)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 72,
                    child: Center(
                      child: _previewNavButton(
                        icon: Icons.chevron_right_rounded,
                        onTap: () => step(1),
                      ),
                    ),
                  ),
                // 底部工具栏：另存为 + 定位到聊天记录
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(12)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _previewToolButton(
                          icon: Icons.save_alt_rounded,
                          label: '另存为',
                          onTap: () => _saveImageAs(cur),
                        ),
                        const SizedBox(width: 12),
                        _previewToolButton(
                          icon: Icons.comment_rounded,
                          label: '定位到聊天记录',
                          onTap: curMsgId <= 0
                              ? null
                              : () {
                                  Navigator.of(ctx).pop();
                                  _jumpToMessage(curMsgId);
                                },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 预览左右切换箭头按钮（半透明黑底圆形）
  Widget _previewNavButton(
      {required IconData icon, required VoidCallback onTap}) {
    return Material(
      color: Colors.black.withValues(alpha: 0.4),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        mouseCursor: SystemMouseCursors.click,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 26, color: Colors.white),
        ),
      ),
    );
  }

  /// 预览底部工具栏按钮（半透明黑底胶囊）
  Widget _previewToolButton(
      {required IconData icon,
      required String label,
      required VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      mouseCursor:
          onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(kRadiusFull),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(kRadiusFull),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15,
                color: onTap == null
                    ? Colors.white.withValues(alpha: 0.4)
                    : Colors.white),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: onTap == null
                    ? Colors.white.withValues(alpha: 0.4)
                    : Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 另存为图片消息：弹出系统保存对话框由用户选择保存位置（优先本地缓存文件拷贝，无缓存走网络）
  Future<void> _saveImageAs(Map<String, dynamic> m) async {
    final body = m['plaintext']?.toString() ?? '';
    final localPath = m['image_local_path']?.toString() ?? '';
    final url = ChatImageCache.parseUrl(body);
    if (url.isEmpty) {
      if (mounted) NotifyStack.warning('图片地址无效', title: '提示');
      return;
    }
    final saved = await saveImageAs(
      AppConfig.resolveUrl(url),
      localPath: localPath,
    );
    if (!mounted) return;
    if (saved != null) {
      NotifyStack.success('已保存到：$saved', title: '另存为成功');
    }
    // 用户取消（null）不提示；失败也 null，静默即可
  }

  /// 撤回消息（5 分钟时限，调后端后本地标记撤回）
  Future<void> _recallMessage(Map<String, dynamic> m) async {
    final friend = _selectedFriend;
    final peerId = (friend?['user_id'] as num?)?.toInt() ?? 0;
    final msgId = (m['msg_id'] as num?)?.toInt() ?? 0;
    if (peerId <= 0 || msgId <= 0) {
      NotifyStack.warning('该消息无法撤回', title: '提示');
      return;
    }
    try {
      final resp = await ApiClient.instance
          .recallChatMessage(peerId: peerId, msgId: msgId)
          .timeout(const Duration(seconds: 8));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] != 0) {
        NotifyStack.warning(json['msg']?.toString() ?? '撤回失败', title: '提示');
        return;
      }
      await ChatStore.instance.markRecalled(msgId);
      if (mounted) await _loadLocalMessages();
    } catch (_) {
      if (mounted) NotifyStack.warning('网络异常，撤回失败', title: '提示');
    }
  }

  /// 当前用户自己的头像（连续气泡组头显示，右侧；磁盘缓存）
  Widget _myAvatar(Brightness b) {
    final avatar = widget.currentUserAvatar.trim();
    return avatar.isNotEmpty
        ? CachedAvatar(url: avatar, size: 32, fallbackText: '我')
        : Container(
            width: 32,
            height: 32,
            decoration:
                BoxDecoration(color: kPrimary, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: const Text('我',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.white)),
          );
  }

  Widget _peerAvatar(Brightness b) {
    final friend = _selectedFriend;
    final avatar = friend?['avatar']?.toString() ?? '';
    final nickname = friend?['nickname']?.toString() ?? '';
    return avatar.trim().isNotEmpty
        ? CachedAvatar(url: avatar, size: 32, fallbackText: nickname)
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

/// 输入框右上角放大/缩小按钮（微信式）：
/// - 默认：贴合右上角弧边的弧线符号（弧度与输入框圆角一致，弱化不抢焦点）
/// - 鼠标悬停：切换成放大/缩小图标
class _InputResizeButton extends StatefulWidget {
  final bool expanded;
  final VoidCallback onTap;

  const _InputResizeButton({
    required this.expanded,
    required this.onTap,
  });

  @override
  State<_InputResizeButton> createState() => _InputResizeButtonState();
}

class _InputResizeButtonState extends State<_InputResizeButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final color = _hover
        ? kPrimary
        : textSecondaryColor(b).withValues(alpha: 0.45);
    return Tooltip(
      message: widget.expanded ? '缩小输入框' : '放大输入框',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: InkWell(
          onTap: widget.onTap,
          mouseCursor: SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(kRadiusSm),
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: _hover
                  ? kPrimary.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(kRadiusSm),
            ),
            child: _hover
                ? Icon(
                    widget.expanded
                        ? Icons.close_fullscreen_rounded
                        : Icons.open_in_full_rounded,
                    size: 15,
                    color: kPrimary,
                  )
                : CustomPaint(
                    size: const Size(26, 26),
                    painter: _CornerArcPainter(color: color),
                  ),
          ),
        ),
      ),
    );
  }
}

/// 右上角弧边符号：贴合输入框右上角圆弧（微信 PC 输入框同款）。
///
/// 画法：与输入框圆角**同心的平行短弧**——圆心位于角落内侧，
/// 弧线从「顶边附近」沿顺时针 90° 到「右边附近」，凸向右上角，
/// 弧度方向与输入框圆角完全一致（像输入框右上角被描了一圈小弧线）。
class _CornerArcPainter extends CustomPainter {
  final Color color;

  const _CornerArcPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;

    // 弧线半径与边距：圆心位于 (cx, cy)，弧从 O 正上方绕到 O 正右方
    final r = 8.0;
    final margin = 4.0;
    final cx = size.width - margin - r;
    final cy = margin + r;
    final start = Offset(cx, margin); // 顶边附近（O 正上方）
    final end = Offset(size.width - margin, cy); // 右边附近（O 正右方）

    final path = Path()
      ..moveTo(start.dx, start.dy)
      // clockwise=true：顺时针 90° 短弧，经右上角方向（凸向右上），
      // 与输入框圆角凸出方向一致（false 会绕大圈画成 270° 长弧）
      ..arcToPoint(
        end,
        radius: Radius.circular(r),
        clockwise: true,
      );
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CornerArcPainter old) =>
      old.color != color;
}
