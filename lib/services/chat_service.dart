import 'dart:async';

import '../core/api_client.dart';
import 'chat_crypto.dart';
import 'chat_image_cache.dart';
import 'chat_notifier.dart';
import 'chat_store.dart';
import '../utils/text_sanitize.dart';

/// 聊天服务：密钥管理 + 消息收发（E2EE 加解密 + 本地存储）
class ChatService {
  ChatService._();
  static final ChatService instance = ChatService._();

  /// 当前用户 ID
  int _userId = 0;

  /// 服务器时间与本地时间偏移（秒），供撤回等时效判断使用：
  /// serverNow ≈ DateTime.now().millisecondsSinceEpoch ~/ 1000 + offset
  static int serverTimeOffsetSec = 0;

  /// 是否已初始化（密钥已就绪）
  bool _ready = false;

  bool get isReady => _ready;

  /// 初始化（登录后/进入消息页时调用）：确保本地密钥存在
  ///
  /// 本地无密钥时**先向服务器领取托管私钥**（保证能解密历史消息），
  /// 服务器无托管则本地生成新密钥并上传公钥。
  Future<void> init(int userId) async {
    _userId = userId;
    // 检查本地密钥
    var keyPair = await ChatStore.instance.getKeyPair(userId);
    if (keyPair == null) {
      // 1) 尝试领取服务器托管密钥（含公钥+私钥）
      try {
        final resp = await ApiClient.instance
            .getChatKey(claim: true)
            .timeout(const Duration(seconds: 10));
        final json = ApiClient.safeJsonDecode(resp.body);
        if (json['code'] == 0) {
          final data = (json['data'] ?? {}) as Map;
          final pub = data['public_key']?.toString() ?? '';
          final priv = data['private_key']?.toString() ?? '';
          if (pub.isNotEmpty && priv.isNotEmpty) {
            await ChatStore.instance.saveKeyPair(
              userId: userId,
              privateKey: priv,
              publicKey: pub,
            );
            keyPair = (privateKey: priv, publicKey: pub);
          }
        }
      } catch (_) {
        // 领取失败则本地生成
      }
    }
    if (keyPair == null) {
      // 2) 服务器无托管 → 本地生成新密钥对
      keyPair = ChatCrypto.generateKeyPair();
      await ChatStore.instance.saveKeyPair(
        userId: userId,
        privateKey: keyPair.privateKey,
        publicKey: keyPair.publicKey,
      );
      // 上传公钥（幂等，服务器唯一约束覆盖）
      try {
        await ApiClient.instance
            .postChatKey(keyPair.publicKey)
            .timeout(const Duration(seconds: 10));
      } catch (_) {}
    }
    _ready = true;
  }

  /// 获取本地私钥
  Future<String> _privateKey() async {
    final kp = await ChatStore.instance.getKeyPair(_userId);
    if (kp == null) {
      throw StateError('chat key not initialized');
    }
    return kp.privateKey;
  }

  /// 发送消息：加密 → 本地暂存 → 调接口 → 更新状态
  ///
  /// [forceClientMsgId]：重发时复用原 client_msg_id 保证幂等
  Future<({int msgId, bool ok, String error})> sendMessage({
    required int receiverId,
    required String plaintext,
    int msgType = 1,
    String imageLocalPath = '',
    String? peerPublicKey,
    String? forceClientMsgId,
  }) async {
    // 发送前清洗非法 UTF-16 代理项（防止坏文本入库/加密/对端渲染崩溃）
    plaintext = sanitizeUtf16(plaintext);
    final clientMsgId = forceClientMsgId ?? _genClientMsgId();
    final chatId = _chatId(_userId, receiverId);
    // 自环/空 chat_id：不合法接收者，直接返回失败
    if (chatId.isEmpty || _isSelfLoopChat(chatId)) {
      return (msgId: 0, ok: false, error: '接收者无效');
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // 需要对方公钥
    var pub = peerPublicKey;
    if (pub == null) {
      try {
        final keys = await ApiClient.instance
            .getChatKeys([receiverId])
            .timeout(const Duration(seconds: 8));
        final json = ApiClient.safeJsonDecode(keys.body);
        if (json['code'] == 0) {
          final keyMap = (json['data'] ?? {})['keys'] as Map? ?? {};
          pub = keyMap['$receiverId']?.toString();
        }
      } catch (_) {
        pub = null; // 拉公钥失败，走下方"未开启"分支标记失败
      }
    }
    if (pub == null || pub.isEmpty) {
      // 极少数网络异常导致拿不到公钥：标记失败并自动重试（服务器总能生成公钥）
      await ChatStore.instance.upsertMessage(
        chatId: chatId,
        msgId: 0,
        clientMsgId: clientMsgId,
        senderId: _userId,
        receiverId: receiverId,
        msgType: msgType,
        plaintext: plaintext,
        ciphertext: '',
        nonce: '',
        ephemeralPub: '',
        sendStatus: 2,
        createTime: now,
        imageLocalPath: imageLocalPath,
      );
      _scheduleRetry();
      return (msgId: 0, ok: false, error: '发送失败，正在重试');
    }

    // 加密（密钥格式非法等异常容错）
    late final dynamic encrypted;
    try {
      encrypted = ChatCrypto.encrypt(plaintext, pub);
    } catch (_) {
      // 密钥非法：本地消息标记失败
      await ChatStore.instance.upsertMessage(
        chatId: chatId,
        msgId: 0,
        clientMsgId: clientMsgId,
        senderId: _userId,
        receiverId: receiverId,
        msgType: msgType,
        plaintext: plaintext,
        ciphertext: '',
        nonce: '',
        ephemeralPub: '',
        sendStatus: 2,
        createTime: now,
        imageLocalPath: imageLocalPath,
      );
      _scheduleRetry();
      return (msgId: 0, ok: false, error: '发送失败，正在重试');
    }

    // 本地暂存（发送中）
    await ChatStore.instance.upsertMessage(
      chatId: chatId,
      msgId: 0,
      clientMsgId: clientMsgId,
      senderId: _userId,
      receiverId: receiverId,
      msgType: msgType,
      plaintext: plaintext,
      ciphertext: encrypted.body,
      nonce: encrypted.nonce,
      ephemeralPub: encrypted.encKey,
      sendStatus: 0,
      createTime: now,
      imageLocalPath: imageLocalPath,
    );

    // 发送即驱动会话（微信原理：我发出的消息也会让会话出现并上浮）
    await ChatStore.instance.upsertConversation(
      chatId: chatId,
      peerId: receiverId,
      peerNickname: '',
      peerAvatar: '',
      lastMsgText:
          ChatStore.conversationPreview({'msg_type': msgType, 'plaintext': plaintext}),
      lastMsgTime: now,
      unreadDelta: 0,
    );

    // 调接口（10s 超时）
    try {
      final resp = await ApiClient.instance
          .sendChatMessage(
            receiverId: receiverId,
            msgType: msgType,
            body: encrypted.body,
            nonce: encrypted.nonce,
            ephemeralPub: encrypted.encKey,
            clientMsgId: clientMsgId,
          )
          .timeout(const Duration(seconds: 10));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] != 0) {
        await ChatStore.instance.updateSendStatus(
            clientMsgId: clientMsgId, sendStatus: 2);
        _scheduleRetry();
        return (msgId: 0, ok: false, error: json['msg']?.toString() ?? '发送失败');
      }
      final data = (json['data'] ?? {}) as Map;
      final msgId = (data['id'] as num?)?.toInt() ?? 0;
      // 写回服务端 msg_id：本地行 msg_id>0 后右键「回复/撤回」才可用
      await ChatStore.instance.updateSendStatus(
          clientMsgId: clientMsgId, sendStatus: 1, msgId: msgId);
      // 校准服务器时间，并用服务器 create_time 覆盖本地时间（撤回时限判定基准）
      final serverTime = (data['server_time'] as num?)?.toInt() ?? 0;
      final serverCreateTime = (data['create_time'] as num?)?.toInt() ?? 0;
      if (serverTime > 0) {
        serverTimeOffsetSec =
            serverTime - (DateTime.now().millisecondsSinceEpoch ~/ 1000);
      }
      if (serverCreateTime > 0) {
        await ChatStore.instance.updateServerCreateTime(
            clientMsgId: clientMsgId, createTime: serverCreateTime);
      }
      return (msgId: msgId, ok: true, error: '');
    } catch (e) {
      // 网络异常/超时：标记失败并入自动重发队列
      await ChatStore.instance.updateSendStatus(
          clientMsgId: clientMsgId, sendStatus: 2);
      _scheduleRetry();
      return (msgId: 0, ok: false, error: '网络异常，发送失败');
    }
  }

  // ===== 自动重发队列（大厂可靠性兜底） =====

  Timer? _retryTimer;
  bool _retrying = false;
  int _retryDelay = 1; // 秒，指数退避 1→2→4→8→16→30 封顶
  final Set<String> _retryingChatIds = <String>{};

  /// 发送失败/超时后触发自动重试（指数退避）
  void _scheduleRetry() {
    _retryTimer?.cancel();
    final delay = _retryDelay > 30 ? 30 : _retryDelay;
    _retryTimer = Timer(Duration(seconds: delay), () {
      _retryTimer = null;
      _retryDelay = (_retryDelay * 2 > 30) ? 30 : _retryDelay * 2;
      retryPending();
    });
  }

  /// WS 重连成功：重置退避、补发失败消息、同步离线期间漏掉的消息
  void onReconnected() {
    _retryDelay = 1;
    retryPending();
    syncOffline();
  }

  /// 尝试补发所有失败消息
  Future<void> retryPending() async {
    if (_retrying) return;
    _retrying = true;
    try {
      final pending = await ChatStore.instance.getPendingRetry(20);
      for (final m in pending) {
        final clientMsgId = m['client_msg_id']?.toString() ?? '';
        final receiverId = (m['receiver_id'] as num?)?.toInt() ?? 0;
        final plaintext = m['plaintext']?.toString() ?? '';
        if (clientMsgId.isEmpty || receiverId <= 0 || plaintext.isEmpty) continue;
        final chatId = _chatId(_userId, receiverId);
        if (_retryingChatIds.contains(chatId)) continue;
        // 重新走发送（幂等 client_msg_id；图片/表情消息需透传类型与缓存路径）
        final r = await sendMessage(
          receiverId: receiverId,
          plaintext: plaintext,
          msgType: (m['msg_type'] as num?)?.toInt() ?? 1,
          imageLocalPath: m['image_local_path']?.toString() ?? '',
          forceClientMsgId: clientMsgId,
        );
        if (r.ok) break; // 成功一条即退出，剩余下次触发
      }
    } catch (_) {
      // 重试失败保持队列，下次再触发
    } finally {
      _retrying = false;
    }
  }

  /// 收到新消息（WS 推送）：解密并本地存储
  ///
  /// 多条消息到达时解密/入库耗时不同，若并发执行会导致**写入顺序颠倒**
  /// （消息显示按本地自增 id 排序）。这里用串行队列保证严格按接收顺序入库。
  Future<void> _storeChain = Future.value();

  Future<void> onIncomingMessage(Map<String, dynamic> msg) {
    final task = _storeChain.then((_) => _storeIncoming(msg));
    // 单条失败不打断后续队列
    _storeChain = task.catchError((_) {});
    return task;
  }

  /// 断线增量同步：拉取离线期间漏掉的消息（WS 重连后调用）
  ///
  /// 以本地最大服务器消息 id 为游标，循环拉取 /chat/sync，
  /// 复用 WS 推送的同一套解密入库逻辑（未读按 sender 是否正确累计）。
  bool _syncing = false;
  Future<void> syncOffline() async {
    if (_userId <= 0 || _syncing) return;
    _syncing = true;
    // 记录发起同步时的账号；循环中检测到切换账号（_userId 变化）立即终止，
    // 防止上一个账号的同步任务把消息写入新账号的库
    final syncUid = _userId;
    try {
      var afterId = await ChatStore.instance.getMaxMsgId();
      for (var page = 0; page < 10; page++) {
        if (_userId != syncUid) return;
        final resp = await ApiClient.instance
            .syncChatMessages(afterId: afterId)
            .timeout(const Duration(seconds: 10));
        if (_userId != syncUid) return;
        final json = ApiClient.safeJsonDecode(resp.body);
        if (json['code'] != 0) break;
        final list = (json['data'] ?? {})['list'] as List? ?? [];
        if (list.isEmpty) break;
        for (final raw in list) {
          // 走同一串行队列，与实时消息交错到达时顺序仍确定
          await onIncomingMessage(Map<String, dynamic>.from(raw));
        }
        afterId = (list.last['id'] as num?)?.toInt() ?? afterId;
        if (list.length < 50) break;
      }
    } catch (_) {
      // 同步失败静默，下次 WS 重连再同步
    } finally {
      _syncing = false;
    }
  }

  /// 退出登录/被踢下线时调用：重置账号上下文。
  /// 置 0 后，尚未完成的 sync/WS 队列任务在 `_storeIncoming` 的身份校验处被拦截，
  /// 不会把上一个账号的消息写入新库。
  void logout() {
    _userId = 0;
    _ready = false;
  }

  /// 统一入库（WS 推送 / 断线同步共用）：解密并本地存储
  Future<void> _storeIncoming(Map<String, dynamic> msg) async {
    final senderId = (msg['sender_id'] as num?)?.toInt() ?? 0;
    final receiverId = (msg['receiver_id'] as num?)?.toInt() ?? 0;
    final body = msg['body']?.toString() ?? '';
    final nonce = msg['nonce']?.toString() ?? '';
    final ephem = msg['ephemeral_pub']?.toString() ?? '';
    final msgId = (msg['id'] as num?)?.toInt() ?? 0;
    final clientMsgId = msg['client_msg_id']?.toString() ?? '';
    final msgType = (msg['msg_type'] as num?)?.toInt() ?? 1;
    final createTime = (msg['create_time'] as num?)?.toInt() ?? 0;

    // 账号身份隔离：消息必须属于当前登录账号（sender 或 receiver 是 _userId），
    // 否则丢弃。防止切换账号后，上一个账号的 WS 队列/sync 残留任务把消息
    // 以新账号身份写入新库（会话列表串号）。
    if (_userId <= 0 || (senderId != _userId && receiverId != _userId)) return;

    // chatId 优先使用服务器权威值（推送/sync 都携带），
    // 缺失时用双方 id 对称计算（与后端 chatId 规则一致）。
    // 不能用 _chatId(_userId, receiverId)：接收方场景两者相等会算出 "B_B" 错误会话。
    final chatId = (msg['chat_id']?.toString() ?? '').isNotEmpty
        ? msg['chat_id']!.toString()
        : _chatId(senderId, receiverId);
    // 自环/空 chat_id 直接丢弃（杜绝脏数据产生）
    if (chatId.isEmpty || _isSelfLoopChat(chatId)) return;

    // 解密（用本地私钥）
    String plaintext = '';
    try {
      plaintext = ChatCrypto.decrypt(
        ciphertextB64: body,
        nonceB64: nonce,
        encKeyB64: ephem,
        privateKeyB64: await _privateKey(),
      );
      // 清洗非法 UTF-16 代理项（解码可能产生孤立 surrogate，渲染会崩）
      plaintext = sanitizeUtf16(plaintext);
    } catch (_) {
      plaintext = '[无法解密的消息]';
    }

    // 本地已删除的消息：跳过（多选删除为仅本设备删除，防止"复活"）
    if (await ChatStore.instance.isMsgDeleted(msgId)) return;

    // 对方是否已读（服务端按 chat_read 游标计算，离线/切号拉取也能恢复）
    final peerRead = (msg['peer_read'] as num?)?.toInt() ?? 0;
    final inserted = await ChatStore.instance.upsertMessage(
      chatId: chatId,
      msgId: msgId,
      clientMsgId: clientMsgId.isEmpty
          ? 'in_$msgId'
          : clientMsgId,
      senderId: senderId,
      receiverId: receiverId,
      msgType: msgType,
      plaintext: plaintext,
      ciphertext: body,
      nonce: nonce,
      ephemeralPub: ephem,
      sendStatus: 1,
      createTime: createTime,
      readStatus: peerRead,
    );
    // 新收到的对方消息 → 离线消息通知（WS 实时 / 断线 sync 都走这里，
    // 只有真正新插入才通知，天然去重；正在查看该会话时不弹）
    if (inserted && senderId != _userId && msgId > 0) {
      unawaited(ChatNotifier.instance.handleNewMessage(
        msgId: msgId,
        chatId: chatId,
        peerId: senderId,
        msgType: msgType,
        plaintext: plaintext,
      ));
    }

    // 图片消息：异步下载并本地缓存（不阻塞入库；失败回退云端 URL，下次再触发）
    if (msgType == 2) {
      final url = ChatImageCache.parseUrl(plaintext);
      if (url.isNotEmpty) {
        final realClientId =
            clientMsgId.isEmpty ? 'in_$msgId' : clientMsgId;
        ChatImageCache.ensureCached(url).then((path) async {
          if (path != null) {
            await ChatStore.instance
                .updateImageLocalPath(clientMsgId: realClientId, path: path);
          }
        });
      }
    }

    // 更新会话摘要（未读数 +1；对方发来的才计）
    // 对端推导：sender 是我（自己其它设备的推送）则 peer=receiver，否则 peer=sender
    final peerId = senderId == _userId ? receiverId : senderId;
    await ChatStore.instance.upsertConversation(
      chatId: chatId,
      peerId: peerId,
      peerNickname: '',
      peerAvatar: '',
      lastMsgText:
          ChatStore.conversationPreview({'msg_type': msgType, 'plaintext': plaintext}),
      lastMsgTime: createTime,
      unreadDelta: senderId != _userId ? 1 : 0,
    );
  }

  /// 拉取会话历史（服务器密文）→ 解密 → 本地存储
  ///
  /// 返回本次拉取的条数（0 = 服务器已无更早历史），供上滑加载更多判断
  Future<int> pullHistory({
    required int peerId,
    int? beforeId,
    int pageSize = 50,
  }) async {
    try {
      final resp = await ApiClient.instance.getChatHistory(
        peerId: peerId,
        beforeId: beforeId,
        pageSize: pageSize,
      );
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] != 0) return 0;
      final data = (json['data'] ?? {}) as Map;
      final list = data['list'] as List? ?? [];
      // 校准服务器时间（撤回时限等时效判断用）
      final serverTime = (data['server_time'] as num?)?.toInt() ?? 0;
      if (serverTime > 0) {
        serverTimeOffsetSec =
            serverTime - (DateTime.now().millisecondsSinceEpoch ~/ 1000);
      }
      final priv = await _privateKey();
      for (final raw in list) {
        final m = (raw as Map).cast<String, dynamic>();
        final body = m['body']?.toString() ?? '';
        final nonce = m['nonce']?.toString() ?? '';
        final ephem = m['ephemeral_pub']?.toString() ?? '';
        String plaintext = '';
        try {
          plaintext = ChatCrypto.decrypt(
            ciphertextB64: body,
            nonceB64: nonce,
            encKeyB64: ephem,
            privateKeyB64: priv,
          );
          // 清洗非法 UTF-16 代理项（渲染防崩）
          plaintext = sanitizeUtf16(plaintext);
        } catch (_) {
          plaintext = '[无法解密的消息]';
        }
        // 本地已删除的消息：跳过（多选删除为仅本设备删除，防止"复活"）
        final serverMsgId = (m['id'] as num?)?.toInt() ?? 0;
        if (await ChatStore.instance.isMsgDeleted(serverMsgId)) continue;
        // 自环/空 chat_id 丢弃（杜绝脏数据产生）
        final histChatId = _chatId(_userId, peerId);
        if (histChatId.isEmpty || _isSelfLoopChat(histChatId)) continue;
        await ChatStore.instance.upsertMessage(
          chatId: histChatId,
          msgId: serverMsgId,
          clientMsgId: m['client_msg_id']?.toString() ??
              'h_${m['id']}',
          senderId: (m['sender_id'] as num?)?.toInt() ?? 0,
          receiverId: (m['receiver_id'] as num?)?.toInt() ?? 0,
          msgType: (m['msg_type'] as num?)?.toInt() ?? 1,
          plaintext: plaintext,
          ciphertext: body,
          nonce: nonce,
          ephemeralPub: ephem,
          sendStatus: 1,
          createTime: (m['create_time'] as num?)?.toInt() ?? 0,
          // 对方是否已读（history 返回 peer_read，离线/切号拉取恢复已读状态）
          readStatus: (m['peer_read'] as num?)?.toInt() ?? 0,
        );
        // 图片消息：异步下载本地缓存（历史记录读本地，不再回云端）
        final mType = (m['msg_type'] as num?)?.toInt() ?? 1;
        if (mType == 2) {
          final url = ChatImageCache.parseUrl(plaintext);
          if (url.isNotEmpty) {
            final realClientId =
                m['client_msg_id']?.toString() ?? 'h_${m['id']}';
            ChatImageCache.ensureCached(url).then((path) async {
              if (path != null) {
                await ChatStore.instance.updateImageLocalPath(
                    clientMsgId: realClientId, path: path);
              }
            });
          }
        }
      }
      return list.length;
    } catch (_) {
      // 拉取失败静默
      return 0;
    }
  }

  /// 会话 ID：min_max。**a==b（自己和自己）返回空串**——
  /// 聊天双方不可能相同，自环 chat_id（如 `19_19`）是历史脏数据来源，
  /// 调用方拿到空串必须拒绝写入。
  String _chatId(int a, int b) {
    if (a <= 0 || b <= 0 || a == b) return '';
    return '${a < b ? a : b}_${a < b ? b : a}';
  }

  /// 自环 chat_id 判定：`min_max` 拆出双方 id 相同即脏（如 `19_19`）。
  bool _isSelfLoopChat(String chatId) {
    final parts = chatId.split('_');
    if (parts.length != 2) return false;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return false;
    return a == b;
  }

  String _genClientMsgId() =>
      '${_userId}_${DateTime.now().millisecondsSinceEpoch}_${_rand4()}';

  String _rand4() {
    final r = DateTime.now().microsecondsSinceEpoch % 10000;
    return r.toString().padLeft(4, '0');
  }
}
