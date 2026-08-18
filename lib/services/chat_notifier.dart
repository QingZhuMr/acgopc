import 'dart:collection';

import '../controllers/system_notifier.dart';
import '../widgets/notify.dart';
import 'chat_store.dart';

/// 聊天消息通知（单例）
///
/// 离线消息通知：收到对方发来的新聊天消息，且**当前没有正在查看该会话**时，
/// 弹应用内通知（NotifyStack）+ Windows 系统通知（Toast，窗口遮挡/托盘也可见），
/// 点击跳转到对应会话。离线期间断线 sync 拉取的消息同样触发（统一在
/// [ChatService] 解密入库时上报，见 `_storeIncoming`）。
///
/// 生命周期：登录成功后 `start()`（main.dart 注入跳转回调），退出登录 `stop()`。
/// 当前会话/活跃状态由消息页上报（`setCurrentChat` / `setPageActive`）。
class ChatNotifier {
  ChatNotifier._();

  static final ChatNotifier instance = ChatNotifier._();

  /// 跳转聊天会话回调（main.dart 注入：切到消息 tab 并打开该好友会话）
  void Function(int peerId)? onOpenChat;

  /// 当前正在查看的会话 peerId（消息页上报，0 = 未打开会话）
  int _currentPeerId = 0;

  /// 消息页当前是否活跃（IndexedStack 是否选中消息 tab）
  bool _pageActive = false;

  /// 是否已登录
  bool _active = false;

  /// 已通知消息去重（按 msg_id，保留最近 [maxNotified] 条防止无限增长）
  final Set<int> _notifiedMsgIds = LinkedHashSet<int>();
  static const int maxNotified = 500;

  /// 启动通知（登录成功后调用）
  void start({void Function(int peerId)? onOpenChat}) {
    this.onOpenChat = onOpenChat;
    _active = true;
  }

  /// 停止通知（退出登录时调用）
  void stop() {
    _active = false;
    onOpenChat = null;
    _currentPeerId = 0;
    _pageActive = false;
    _notifiedMsgIds.clear();
  }

  /// 消息页上报当前查看的会话（打开/切换会话时）
  void setCurrentChat(int peerId) => _currentPeerId = peerId;

  /// 消息页上报关闭会话（取消选中）
  void clearCurrentChat() => _currentPeerId = 0;

  /// 消息页上报活跃状态（IndexedStack 切换消息 tab）
  void setPageActive(bool active) => _pageActive = active;

  /// 处理新收到的消息（[ChatService._storeIncoming] 确认新插入后调用）
  ///
  /// 仅处理对方发来的消息（自己其他设备的推送不通知）；
  /// 正在查看该会话（消息页活跃 + 当前 peer 一致）时不通知。
  Future<void> handleNewMessage({
    required int msgId,
    required String chatId,
    required int peerId,
    required int msgType,
    required String plaintext,
  }) async {
    if (!_active) return;
    if (msgId <= 0 || peerId <= 0) return;
    // 去重：同一条消息（WS 推送 / 断线 sync 可能都触发）只通知一次
    if (_notifiedMsgIds.contains(msgId)) return;
    _notifiedMsgIds.add(msgId);
    if (_notifiedMsgIds.length > maxNotified) {
      final it = _notifiedMsgIds.iterator;
      if (it.moveNext()) _notifiedMsgIds.remove(it.current);
    }
    // 正在查看该会话 → 正常聊天，不通知
    if (_pageActive && _currentPeerId == peerId) return;

    // 会话昵称（找不到用通用文案兜底）
    var nickname = '新消息';
    try {
      final conv = await ChatStore.instance.getConversationByChatId(chatId);
      final n = conv?['peer_nickname']?.toString() ?? '';
      if (n.isNotEmpty) nickname = n;
    } catch (_) {}

    // 内容摘要（图片/表情/引用均取友好文案，不暴露加密 JSON）
    final preview = ChatStore.conversationPreview(
        {'msg_type': msgType, 'plaintext': plaintext});

    // 应用内通知（客户端前台常驻时可见）
    NotifyStack.notify(
      title: nickname,
      message: preview,
      onTap: () => _openChat(peerId),
      persistent: false,
    );

    // Windows 系统通知（窗口被遮挡/最小化/在托盘也能看到，点击跳会话）
    await SystemNotifier.instance.show(
      title: nickname,
      subtitle: '耶熊',
      body: preview,
      onClick: () => _openChat(peerId),
    );
  }

  void _openChat(int peerId) {
    final cb = onOpenChat;
    if (cb != null && peerId > 0) cb(peerId);
  }
}
