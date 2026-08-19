import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import 'cached_avatar.dart';

/// 用户头像：有 URL 时显示图片，加载失败 fallback 到昵称首字
class UserAvatar extends StatelessWidget {
  final String? avatarUrl;
  final String nickname;
  final double size;

  const UserAvatar({
    super.key,
    required this.avatarUrl,
    required this.nickname,
    this.size = 36,
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final initial = _initialText(nickname);

    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: primarySoftColor(b),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          fontSize: size * 0.4,
          fontWeight: FontWeight.w600,
          color: kPrimary,
        ),
      ),
    );

    if (avatarUrl == null || avatarUrl!.isEmpty) {
      return placeholder;
    }

    // 头像磁盘缓存：好友/作者不换头像时不重复网络加载
    // （缓存文件损坏时 CachedAvatar 内部回退网络加载）
    return CachedAvatar(
      url: avatarUrl!,
      size: size,
      fallbackText: nickname,
    );
  }

  /// 取昵称首字（最多2字），处理空字符串
  String _initialText(String name) {
    final s = name.trim();
    if (s.isEmpty) return '?';
    if (s.length <= 2) return s;
    return s.substring(0, 2);
  }
}
