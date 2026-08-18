import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderImage;

import '../core/app_config.dart';
import '../core/app_theme.dart';
import '../services/image_cache.dart' as disk_cache;

/// 通用网络图片组件：统一「加载中占位 + 加载失败占位」，
/// 图片加载不出来时显示底色 + 破损图标，不再空白一片。
///
/// **磁盘缓存**：帖子/评论等图片会缓存到本地（`ImageCache`，按用户隔离、
/// 7 天自动清理），避免每次打开重复加载；头像不适用（走 `CachedAvatar`）。
class NetImage extends StatefulWidget {
  /// 图片路径（相对路径或完整 URL 均可，内部统一 resolve）
  final String url;

  final double? width;
  final double? height;
  final BoxFit fit;

  /// 限制解码尺寸（px），降低内存与解码开销
  final int? cacheWidth;

  /// 占位背景色；默认跟随主题的 hover 底色
  final Color? bgColor;

  /// 加载中转圈大小
  final double loadingSize;

  /// 加载中转圈颜色；默认主题主色
  final Color? spinnerColor;

  /// 加载失败图标
  final IconData errorIcon;

  /// 加载失败图标大小
  final double errorIconSize;

  /// 加载失败图标颜色；默认主题弱化色
  final Color? errorIconColor;

  /// 加载失败回调（图片 404/网络错误时触发；用于自动清理失效资源等）
  final VoidCallback? onError;

  /// 图片解码完成回调（携带实际宽高；磁盘缓存命中同样触发）。
  /// 注意：受 `cacheWidth` 影响返回缩放后尺寸，但宽高比与原图一致。
  final void Function(int width, int height)? onLoaded;

  /// 是否启用磁盘缓存（默认 true；实时性要求高的场景可关）
  final bool useDiskCache;

  const NetImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.bgColor,
    this.loadingSize = 18,
    this.spinnerColor,
    this.errorIcon = Icons.broken_image_outlined,
    this.errorIconSize = 24,
    this.errorIconColor,
    this.onError,
    this.onLoaded,
    this.useDiskCache = true,
  });

  @override
  State<NetImage> createState() => _NetImageState();
}

class _NetImageState extends State<NetImage> {
  bool _checkedCache = false;
  Uint8List? _memBytes;
  bool _reportedSize = false;

  @override
  void didUpdateWidget(covariant NetImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _checkedCache = false;
      _memBytes = null;
      _reportedSize = false;
    }
  }

  /// 图片解码完成后回调实际宽高（内存/网络两个分支共用）。
  /// 用 [RenderImage] 拿解码后尺寸：受 `cacheWidth` 影响为缩放尺寸，但宽高比与原图一致。
  /// 注意：静态图 `frame` 恒为 null（动画图才有帧号），不能依赖它判断"已加载"，
  /// 而是在 post-frame 检查 findRenderObject 是否已是 RenderImage。
  Widget _frameBuilder(
      BuildContext context, Widget child, int? frame, bool wasSynchronouslyLoaded) {
    final cb = widget.onLoaded;
    if (cb == null || _reportedSize) return child;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _reportedSize) return;
      final render = context.findRenderObject();
      if (render is RenderImage && render.image != null) {
        _reportedSize = true;
        cb(render.image!.width, render.image!.height);
      }
    });
    return child;
  }

  Future<void> _tryDiskCache() async {
    if (!widget.useDiskCache || _checkedCache) return;
    _checkedCache = true;
    final bytes = await disk_cache.ImageCache.instance.readCached(widget.url);
    if (!mounted || bytes == null) return;
    _memBytes = Uint8List.fromList(bytes);
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _tryDiskCache();
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final Color bg = widget.bgColor ?? bgHoverColor(b);
    final loading = Container(
      width: widget.width,
      height: widget.height,
      color: bg,
      alignment: Alignment.center,
      child: SizedBox(
        width: widget.loadingSize,
        height: widget.loadingSize,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: widget.spinnerColor ?? Theme.of(context).colorScheme.primary,
        ),
      ),
    );
    final errorBox = Container(
      width: widget.width,
      height: widget.height,
      color: bg,
      alignment: Alignment.center,
      child: Icon(
        widget.errorIcon,
        size: widget.errorIconSize,
        color: widget.errorIconColor ?? textFaintColor(b),
      ),
    );
    // 磁盘缓存命中 → 直接用内存字节展示（不再请求网络）
    final mem = _memBytes;
    if (mem != null) {
      return Image.memory(
        mem,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        cacheWidth: widget.cacheWidth,
        filterQuality: FilterQuality.medium,
        frameBuilder: _frameBuilder,
        errorBuilder: (_, __, ___) {
          _memBytes = null;
          return errorBox;
        },
      );
    }
    return Image.network(
      AppConfig.resolveUrl(widget.url),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      cacheWidth: widget.cacheWidth,
      filterQuality: FilterQuality.medium,
      frameBuilder: _frameBuilder,
      loadingBuilder: (context, child, progress) {
        // 加载完成：后台下载并写磁盘缓存（供下次打开直接命中）
        if (progress == null && widget.useDiskCache) {
          unawaited(_writeCacheAfterLoad());
        }
        return progress == null ? child : loading;
      },
      errorBuilder: (context, error, stackTrace) {
        widget.onError?.call();
        return errorBox;
      },
    );
  }

  Future<void> _writeCacheAfterLoad() async {
    // 已从磁盘命中则不重复下载
    if (_memBytes != null) return;
    await disk_cache.ImageCache.instance.downloadToCache(widget.url);
  }
}
