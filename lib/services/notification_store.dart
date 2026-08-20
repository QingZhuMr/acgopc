import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/app_config.dart';

/// 通知本地缓存（SQLite）
///
/// 与聊天缓存（`ChatStore`）同款模式：按账号隔离（`acgo_notification_<uid>.db`），
/// 桌面端走 sqflite ffi、移动端走原生实现。缓存服务端通知列表第一页 + 未读数，
/// 打开通知页先读缓存秒出，网络拉取成功后覆盖刷新；已读 / 删除 / 全部已读
/// 同步更新缓存，避免重复操作后状态回跳。
class NotificationStore {
  NotificationStore._();
  static final NotificationStore instance = NotificationStore._();

  Database? _db;

  /// 当前登录用户 id（0=未登录）；通知缓存按账号隔离
  int _uid = 0;

  /// 当前已打开连接所属用户 id（用于判断连接是否匹配当前账号）
  int _dbUid = 0;

  /// sqflite ffi factory 是否已初始化（桌面端全局唯一，重复设置会打印警告）
  static bool _ffiInitDone = false;

  /// 登录后调用：切换通知缓存库到该账号专属文件（`acgo_notification_<uid>.db`）
  Future<void> openForUser(int uid) async {
    if (uid <= 0 || uid == _uid) return;
    final old = _db;
    _db = null;
    _dbUid = 0;
    _uid = uid;
    if (old != null) {
      try {
        await old.close();
      } catch (_) {}
    }
  }

  /// 退出登录调用：关闭缓存库连接（下次登录重新按新账号打开）
  Future<void> closeForUser() async {
    final old = _db;
    _db = null;
    _dbUid = 0;
    _uid = 0;
    if (old != null) {
      try {
        await old.close();
      } catch (_) {}
    }
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
    final db = await _openDb(
        _uid > 0 ? 'acgo_notification_$_uid.db' : 'acgo_notification.db');
    _db = db;
    _dbUid = _uid;
    return db;
  }

  Future<Database> _openDb(String fileName) async {
    final target = p.join(AppConfig.dataDir, fileName);
    return openDatabase(
      target,
      version: 1,
      onCreate: (db, version) async {
        // 通知条目整条 JSON 存储（字段动态：聚合条目含 id_list/from_uids 等）
        await db.execute('''
          CREATE TABLE local_notification (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            data TEXT NOT NULL,
            sort_time INTEGER NOT NULL DEFAULT 0,
            is_read INTEGER NOT NULL DEFAULT 0
          )
        ''');
        // 未读数等 key-value 元信息
        await db.execute('''
          CREATE TABLE local_notification_meta (
            meta_key TEXT PRIMARY KEY,
            meta_value TEXT NOT NULL
          )
        ''');
      },
    );
  }

  /// 该通知条目的 id 集合（聚合条目取 id_list，单条取 [id]）
  static List<int> _idList(Map<String, dynamic> n) {
    final raw = n['id_list'];
    if (raw is List && raw.isNotEmpty) {
      return raw
          .map((e) => (e as num?)?.toInt() ?? 0)
          .where((e) => e > 0)
          .toList();
    }
    final id = (n['id'] as num?)?.toInt() ?? 0;
    return id > 0 ? [id] : [];
  }

  static bool _isRead(Map<String, dynamic> n) =>
      ((n['is_read'] as num?)?.toInt() ?? 0) == 1;

  static int _sortTime(Map<String, dynamic> n) =>
      (n['create_time'] as num?)?.toInt() ?? 0;

  /// 保存第一页缓存（覆盖式）：清空旧数据 + 写入新列表 + 更新未读数
  Future<void> saveFirstPage(List<Map<String, dynamic>> items, int unread) async {
    try {
      final db = await _database;
      await db.delete('local_notification');
      for (final n in items) {
        await db.insert('local_notification', {
          'data': jsonEncode(n),
          'sort_time': _sortTime(n),
          'is_read': _isRead(n) ? 1 : 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await _saveMeta(db, 'unread_count', '$unread');
    } catch (_) {
      // 缓存失败不影响主流程
    }
  }

  /// 单独更新未读数缓存（拉取未读接口成功后调用）
  Future<void> saveUnread(int unread) async {
    try {
      final db = await _database;
      await _saveMeta(db, 'unread_count', '$unread');
    } catch (_) {}
  }

  /// 追加后续页缓存（去重：与缓存中 id 集合无交集的才写入）
  Future<void> appendPage(List<Map<String, dynamic>> items) async {
    try {
      final db = await _database;
      final rows = await db.query('local_notification', columns: ['data']);
      final cachedIds = <int>{
        for (final r in rows)
          ..._idList(jsonDecode(r['data'] as String) as Map<String, dynamic>),
      };
      for (final n in items) {
        final ids = _idList(n);
        if (ids.isEmpty || ids.any(cachedIds.contains)) continue;
        await db.insert('local_notification', {
          'data': jsonEncode(n),
          'sort_time': _sortTime(n),
          'is_read': _isRead(n) ? 1 : 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        cachedIds.addAll(ids);
      }
    } catch (_) {}
  }

  /// 读缓存：无缓存（从未成功拉取过）返回 null
  Future<({List<Map<String, dynamic>> items, int unread})?> loadCached() async {
    try {
      final db = await _database;
      final rows = await db.query('local_notification', orderBy: 'sort_time DESC');
      if (rows.isEmpty) return null;
      final items = <Map<String, dynamic>>[
        for (final r in rows)
          jsonDecode(r['data'] as String) as Map<String, dynamic>,
      ];
      final unread = await _readMetaInt(db, 'unread_count');
      return (items: items, unread: unread);
    } catch (_) {
      return null;
    }
  }

  /// 标记某通知（聚合内所有 id）已读：同步更新缓存条目与未读数
  Future<void> markRead(int id) async {
    if (id <= 0) return;
    try {
      final db = await _database;
      final rows = await db.query('local_notification');
      for (final r in rows) {
        final n = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        final ids = _idList(n);
        if (!ids.contains(id) || _isRead(n)) continue;
        n['is_read'] = 1;
        await db.update(
          'local_notification',
          {'data': jsonEncode(n), 'is_read': 1},
          where: 'id = ?',
          whereArgs: [r['id']],
        );
        await _changeUnread(db, -ids.length);
      }
    } catch (_) {}
  }

  /// 一键全部已读：本地缓存全部置已读 + 未读数清零
  Future<void> markAllRead() async {
    try {
      final db = await _database;
      final rows = await db.query('local_notification');
      for (final r in rows) {
        final n = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        if (_isRead(n)) continue;
        n['is_read'] = 1;
        await db.update(
          'local_notification',
          {'data': jsonEncode(n), 'is_read': 1},
          where: 'id = ?',
          whereArgs: [r['id']],
        );
      }
      await _saveMeta(db, 'unread_count', '0');
    } catch (_) {}
  }

  /// 删除通知（批量）：删除缓存中包含任一 id 的条目，并重算未读数
  Future<void> deleteByIds(List<int> ids) async {
    if (ids.isEmpty) return;
    final idSet = ids.toSet();
    try {
      final db = await _database;
      final rows = await db.query('local_notification');
      for (final r in rows) {
        final n = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        final list = _idList(n);
        if (!list.any(idSet.contains)) continue;
        if (!_isRead(n)) await _changeUnread(db, -list.length);
        await db.delete('local_notification',
            where: 'id = ?', whereArgs: [r['id']]);
      }
    } catch (_) {}
  }

  Future<void> _saveMeta(Database db, String key, String value) async {
    await db.insert('local_notification_meta', {
      'meta_key': key,
      'meta_value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<int> _readMetaInt(Database db, String key) async {
    final rows = await db.query('local_notification_meta',
        where: 'meta_key = ?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return 0;
    return int.tryParse(rows.first['meta_value']?.toString() ?? '') ?? 0;
  }

  /// 未读数增减（不低于 0）
  Future<void> _changeUnread(Database db, int delta) async {
    if (delta == 0) return;
    final cur = await _readMetaInt(db, 'unread_count');
    final next = cur + delta < 0 ? 0 : cur + delta;
    await _saveMeta(db, 'unread_count', '$next');
  }

  /// 当前登录用户 id（与 ChatStore 一致，供上层判断）
  int get currentUid => _uid;
}
