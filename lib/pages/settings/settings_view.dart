import 'dart:io';

import 'package:flutter/material.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../../core/app_config.dart';
import '../../core/app_theme.dart';
import '../../services/chat_store.dart';
import '../../services/image_cache.dart' as disk_cache;
import '../../services/theme_controller.dart';
import '../../services/updater.dart';
import '../../widgets/notify.dart';
import '../../widgets/page_scaffold.dart';

/// 设置页视图
class SettingsView extends StatefulWidget {
  final ThemeController theme;

  /// 当前登录用户
  final Map<String, dynamic> user;

  /// 退出登录回调
  final VoidCallback onLogout;

  const SettingsView({
    super.key,
    required this.theme,
    required this.user,
    required this.onLogout,
  });

  @override
  State<SettingsView> createState() => SettingsViewState();
}

class SettingsViewState extends State<SettingsView> {
  ThemeController get _theme => widget.theme;

  /// 选择主题模式：更新控制器并强制本地刷新 UI
  void _selectMode(AppThemeMode mode) {
    _theme.setMode(mode);
    // 本地 setState 确保单选圈等 UI 立即刷新（不依赖父级重建）
    if (mounted) setState(() {});
  }

  /// 字节格式化（B / KB / MB）
  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  /// 当前缓存总大小（图片缓存 + 头像缓存 + 聊天图片缓存），字节
  Future<int> _cacheTotalBytes() async {
    var total = 0;
    total += await disk_cache.ImageCache.instance.currentUserBytes();
    // 头像缓存目录（CachedAvatar 用）
    try {
      final d =
          Directory('${AppConfig.dataDir}${Platform.pathSeparator}avatar_cache');
      if (d.existsSync()) {
        await for (final e in d.list(recursive: true)) {
          if (e is File) total += await e.length();
        }
      }
    } catch (_) {}
    // 聊天图片本地缓存目录
    try {
      final uid = ChatStore.instance.currentUid;
      final d = Directory(ChatStore.chatImageDirFor(uid));
      if (d.existsSync()) {
        await for (final e in d.list(recursive: true)) {
          if (e is File) total += await e.length();
        }
      }
    } catch (_) {}
    return total;
  }

  /// 清除缓存：图片缓存 + 头像缓存 + 聊天图片缓存
  Future<void> _clearCache() async {
    final confirmed = await AppDialog.confirm(
      context,
      title: '清除缓存',
      message: '将清除本地缓存图片（帖子图片/头像/聊天图片），\n下次打开会自动重新下载。确定清除吗？',
      confirmText: '清除',
      danger: true,
    );
    if (confirmed != true || !mounted) return;
    try {
      await disk_cache.ImageCache.instance.clearCurrentUser();
      // 头像缓存目录（CachedAvatar 用）
      final d =
          Directory('${AppConfig.dataDir}${Platform.pathSeparator}avatar_cache');
      if (d.existsSync()) await d.delete(recursive: true);
      // 聊天图片本地缓存目录
      final uid = ChatStore.instance.currentUid;
      final chatDir = Directory(ChatStore.chatImageDirFor(uid));
      if (chatDir.existsSync()) await chatDir.delete(recursive: true);
    } catch (_) {}
    if (mounted) {
      setState(() {});
      NotifyStack.success('缓存已清除', title: '提示');
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final theme = _theme;
    return PageScaffold(
      title: '设置',
      child: SilkyListView(
        padding: const EdgeInsets.all(16),
        scrollSpeed: 1.6,
        silkyScrollDuration: const Duration(milliseconds: 600),
        animationCurve: Curves.easeOutCubic,
        children: [
          // ===== 主题模式（自绘可点击行，彻底避免 Material Radio 的"同值不触发"行为） =====
          Card(
            elevation: 0,
            color: bgHoverColor(b),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kRadiusMd),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题（无左侧图标）
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('主题模式',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: textColor(b))),
                ),
                ThemeOption(
                  label: '白天',
                  subtitle: '浅色界面',
                  value: AppThemeMode.light,
                  current: theme.mode,
                  brightness: b,
                  onTap: _selectMode,
                ),
                ThemeOption(
                  label: '黑夜',
                  subtitle: '深色界面',
                  value: AppThemeMode.dark,
                  current: theme.mode,
                  brightness: b,
                  onTap: _selectMode,
                ),
                ThemeOption(
                  label: '跟随系统',
                  subtitle: '自动跟随 Windows 明暗',
                  value: AppThemeMode.system,
                  current: theme.mode,
                  brightness: b,
                  onTap: _selectMode,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // ===== 清除缓存（在检查更新上方） =====
          Card(
            elevation: 0,
            color: bgHoverColor(b),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kRadiusMd),
            ),
            child: ListTile(
              leading: const Icon(Icons.cleaning_services_outlined,
                  color: kPrimary),
              title: Text('清除缓存',
                  style: TextStyle(color: textColor(b), fontSize: 14)),
              subtitle: FutureBuilder<int>(
                future: _cacheTotalBytes(),
                builder: (context, snap) {
                  final bytes = snap.data ?? 0;
                  return Text(
                    bytes > 0 ? '占用 ${_formatBytes(bytes)}' : '当前无缓存',
                    style: TextStyle(color: textMutedColor(b)),
                  );
                },
              ),
              onTap: _clearCache,
            ),
          ),
          const SizedBox(height: 12),
          // ===== 检查更新 =====
          Card(
            elevation: 0,
            color: bgHoverColor(b),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kRadiusMd),
            ),
            child: ListTile(
              leading: const Icon(Icons.system_update, color: kPrimary),
              title: Text('检查更新',
                  style: TextStyle(color: textColor(b), fontSize: 14)),
              subtitle: Text('当前版本 ${AppConfig.appVersion}',
                  style: TextStyle(color: textMutedColor(b))),
              onTap: () async {
                // 用固定 id 展示"正在检查"，完成后 dismiss（避免提示残留）
                const checkingId = 'checking_update';
                NotifyStack.instance.push(NotifyItem(
                  id: checkingId,
                  title: '检查更新',
                  message: '正在检查更新…',
                  type: NotifyType.info,
                ));
                // 手动检查：绕开本地忽略缓存，始终以服务端最新版本为准
                final info =
                    await Updater.instance.checkUpdate(ignoreFilter: false);
                NotifyStack.instance.dismiss(checkingId);
                if (info == null) {
                  NotifyStack.success('已是最新版本');
                } else {
                  // 直接推送更新通知（不再重复 checkUpdate，避免被忽略过滤）
                  await Updater.instance.showUpdateIfAvailable(info);
                }
              },
            ),
          ),
          const SizedBox(height: 12),
          // 关于（直接 ListTile，无上方分割线，不可点击）
          ListTile(
            enabled: false,
            leading: Icon(Icons.info_outline, color: textMutedColor(b)),
            title: Text('关于', style: TextStyle(color: textColor(b))),
            subtitle: Text('${AppConfig.appName} 客户端 v${AppConfig.appVersion}',
                style: TextStyle(color: textMutedColor(b))),
          ),
        ],
      ),
    );
  }
}

/// 主题模式单选项（自绘：InkWell + 单选圈，永远可点击切换）
class ThemeOption extends StatelessWidget {
  final String label;
  final String subtitle;
  final AppThemeMode value;
  final AppThemeMode current;
  final Brightness brightness;
  final ValueChanged<AppThemeMode> onTap;

  const ThemeOption({
    super.key,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.current,
    required this.brightness,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final selected = value == current;
    return InkWell(
      onTap: () => onTap(value),
      mouseCursor: SystemMouseCursors.click, // 悬停显示手指
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            // 单选圈
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? kPrimary : textFaintColor(brightness),
                  width: 2,
                ),
              ),
              child: selected
                  ? Center(
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: kPrimary,
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                          color: textColor(brightness))),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 12, color: textMutedColor(brightness))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
