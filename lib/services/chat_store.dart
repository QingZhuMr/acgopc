import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/app_config.dart';
import '../utils/text_sanitize.dart';
import 'secure_storage.dart';

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

  /// 当前登录用户 id（0=未登录）；聊天本地库按账号隔离
  int _uid = 0;

  /// 当前已打开连接所属用户 id（用于判断连接是否匹配当前账号）
  int _dbUid = 0;

  /// sqflite ffi factory 是否已初始化（桌面端全局唯一，重复设置会打印警告）
  static bool _ffiInitDone = false;

  /// 未读数变化通知（左侧导航消息角标 / 会话列表刷新监听）。
  /// 每次未读数可能变化时 +1，监听方自行重新查询汇总。
  final ValueNotifier<int> chatUnreadTick = ValueNotifier<int>(0);

  void _notifyUnreadChanged() => chatUnreadTick.value++;

  /// 登录后调用：切换聊天本地库到该账号专属文件（`acgo_chat_<uid>.db`）
  ///
  /// 切换账号后各账号会话/消息互不可见；首次登录某账号时自动从旧公共库
  /// `acgo_chat.db` 一次性迁移该账号的数据（消息/密钥/隐藏/删除标记）。
  Future<void> openForUser(int uid) async {
    if (uid <= 0 || uid == _uid) return;
    final old = _db;
    _db = null;
    _dbUid = 0;
    _uid = uid;
    _deletedLoaded = false;
    if (old != null) {
      try {
        await old.close();
      } catch (_) {}
    }
  }

  /// 退出登录调用：关闭聊天库连接（下次登录重新按新账号打开）
  Future<void> closeForUser() async {
    final old = _db;
    _db = null;
    _dbUid = 0;
    _uid = 0;
    _deletedLoaded = false;
    if (old != null) {
      try {
        await old.close();
      } catch (_) {}
    }
  }

  /// 串号兜底清理（登录后调用）：删除当前账号库中**不属于本账号**的脏数据。
  ///
  /// 背景：早期版本切换账号时，上个账号残留的 WS/sync 任务可能把消息写入
  /// 新账号库（chat_id 为他人会话）。身份校验已堵住新增，但历史脏数据
  /// 需要兜底清除，否则会话列表会出现"别人的会话"。
  ///
  /// 三步清理：
  /// 1. 删不属于本账号的**消息**（chat_id 双方都不含 uid）
  /// 2. 删不属于本账号的**会话**（同上）
  /// 3. 合并**同一个对端**的重复会话（不同 chat_id 历史生成不规范，
  ///    如 `19_21` 和 `21_19` 都用过；按 peer_id 分组保留最新一条，
  ///    其他会话和其消息一起删/合并 chat_id）
  Future<void> pruneForeignData(int uid) async {
    if (uid <= 0) return;
    try {
      final db = await _database;
      if (_dbUid != uid) return; // 连接不属于该账号则跳过（防误删）

      // 1) 清理不属于本账号的消息
      final msgs = await db.query('local_chat_message',
          columns: ['id', 'chat_id']);
      final deadMsgIds = <int>[];
      for (final row in msgs) {
        final chatId = row['chat_id']?.toString() ?? '';
        if (chatId.isEmpty) continue;
        if (!_chatBelongsTo(chatId, uid)) {
          deadMsgIds.add(row['id'] as int);
        }
      }
      for (final id in deadMsgIds) {
        await db.delete('local_chat_message',
            where: 'id = ?', whereArgs: [id]);
      }

      // 2) 清理不属于本账号的会话
      final convs = await db.query('local_conversation',
          columns: ['chat_id']);
      for (final row in convs) {
        final chatId = row['chat_id']?.toString() ?? '';
        if (chatId.isEmpty) continue;
        if (!_chatBelongsTo(chatId, uid)) {
          await db.delete('local_conversation',
              where: 'chat_id = ?', whereArgs: [chatId]);
        }
      }

      // 3) 合并同一个 peer 的重复会话（不同 chat_id 历史不规范）
      final merged = await _mergeDuplicateConversations(uid);

      if (deadMsgIds.isNotEmpty || merged) {
        _notifyUnreadChanged();
      }
    } catch (_) {
      // 兜底清理失败不影响主流程（下次登录再试）
    }
  }

  /// 合并**同一个 peer** 的多个会话（chat_id 历史不规范，如 `19_21` 和 `21_19`）。
  ///
  /// 对每个 peer：保留**最新一条**会话（按 last_msg_time 最大）作为 canonical，
  /// 其他会话删掉，其消息的 chat_id 重映射到 canonical。
  Future<bool> _mergeDuplicateConversations(int uid) async {
    final db = await _database;
    final convs = await db.query('local_conversation');
    if (convs.length < 2) return false;

    // 按 peerId 分组：peerId → [(chatId, lastMsgTime)]
    final groups = <int, List<Map<String, dynamic>>>{};
    for (final c in convs) {
      final chatId = c['chat_id']?.toString() ?? '';
      if (chatId.isEmpty) continue;
      final peerId = _peerOfChatId(chatId, uid);
      if (peerId == null) continue;
      groups.putIfAbsent(peerId, () => []).add({
        'chat_id': chatId,
        'last_msg_time': (c['last_msg_time'] as num?)?.toInt() ?? 0,
      });
    }

    var merged = false;
    for (final entry in groups.entries) {
      final list = entry.value;
      if (list.length < 2) continue;
      // 按 last_msg_time 降序排：最新一条作为 canonical
      list.sort((a, b) => (b['last_msg_time'] as int).compareTo(a['last_msg_time'] as int));
      final canonical = list.first['chat_id'] as String;
      for (var i = 1; i < list.length; i++) {
        final oldId = list[i]['chat_id'] as String;
        if (oldId == canonical) continue;
        // 把老会话的消息 chat_id 重映射到 canonical
        await db.rawUpdate(
            'UPDATE local_chat_message SET chat_id = ? WHERE chat_id = ?',
            [canonical, oldId]);
        // 删除老会话
        await db.delete('local_conversation',
            where: 'chat_id = ?', whereArgs: [oldId]);
        merged = true;
      }
    }
    return merged;
  }

  /// chat_id（`min_max`）是否属于 [uid]：拆出双方 id，至少一方等于 uid。
  /// **min==max（自己和自己）一定是脏数据**（聊天双方不可能相同），
  /// 即使其中一方等于 uid 也返回 false（历史 bug：接收方场景用
  /// `_chatId(uid, uid)` 算出 `19_19` 这种错误会话）。
  bool _chatBelongsTo(String chatId, int uid) {
    final parts = chatId.split('_');
    if (parts.length != 2) return false;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return false;
    if (a == b) return false; // 自己和自己聊天：脏数据
    return a == uid || b == uid;
  }

  /// 从 chat_id 拆出对端 id（peer）；chat_id 非法、双方相同、或双方都不含 uid → null。
  int? _peerOfChatId(String chatId, int uid) {
    final parts = chatId.split('_');
    if (parts.length != 2) return null;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return null;
    if (a == b) return null; // 自己和自己：脏数据
    if (a == uid) return b;
    if (b == uid) return a;
    return null;
  }

  Future<Database> get _database async {
    // 连接与当前账号匹配 → 直接复用
    if (_db != null && _dbUid == _uid) return _db!;
    // 关闭旧连接（可能属于上一个账号）
    final old = _db;
    _db = null;
    _dbUid = 0;
    if (old != null) {
      try {
        await old.close();
      } catch (_) {}
    }
    // 桌面端（Windows/macOS/Linux）用 ffi 实现；移动端用原生。
    // 只初始化一次（sqflite 默认 factory 全局生效，重复设置会打印警告）
    if (Platform.isWindows || Platform.isLinux) {
      if (!_ffiInitDone) {
        _ffiInitDone = true;
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }
    }
    // 未登录：回退公共库（正常流程登录后即切专属库，此处仅兜底）
    if (_uid <= 0) {
      final db = await _openDb('acgo_chat.db');
      _db = db;
      _dbUid = 0;
      return db;
    }
    // 首次使用该账号：从旧公共库一次性迁移数据（内部打开新库并缓存）
    await _migrateFromLegacyIfNeeded(_uid);
    if (_db != null && _dbUid == _uid) return _db!;
    final db = await _openDb('acgo_chat_$_uid.db');
    _db = db;
    _dbUid = _uid;
    return db;
  }

  Future<Database> _openDb(String fileName) async {
    // 数据库统一放在应用数据目录（AppConfig.dataDir），与缓存/配置一致。
    // 首次使用前从旧默认路径（getDatabasesPath）迁移已存在的账号库，避免丢数据。
    final dir = AppConfig.dataDir;
    final target = p.join(dir, fileName);
    // 目标不存在但旧路径存在 → 迁移
    if (!File(target).existsSync()) {
      try {
        final legacyDir = await getDatabasesPath();
        final legacy = p.join(legacyDir, fileName);
        if (File(legacy).existsSync()) {
          File(legacy).copySync(target);
          // 忽略 wal/shm 临时文件
        }
      } catch (_) {}
    }
    return openDatabase(
      target,
      version: 8,
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
            recalled INTEGER DEFAULT 0,
            image_local_path TEXT DEFAULT '',
            read_status INTEGER DEFAULT 0,
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
        // 隐藏会话（删除但保留聊天记录，重新收发消息后自动恢复可见）
        await db.execute('''
          CREATE TABLE IF NOT EXISTS hidden_conversation (
            chat_id TEXT PRIMARY KEY
          )
        ''');
        // 本地已删除消息标记（多选删除/单条删除：仅本设备删除，
        // 拉历史/断线同步时按 msg_id 过滤，防止服务器缓存中消息"复活"）
        await db.execute('''
          CREATE TABLE IF NOT EXISTS local_deleted_msg (
            msg_id INTEGER PRIMARY KEY,
            delete_time INTEGER DEFAULT 0
          )
        ''');
      },
      onUpgrade: (db, oldV, newV) async {
        // v7 → v8：本地已删除消息标记表（多选删除防"复活"）
        if (oldV < 8) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS local_deleted_msg (
              msg_id INTEGER PRIMARY KEY,
              delete_time INTEGER DEFAULT 0
            )
          ''');
        }
        // v6 → v7：我发出的消息的已读状态列（对方是否已读）
        if (oldV < 7) {
          final cols7 =
              await db.rawQuery('PRAGMA table_info(local_chat_message)');
          final names7 = cols7.map((c) => c['name']).toSet();
          if (!names7.contains('read_status')) {
            await db.execute(
                'ALTER TABLE local_chat_message ADD COLUMN read_status INTEGER DEFAULT 0');
          }
        }
        // v5 → v6：图片消息本地缓存路径列
        if (oldV < 6) {
          final cols6 =
              await db.rawQuery('PRAGMA table_info(local_chat_message)');
          final names6 = cols6.map((c) => c['name']).toSet();
          if (!names6.contains('image_local_path')) {
            await db.execute(
                'ALTER TABLE local_chat_message ADD COLUMN image_local_path TEXT DEFAULT \'\'');
          }
        }
        // v4 → v5：新增消息类型列（1文本 2图片）
        if (oldV < 5) {
          final cols5 =
              await db.rawQuery('PRAGMA table_info(local_chat_message)');
          final names5 = cols5.map((c) => c['name']).toSet();
          if (!names5.contains('msg_type')) {
            await db.execute(
                'ALTER TABLE local_chat_message ADD COLUMN msg_type INTEGER DEFAULT 1');
          }
        }
        // v3 → v4：新增撤回标记列
        if (oldV < 4) {
          final cols =
              await db.rawQuery('PRAGMA table_info(local_chat_message)');
          final names = cols.map((c) => c['name']).toSet();
          if (!names.contains('recalled')) {
            await db.execute(
                'ALTER TABLE local_chat_message ADD COLUMN recalled INTEGER DEFAULT 0');
          }
        }
        // v2 → v3：新增隐藏会话表（删除会话但保留记录）
        if (oldV < 3) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS hidden_conversation (
              chat_id TEXT PRIMARY KEY
            )
          ''');
        }
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
          await db.execute('''
            CREATE TABLE IF NOT EXISTS hidden_conversation (
              chat_id TEXT PRIMARY KEY
            )
          ''');
        }
      },
    );
  }

  /// 首次登录该账号时，从旧公共库 `acgo_chat.db` 一次性迁移该账号的本地数据。
  ///
  /// 旧库无 owner 列，按 `sender_id/receiver_id` 归属消息、按 user_id 归属密钥；
  /// 会话表不迁移（消息迁移后由 `syncConversationsFromMessages` 自动聚合重建）；
  /// 幂等：目标库已存在则跳过。迁移失败不阻塞登录（最多丢旧库数据）。
  Future<void> _migrateFromLegacyIfNeeded(int uid) async {
    try {
      final dir = await getDatabasesPath();
      final legacyPath = p.join(dir, 'acgo_chat.db');
      final userPath = p.join(dir, 'acgo_chat_$uid.db');
      if (!File(legacyPath).existsSync()) return;
      if (File(userPath).existsSync()) return;
      // 打开旧库（只读）
      final legacy = await openDatabase(legacyPath, readOnly: true);
      try {
        // 打开新库并缓存（不走 getter 避免递归）
        final db = await _openDb('acgo_chat_$uid.db');
        _db = db;
        _dbUid = uid;
        // 密钥（该账号的 E2EE 密钥对）
        final keys = await legacy.query(
          'local_key_store',
          where: 'user_id = ?',
          whereArgs: [uid],
        );
        for (final k in keys) {
          await db.insert('local_key_store', k,
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
        // 消息（sender 或 receiver 是该账号的）
        final msgs = await legacy.query(
          'local_chat_message',
          where: 'sender_id = ? OR receiver_id = ?',
          whereArgs: [uid, uid],
        );
        for (final m in msgs) {
          await db.insert('local_chat_message', m,
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        // 隐藏会话（仅迁该账号有聊天记录的会话）
        final hiddenRows = await legacy.query('hidden_conversation');
        final migratedChatIds = {
          for (final m in msgs) m['chat_id']?.toString() ?? ''
        }..remove('');
        for (final h in hiddenRows) {
          final cid = h['chat_id']?.toString() ?? '';
          if (cid.isNotEmpty && migratedChatIds.contains(cid)) {
            await db.insert('hidden_conversation', {'chat_id': cid},
                conflictAlgorithm: ConflictAlgorithm.ignore);
          }
        }
        // 已删除消息标记（msg_id 全局唯一，全量迁移）
        try {
          final deleted = await legacy.query('local_deleted_msg');
          for (final d in deleted) {
            await db.insert('local_deleted_msg', d,
                conflictAlgorithm: ConflictAlgorithm.ignore);
          }
        } catch (_) {}
      } finally {
        await legacy.close();
      }
    } catch (_) {
      // 迁移失败不阻塞登录（最多丢旧库数据，新库正常用）
    }
  }

  /// 保存本地消息（幂等：按 client_msg_id UNIQUE 去重）
  ///
  /// 返回 true 表示本次为新插入（离线通知等场景据此判断是否首次收到）。
  Future<bool> upsertMessage({
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
    String imageLocalPath = '',
    int readStatus = 0, // 0未读 1对方已读（仅自己发出的消息有意义）
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
        // 已读状态以服务端为准：拉取/推送都可能带来更新的已读游标
        if (readStatus >
            ((exists.first['read_status'] as num?)?.toInt() ?? 0))
          'read_status': readStatus,
      };
      // 明文为空时补明文（首次解密落库）
      if (plaintext.isNotEmpty && (exists.first['plaintext'] as String? ?? '').isEmpty) {
        update['plaintext'] = plaintext;
      }
      // 图片本地缓存路径回填（下载完成后写入，不覆盖已有路径）
      if (imageLocalPath.isNotEmpty) {
        update['image_local_path'] = imageLocalPath;
      }
      await db.update(
        'local_chat_message',
        update,
        where: 'id = ?',
        whereArgs: [exists.first['id']],
      );
      return false;
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
      'image_local_path': imageLocalPath,
      'read_status': readStatus,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return true;
  }

  /// 图片缓存回填通知（消息列表监听后刷新，展示本地图片）
  static final ValueNotifier<int> imageCacheTick = ValueNotifier<int>(0);

  /// 图片消息本地缓存路径回填（下载完成后调用）
  Future<void> updateImageLocalPath({
    required String clientMsgId,
    required String path,
  }) async {
    final db = await _database;
    final res = await db.update(
      'local_chat_message',
      {'image_local_path': path},
      where: 'client_msg_id = ? AND image_local_path = \'\'',
      whereArgs: [clientMsgId],
    );
    if (res > 0) imageCacheTick.value++;
  }

  /// 更新发送状态（发送成功后）
  ///
  /// [msgId]：发送成功时携带服务端消息 id，一并写回本地行。
  /// 否则本地行 msg_id 恒为 0，右键「回复/撤回」（判定 msgId > 0）不可用，
  /// 必须重新拉历史才能恢复。
  Future<void> updateSendStatus(
      {required String clientMsgId,
      required int sendStatus,
      int? msgId}) async {
    final db = await _database;
    final fields = <String, Object?>{'send_status': sendStatus};
    if (msgId != null && msgId > 0) fields['msg_id'] = msgId;
    await db.update(
      'local_chat_message',
      fields,
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

  /// 全量搜索本地聊天记录（明文 LIKE，跨会话），按时间倒序
  ///
  /// 仅搜索纯文本消息（msg_type=1）且未撤回的，避免图片/表情消息的
  /// 加密元数据 JSON 与撤回占位文案干扰搜索结果。
  Future<List<Map<String, dynamic>>> searchMessages(String keyword,
      {int limit = 50}) async {
    final db = await _database;
    final kw = keyword.trim();
    if (kw.isEmpty) return [];
    // 转义 LIKE 通配符，避免用户输入 % _ 干扰
    final escaped = kw
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    return db.query(
      'local_chat_message',
      where: "msg_type = 1 AND recalled = 0 AND plaintext LIKE ? ESCAPE '\\'",
      whereArgs: ['%$escaped%'],
      orderBy: 'create_time DESC',
      limit: limit,
    );
  }

  /// 发送成功后用服务器 create_time 覆盖本地时间（撤回时限判定以服务器时间为准）
  Future<void> updateServerCreateTime({
    required String clientMsgId,
    required int createTime,
  }) async {
    final db = await _database;
    await db.update(
      'local_chat_message',
      {'create_time': createTime},
      where: 'client_msg_id = ?',
      whereArgs: [clientMsgId],
    );
  }

  /// 本地最大的服务器消息 id（断线增量同步的游标）
  Future<int> getMaxMsgId() async {
    final db = await _database;
    final rows = await db.rawQuery(
        'SELECT MAX(msg_id) AS m FROM local_chat_message');
    return (rows.isNotEmpty ? rows.first['m'] as num? : null)?.toInt() ?? 0;
  }

  /// 标记消息已撤回（本地展示占位文案，原文保留在库里）
  Future<void> markRecalled(int msgId) async {
    final db = await _database;
    await db.update(
      'local_chat_message',
      {'recalled': 1},
      where: 'msg_id = ?',
      whereArgs: [msgId],
    );
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
    // 有新消息即恢复可见（删除隐藏的会话重新收发消息后再次出现）
    await db.delete('hidden_conversation',
        where: 'chat_id = ?', whereArgs: [chatId]);
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
    // 未读数变化才通知（sync 批量重建 unreadDelta=0 不打扰角标）
    if (unreadDelta != 0) _notifyUnreadChanged();
  }

  /// 从本地聊天记录聚合会话（微信原理：会话 = 本地聊天记录，无论收发）
  ///
  /// 以 [local_chat_message] 为唯一真相源：为每个 chat_id 取最新一条消息
  /// （含我发出的）更新会话摘要，并清理已无任何聊天记录的会话。
  /// [myUid] 用于推导对端：消息 sender 是我则 peer=receiver，否则 peer=sender。
  Future<void> syncConversationsFromMessages(int myUid) async {
    final db = await _database;
    // 用户主动隐藏的会话：聚合时跳过（删除但保留记录，不再自动出现）
    final hiddenRows = await db.query('hidden_conversation');
    final hidden = {
      for (final r in hiddenRows) r['chat_id']?.toString() ?? ''
    }..remove('');
    // 所有仍有聊天记录的会话（用于清理无记录会话）
    final chatRows = await db.rawQuery(
        'SELECT DISTINCT chat_id FROM local_chat_message WHERE chat_id != \'\'');
    final valid = {
      for (final r in chatRows) r['chat_id']?.toString() ?? ''
    }..remove('');
    // 按时间倒序取最新消息（2000 条足够覆盖各会话最新摘要）
    final rows = await db.query(
      'local_chat_message',
      orderBy: 'create_time DESC',
      limit: 2000,
    );
    final seen = <String>{};
    for (final m in rows) {
      final chatId = m['chat_id']?.toString() ?? '';
      if (chatId.isEmpty || !seen.add(chatId)) continue;
      // 用户主动隐藏的会话跳过（不重建）
      if (hidden.contains(chatId)) continue;
      final senderId = (m['sender_id'] as num?)?.toInt() ?? 0;
      final receiverId = (m['receiver_id'] as num?)?.toInt() ?? 0;
      await upsertConversation(
        chatId: chatId,
        peerId: senderId == myUid ? receiverId : senderId,
        peerNickname: '',
        peerAvatar: '',
        lastMsgText: ChatStore.conversationPreview(m),
        lastMsgTime: (m['create_time'] as num?)?.toInt() ?? 0,
        unreadDelta: 0,
      );
    }
    // 清理：本地已无聊天记录的会话。
    // 保留"点击好友预建的会话窗口"（有昵称/头像但暂无消息），
    // 只清纯脏数据（无消息且无对端信息）。
    final convRows = await db.query('local_conversation');
    for (final c in convRows) {
      final chatId = c['chat_id']?.toString() ?? '';
      if (chatId.isEmpty || valid.contains(chatId)) continue;
      final hasPeerInfo =
          (c['peer_nickname']?.toString() ?? '').isNotEmpty ||
              (c['peer_avatar']?.toString() ?? '').isNotEmpty;
      if (hasPeerInfo) continue;
      await db.delete(
          'local_conversation', where: 'chat_id = ?', whereArgs: [chatId]);
    }
  }

  /// 会话摘要预览文本：图片消息显示 [图片]、表情消息显示 [表情]，
  /// 引用消息显示实际文本（不暴露加密 JSON 结构），不暴露原始 URL/JSON
  ///
  /// [row] 为 local_chat_message 行，至少含 msg_type / plaintext。
  static String conversationPreview(Map<String, dynamic> row) {
    final msgType = (row['msg_type'] as num?)?.toInt() ?? 1;
    if (msgType == 2) return '[图片]';
    if (msgType == 3) return '[表情]';
    // 渲染兜底：清洗非法 UTF-16 代理项（防会话列表 Text 崩溃）
    final text = sanitizeUtf16(row['plaintext']?.toString() ?? '');
    // 表情消息（评论/聊天通用占位格式 [sticker:xx]）
    if (RegExp(r'^\[sticker:.+\]$').hasMatch(text.trim())) {
      return '[表情]';
    }
    // 引用消息：body 为 {"text":"...","reply_to":{...}}，摘要只取实际文本
    if (text.startsWith('{')) {
      try {
        final j = jsonDecode(text);
        if (j is Map && j['text'] is String && j['reply_to'] is Map) {
          return j['text'] as String;
        }
      } catch (_) {}
    }
    return text;
  }

  /// 聊天图片本地缓存目录：**按账号隔离**（`chat_images/<uid>/`）。
  /// 不同账号的图片缓存互不可见/不覆盖；[uid]<=0 用公共子目录兜底。
  /// 老版本在无 uid 子目录下的旧文件仍可读（历史 image_local_path 存绝对路径）。
  static String chatImageDirFor(int uid) {
    final base = '${AppConfig.dataDir}${Platform.pathSeparator}chat_images';
    final safeUid = uid > 0 ? uid : 0;
    return '$base${Platform.pathSeparator}$safeUid';
  }

  /// 当前登录用户 id（聊天图片缓存目录按此隔离）
  int get currentUid => _uid;

  /// 删除本地上限 [paths] 内的图片缓存文件（存在才删）
  static Future<void> deleteLocalImages(List<String> paths) async {
    for (final p in paths) {
      try {
        if (p.isNotEmpty && File(p).existsSync()) {
          await File(p).delete();
        }
      } catch (_) {}
    }
  }

  /// 清空会话（"清空聊天记录"）：删除该会话所有本地消息、会话行、隐藏标记与本地图片缓存
  Future<void> clearChatMessages(String chatId) async {
    final db = await _database;
    final rows = await db.query(
      'local_chat_message',
      columns: ['image_local_path'],
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );
    await ChatStore.deleteLocalImages([
      for (final r in rows)
        if ((r['image_local_path'] as String? ?? '').isNotEmpty)
          r['image_local_path'] as String,
    ]);
    await db.delete('local_chat_message',
        where: 'chat_id = ?', whereArgs: [chatId]);
    await db.delete('hidden_conversation',
        where: 'chat_id = ?', whereArgs: [chatId]);
    await db.delete('local_conversation',
        where: 'chat_id = ?', whereArgs: [chatId]);
    _notifyUnreadChanged();
  }

  /// 本地已删除消息的服务器 msg_id 集合（内存缓存，防重复查询）
  Set<int> _deletedMsgIds = {};
  bool _deletedLoaded = false;

  Future<void> _ensureDeletedLoaded() async {
    if (_deletedLoaded) return;
    final db = await _database;
    final rows = await db.query('local_deleted_msg', columns: ['msg_id']);
    _deletedMsgIds = {
      for (final r in rows) (r['msg_id'] as num?)?.toInt() ?? 0
    }..remove(0);
    _deletedLoaded = true;
  }

  /// 该服务器消息 id 是否已在本地被删除（删除后拉历史/断线同步时过滤）
  Future<bool> isMsgDeleted(int msgId) async {
    if (msgId <= 0) return false;
    await _ensureDeletedLoaded();
    return _deletedMsgIds.contains(msgId);
  }

  /// 记录已删除消息的服务器 msg_id（防止服务器缓存中该消息"复活"）
  Future<void> markLocallyDeleted(List<int> msgIds) async {
    if (msgIds.isEmpty) return;
    final db = await _database;
    await _ensureDeletedLoaded();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (final id in msgIds) {
      if (id <= 0) continue;
      _deletedMsgIds.add(id);
      await db.insert(
        'local_deleted_msg',
        {'msg_id': id, 'delete_time': now},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  /// 批量删除本地消息（多选删除，仅本设备生效）：
  /// 记录服务器 msg_id（防拉历史"复活"）→ 删除消息行 → 清理本地图片缓存。
  Future<void> deleteMessagesByLocalIds(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _database;
    final unique = ids.toSet().toList();
    final ph = List.filled(unique.length, '?').join(',');
    // 先收集服务器 msg_id（防复活）与图片缓存路径，再删行
    final rows = await db.query(
      'local_chat_message',
      columns: ['msg_id', 'image_local_path'],
      where: 'id IN ($ph)',
      whereArgs: unique,
    );
    await markLocallyDeleted([
      for (final r in rows) (r['msg_id'] as num?)?.toInt() ?? 0,
    ]);
    await ChatStore.deleteLocalImages([
      for (final r in rows)
        if ((r['image_local_path'] as String? ?? '').isNotEmpty)
          r['image_local_path'] as String,
    ]);
    await db.delete('local_chat_message',
        where: 'id IN ($ph)', whereArgs: unique);
  }

  /// 删除/隐藏会话：
  /// - [purgeMessages]=true：彻底删除（本地聊天记录一并清除，空对话人清理用）
  /// - false：仅隐藏（保留聊天记录，重新收发消息后会自动恢复可见）
  Future<void> deleteConversation(String chatId,
      {bool purgeMessages = false}) async {
    final db = await _database;
    if (purgeMessages) {
      final rows = await db.query(
        'local_chat_message',
        columns: ['image_local_path'],
        where: 'chat_id = ?',
        whereArgs: [chatId],
      );
      await ChatStore.deleteLocalImages([
        for (final r in rows)
          if ((r['image_local_path'] as String? ?? '').isNotEmpty)
            r['image_local_path'] as String,
      ]);
      await db.delete('local_chat_message',
          where: 'chat_id = ?', whereArgs: [chatId]);
    } else {
      // 记录隐藏状态，防止 syncConversationsFromMessages 重新聚合出会话
      await db.insert('hidden_conversation', {'chat_id': chatId},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await db.delete('local_conversation',
        where: 'chat_id = ?', whereArgs: [chatId]);
    _notifyUnreadChanged();
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

  /// 按 chat_id 查询会话（离线消息通知取昵称/头像用）
  Future<Map<String, dynamic>?> getConversationByChatId(String chatId) async {
    final db = await _database;
    final rows = await db.query(
      'local_conversation',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
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
    _notifyUnreadChanged();
  }

  /// 所有会话未读总数（左侧导航消息角标用；未登录返回 0）
  Future<int> totalUnread() async {
    try {
      final db = await _database;
      final rows = await db.rawQuery(
          'SELECT COALESCE(SUM(unread_count), 0) AS t FROM local_conversation');
      return (rows.first['t'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
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
  /// 对方已读回执：标记"我发出的且 msg_id <= upToMsgId"的消息为已读
  Future<void> markMyMessagesRead(
      String chatId, int myUid, int upToMsgId) async {
    final db = await _database;
    await db.update(
      'local_chat_message',
      {'read_status': 1},
      where: 'chat_id = ? AND sender_id = ? AND msg_id > 0 AND msg_id <= ?',
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
    // 私钥用本机派生密钥加密后存储（防数据库文件泄露即明文泄露）
    final encryptedPriv =
        await SecureStorage.instance.encryptLocal(privateKey);
    await db.insert(
      'local_key_store',
      {
        'user_id': userId,
        'private_key': encryptedPriv,
        'public_key': publicKey,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 获取本地密钥对（私钥自动解密；旧版本明文私钥自动迁移为加密）
  ///
  /// 解密失败（换机器/换系统导致密钥派生变化）返回 null，
  /// 上层走"重新生成/claim 托管"流程自动恢复。
  Future<({String privateKey, String publicKey})?> getKeyPair(int userId) async {
    final db = await _database;
    final rows = await db.query(
      'local_key_store',
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    var priv = rows.first['private_key'] as String;
    final pub = rows.first['public_key'] as String;
    // 已加密：解密
    if (priv.startsWith('g1:')) {
      final decrypted = await SecureStorage.instance.decryptLocal(priv);
      if (decrypted == null) return null; // 本机解密失败 → 需重新生成
      priv = decrypted;
    } else {
      // 旧版本明文私钥：加密回写迁移
      await saveKeyPair(userId: userId, privateKey: priv, publicKey: pub);
    }
    return (privateKey: priv, publicKey: pub);
  }
}
