import 'dart:io';

import 'package:flutter/material.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../core/api_client.dart';
import '../core/app_theme.dart';
import '../widgets/notify.dart';

/// 隐私设置页
///
/// 两种展示模式：
/// - 内容区覆盖模式（`embedded: true`，默认由个人中心省略号菜单触发）：
///   通过 `_HomePageState` 的 `_macOverlay` 机制展示在内容区，**保留左侧导航栏**
///   不遮挡。此时顶部距离由宿主窗口的 `_TitleBar` 承担，标题栏无需额外顶距，
///   样式与 `PublishPostPage`/`PostDetailPage` 内嵌模式一致（高 48、标题 15px/w600）。
/// - 全屏模式（`embedded: false`）：遵守 macOS / Windows 顶部距离规范
///   （Win 顶距 5px / macOS 20px，标题 20px/w600、左右 24px）。
///
/// 当前隐私设置项：
/// - 动态可见性（privacy_posts）：自己主页「动态」对他人是否可见（默认公开）
/// - 收藏可见性（privacy_favorites）：自己主页「收藏」对他人是否可见（默认公开）
///
/// 为后续"访问他人主页"功能做准备：他人访问时服务端按此配置过滤。
///
/// 样式遵循 docs/UI规范.md：可滚动区域用 SilkyListView，颜色一律用
/// app_theme.dart 的函数/常量，禁硬编码。
class PrivacySettingsPage extends StatefulWidget {
  /// 是否以内嵌模式展示（内容区覆盖，保留左侧导航栏）
  final bool embedded;

  /// 内嵌模式下点击返回按钮的回调（由宿主清空内容区覆盖层）
  final VoidCallback? onBack;

  const PrivacySettingsPage({
    super.key,
    this.embedded = false,
    this.onBack,
  });

  @override
  State<PrivacySettingsPage> createState() => _PrivacySettingsPageState();
}

class _PrivacySettingsPageState extends State<PrivacySettingsPage> {
  /// 动态可见性：true=公开 false=仅自己
  bool? _privacyPosts;

  /// 收藏可见性：true=公开 false=仅自己
  bool? _privacyFavorites;

  /// 是否正在保存（防连点）
  bool _saving = false;

  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadPrivacy();
  }

  /// 拉取当前隐私配置
  Future<void> _loadPrivacy() async {
    try {
      final resp = await ApiClient.instance.getPrivacy();
      final json = ApiClient.safeJsonDecode(resp.body);
      if (!mounted) return;
      if (json['code'] != 0) {
        NotifyStack.warning(json['msg']?.toString() ?? '获取隐私配置失败',
            title: '提示');
        setState(() => _loaded = true);
        return;
      }
      final data = (json['data'] as Map<String, dynamic>?) ?? {};
      setState(() {
        _privacyPosts = (data['privacy_posts'] ?? 1) == 1;
        _privacyFavorites = (data['privacy_favorites'] ?? 1) == 1;
        _loaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      NotifyStack.warning('无法获取隐私配置，请稍后重试', title: '提示');
      setState(() => _loaded = true);
    }
  }

  /// 保存单项设置（切换开关即保存）
  Future<void> _save({
    bool? privacyPosts,
    bool? privacyFavorites,
  }) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final resp = await ApiClient.instance.savePrivacy(
        privacyPosts: privacyPosts,
        privacyFavorites: privacyFavorites,
      );
      final json = ApiClient.safeJsonDecode(resp.body);
      if (!mounted) return;
      if (json['code'] != 0) {
        NotifyStack.warning(json['msg']?.toString() ?? '保存失败', title: '提示');
        // 回滚开关
        await _loadPrivacy();
      }
    } catch (e) {
      if (!mounted) return;
      NotifyStack.warning('隐私设置保存失败，请稍后重试', title: '提示');
      // 回滚开关
      await _loadPrivacy();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Scaffold(
      backgroundColor: bgColor(b),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTitleBar(b, context),
          Expanded(
            child: SilkyListView(
              padding: const EdgeInsets.all(16),
              scrollSpeed: 1.6,
              silkyScrollDuration: const Duration(milliseconds: 600),
              animationCurve: Curves.easeOutCubic,
              children: [
                if (!_loaded)
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: Center(
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: kPrimary,
                      ),
                    ),
                  )
                else ...[
                  // ===== 主页可见性 =====
                  Card(
                    elevation: 0,
                    color: bgHoverColor(b),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(kRadiusMd),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding:
                              const EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Text('主页可见性',
                              style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: textColor(b))),
                        ),
                        _buildPrivacySwitch(
                          b,
                          label: '动态',
                          subtitle: '他人访问你的主页时，是否可见你的「动态」列表',
                          value: _privacyPosts ?? true,
                          onChanged: (v) {
                            setState(() => _privacyPosts = v);
                            _save(privacyPosts: v);
                          },
                        ),
                        _buildPrivacySwitch(
                          b,
                          label: '收藏',
                          subtitle: '他人访问你的主页时，是否可见你的「收藏」列表',
                          value: _privacyFavorites ?? true,
                          onChanged: (v) {
                            setState(() => _privacyFavorites = v);
                            _save(privacyFavorites: v);
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 说明
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      '开启后所有人可见；关闭后仅自己可见，他人访问你的主页时将不显示对应内容。',
                      style: TextStyle(
                        fontSize: 12,
                        color: textMutedColor(b),
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 隐私开关行（自绘：标题 + 副标题 + 右侧 Switch）
  Widget _buildPrivacySwitch(
    Brightness b, {
    required String label,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return InkWell(
      onTap: _saving ? null : () => onChanged(!value),
      mouseCursor: SystemMouseCursors.click,
      hoverColor: bgHoverColor(b),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: textColor(b))),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 12, color: textMutedColor(b))),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Switch(
              value: value,
              activeThumbColor: kPrimary,
              onChanged: _saving ? null : onChanged,
            ),
          ],
        ),
      ),
    );
  }

  /// 标题栏
  ///
  /// embedded（内容区覆盖）：与 PublishPostPage 内嵌模式一致——高 48、
  /// 水平 8px、标题 15px/w600、macOS 风格返回按钮（40x40、kRadiusMd 圆角、
  /// arrow_back_ios_new_rounded 16px）。顶部距离由宿主 _TitleBar 承担。
  ///
  /// 全屏模式：返回按钮 + 标题，遵守双端顶部距离规范
  /// （Win 顶距 5px / macOS 20px，标题 20px/w600，左右 24px）。
  Widget _buildTitleBar(Brightness b, BuildContext context) {
    if (widget.embedded) {
      return SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              // macOS 风格返回按钮
              SizedBox(
                width: 40,
                height: 40,
                child: InkWell(
                  borderRadius: BorderRadius.circular(kRadiusMd),
                  onTap: () {
                    if (widget.onBack != null) {
                      widget.onBack!();
                    } else {
                      Navigator.of(context).maybePop();
                    }
                  },
                  mouseCursor: SystemMouseCursors.click,
                  hoverColor: bgHoverColor(b),
                  child: Center(
                    // 图标下移 1px，与 15px 标题文字视觉中线对齐（Material 箭头基线偏上）
                    child: Transform.translate(
                      offset: const Offset(0, 1),
                      child: Icon(Icons.arrow_back_ios_new_rounded,
                          size: 16, color: textMutedColor(b)),
                    ),
                  ),
                ),
              ),
              Text(
                '隐私设置',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: textColor(b),
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        Platform.isWindows ? 5 : 20,
        24,
        4,
      ),
      child: Row(
        children: [
          // 返回按钮（kRadiusMd 圆角 hover）
          SizedBox(
            width: 36,
            height: 36,
            child: InkWell(
              borderRadius: BorderRadius.circular(kRadiusMd),
              onTap: () => Navigator.of(context).pop(),
              mouseCursor: SystemMouseCursors.click,
              hoverColor: bgHoverColor(b),
              child: Icon(Icons.arrow_back,
                  size: 18, color: textMutedColor(b)),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              '隐私设置',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: textColor(b),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
