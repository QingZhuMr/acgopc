// ACGO PC 桌面客户端 —— 入口文件
//
// 运行方式（需已安装 Flutter SDK + Visual Studio C++ 桌面开发）：
//   1. 进入本项目目录 d:/wwwroot/acgopc
//   2. flutter create .     （补齐 Windows 平台编译文件，已执行）
//   3. flutter run -d windows
//
//   - Windows 桌面窗口 + 左侧导航 + 右侧内容区的基本布局
//   - 无边框的左右分区：导航栏(副区块 #F5F7FA/#1E1E23) + 内容页(标准色 #FFF/#23232A)
//   - 白天 / 黑夜 / 跟随系统 三套主题
//
// 代码结构：
//   - lib/main.dart            应用入口（窗口初始化 + runApp）
//   - lib/app/app.dart         应用根组件 AcgoPcApp（主题 / 登录 / WS / 通知）
//   - lib/pages/home/          主框架 HomePage 与广场瀑布流
//   - lib/pages/profile/       个人中心 / 他人主页
//   - lib/pages/settings/      设置页
//   - lib/widgets/             通用组件
//
// 字体：Segoe UI Variable + 中文回退微软雅黑，颜色统一取自 app_theme.dart。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'core/app_config.dart';
import 'core/window_effect.dart';
import 'mobile/mobile_app.dart';
import 'services/app_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 屏蔽 RenderFlex overflow 的底部警示条（黄黑条纹 + 控制台告警），
  // 避免展开评论输入框等布局在 debug 下报 "bottom overflowed by xx pixels"。
  // 仅过滤布局溢出错误，不影响其它异常。
  final originalOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    final msg = details.exceptionAsString();
    if (msg.contains('overflowed by') ||
        msg.contains('A RenderFlex overflowed')) {
      return; // 静默忽略布局溢出
    }
    originalOnError?.call(details);
  };

  // 手机预览模式：`--dart-define=MOBILE_PREVIEW=true`（见 docs/移动端适配方案.md §3.3）
  // 用于在 Windows 桌面以手机尺寸窗口预览移动端 UI（无需 Android/iOS 模拟器）。
  const bool mobilePreview = bool.fromEnvironment('MOBILE_PREVIEW');

  // ==================== 移动端入口分流 ====================
  // 真移动端（Android/iOS）经 DeviceGate 判定：平板（pad）走 PC 界面、
  // 手机走移动端 UI，均不初始化桌面窗口服务；
  // 桌面平台 + MOBILE_PREVIEW=true 时，以手机尺寸窗口运行移动端 UI 做预览。
  if (AppConfig.isMobile || mobilePreview) {
    if (mobilePreview) {
      // 预览模式（仅桌面有效）：手机尺寸窗口（iPhone 15 Pro 逻辑分辨率）
      await windowManager.ensureInitialized();
      const Size kPhoneSize = Size(390, 844);
      const options = WindowOptions(
        size: kPhoneSize,
        center: true,
        minimumSize: Size(320, 568),
        title: '${AppConfig.appName}（手机预览）',
        // 预览期保留系统标题栏，保证可拖动 / 可关闭
        titleBarStyle: TitleBarStyle.normal,
        backgroundColor: null,
      );
      windowManager.waitUntilReadyToShow(options, () async {
        await windowManager.setMinimumSize(const Size(320, 568));
        await windowManager.setSize(kPhoneSize);
        await windowManager.center();
        await windowManager.show();
        await windowManager.focus();
      });
    }
    if (AppConfig.isMobile) {
      // 真移动端：先经 DeviceGate 判定平板/手机再分流
      runApp(const DeviceGate());
    } else {
      // 桌面上的手机预览（MOBILE_PREVIEW=true）直接走移动端 UI
      // 【2026-08-20】弃用 iOS 26 液态玻璃插件（liquid_glass_widgets），
      // 底部导航栏改为自绘高斯模糊样式（见 home_page.dart）。
      runApp(const MobileApp());
    }
    return;
  }

  // ==================== 桌面正式入口 ====================

  // 初始化窗口管理器
  await windowManager.ensureInitialized();

  // 初始化窗口玻璃效果原生通道（实心版本为 no-op，保留调用便于将来恢复）
  await WindowEffectService.initialize();

  // 初始化应用服务（单实例 + 关闭驻留）；失败说明已有实例运行
  // 注意：单实例锁必须最先判定，绝不能阻塞或漏判，避免多开
  if (!await AppService.instance.init()) {
    // 已有实例在运行：必须显式 exit，否则 Flutter 引擎进程不会自动退出
    exit(0);
  }
  // 全程序统一安全最小窗口尺寸（登录窗口与主窗口共用）
  const Size kMinWindowSize = Size(900, 640);
  // 标题栏策略：所有平台都隐藏原生标题栏，由 Flutter 自绘顶栏承担。
  //   - macOS：隐藏原生栏后红黄绿窗口按钮仍显示在左上角，自绘顶栏为其预留安全距离、不绘制窗口按钮
  //   - Windows：隐藏原生栏，自绘顶栏绘制窗口按钮
  // 实心版本：窗口背景保持默认不透明（不启用任何玻璃效果）。
  final options = WindowOptions(
    size: const Size(1080, 720),
    center: true,
    minimumSize: kMinWindowSize,
    // 窗口标题（任务栏 / 菜单栏展示名 = AppConfig.appName）
    title: AppConfig.appName,
    titleBarStyle: TitleBarStyle.hidden,
    // 窗口背景：不透明（实心版本）
    backgroundColor: null,
  );
  windowManager.waitUntilReadyToShow(options, () async {
    // 先固定窗口尺寸，避免 show 时出现"瞬间放大又回归"的闪烁
    await windowManager.setMinimumSize(kMinWindowSize);
    await windowManager.setSize(const Size(1080, 720));
    await windowManager.center();
    // 应用窗口玻璃效果（实心版本为 no-op，须在窗口创建后调用，便于将来恢复）
    await WindowEffectService.applyEffect();
    await windowManager.show();
    await windowManager.focus();
  });
  // 立即启动 UI，确保窗口第一时间显示
  runApp(const AcgoPcApp());
}

/// 移动端启动分流网关（真机 Android/iOS 使用）：
/// 首帧读取屏幕尺寸判定是否平板（pad），然后分流：
///   - pad：走 PC 端界面（AcgoPcApp），支持横竖屏切换，顶栏高度 0px；
///   - 手机：走移动端 UI（MobileApp），锁定竖屏。
/// pad 判定标准：屏幕最短边 >= 600dp（Material 官方 tablet 断点），
/// 无需原生代码，跨 Android/iOS 通用。
class DeviceGate extends StatefulWidget {
  const DeviceGate({super.key});

  @override
  State<DeviceGate> createState() => _DeviceGateState();
}

class _DeviceGateState extends State<DeviceGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _decide());
  }

  Future<void> _decide() async {
    final size = MediaQuery.sizeOf(context);
    final isPad = size.shortestSide >= 600;
    AppConfig.isPad = isPad;
    // 方向策略：pad 支持横竖屏切换；手机不支持横屏（锁定竖屏）
    await SystemChrome.setPreferredOrientations(isPad
        ? const [
            DeviceOrientation.portraitUp,
            DeviceOrientation.portraitDown,
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
    // pad 无窗口顶栏：隐藏系统状态栏/导航栏，让 PC 布局全屏展示（可手势唤出）
    if (isPad) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    if (!mounted) return;
    // pad → PC 界面（各顶栏按 AppConfig.isPad 分支返回高度 0）；
    // 手机 → 移动端 UI。
    runApp(isPad ? const AcgoPcApp() : const MobileApp());
  }

  @override
  Widget build(BuildContext context) {
    // 短暂空白引导页，判定完成即切换（肉眼几乎无感）
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.white,
        body: SizedBox.expand(),
      ),
    );
  }
}
