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
      version: 1,
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
            plaintext TEXT DEFAULT '',
            ciphertext TEXT DEFAULT '',
            nonce TEXT DEFAULT '',
            ephemeral_pub TEXT DEFAULT '',
            send_status INTEGER DEFAULT 1,
            create_time INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE local_key_store (
            user_id INTEGER PRIMARY KEY,
            private_key TEXT NOT NULL,
            public_key TEXT NOT NULL
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_msg_chat ON local_chat_message (chat_id, id)');
      },
    );
    _db = db;
    return db;
  }

  /// 保存本地消息（upsert by client_msg_id / msg_id）
  Future<void> upsertMessage({
    required String chatId,
    required int msgId,
    required String clientMsgId,
    required int senderId,
    required int receiverId,
    required int msgType,
    required String plaintext,
    required String ciphertext,
    required String nonce,
    required String ephemeralPub,
    required int sendStatus, // 0发送中 1已发送 2失败
    required int createTime,
  }) async {
    final db = await _database;
    final exists = await db.query(
      'local_chat_message',
      where: 'client_msg_id = ? AND sender_id = ?',
      whereArgs: [clientMsgId, senderId],
      limit: 1,
    );
    if (exists.isNotEmpty) {
      await db.update(
        'local_chat_message',
        {
          'msg_id': msgId,
          'plaintext': plaintext,
          'ciphertext': ciphertext,
          'nonce': nonce,
          'ephemeral_pub': ephemeralPub,
          'send_status': sendStatus,
          'create_time': createTime,
        },
        where: 'id = ?',
        whereArgs: [exists.first['id']],
      );
    } else {
      await db.insert('local_chat_message', {
        'chat_id': chatId,
        'msg_id': msgId,
        'client_msg_id': clientMsgId,
        'sender_id': senderId,
        'receiver_id': receiverId,
        'msg_type': msgType,
        'plaintext': plaintext,
        'ciphertext': ciphertext,
        'nonce': nonce,
        'ephemeral_pub': ephemeralPub,
        'send_status': sendStatus,
        'create_time': createTime,
      });
    }
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
