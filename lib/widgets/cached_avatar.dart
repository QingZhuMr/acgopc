import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/app_config.dart';
import '../utils/net_image.dart';

/// 头像磁盘缓存组件
///
/// 好友头像本地缓存（`<dataDir>/avatar_cache/<url哈希>`），**好友不换头像时
/// 不再重复网络加载**（同一头像多次打开会话/列表只读一次磁盘文件）：
/// - 缓存命中 → `Image.file`（Flutter 内存 ImageCache 二次加速）
/// - 缓存未命中 → `NetImage` 显示 + 后台 http 下载落盘，下次命中
/// - 换头像（url 变化）→ 哈希不同 → 自动重新下载，互不影响
/// - 下载成功后顺带清理超过 [maxAge] 天的旧头像缓存（防无限累积）
class CachedAvatar extends StatefulWidget {
  /// 云端头像地址（相对或绝对路径，内部 resolve）
  final String url;

  /// 头像边长（正方形）
  final double size;

  /// 占位首字母（url 为空或加载失败时显示昵称首字）
  final String fallbackText;

  /// 缓存最长保留天数（超过则重新下载）
  final int maxAgeDays;

  const CachedAvatar({
    super.key,
    required this.url,
    required this.size,
    this.fallbackText = '',
    this.maxAgeDays = 7,
  });

  @override
  State<CachedAvatar> createState() => _CachedAvatarState();
}

class _CachedAvatarState extends State<CachedAvatar> {
  String? _cachedPath;
  bool _downloading = false;
  Timer? _debounce;

  static String get _dir =>
      '${AppConfig.dataDir}${Platform.pathSeparator}avatar_cache';

  static String _fileFor(String url) {
    final h = url.hashCode.abs().toRadixString(16);
    return '$_dir${Platform.pathSeparator}$h.img';
  }

  @override
  void initState() {
    super.initState();
    _cachedPath = _existingCache();
    if (_cachedPath == null && widget.url.isNotEmpty) {
      // 延迟到首帧后再下载，避免 build 期间触发网络
      _debounce = Timer(const Duration(milliseconds: 300), _downloadAndCache);
    }
  }

  @override
  void didUpdateWidget(covariant CachedAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _cachedPath = _existingCache();
      _debounce?.cancel();
      if (_cachedPath == null && widget.url.isNotEmpty) {
        _debounce = Timer(const Duration(milliseconds: 300), _downloadAndCache);
      }
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// 检查缓存文件是否存在（存在且未过期则返回路径）
  String? _existingCache() {
    final url = widget.url.trim();
    if (url.isEmpty) return null;
    final f = File(_fileFor(url));
    if (!f.existsSync()) return null;
    final age = DateTime.now().difference(f.lastModifiedSync()).inDays;
    if (age >= widget.maxAgeDays) {
      try {
        f.deleteSync();
      } catch (_) {}
      return null;
    }
    return f.path;
  }

  Future<void> _downloadAndCache() async {
    final url = widget.url.trim();
    if (url.isEmpty || _downloading) return;
    _downloading = true;
    try {
      final resp = await http
          .get(Uri.parse(AppConfig.resolveUrl(url)))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return;
      final dir = Directory(_dir);
      if (!dir.existsSync()) await dir.create(recursive: true);
      final f = File(_fileFor(url));
      await f.writeAsBytes(resp.bodyBytes, flush: true);
      _cleanupOldFiles();
      if (mounted) setState(() => _cachedPath = f.path);
    } catch (_) {
      // 下载失败：保留 NetImage 占位显示，不写坏缓存
    } finally {
      _downloading = false;
    }
  }

  /// 清理超过 maxAge 天的旧头像缓存（本组件下载成功后调用）
  void _cleanupOldFiles() {
    try {
      final dir = Directory(_dir);
      if (!dir.existsSync()) return;
      final cutoff = DateTime.now()
          .subtract(Duration(days: widget.maxAgeDays));
      for (final e in dir.listSync()) {
        try {
          if (e is File && e.lastModifiedSync().isBefore(cutoff)) {
            e.deleteSync();
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final path = _cachedPath;
    if (path != null) {
      return ClipOval(
        child: Image.file(
          File(path),
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          // 缓存文件损坏时回退网络
          errorBuilder: (_, __, ___) => _networkFallback(),
        ),
      );
    }
    return _networkFallback();
  }

  Widget _networkFallback() {
    return ClipOval(
      child: NetImage(
        url: widget.url,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        loadingSize: widget.size >= 40 ? 16 : 14,
        errorIconSize: widget.size >= 40 ? 16 : 14,
        errorIconColor: Colors.grey,
      ),
    );
  }
}
