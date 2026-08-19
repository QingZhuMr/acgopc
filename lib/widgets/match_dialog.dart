import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import 'cached_avatar.dart';

/// 配对信息（来自 WS `match_notice` 推送或本地配对成功回调）
class MatchInfo {
  /// 对方用户 id
  final int uid;

  /// 对方昵称
  final String nickname;

  /// 对方头像
  final String avatar;

  /// 对方填写的资料（gender/age/income_range/personality/city/face_score/edu_level）
  final Map<String, dynamic>? profile;

  /// 配对发生的星球名
  final String? planetName;

  /// 对应的通知 id（用于点击按钮后标记已读）
  final int? notificationId;

  const MatchInfo({
    required this.uid,
    required this.nickname,
    required this.avatar,
    this.profile,
    this.planetName,
    this.notificationId,
  });
}

/// 配对成功全局弹窗
///
/// - 显示对方头像 / 昵称 / 填写的资料
/// - 无法在应用内手动关闭（不可点遮罩、不可按 ESC/返回键、无关闭按钮）
/// - 只有点击「去聊天」按钮才会关闭并结束该通知回调：
///   按钮点击后触发 [onOpenChat]，返回值 true 表示通知流程已结束。
Future<bool> showMatchDialog(
  BuildContext context,
  MatchInfo info, {
  required VoidCallback onOpenChat,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black54,
    useRootNavigator: true,
    builder: (_) => PopScope(
      canPop: false,
      child: _MatchDialogContent(
        info: info,
        onOpenChat: () {
          navigator.pop(true);
          onOpenChat();
        },
      ),
    ),
  );
  return result ?? false;
}

/// 弹窗内容
class _MatchDialogContent extends StatelessWidget {
  final MatchInfo info;
  final VoidCallback onOpenChat;

  const _MatchDialogContent({
    required this.info,
    required this.onOpenChat,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? DarkColors.bgSoft : LightColors.bgSoft;
    final subColor = dark ? Colors.white60 : Colors.black54;

    return AlertDialog(
      backgroundColor: bg,
      shape: RoundedRectangleBorder(borderRadius: kRadiusCardAll),
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      title: Column(
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.favorite_rounded, color: Color(0xFFFF4D6D), size: 22),
              SizedBox(width: 8),
              Text('配对成功', style: TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${info.nickname} 在「${info.planetName ?? '星球'}」星球和你配对了',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: subColor),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 6),
          _buildAvatar(info.avatar, 64),
          const SizedBox(height: 10),
          Text(
            info.nickname,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          _buildProfileCard(info.profile, dark),
          const SizedBox(height: 10),
          Text(
            '你们已成为绑定人，互相自动关注；解除绑定前将保持好友关系',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: subColor),
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        SizedBox(
          width: double.infinity,
          height: 42,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: kPrimary,
              shape: RoundedRectangleBorder(borderRadius: kRadiusBtnAll),
            ),
            onPressed: onOpenChat,
            child: const Text(
              '去聊天',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }

  /// 对方资料卡片（显示填写的资料，无资料时不展示）
  Widget _buildProfileCard(Map<String, dynamic>? profile, bool dark) {
    final lines = _profileLines(profile);
    if (lines.isEmpty) return const SizedBox.shrink();

    final chipBg = dark ? Colors.white10 : Colors.black.withValues(alpha: 0.05);
    final chipColor = dark ? Colors.white70 : Colors.black87;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: chipBg,
        borderRadius: kRadiusMdAll,
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final line in lines)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: dark ? Colors.white12 : Colors.black.withValues(alpha: 0.06),
                borderRadius: kRadiusSmAll,
              ),
              child: Text(
                line,
                style: TextStyle(fontSize: 12, color: chipColor),
              ),
            ),
        ],
      ),
    );
  }

  /// 圆形头像（复用磁盘缓存组件，url 为空/加载失败显示昵称首字占位）
  Widget _buildAvatar(String avatar, double size) {
    return CachedAvatar(
      url: avatar,
      size: size,
      fallbackText:
          info.nickname.isNotEmpty ? info.nickname.characters.first : '',
    );
  }

  /// 把资料字段转成一行行文案
  List<String> _profileLines(Map<String, dynamic>? p) {
    if (p == null || p.isEmpty) return const [];
    final lines = <String>[];

    // 基础信息：性别 · 年龄 · 城市
    final parts = <String>[];
    final gender = p['gender'];
    if (gender is num) parts.add(gender.toInt() == 1 ? '男' : '女');
    final age = p['age'];
    if (age is num) parts.add('${age.toInt()}岁');
    final city = p['city'];
    if (city is String && city.isNotEmpty) parts.add(city);
    if (parts.isNotEmpty) lines.add(parts.join(' · '));

    final income = p['income_range'];
    if (income is String && income.isNotEmpty) lines.add('收入 $income');
    final edu = p['edu_level'];
    if (edu is String && edu.isNotEmpty) lines.add('学历 $edu');
    final personality = p['personality'];
    if (personality is String && personality.isNotEmpty) lines.add('性格 $personality');
    final face = p['face_score'];
    if (face is num) lines.add('颜值 ${face.toInt()}/10');

    return lines;
  }
}
