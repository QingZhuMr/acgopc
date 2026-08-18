import '../core/api_client.dart';
import 'chat_crypto.dart';
import 'chat_store.dart';

/// 聊天服务：密钥管理 + 消息收发（E2EE 加解密 + 本地存储）
class ChatService {
  ChatService._();
  static final ChatService instance = ChatService._();

  /// 当前用户 ID
  int _userId = 0;

  /// 是否已初始化（密钥已就绪）
  bool _ready = false;

  bool get isReady => _ready;

  /// 初始化（登录后/进入消息页时调用）：确保本地密钥存在并上传公钥
  Future<void> init(int userId) async {
    _userId = userId;
    // 检查本地密钥
    var keyPair = await ChatStore.instance.getKeyPair(userId);
    if (keyPair == null) {
      keyPair = ChatCrypto.generateKeyPair();
      await ChatStore.instance.saveKeyPair(
        userId: userId,
        privateKey: keyPair.privateKey,
        publicKey: keyPair.publicKey,
      );
    }
    // 上传公钥（幂等，每次启动都同步一次，服务器唯一约束覆盖）
    try {
      final resp = await ApiClient.instance.postChatKey(keyPair.publicKey);
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] != 0) {
        // 上传失败不阻塞（聊天时可能用旧公钥）
      }
    } catch (_) {}
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
  Future<({int msgId, bool ok, String error})> sendMessage({
    required int receiverId,
    required String plaintext,
    String? peerPublicKey,
  }) async {
    final clientMsgId = _genClientMsgId();
    final chatId = _chatId(_userId, receiverId);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // 需要对方公钥
    var pub = peerPublicKey;
    if (pub == null) {
      final keys = await ApiClient.instance.getChatKeys([receiverId]);
      final json = ApiClient.safeJsonDecode(keys.body);
      if (json['code'] == 0) {
        final keyMap = (json['data'] ?? {})['keys'] as Map? ?? {};
        pub = keyMap['$receiverId']?.toString();
      }
    }
    if (pub == null || pub.isEmpty) {
      return (msgId: 0, ok: false, error: '对方尚未开启聊天');
    }

    // 加密（密钥格式非法等异常容错）
    late final dynamic encrypted;
    try {
      encrypted = ChatCrypto.encrypt(plaintext, pub);
    } catch (_) {
      return (msgId: 0, ok: false, error: '对方聊天密钥无效，暂无法发送');
    }

    // 本地暂存（发送中）
    await ChatStore.instance.upsertMessage(
      chatId: chatId,
      msgId: 0,
      clientMsgId: clientMsgId,
      senderId: _userId,
      receiverId: receiverId,
      msgType: 1,
      plaintext: plaintext,
      ciphertext: encrypted.body,
      nonce: encrypted.nonce,
      ephemeralPub: encrypted.encKey,
      sendStatus: 0,
      createTime: now,
    );

    // 调接口
    try {
      final resp = await ApiClient.instance.sendChatMessage(
        receiverId: receiverId,
        body: encrypted.body,
        nonce: encrypted.nonce,
        ephemeralPub: encrypted.encKey,
        clientMsgId: clientMsgId,
      );
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] != 0) {
        await ChatStore.instance.updateSendStatus(
            clientMsgId: clientMsgId, sendStatus: 2);
        return (msgId: 0, ok: false, error: json['msg']?.toString() ?? '发送失败');
      }
      final data = (json['data'] ?? {}) as Map;
      final msgId = (data['id'] as num?)?.toInt() ?? 0;
      await ChatStore.instance.updateSendStatus(
          clientMsgId: clientMsgId, sendStatus: 1);
      return (msgId: msgId, ok: true, error: '');
    } catch (e) {
      await ChatStore.instance.updateSendStatus(
          clientMsgId: clientMsgId, sendStatus: 2);
      return (msgId: 0, ok: false, error: '网络异常，发送失败');
    }
  }

  /// 收到新消息（WS 推送）：解密并本地存储
  Future<void> onIncomingMessage(Map<String, dynamic> msg) async {
    final senderId = (msg['sender_id'] as num?)?.toInt() ?? 0;
    final receiverId = (msg['receiver_id'] as num?)?.toInt() ?? 0;
    final body = msg['body']?.toString() ?? '';
    final nonce = msg['nonce']?.toString() ?? '';
    final ephem = msg['ephemeral_pub']?.toString() ?? '';
    final msgId = (msg['id'] as num?)?.toInt() ?? 0;
    final clientMsgId = msg['client_msg_id']?.toString() ?? '';
    final msgType = (msg['msg_type'] as num?)?.toInt() ?? 1;
    final createTime = (msg['create_time'] as num?)?.toInt() ?? 0;

    // 解密（用本地私钥）
    String plaintext = '';
    try {
      plaintext = ChatCrypto.decrypt(
        ciphertextB64: body,
        nonceB64: nonce,
        encKeyB64: ephem,
        privateKeyB64: await _privateKey(),
      );
    } catch (_) {
      plaintext = '[无法解密的消息]';
    }

    final chatId = _chatId(_userId, receiverId);
    await ChatStore.instance.upsertMessage(
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
    );
  }

  /// 拉取会话历史（服务器密文）→ 解密 → 本地存储
  Future<void> pullHistory({
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
      if (json['code'] != 0) return;
      final list = (json['data'] ?? {})['list'] as List? ?? [];
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
        } catch (_) {
          plaintext = '[无法解密的消息]';
        }
        await ChatStore.instance.upsertMessage(
          chatId: _chatId(_userId, peerId),
          msgId: (m['id'] as num?)?.toInt() ?? 0,
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
        );
      }
    } catch (_) {
      // 拉取失败静默
    }
  }

  String _chatId(int a, int b) => '${a < b ? a : b}_${a < b ? b : a}';

  String _genClientMsgId() =>
      '${_userId}_${DateTime.now().millisecondsSinceEpoch}_${_rand4()}';

  String _rand4() {
    final r = DateTime.now().microsecondsSinceEpoch % 10000;
    return r.toString().padLeft(4, '0');
  }
}
