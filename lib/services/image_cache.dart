import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/app_config.dart';
import 'chat_store.dart';

/// 图片磁盘缓存（单例）
///
/// **所有缓存均按用户隔离**：目录 `<dataDir>/image_cache/<uid>/<url哈希>.img`，
/// 不同账号互不可见/不覆盖；切换账号自动切目录（读 [ChatStore.currentUid]）。
///
/// 用途：帖子/评论图片等网络图片避免每次打开重复加载；
/// 头像用专属 `CachedAvatar`（独立目录）。
/// 7 天后自动清理：每次写入成功后清理过期文件 + 记录文件访问时间。
///
/// 线程安全：单条下载并发由调用方控制；写入用临时文件 + rename 防半写。
class ImageCache {
  ImageCache._();

  static final ImageCache instance = ImageCache._();

  /// 缓存最长保留天数
  static const int maxAgeDays = 7;

  static String _dirFor(int uid) {
    final base =
        '${AppConfig.dataDir}${Platform.pathSeparator}image_cache';
    return '$base${Platform.pathSeparator}${uid > 0 ? uid : 0}';
  }

  static String _fileFor(String url, int uid) {
    final h = url.hashCode.abs().toRadixString(16);
    return '${_dirFor(uid)}${Platform.pathSeparator}$h.img';
  }

  /// 获取本地缓存路径；无缓存返回 null
  String? getCachedPath(String url) {
    final urlT = url.trim();
    if (urlT.isEmpty) return null;
    final f = File(_fileFor(urlT, ChatStore.instance.currentUid));
    if (!f.existsSync()) return null;
    return f.path;
  }

  /// 读取缓存字节；无缓存/已过期返回 null
  Future<List<int>?> readCached(String url) async {
    final path = getCachedPath(url);
    if (path == null) return null;
    try {
      final f = File(path);
      final age = DateTime.now().difference(f.lastModifiedSync()).inDays;
      if (age >= maxAgeDays) {
        try {
          f.deleteSync();
        } catch (_) {}
        return null;
      }
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// 下载并写入缓存（返回字节；失败返回 null）
  Future<List<int>?> downloadToCache(String url) async {
    final urlT = url.trim();
    if (urlT.isEmpty) return null;
    try {
      final resp = await http
          .get(Uri.parse(AppConfig.resolveUrl(urlT)))
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return null;
      final bytes = resp.bodyBytes;
      final f = File(_fileFor(urlT, ChatStore.instance.currentUid));
      final dir = f.parent;
      if (!dir.existsSync()) await dir.create(recursive: true);
      // 临时文件 + rename 防半写
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
      await tmp.rename(f.path);
      _cleanup(dir.path);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// 清理超过 [maxAgeDays] 天的缓存文件（每次写入成功后调用）
  void _cleanup(String dirPath) {
    try {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) return;
      final cutoff = DateTime.now().subtract(const Duration(days: maxAgeDays));
      for (final e in dir.listSync()) {
        try {
          if (e is File && e.lastModifiedSync().isBefore(cutoff)) {
            e.deleteSync();
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 清除当前用户全部图片缓存（设置页「清除缓存」）
  Future<void> clearCurrentUser() async {
    try {
      final dir = Directory(_dirFor(ChatStore.instance.currentUid));
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }

  /// 清除全部用户的图片缓存（退出登录/切换账号时可选调用）
  Future<void> clearAll() async {
    try {
      final base = '${AppConfig.dataDir}${Platform.pathSeparator}image_cache';
      final dir = Directory(base);
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }

  /// 当前用户缓存占用字节数（设置页展示用）
  Future<int> currentUserBytes() async {
    try {
      final dir = Directory(_dirFor(ChatStore.instance.currentUid));
      if (!dir.existsSync()) return 0;
      var total = 0;
      await for (final e in dir.list(recursive: true)) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {}
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }
}
