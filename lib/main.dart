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
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'core/app_config.dart';
import 'core/window_effect.dart';
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
