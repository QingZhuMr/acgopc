import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/app_config.dart';
import 'chat_store.dart';

/// 聊天图片本地缓存（微信同款机制）
///
/// 核心思路：
/// - **发送方**：上传图片拿 URL 的同时，把图片字节直接写入本地缓存目录；
/// - **接收方**：收到图片消息（WS 推送/拉历史/断线同步）→ 异步下载并缓存到本地，
///   展示时优先读本地文件，不再每次从云端拉取；
/// - **云端只作中转**：服务器图片缓存 30 天后清理（与消息密文同生命周期），
///   只要有一端收到过图片，本地就永久保留；其他设备上线后通过断线同步
///   拉到消息时顺带下载补缓存；云端过期且从未下载过的端拿不到图（同消息数据）。
class ChatImageCache {
  static String? _cacheDir;

  /// 当前缓存目录所属账号（切换账号时重建目录，实现缓存隔离）
  static int _cacheUid = 0;

  /// 图片缓存目录（懒创建，按账号隔离：`chat_images/<uid>/`）
  static Future<String> get dir async {
    final uid = ChatStore.instance.currentUid;
    if (_cacheDir == null || _cacheUid != uid) {
      final d = ChatStore.chatImageDirFor(uid);
      if (!Directory(d).existsSync()) {
        await Directory(d).create(recursive: true);
      }
      _cacheDir = d;
      _cacheUid = uid;
    }
    return _cacheDir!;
  }

  /// 从消息 body（{"url":...}）解析图片 URL
  static String parseUrl(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map) return json['url']?.toString() ?? '';
    } catch (_) {}
    return '';
  }

  /// 本地缓存文件名：按 URL 哈希，保证同一 URL 只缓存一份（幂等）
  static String _fileName(String url) {
    final hash = _hash(url);
    final ext = _extOf(url);
    return 'img_${hash.substring(0, 16)}.$ext';
  }

  static String _extOf(String url) {
    final m = RegExp(r'\.(jpg|jpeg|png|gif|webp)(\?|$)',
        caseSensitive: false).firstMatch(url);
    final e = m?.group(1)?.toLowerCase() ?? '';
    if (e == 'jpeg') return 'jpg';
    return e.isEmpty ? 'jpg' : e;
  }

  /// 确定性哈希（FNV-1a），仅用于文件名唯一性标识
  static String _hash(String input) {
    final bytes = utf8.encode(input);
    var hash = 0x811c9dc5;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    final h1 = hash.toRadixString(16).padLeft(8, '0');
    final h2 = (hash ^ bytes.length * 0x9E3779B9).toRadixString(16);
    return '$h1$h2';
  }

  /// 查询本地缓存路径（存在返回，否则 null）
  static Future<String?> cachedPathFor(String url) async {
    if (url.isEmpty) return null;
    final d = await dir;
    final p = '$d${Platform.pathSeparator}${_fileName(url)}';
    return File(p).existsSync() ? p : null;
  }

  /// 确保图片已本地缓存：
  /// - [bytes] 非空（发送方场景）直接写入；
  /// - 否则从云端下载；
  /// 返回本地路径（成功）或 null（失败）。
  static Future<String?> ensureCached(String url, {List<int>? bytes}) async {
    if (url.isEmpty) return null;
    final existing = await cachedPathFor(url);
    if (existing != null) return existing;
    final d = await dir;
    final target = '$d${Platform.pathSeparator}${_fileName(url)}';
    try {
      if (bytes != null && bytes.isNotEmpty) {
        await File(target).writeAsBytes(bytes, flush: true);
        return target;
      }
      final resp = await http
          .get(Uri.parse(AppConfig.resolveUrl(url)))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
        await File(target).writeAsBytes(resp.bodyBytes, flush: true);
        return target;
      }
    } catch (_) {
      // 下载失败：回退云端 URL 展示，下次再触发缓存
    }
    return null;
  }
}
