import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../theme/mobile_theme.dart';
import '../widgets/glass_button.dart';
import 'message_page.dart';

/// 登录后主界面（首页骨架）
///
/// 规格（`docs/移动端UI规范.md` §4.3 / `docs/UI规范.md` §11）：
///  - 底部导航栏为自绘玻璃样式（【2026-08-20】弃用 liquid_glass_widgets 插件）：
///    高斯模糊（BackdropFilter）+ 半透明底色 + 细边框 + 圆角，参考 PC 探索页；
///  - 内容区 `PageView` 支持左右滑动切换，各 tab 用 `AutomaticKeepAliveClientMixin`
///    保持滚动位置 / 页面状态；
///  - 4 个入口：消息 / 广场 / 探索 / 我的，受控组件 `selectedIndex` / `onTabSelected`
///    与 `PageController` 联动；
///  - 切换动画：选中项背景胶囊 + 图标/文字颜色过渡（AnimatedContainer）；
///  - 平板适配：每页内容列 `maxWidth` 限宽 + 居中（§4.5 强约束）。
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.user, required this.onLogout});

  final Map<String, dynamic> user;

  /// 退出登录回调（清登录态回登录页）
  final Future<void> Function() onLogout;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// 平板下内容列最大宽度（§4.5 表单/内容限宽强约束）
  static const double _kContentMaxWidth = 560;

  int _currentIndex = 0;
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onTabSelected(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _onPageChanged(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;

    // 自绘玻璃底部导航栏：高斯模糊 + 半透明底 + 细边框 + 圆角，
    // 四个 tab 页（消息/广场/探索/我的）共用移动端主背景色（夜间纯黑）。
    return Scaffold(
      backgroundColor: MobileTheme.pageBackground(b),
      extendBody: true,
      body: PageView(
        controller: _pageController,
        physics: const BouncingScrollPhysics(),
        onPageChanged: _onPageChanged,
        children: [
          _MessageTab(user: widget.user),
          const _SquareTab(),
          const _ExploreTab(),
          _MineTab(user: widget.user, onLogout: widget.onLogout),
        ],
      ),
      bottomNavigationBar: _GlassBottomNav(
        currentIndex: _currentIndex,
        onTabSelected: _onTabSelected,
      ),
    );
  }
}

/// 自绘玻璃底部导航栏（参考 PC 探索页 `_GlassBlock` 风格）
///
/// 结构：SafeArea → 外层留白 → ClipRRect(圆角) + BackdropFilter(高斯模糊) +
/// 半透明底色 + 细边框；选中项有背景胶囊浮起 + 图标/文字颜色过渡动画。
class _GlassBottomNav extends StatelessWidget {
  const _GlassBottomNav({required this.currentIndex, required this.onTabSelected});

  final int currentIndex;
  final ValueChanged<int> onTabSelected;

  static const List<({IconData icon, String label})> _tabs = [
    (icon: Icons.chat_bubble_outline_rounded, label: '消息'),
    (icon: Icons.grid_view_outlined, label: '广场'),
    (icon: Icons.explore_outlined, label: '探索'),
    (icon: Icons.person_outline_rounded, label: '我的'),
  ];

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final borderColor =
        b == Brightness.dark ? Colors.white : Colors.black;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: ClipRRect(
          // 整体与选中胶囊统一为完全胶囊（kRadiusFull），圆角弧度一致（iOS 理念）
          borderRadius: BorderRadius.circular(kRadiusFull),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              height: 64,
              decoration: BoxDecoration(
                color: b == Brightness.dark
                    ? const Color(0xCC23232A) // 夜间：主背景色高不透明度玻璃
                    : Colors.white.withValues(alpha: 0.85),
                border: Border.all(
                  color: borderColor.withValues(alpha: b == Brightness.dark ? 0.12 : 0.08),
                  width: 0.8,
                ),
                borderRadius: BorderRadius.circular(kRadiusFull),
              ),
              child: Row(
                children: List.generate(_tabs.length, (i) {
                  final tab = _tabs[i];
                  final selected = i == currentIndex;
                  return Expanded(
                    child: _GlassNavItem(
                      icon: tab.icon,
                      label: tab.label,
                      selected: selected,
                      onTap: () => onTabSelected(i),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 单个导航项：选中时背景胶囊浮起 + 图标/文字颜色 + 微放大过渡
class _GlassNavItem extends StatelessWidget {
  const _GlassNavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final color = selected ? kPrimary : textMutedColor(b);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        // 内容区固定 48 高（64 - 8×2），图标文字位置保持不动；
        // 选中胶囊用 Stack+Positioned 上下各外扩 2px（总高 52），居中覆盖且不参与布局。
        child: SizedBox(
          height: 48,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Positioned(
                top: -2,
                bottom: -2,
                left: 0,
                right: 0,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    color: selected
                        ? kPrimary.withValues(alpha: b == Brightness.dark ? 0.22 : 0.10)
                        : Colors.transparent,
                    // 完全胶囊：两侧大圆角
                    borderRadius: BorderRadius.circular(kRadiusFull),
                  ),
                ),
              ),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedScale(
                    // 选中整体微放大（回弹只放外层：scale 无 [0,1] 约束，overshoot 安全）
                    scale: selected ? 1.12 : 1.0,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutBack,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      // 关键：switchIn 禁止 easeOutBack——它 overshoot 到 >1.0，
                      // 会直接传进下方 FadeTransition 的 opacity 触发
                      // "parametric value is outside of [0, 1] range" 断言刷屏。
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      // 图标平滑变换：淡入淡出 + 缩放（0.6→1.0，easeOutCubic 不越界）
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: ScaleTransition(
                          scale: Tween<double>(begin: 0.6, end: 1.0).animate(
                            CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
                          ),
                          child: child,
                        ),
                      ),
                      child: Icon(
                        selected ? _filledOf(icon) : icon,
                        key: ValueKey(selected),
                        size: 24,
                        color: color,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    style: TextStyle(
                      fontSize: 11,
                      color: color,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                    child: Text(label),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// outline 图标选中态切换到 filled 版本（体现选中状态变化）
  static IconData _filledOf(IconData icon) {
    switch (icon) {
      case Icons.chat_bubble_outline_rounded:
        return Icons.chat_bubble_rounded;
      case Icons.grid_view_outlined:
        return Icons.grid_view_rounded;
      case Icons.explore_outlined:
        return Icons.explore_rounded;
      default:
        return Icons.person_rounded;
    }
  }
}

/// 内容列限宽 + 居中（平板适配，§4.5）
class _ContentPane extends StatelessWidget {
  const _ContentPane({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _HomePageState._kContentMaxWidth),
        child: child,
      ),
    );
  }
}

/// 通用 tab 页骨架：安全区 + 限宽内容列 + 回弹滚动
abstract class _TabPage extends StatefulWidget {
  const _TabPage();

  @override
  State<_TabPage> createState() => _TabPageState<_TabPage>();
}

class _TabPageState<T extends _TabPage> extends State<T>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final b = Theme.of(context).brightness;
    return SafeArea(
      bottom: false,
      child: _ContentPane(
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: buildSlivers(context, b),
        ),
      ),
    );
  }

  /// 由子类实现具体内容（各 tab 页骨架统一走回弹滚动 + 限宽）
  List<Widget> buildSlivers(BuildContext context, Brightness b) {
    return const [SliverToBoxAdapter(child: SizedBox.shrink())];
  }
}

/// 空状态占位组件（各 tab 内容迭代前的骨架）
class _TabEmpty extends StatelessWidget {
  const _TabEmpty({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final muted = textMutedColor(b);
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: muted.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Text(title,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(subtitle,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: muted)),
          ],
        ),
      ),
    );
  }
}

/// 消息 tab（会话列表）
class _MessageTab extends StatefulWidget {
  const _MessageTab({required this.user});

  final Map<String, dynamic> user;

  @override
  State<_MessageTab> createState() => _MessageTabState();
}

class _MessageTabState extends State<_MessageTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return MobileMessagePage(user: widget.user);
  }
}

/// 广场 tab（后续接帖子瀑布流）
class _SquareTab extends _TabPage {
  const _SquareTab();

  @override
  State<_SquareTab> createState() => _SquareTabState();
}

class _SquareTabState extends _TabPageState<_SquareTab> {
  @override
  List<Widget> buildSlivers(BuildContext context, Brightness b) {
    return const [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
        sliver: SliverToBoxAdapter(
          child: Text('广场',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
        ),
      ),
      _TabEmpty(
        icon: Icons.grid_view_rounded,
        title: '广场内容开发中',
        subtitle: '大家的帖子与动态会在这里展示',
      ),
    ];
  }
}

/// 探索 tab（后续接星球 / 用户发现）
class _ExploreTab extends _TabPage {
  const _ExploreTab();

  @override
  State<_ExploreTab> createState() => _ExploreTabState();
}

class _ExploreTabState extends _TabPageState<_ExploreTab> {
  @override
  List<Widget> buildSlivers(BuildContext context, Brightness b) {
    return const [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
        sliver: SliverToBoxAdapter(
          child: Text('探索',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
        ),
      ),
      _TabEmpty(
        icon: Icons.explore_rounded,
        title: '探索功能开发中',
        subtitle: '星球、群组与新朋友等你发现',
      ),
    ];
  }
}

/// 我的 tab（个人资料 + 退出登录）
class _MineTab extends _TabPage {
  const _MineTab({required this.user, required this.onLogout});

  final Map<String, dynamic> user;
  final Future<void> Function() onLogout;

  @override
  State<_MineTab> createState() => _MineTabState();
}

class _MineTabState extends _TabPageState<_MineTab> {
  bool _loggingOut = false;

  Future<void> _logout() async {
    if (_loggingOut) return;
    setState(() => _loggingOut = true);
    await widget.onLogout();
    if (mounted) setState(() => _loggingOut = false);
  }

  @override
  List<Widget> buildSlivers(BuildContext context, Brightness b) {
    final nickname =
        (widget.user['nickname'] ?? widget.user['username'] ?? '') as String;
    final avatar = widget.user['avatar'] as String?;
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        sliver: SliverToBoxAdapter(
          child: Text('我的',
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
        ),
      ),
      // 个人信息卡
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        sliver: SliverToBoxAdapter(
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: MobileTheme.glassLayer(b),
            child: Row(
              children: [
                // 头像：有则用网络图，无则首字占位
                ClipOval(
                  child: avatar != null && avatar.isNotEmpty
                      ? Image.network(
                          avatar,
                          width: 64,
                          height: 64,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              _AvatarFallback(name: nickname),
                        )
                      : _AvatarFallback(name: nickname),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(nickname,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text('账号：${widget.user['username'] ?? ''}',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      // 退出登录
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        sliver: SliverToBoxAdapter(
          child: GlassButton.secondary(
            label: _loggingOut ? '退出中…' : '退出登录',
            expanded: true,
            onPressed: _loggingOut ? null : _logout,
          ),
        ),
      ),
    ];
  }
}

/// 无头像时的首字占位头像
class _AvatarFallback extends StatelessWidget {
  const _AvatarFallback({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name.characters.first : '?';
    return Container(
      width: 64,
      height: 64,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [kPrimary.withValues(alpha: 0.9), kPrimary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Text(
        initial,
        style: const TextStyle(
            color: Colors.white, fontSize: 26, fontWeight: FontWeight.w600),
      ),
    );
  }
}
