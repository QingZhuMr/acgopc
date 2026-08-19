import 'dart:convert';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/app_theme.dart';
import '../services/planet_generator.dart';
import '../widgets/find_form_dialog.dart';
import '../widgets/notify.dart';
import '../widgets/planet_globe.dart';
import '../widgets/starfield.dart';

/// 星球页面
///
/// 通过左侧导航栏「广场」下方、「我的」上方的「星球」入口进入。
/// 内容：后台创建的星球列表（程序化生成外观，按 seed 展示）+ 宇宙星空背景
/// + 左上角标语卡片 + 左右箭头切换不同星球 + 左下角当前星球名称/介绍。
/// 作为侧边栏 tab 内嵌展示（不遮挡左侧导航栏），无返回按钮。
class PlanetPage extends StatefulWidget {
  const PlanetPage({super.key});

  @override
  State<PlanetPage> createState() => _PlanetPageState();
}

class _PlanetPageState extends State<PlanetPage> {
  /// 后台星球列表 [{id, seed, name, intro}]
  List<Map<String, dynamic>> _planets = [];

  /// 当前展示的星球索引
  int _index = 0;

  /// 是否加载中
  bool _loading = true;

  /// 列表为空或加载失败时展示的兜底星球种子（保证始终有一颗星球可看）
  static const int _fallbackSeed = 74210366;

  /// 星球滑动控制器（无限循环 PageView，初始页 500 留足左右滑动空间）
  late final PageController _pageCtrl = PageController(initialPage: 500);

  /// 当前 PageView 页号（onPageChanged 更新，用于按钮切换定位）
  int _currentPage = 500;

  /// 当前星球的寻人配置（find/config 返回，切换星球时刷新）
  Map<String, dynamic>? _findConfig;

  /// 正在加载寻人配置
  bool _findLoading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final resp = await ApiClient.instance.getPlanets();
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      if (body['code'] == 0 && body['data'] is List) {
        final list = (body['data'] as List)
            .whereType<Map<String, dynamic>>()
            .toList();
        if (!mounted) return;
        setState(() {
          _planets = list;
          _index = 0;
          _loading = false;
        });
        // 数据就绪后，将无限 PageView 定位到"第一颗星球"对应的页
        if (list.length >= 2) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_pageCtrl.hasClients) return;
            final base = 500 * list.length;
            _pageCtrl.jumpToPage(base);
            _currentPage = base;
          });
        }
        // 加载第一颗星球的寻人配置
        _loadFindConfig();
        return;
      }
    } catch (_) {
      // 网络/解析失败：走兜底展示
    }
    if (!mounted) return;
    setState(() {
      _planets = [];
      _loading = false;
    });
  }

  /// 当前星球 ID（无列表返回 0）
  int get _planetId {
    if (_planets.isEmpty) return 0;
    return (_planets[_index]['id'] as num?)?.toInt() ?? 0;
  }

  /// 加载当前星球的寻人配置（find/config）
  Future<void> _loadFindConfig() async {
    final pid = _planetId;
    if (pid <= 0) return;
    if (_findLoading) return;
    setState(() => _findLoading = true);
    try {
      final resp = await ApiClient.instance.getFindConfig(planetId: pid);
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      if (body['code'] == 0 && mounted) {
        setState(() {
          _findConfig = body['data'] as Map<String, dynamic>?;
        });
      }
    } catch (_) {
      // 静默失败：保持上次配置，按钮仍可点击再次尝试
    } finally {
      if (mounted) setState(() => _findLoading = false);
    }
  }

  /// 当前星球种子（有列表取当前项，否则兜底）
  int get _seed {
    if (_planets.isEmpty) return _fallbackSeed;
    return (_planets[_index]['seed'] as num?)?.toInt() ?? _fallbackSeed;
  }

  /// 当前星球类型（接口 type；无列表/未知返回 null 走白名单回退）
  String? get _type {
    if (_planets.isEmpty) return null;
    return _planets[_index]['type']?.toString();
  }

  /// 当前星球名称（无列表时返回 null，隐藏卡片）
  String? get _name {
    if (_planets.isEmpty) return null;
    return _planets[_index]['name']?.toString() ?? '';
  }

  /// 当前星球介绍
  String? get _intro {
    if (_planets.isEmpty) return null;
    return _planets[_index]['intro']?.toString() ?? '';
  }

  void _switch(int delta) {
    if (_planets.length < 2) return;
    // 基于实时页号（动画中取 round），支持快速连点不乱序
    final current = (_pageCtrl.hasClients && _pageCtrl.page != null)
        ? _pageCtrl.page!.round()
        : _currentPage;
    _pageCtrl.animateToPage(
      current + delta,
      duration: const Duration(milliseconds: 480),
      curve: Curves.easeInOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 白天模式背景稍亮（深蓝黑），夜间模式保持宇宙黑
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? _spaceBg : _spaceBgDay;
    return Scaffold(
      backgroundColor: bg,
      body: Stack(
        children: [
          // 星空背景板（底层，不遮挡前端内容；白天背景稍亮）
          Positioned.fill(
            child: StarfieldBackground(backgroundColor: bg),
          ),
          // 内容区：星球 + 左右切换 + 正下方「开始寻找」按钮
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    // 星球大小为可用空间的一半（保留大量星空视野）
                    final size = constraints.biggest.shortestSide * 0.45;
                    // 内容区总宽度（PageView 铺满，星球从页面左右边缘滑入/滑出）
                    final totalW = constraints.biggest.width;
                    // 左右箭头按钮宽度
                    const arrowW = 44.0;
                    // 箭头固定在星球两侧（星球居中，故箭头距页面边缘 = (总宽-星径)/2 - 箭头宽 - 间距）
                    final sideGap =
                        ((totalW - size) / 2 - arrowW - 12).clamp(8.0, 1e9);
                    return SizedBox(
                      width: totalW,
                      height: size,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // 星球滑动区：铺满整个页面内容区宽度 →
                          // 切换时星球从页面左右边缘滑出/滑入
                          // 多颗星球 → 无限循环 PageView（点击左/右箭头平滑滑动切换）
                          // 单颗/加载中 → 静态单颗星球
                          Positioned.fill(
                            child: _planets.length >= 2
                                ? _buildGlobePager(size)
                                : Center(child: _buildGlobe(size, _seed, _type)),
                          ),
                          // 左箭头：切换上一颗星球（当前星球右滑出、上一颗从左侧滑入）
                          Positioned(
                            left: sideGap,
                            child: _switchButton(
                              icon: Icons.chevron_left_rounded,
                              enabled: _planets.length > 1,
                              onTap: () => _switch(-1),
                              isDark: isDark,
                            ),
                          ),
                          // 右箭头：切换下一颗星球（当前星球左滑出、下一颗从右侧滑入）
                          Positioned(
                            right: sideGap,
                            child: _switchButton(
                              icon: Icons.chevron_right_rounded,
                              enabled: _planets.length > 1,
                              onTap: () => _switch(1),
                              isDark: isDark,
                            ),
                          ),
                          // 加载中：覆盖一个转圈（列表为空且加载中）
                          if (_loading && _planets.isEmpty)
                            const SizedBox(
                              width: 42,
                              height: 42,
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                color: Colors.white54,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 28),
                // 「开始寻找」按钮（透明玻璃效果，无图标；按寻找状态显示文案）
                _buildFindButton(isDark),
                // 状态辅助文案（寻找中 / 已配对）
                if (_findHint != null) ...[
                  const SizedBox(height: 10),
                  _GlassBlock(
                    radius: 14,
                    hPad: 18,
                    vPad: 8,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _findHintIcon,
                          size: 14,
                          color: const Color(0xFFFFC873),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _findHint!,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: _spaceText,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          // 左上角：标语 + 幸运值（同一张高斯卡片，宽度对齐、左对齐）
          Positioned(
            top: 16,
            left: 20,
            child: _GlassBlock(
              child: SizedBox(
                width: 320,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '在不同的星球上，遇见想遇见的人。',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: isDark ? _spaceText : const Color(0xFFE8EDF7),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 幸运值信息：默认进度 50%（未来花费积分可提升幸运值）
                    Row(
                      children: [
                        const Icon(Icons.auto_awesome_rounded,
                            size: 16, color: Color(0xFFFFC873)),
                        const SizedBox(width: 6),
                        Text(
                          '幸运值',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? _spaceText
                                : const Color(0xFFE8EDF7),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '50%',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFFFFC873),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: 0.5,
                        minHeight: 5,
                        backgroundColor: Colors.white.withValues(alpha: 0.12),
                        color: const Color(0xFFFFC873),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 左下角：当前星球名称 + 介绍（有列表数据时才显示）
          if (_name != null)
            Positioned(
              left: 20,
              bottom: 20,
              child: _GlassBlock(
                hPad: 16,
                vPad: 12,
                child: SizedBox(
                  width: 300,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.public_rounded,
                              size: 16, color: Color(0xFFFFC873)),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              _name!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: isDark
                                    ? _spaceText
                                    : const Color(0xFFE8EDF7),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if ((_intro ?? '').isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          _intro!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.5,
                            color: isDark
                                ? _spaceText.withValues(alpha: 0.72)
                                : const Color(0xFFE8EDF7).withValues(alpha: 0.72),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 单颗星球球体（材质优先级：接口 type → 白名单回退 → earth）
  Widget _buildGlobe(double size, int seed, [String? type]) {
    final style = _stylePreviewAll ??
        PlanetStyle.fromApi(type) ??
        _styleBySeed[seed] ??
        PlanetStyle.earth;
    return PlanetGlobe(size: size, seed: seed, style: style);
  }

  /// 无限循环星球滑动器（loop：左右任意方向循环切换）
  Widget _buildGlobePager(double size) {
    final count = _planets.length;
    return PageView.builder(
      controller: _pageCtrl,
      allowImplicitScrolling: true, // 预构建相邻页，滑动时贴图已就绪更平滑
      physics: const PageScrollPhysics(),
      onPageChanged: (page) {
        if (count == 0 || !mounted) return;
        final idx = ((page % count) + count) % count;
        setState(() {
          _currentPage = page;
          _index = idx;
        });
        // 切换星球后刷新该星球的寻人配置
        _loadFindConfig();
      },
      itemBuilder: (context, page) {
        final idx = ((page % count) + count) % count;
        final item = _planets[idx];
        final seed = (item['seed'] as num?)?.toInt() ?? _fallbackSeed;
        final type = item['type']?.toString();
        return Center(child: _buildGlobe(size, seed, type));
      },
    );
  }

  /// 当前星球寻找状态辅助文案（null 不显示）
  String? get _findHint {
    final cfg = _findConfig;
    if (cfg == null) return null;
    if (cfg['my_bind'] is Map<String, dynamic>) {
      return '已配对成功';
    }
    final find = cfg['my_find'];
    if (find is Map<String, dynamic> && (find['status'] as num?)?.toInt() == 0) {
      return '正在寻找中';
    }
    return null;
  }

  /// 寻找状态辅助图标
  IconData get _findHintIcon {
    final cfg = _findConfig;
    if (cfg != null && cfg['my_bind'] is Map<String, dynamic>) {
      return Icons.favorite_rounded;
    }
    return Icons.radar_rounded;
  }

  /// 「开始寻找」按钮（按当前星球配置与我的状态展示文案/可用性）
  Widget _buildFindButton(bool isDark) {
    final cfg = _findConfig;
    final enabled = cfg != null && (cfg['enable_find'] == true);
    final bound = cfg?['my_bind'] is Map<String, dynamic>;
    final finding = cfg?['my_find'] is Map<String, dynamic> &&
        (cfg?['my_find']['status'] as num?)?.toInt() == 0;

    String text;
    if (bound) {
      text = '已配对';
    } else if (finding) {
      text = '寻找中';
    } else if (enabled) {
      text = '开始寻找';
    } else {
      text = '暂未开放';
    }
    final clickable = enabled || bound || finding;

    return _GlassBlock(
      radius: 24,
      hPad: 40,
      vPad: 12,
      child: InkWell(
        onTap: clickable ? () => _onFindTap() : null,
        borderRadius: BorderRadius.circular(24),
        mouseCursor: clickable
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: Text(
          text,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: clickable
                ? (isDark ? _spaceText : const Color(0xFFE8EDF7))
                : Colors.white38,
          ),
        ),
      ),
    );
  }

  /// 点击「开始寻找 / 寻找中 / 已配对」
  Future<void> _onFindTap() async {
    final cfg = _findConfig;
    if (cfg == null) {
      await _loadFindConfig();
      return;
    }
    // 已配对：展示绑定人信息 + 解除绑定
    final bind = cfg['my_bind'];
    if (bind is Map<String, dynamic>) {
      _showBindDetail(bind);
      return;
    }
    // 寻找中：提示已开启，可手动停止
    final find = cfg['my_find'];
    if (find is Map<String, dynamic> && (find['status'] as num?)?.toInt() == 0) {
      _showFindingHint(find);
      return;
    }
    // 未开启：提示
    if (cfg['enable_find'] != true) {
      NotifyStack.warning('该星球暂未开放寻找配对', title: '提示');
      return;
    }
    // 正常：弹出填写表单
    _openFindForm(cfg);
  }

  /// 打开「开始寻找」动态表单
  Future<void> _openFindForm(Map<String, dynamic> cfg) async {
    final result = await showDialog<FindFormResult>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => FindFormDialog(
        planetId: _planetId,
        planetName: _name ?? '',
        findFields: (cfg['find_fields'] as List? ?? [])
            .map((e) => '$e')
            .toList(),
        profile: cfg['profile'] is Map<String, dynamic>
            ? cfg['profile'] as Map<String, dynamic>
            : null,
        forceFaceAuth: cfg['force_face_auth'] == true,
        forceEduAuth: cfg['force_edu_auth'] == true,
        forceAssetAuth: cfg['force_asset_auth'] == true,
      ),
    );
    if (result == null || !mounted) return;
    if (result.status == 1) {
      // 配对成功：展示绑定人
      _showMatched(result);
    } else {
      NotifyStack.success('已开始寻找，请保持在线', title: '寻找中');
    }
    // 刷新配置（按钮状态更新为寻找中/已配对）
    _loadFindConfig();
  }

  /// 配对成功弹窗
  void _showMatched(FindFormResult result) {
    final u = result.matchedUser;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => AlertDialog(
        backgroundColor:
            Theme.of(context).brightness == Brightness.dark
                ? DarkColors.bgSoft
                : LightColors.bgSoft,
        shape: RoundedRectangleBorder(borderRadius: kRadiusCardAll),
        title: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.favorite_rounded, color: Color(0xFFFF4D6D), size: 22),
            SizedBox(width: 8),
            Text('配对成功', style: TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '恭喜！${u?['nickname'] ?? '对方'} 和你在「$_name」星球上配对了',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 14),
            _buildAvatar(u?['avatar'] as String? ?? '', 56),
            const SizedBox(height: 10),
            Text(
              u?['nickname'] as String? ?? '配对对象',
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              '你们已成为绑定人，互相自动关注；解除绑定前将保持好友关系',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 寻找中弹窗（可手动停止）
  void _showFindingHint(Map<String, dynamic> find) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => AlertDialog(
        backgroundColor:
            Theme.of(context).brightness == Brightness.dark
                ? DarkColors.bgSoft
                : LightColors.bgSoft,
        shape: RoundedRectangleBorder(borderRadius: kRadiusCardAll),
        title: const Text('正在寻找中', textAlign: TextAlign.center),
        content: const Text(
          '你正在该星球寻找有缘人，配对成功后会自动通知你。\n可以随时手动停止寻找。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: Colors.grey),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('继续寻找'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _stopFind();
            },
            child: const Text('停止寻找',
                style: TextStyle(color: Color(0xFFFF4D6D))),
          ),
        ],
      ),
    );
  }

  /// 手动停止寻找
  Future<void> _stopFind() async {
    try {
      final resp = await ApiClient.instance.stopFind();
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      if (body['code'] == 0) {
        NotifyStack.success('已停止寻找', title: '已停止');
        _loadFindConfig();
      } else {
        NotifyStack.warning(body['msg'] as String? ?? '操作失败', title: '提示');
      }
    } catch (_) {
      NotifyStack.error('网络异常，请稍后重试');
    }
  }

  /// 绑定详情弹窗（展示绑定人 + 解除绑定）
  void _showBindDetail(Map<String, dynamic> bind) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => AlertDialog(
        backgroundColor:
            Theme.of(context).brightness == Brightness.dark
                ? DarkColors.bgSoft
                : LightColors.bgSoft,
        shape: RoundedRectangleBorder(borderRadius: kRadiusCardAll),
        title: const Text('已配对', textAlign: TextAlign.center),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildAvatar(bind['avatar'] as String? ?? '', 56),
            const SizedBox(height: 10),
            Text(
              bind['nickname'] as String? ?? '绑定人',
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              '你们是绑定人关系，互相自动关注；\n解除绑定后才能解除好友或重新开始寻找',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _unbind(bind);
            },
            child: const Text('解除绑定',
                style: TextStyle(color: Color(0xFFFF4D6D))),
          ),
        ],
      ),
    );
  }

  /// 解除绑定
  Future<void> _unbind(Map<String, dynamic> bind) async {
    final ok = await AppDialog.confirm(
      context,
      title: '解除绑定',
      message: '确定要与「${bind['nickname'] ?? '对方'}」解除绑定关系吗？\n解除后你们仍为好友，但可互相取消关注，也可以重新发起寻找。',
      confirmText: '解除绑定',
      cancelText: '再想想',
      danger: true,
    );
    if (ok != true || !mounted) return;
    try {
      final targetUid = (bind['uid'] as num?)?.toInt() ?? 0;
      if (targetUid <= 0) {
        NotifyStack.warning('数据异常，请稍后重试', title: '提示');
        return;
      }
      final resp = await ApiClient.instance.unbindFind(targetUid: targetUid);
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      if (body['code'] == 0) {
        NotifyStack.success('已解除绑定', title: '已解除');
        _loadFindConfig();
      } else {
        NotifyStack.warning(body['msg'] as String? ?? '解除失败', title: '提示');
      }
    } catch (_) {
      NotifyStack.error('网络异常，请稍后重试');
    }
  }

  /// 圆形头像（空则显示占位）
  Widget _buildAvatar(String avatar, double size) {
    if (avatar.isEmpty) {
      return CircleAvatar(
        radius: size / 2,
        backgroundColor: Colors.black26,
        child: Icon(Icons.person_rounded,
            size: size * 0.5, color: Colors.white70),
      );
    }
    return ClipOval(
      child: Image.network(
        AppConfig.resolveUrl(avatar),
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => CircleAvatar(
          radius: size / 2,
          backgroundColor: Colors.black26,
          child: Icon(Icons.person_rounded,
              size: size * 0.5, color: Colors.white70),
        ),
      ),
    );
  }

  /// 左右切换箭头按钮（玻璃圆钮，hover 变小手）
  Widget _switchButton({
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
    required bool isDark,
  }) {
    final color = enabled
        ? (isDark ? _spaceText : const Color(0xFFE8EDF7))
        : Colors.white24;
    return _GlassBlock(
      radius: 22,
      hPad: 0,
      vPad: 0,
      child: InkWell(
        onTap: enabled ? onTap : null,
        customBorder: const CircleBorder(),
        // 悬停直接变为小手（与 onTap 状态绑定，禁用时恢复默认光标）
        mouseCursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, size: 22, color: color),
        ),
      ),
    );
  }
}

/// 高斯模糊毛玻璃块（把背后的星星光晕模糊掉，保证文字清晰）
class _GlassBlock extends StatelessWidget {
  final Widget child;

  /// 圆角半径（默认 12）
  final double radius;

  /// 水平内边距（默认 14）
  final double hPad;

  /// 垂直内边距（默认 8）
  final double vPad;

  const _GlassBlock({
    required this.child,
    this.radius = 12,
    this.hPad = 14,
    this.vPad = 8,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
          decoration: BoxDecoration(
            color: const Color(0x33000000),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: const Color(0x1AFFFFFF), // 10% 白细边，玻璃质感
              width: 0.8,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 星球材质回退白名单（seed → 材质风格）。
/// 优先级：接口 `type` 字段 → 本白名单 → 默认 earth。
/// 仅用于老版本数据/接口未返回 type 时兜底；后台创建时已可指定 type。
const Map<int, PlanetStyle> _styleBySeed = {
  88886666: PlanetStyle.lava, // 熔岩星（旧数据兜底）
  99990001: PlanetStyle.jupiter, // 木星云带星（旧数据兜底）
  66667777: PlanetStyle.gradientPink, // 粉红渐变星（旧数据兜底）
};

/// 临时预览开关：赋值则忽略接口 type 全量预览该材质；null = 按正常逻辑。
const PlanetStyle? _stylePreviewAll = null;

/// 星球页专用颜色：夜间宇宙黑
const Color _spaceBg = Color(0xFF03030A);

/// 星球页专用颜色：白天稍亮深蓝黑
const Color _spaceBgDay = Color(0xFF0B1020);

/// 星球页主文字（宇宙黑上固定白色）
const Color _spaceText = Colors.white;
