import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    hide GlassButton;

import '../../core/app_theme.dart';
import '../theme/mobile_theme.dart';
import '../widgets/glass_button.dart';

/// 登录后主界面（首页骨架）
///
/// 规格（`docs/移动端UI规范.md` §4.3 / `docs/UI规范.md` §11）：
///  - 完全照插件官方示例（example/example.dart）：`GlassScaffold` 渐变背景 +
///    `GlassTabBar.bottom` 玻璃标签栏，`GlassTab(icon: Icon(...), label: ...)`
///    直接传 Icon，不叠加自绘角标；
///  - 内容区 `PageView` 支持左右滑动切换，各 tab 用 `AutomaticKeepAliveClientMixin`
///    保持滚动位置 / 页面状态；
///  - 4 个入口：消息 / 广场 / 探索 / 我的，受控组件 `selectedIndex` / `onTabSelected`
///    与 `PageController` 联动；
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

  /// 导航栏亮度源：跟随客户端全局白天/夜晚判断（`Theme.of(context).brightness`），
  /// 作为插件 `GlassTabBar.bottom` 的 `brightnessOverride`，
  /// 夜间自动渲染深色玻璃/阴影（`GlassContentAwareBrightness` 直接吃该 listenable）。
  final ValueNotifier<Brightness> _navBrightness =
      ValueNotifier<Brightness>(Brightness.light);

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 首次挂载前把亮度源同步成当前真实亮度（父组件回调先于子组件执行），
    // 避免 GlassContentAwareBrightness 拿到默认 light 后，再被 build 里的
    // 同步改成 dark 而触发一次 200ms cross-fade —— 表现为"导航栏加载一下才稳定"。
    // 主题后续切换仍由 build 里的同步接管（值不变时 ValueNotifier 不通知）。
    _navBrightness.value = Theme.of(context).brightness;
  }

  @override
  void dispose() {
    _pageController.dispose();
    _navBrightness.dispose();
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
    // 客户端通用白天/夜晚判断同步给导航栏亮度源（值未变时 ValueNotifier 不触发通知）
    _navBrightness.value = b;

    // 照插件官方示例（example/example.dart）的写法：
    // GlassScaffold 渐变背景 + GlassTabBar.bottom 玻璃标签栏，
    // GlassTab 直接传 Icon + label。
    return GlassScaffold(
      background: Container(
        decoration: BoxDecoration(gradient: MobileTheme.background(b)),
      ),
      body: Material(
        type: MaterialType.transparency,
        child: PageView(
          controller: _pageController,
          physics: const BouncingScrollPhysics(),
          onPageChanged: _onPageChanged,
          children: [
            const _MessageTab(),
            const _SquareTab(),
            const _ExploreTab(),
            _MineTab(user: widget.user, onLogout: widget.onLogout),
          ],
        ),
      ),
      // GlassScaffold 底层为 CupertinoPageScaffold（无 Material 祖先），
      // bottomBar 里的 GlassTab label 文本同样需要 Material 祖先，
      // 否则渲染"黄色双下划线"伪影 —— 故 bottomBar 也包一层透明 Material。
      bottomBar: Material(
        type: MaterialType.transparency,
        child: GlassTabBar.bottom(
          // 高精渲染管线：圆角/边缘更平滑（导航栏是静态布局，premium 档适用）
          quality: GlassQuality.premium,
          // 接入客户端通用白天/夜晚判断：夜间模式下玻璃渲染深色 + 阴影
          adaptiveBrightness: true,
          brightnessOverride: _navBrightness,
          tabs: const [
            GlassTab(icon: Icon(Icons.chat_bubble_outline_rounded), label: '消息'),
            GlassTab(icon: Icon(Icons.grid_view_outlined), label: '广场'),
            GlassTab(icon: Icon(Icons.explore_outlined), label: '探索'),
            GlassTab(icon: Icon(Icons.person_outline_rounded), label: '我的'),
          ],
          selectedIndex: _currentIndex,
          onTabSelected: _onTabSelected,
          // 选中态：图标 + 文字用主题蓝 kPrimary（0xFF0A84FF）
          selectedIconColor: kPrimary,
          selectedLabelColor: kPrimary,
        ),
      ),
    );
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

/// 消息 tab（后续接会话 / 通知列表）
class _MessageTab extends _TabPage {
  const _MessageTab();

  @override
  State<_MessageTab> createState() => _MessageTabState();
}

class _MessageTabState extends _TabPageState<_MessageTab> {
  @override
  List<Widget> buildSlivers(BuildContext context, Brightness b) {
    return const [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
        sliver: SliverToBoxAdapter(
          child: Text('消息',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
        ),
      ),
      _TabEmpty(
        icon: Icons.forum_outlined,
        title: '暂无消息',
        subtitle: '评论、回复与系统通知会出现在这里',
      ),
    ];
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
