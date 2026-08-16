import 'package:flutter/material.dart';

import '../core/app_config.dart';
import '../core/app_theme.dart';

/// 通用网络图片组件：统一「加载中占位 + 加载失败占位」，
/// 图片加载不出来时显示底色 + 破损图标，不再空白一片。
///
/// 头像不适用本组件：头像有专属的圆形首字兜底
/// （_UserAvatar / _AvatarBox / _NotifyAvatar / _Avatar）。
class NetImage extends StatelessWidget {
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
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final bg = bgColor ?? bgHoverColor(b);
    final loading = Container(
      width: width,
      height: height,
      color: bg,
      alignment: Alignment.center,
      child: SizedBox(
        width: loadingSize,
        height: loadingSize,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: spinnerColor ?? Theme.of(context).colorScheme.primary,
        ),
      ),
    );
    final errorBox = Container(
      width: width,
      height: height,
      color: bg,
      alignment: Alignment.center,
      child: Icon(
        errorIcon,
        size: errorIconSize,
        color: errorIconColor ?? textFaintColor(b),
      ),
    );
    return Image.network(
      AppConfig.resolveUrl(url),
      width: width,
      height: height,
      fit: fit,
      cacheWidth: cacheWidth,
      filterQuality: FilterQuality.medium,
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : loading,
      errorBuilder: (context, error, stackTrace) => errorBox,
    );
  }
}
