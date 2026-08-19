import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../utils/text_sanitize.dart';
import '../../widgets/text_input_menu.dart';

/// 计数入口（关注/粉丝等）：数字 + 标签
class CountEntry extends StatelessWidget {
  final String label;
  final int count;
  final VoidCallback onTap;

  const CountEntry({
    super.key,
    required this.label,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return InkWell(
      onTap: onTap,
      mouseCursor: SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(kRadiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$count',
              style: TextStyle(
                fontSize: 14,
                height: 1.0,
                fontWeight: FontWeight.w700,
                color: textColor(b),
              ),
            ),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                height: 1.0,
                color: textMutedColor(b),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 个人中心顶部 tab（动态 / 收藏 / 历史）胶囊切换按钮
class ProfileTab extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  const ProfileTab({
    super.key,
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? primarySoftColor(b) : Colors.transparent,
            borderRadius: BorderRadius.circular(kRadiusBtn),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? kPrimary : textSecondaryColor(b),
                ),
              ),
              if (count > 0) ...[
                const SizedBox(width: 6),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 13,
                    color: selected ? kPrimary : textMutedColor(b),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 我的收藏 / 我的动态：加载失败重试
class FavRetry extends StatelessWidget {
  final VoidCallback onRetry;
  final String label;
  const FavRetry({super.key, required this.onRetry, this.label = '收藏加载失败'});

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 42, color: textMutedColor(b)),
            const SizedBox(height: 12),
            Text(label,
                style: TextStyle(fontSize: 14, color: textMutedColor(b))),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重试'),
              style: OutlinedButton.styleFrom(
                foregroundColor: kPrimary,
                side: const BorderSide(color: kPrimary, width: 1.2),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 我的收藏 / 我的动态：空态（可自定义图标 / 文案）
class EmptyFavorites extends StatelessWidget {
  final Brightness b;
  final IconData icon;
  final String title;
  final String subtitle;
  const EmptyFavorites({
    super.key,
    required this.b,
    this.icon = Icons.bookmark_border,
    this.title = '还没有收藏任何动态',
    this.subtitle = '去广场逛逛，看到喜欢的内容点个收藏吧',
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 48),
      decoration: BoxDecoration(
        color: bgHoverColor(b),
        borderRadius: BorderRadius.circular(kRadiusMd),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: textMutedColor(b)),
          const SizedBox(height: 12),
          Text(title,
              style: TextStyle(fontSize: 14, color: textMutedColor(b))),
          const SizedBox(height: 6),
          Text(subtitle,
              style: TextStyle(fontSize: 12, color: textMutedColor(b))),
        ],
      ),
    );
  }
}

/// 状态徽标：正常（绿）/ 封禁（红）
class StatusBadge extends StatelessWidget {
  final bool banned;
  const StatusBadge({super.key, required this.banned});

  @override
  Widget build(BuildContext context) {
    final fg = banned ? kDanger : kSuccess;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(kRadiusSm),
      ),
      child: Text(
        banned ? '封禁' : '正常',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }
}

/// 密码输入框
class PwdField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final Brightness brightness;

  const PwdField({
    super.key,
    required this.label,
    required this.controller,
    required this.brightness,
  });

  @override
  Widget build(BuildContext context) {
    return TextInputBubbleMenu(
      controller: controller,
      obscure: true,
      child: TextField(
        controller: controller,
        obscureText: true,
        // 禁用系统右键菜单（统一用气泡方案）
        contextMenuBuilder: (_, __) => const SizedBox.shrink(),
        // 过滤粘贴/输入的非法 UTF-16 代理项（防渲染崩溃）
        inputFormatters: const [Utf16SanitizeTextInputFormatter()],
        style: TextStyle(color: textColor(brightness)),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: textMutedColor(brightness)),
          filled: true,
          fillColor: bgColor(brightness),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(kRadiusMd),
            borderSide: BorderSide(
                color: textFaintColor(brightness).withValues(alpha: .3)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(kRadiusMd),
            borderSide: const BorderSide(color: kPrimary, width: 1.5),
          ),
        ),
      ),
    );
  }
}
