import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 聊天本地存储（SQLite）
///
/// 存储：
/// - 本地消息（解密后明文 + 密文元数据），供离线浏览
/// - 本地 E2EE 密钥对（私钥永不上传）
///
/// 表结构见 docs/聊天系统设计.md 3.2。
class ChatStore {
  ChatStore._();
  static final ChatStore instance = ChatStore._();

  Database? _db;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    // 桌面端（Windows/macOS/Linux）用 ffi 实现；移动端用原生
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dir, 'acgo_chat.db'),
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE local_chat_message (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            chat_id TEXT NOT NULL,
            msg_id INTEGER DEFAULT 0,
            client_msg_id TEXT DEFAULT '',
            sender_id INTEGER NOT NULL,
            receiver_id INTEGER NOT NULL,
            msg_type INTEGER DEFAULT 1,
            seq INTEGER DEFAULT 0,
            plaintext TEXT DEFAULT '',
            ciphertext TEXT DEFAULT '',
            nonce TEXT DEFAULT '',
            ephemeral_pub TEXT DEFAULT '',
            signature TEXT DEFAULT '',
            send_status INTEGER DEFAULT 1,
            create_time INTEGER NOT NULL
          )
        ''');
        await db.execute(
            'CREATE UNIQUE INDEX idx_uniq_client_msg ON local_chat_message (client_msg_id)');
        await db.execute(
            'CREATE INDEX idx_msg_chat ON local_chat_message (chat_id, id)');
        await db.execute('''
          CREATE TABLE local_key_store (
            user_id INTEGER PRIMARY KEY,
            private_key TEXT NOT NULL,
            public_key TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE local_conversation (
            chat_id TEXT PRIMARY KEY,
            peer_id INTEGER NOT NULL,
            peer_nickname TEXT DEFAULT '',
            peer_avatar TEXT DEFAULT '',
            last_msg_text TEXT DEFAULT '',
            last_msg_time INTEGER DEFAULT 0,
            unread_count INTEGER DEFAULT 0,
            update_time INTEGER DEFAULT 0
          )
        ''');
      },
      onUpgrade: (db, oldV, newV) async {
        // v1 → v2：新增 seq/signature 列 + 唯一索引 + 会话表
        if (oldV < 2) {
          final cols = await db.rawQuery('PRAGMA table_info(local_chat_message)');
          final names = cols.map((c) => c['name']).toSet();
          if (!names.contains('seq')) {
            await db.execute(
                'ALTER TABLE local_chat_message ADD COLUMN seq INTEGER DEFAULT 0');
          }
          if (!names.contains('signature')) {
            await db.execute(
                'ALTER TABLE local_chat_message ADD COLUMN signature TEXT DEFAULT \'\'');
          }
          try {
            await db.execute(
                'CREATE UNIQUE INDEX idx_uniq_client_msg ON local_chat_message (client_msg_id)');
          } catch (_) {
            // 已存在（脏数据场景容忍重复，用 INSERT OR IGNORE 兜底）
          }
          await db.execute('''
            CREATE TABLE IF NOT EXISTS local_conversation (
              chat_id TEXT PRIMARY KEY,
              peer_id INTEGER NOT NULL,
              peer_nickname TEXT DEFAULT '',
              peer_avatar TEXT DEFAULT '',
              last_msg_text TEXT DEFAULT '',
              last_msg_time INTEGER DEFAULT 0,
              unread_count INTEGER DEFAULT 0,
              update_time INTEGER DEFAULT 0
            )
          ''');
        }
      },
    );
    _db = db;
    return db;
  }

  /// 保存本地消息（幂等：按 client_msg_id UNIQUE 去重）
  Future<void> upsertMessage({
    required String chatId,
    required int msgId,
    required String clientMsgId,
    required int senderId,
    required int receiverId,
    required int msgType,
    int seq = 0,
    required String plaintext,
    required String ciphertext,
    required String nonce,
    required String ephemeralPub,
    String signature = '',
    required int sendStatus, // 0发送中 1已发送 2失败
    required int createTime,
  }) async {
    final db = await _database;
    if (clientMsgId.isEmpty) {
      clientMsgId = 'c_${msgId}_$senderId';
    }
    // 幂等：已存在则仅更新状态/服务端 id/seq（不覆盖明文——WS 与拉取可能重复）
    final exists = await db.query(
      'local_chat_message',
      where: 'client_msg_id = ?',
      whereArgs: [clientMsgId],
      limit: 1,
    );
    if (exists.isNotEmpty) {
      final update = <String, Object?>{
        'msg_id': msgId,
        'send_status': sendStatus,
        if (seq > 0) 'seq': seq,
        if (signature.isNotEmpty) 'signature': signature,
      };
      // 明文为空时补明文（首次解密落库）
      if (plaintext.isNotEmpty && (exists.first['plaintext'] as String? ?? '').isEmpty) {
        update['plaintext'] = plaintext;
      }
      await db.update(
        'local_chat_message',
        update,
        where: 'id = ?',
        whereArgs: [exists.first['id']],
      );
      return;
    }
    await db.insert('local_chat_message', {
      'chat_id': chatId,
      'msg_id': msgId,
      'client_msg_id': clientMsgId,
      'sender_id': senderId,
      'receiver_id': receiverId,
      'msg_type': msgType,
      'seq': seq,
      'plaintext': plaintext,
      'ciphertext': ciphertext,
      'nonce': nonce,
      'ephemeral_pub': ephemeralPub,
      'signature': signature,
      'send_status': sendStatus,
      'create_time': createTime,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// 按 msg_id 更新发送状态（发送成功后）
  Future<void> updateSendStatus(
      {required String clientMsgId, required int sendStatus}) async {
    final db = await _database;
    await db.update(
      'local_chat_message',
      {'send_status': sendStatus},
      where: 'client_msg_id = ?',
      whereArgs: [clientMsgId],
    );
  }

  /// 拉取某会话本地消息（按 id 倒序，最多 limit 条）
  Future<List<Map<String, dynamic>>> getMessages(
    String chatId, {
    int limit = 100,
    int? beforeId,
  }) async {
    final db = await _database;
    final where = StringBuffer('chat_id = ?');
    final args = <Object?>[chatId];
    if (beforeId != null) {
      where.write(' AND id < ?');
      args.add(beforeId);
    }
    final rows = await db.query(
      'local_chat_message',
      where: where.toString(),
      whereArgs: args,
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows;
  }

  /// 查询待重发消息（send_status=2 失败，或 =0 发送中超时未确认），按时间升序
  Future<List<Map<String, dynamic>>> getPendingRetry(int limit) async {
    final db = await _database;
    final rows = await db.query(
      'local_chat_message',
      where: 'send_status = ?',
      whereArgs: [2],
      orderBy: 'create_time ASC',
      limit: limit,
    );
    return rows;
  }

  /// 更新会话摘要（收到/发送消息后）
  Future<void> upsertConversation({
    required String chatId,
    required int peerId,
    required String peerNickname,
    required String peerAvatar,
    required String lastMsgText,
    required int lastMsgTime,
    int unreadDelta = 0,
  }) async {
    final db = await _database;
    final exists = await db.query(
      'local_conversation',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      limit: 1,
    );
    if (exists.isEmpty) {
      await db.insert('local_conversation', {
        'chat_id': chatId,
        'peer_id': peerId,
        'peer_nickname': peerNickname,
        'peer_avatar': peerAvatar,
        'last_msg_text': lastMsgText,
        'last_msg_time': lastMsgTime,
        'unread_count': unreadDelta > 0 ? unreadDelta : 0,
        'update_time': lastMsgTime,
      });
    } else {
      final unread =
          ((exists.first['unread_count'] as num?)?.toInt() ?? 0) + unreadDelta;
      await db.update(
        'local_conversation',
        {
          'last_msg_text': lastMsgText,
          'last_msg_time': lastMsgTime,
          if (peerNickname.isNotEmpty) 'peer_nickname': peerNickname,
          if (peerAvatar.isNotEmpty) 'peer_avatar': peerAvatar,
          'unread_count': unread < 0 ? 0 : unread,
          'update_time': lastMsgTime,
        },
        where: 'chat_id = ?',
        whereArgs: [chatId],
      );
    }
  }

  /// 获取会话列表（按最近消息时间倒序）
  Future<List<Map<String, dynamic>>> getConversations() async {
    final db = await _database;
    return db.query(
      'local_conversation',
      orderBy: 'last_msg_time DESC',
      limit: 50,
    );
  }

  /// 清零某会话未读数
  Future<void> clearUnread(String chatId) async {
    final db = await _database;
    await db.update(
      'local_conversation',
      {'unread_count': 0},
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );
  }

  /// 标记某会话所有消息已读（打开会话时调用）
  Future<void> markChatRead(String chatId, int myUid) async {
    final db = await _database;
    await db.update(
      'local_chat_message',
      {'send_status': 1},
      where: 'chat_id = ? AND sender_id != ? AND send_status = ?',
      whereArgs: [chatId, myUid, 0],
    );
  }

  /// 更新某条消息状态（服务端已读回执后标记）
  Future<void> markMessagesReadByMsgIds(
      String chatId, int myUid, int upToMsgId) async {
    final db = await _database;
    // 本地 seq 小于等于 upToMsgId 且来自对方的消息标记已读
    await db.update(
      'local_chat_message',
      {'send_status': 1},
      where: 'chat_id = ? AND sender_id != ? AND msg_id > 0 AND msg_id <= ?',
      whereArgs: [chatId, myUid, upToMsgId],
    );
  }

  /// 保存密钥对
  Future<void> saveKeyPair({
    required int userId,
    required String privateKey,
    required String publicKey,
  }) async {
    final db = await _database;
    await db.insert(
      'local_key_store',
      {'user_id': userId, 'private_key': privateKey, 'public_key': publicKey},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 获取本地密钥对
  Future<({String privateKey, String publicKey})?> getKeyPair(int userId) async {
    final db = await _database;
    final rows = await db.query(
      'local_key_store',
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (
      privateKey: rows.first['private_key'] as String,
      publicKey: rows.first['public_key'] as String,
    );
  }
}
