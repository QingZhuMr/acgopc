import 'dart:io';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app_config.dart';

/// 应用服务：管理单实例 + 系统托盘 + 关闭驻留后台。
///
/// 功能：
///  - 单实例：程序只允许运行一个；重复启动时唤起已有实例的窗口
///  - 系统托盘：关闭窗口时隐藏到托盘（后台驻存），托盘菜单可恢复/退出
class AppService {
  AppService._();

  /// 单例
  static final AppService instance = AppService._();

  /// "唤起窗口"请求标记文件路径
  String get _showRequestPath =>
      '${_cacheDir()}${Platform.pathSeparator}show_request';

  /// 窗口关闭监听（成员持有，避免被 GC 导致监听失效）
  final _WindowCloseListener _closeListener = _WindowCloseListener();

  /// 托盘事件监听（成员持有，避免被 GC）
  final _TrayListener _trayListener = _TrayListener();

  /// 初始化应用服务。
  /// 返回 true 表示本进程是主实例（可以启动）；false 表示已有实例并已请求唤起其窗口。
  Future<bool> init() async {
    // 双重单实例检测：进程检测（主）+ 文件锁（兜底）
    // 若已有其它实例在运行 => 请求唤起其窗口并返回 false
    if (await _hasExistingInstance()) {
      _requestShow();
      return false;
    }
    // 拦截窗口关闭：点 × 时隐藏到托盘而非退出
    // 用 setPreventClose(true) 阻止默认关闭（可靠），配合 onWindowClose 隐藏
    try {
      await windowManager.setPreventClose(true);
    } catch (_) {}
    windowManager.addListener(_closeListener);
    // 托盘初始化放后台执行，失败不影响窗口显示
    _setupTray();
    // 监听"唤起窗口"请求：有新的启动尝试时显示本窗口
    _startShowRequestWatcher();
    return true;
  }

  /// 检测是否已有本程序实例在运行。
  ///
  /// 采用双保险：
  ///  - 进程检测（主）：用 PowerShell Get-Process 统计 Yeahbear 进程数，>1 则已有实例
  ///  - 文件锁（兜底）：lockSync 被占用则视为已有实例
  Future<bool> _hasExistingInstance() async {
    // 第一层：进程检测（可靠）
    try {
      final res = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        '(Get-Process -Name Yeahbear -ErrorAction SilentlyContinue).Count',
      ]);
      final count = int.tryParse(res.stdout.toString().trim()) ?? 0;
      if (count > 1) {
        return true; // 已有其它实例在运行
      }
    } catch (_) {}

    // 第二层：文件锁兜底
    try {
      final dir = Directory(_cacheDir());
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final lockPath =
          '${_cacheDir()}${Platform.pathSeparator}single_instance.lock';
      final f = File(lockPath);
      if (!f.existsSync()) {
        f.writeAsStringSync('lock\n');
      }
      final raf = f.openSync(mode: FileMode.append);
      try {
        raf.lockSync(FileLock.exclusive, 0, 1);
      } catch (_) {
        raf.closeSync();
        return true; // 已有实例持锁
      }
      raf.closeSync();
    } catch (_) {}

    return false;
  }

  /// 请求已有实例显示窗口（写标记文件）
  void _requestShow() {
    try {
      final dir = Directory(_cacheDir());
      if (!dir.existsSync()) dir.createSync(recursive: true);
      File(_showRequestPath).writeAsStringSync(
          '${DateTime.now().toIso8601String()}\n');
    } catch (_) {}
  }

  /// 用户缓存目录（文档目录/appNameEn）
  String _cacheDir() => AppConfig.dataDir;

  /// 初始化系统托盘
  Future<void> _setupTray() async {
    // 提取托盘图标（asset 打包后不可直接当路径，写入临时目录）
    final iconFile = await _extractTrayIcon();

    if (iconFile != null) {
      await trayManager.setIcon(iconFile.path);
    }
    await trayManager.setToolTip(AppConfig.appName);

    // 托盘右键菜单
    final menu = Menu(
      items: [
        MenuItem(
          key: 'show',
          label: '显示主窗口',
          onClick: (_) => windowManager.show(),
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'quit',
          label: '退出',
          onClick: (_) async {
            // 真正退出：先解除关闭阻止，再销毁窗口退出
            try {
              await windowManager.setPreventClose(false);
            } catch (_) {}
            await windowManager.destroy();
            exit(0);
          },
        ),
      ],
    );
    await trayManager.setContextMenu(menu);

    // 托盘事件监听（用成员变量，避免被 GC）
    trayManager.addListener(_trayListener);
  }

  /// 从 asset 提取托盘图标到临时目录（Windows 需 .ico）
  Future<File?> _extractTrayIcon() async {
    try {
      final data = await rootBundle.load(AppConfig.assetTrayIcon);
      final tmp = Directory.systemTemp;
      final f = File('${tmp.path}${Platform.pathSeparator}acgo_tray.ico');
      await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
      return f;
    } catch (_) {
      return null;
    }
  }

  /// 监听"唤起窗口"请求：周期性检查 show_request 文件，
  /// 存在则显示窗口并清除标记。用于重复启动时把已有实例窗口带到前台。
  void _startShowRequestWatcher() {
    Future<void> loop() async {
      while (true) {
        try {
          final req = File(_showRequestPath);
          if (await req.exists()) {
            await req.delete();
            await windowManager.show();
            await windowManager.focus();
          }
        } catch (_) {}
        // 每 500ms 检查一次
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }

    loop();
  }

  /// 清理（进程退出时调用：清理唤起标记）
  Future<void> dispose() async {
    try {
      final req = File(_showRequestPath);
      if (await req.exists()) await req.delete();
    } catch (_) {}
  }
}

/// 窗口关闭监听：点击关闭按钮（×）时隐藏到托盘，而不是退出进程。
class _WindowCloseListener extends WindowListener {
  @override
  void onWindowClose() async {
    try {
      // 阻止默认关闭（退出），改为隐藏窗口（驻留后台，进程保留）
      await windowManager.hide();
    } catch (_) {
      // hide 失败兜底：强制隐藏，确保进程不退出
      await windowManager.setSkipTaskbar(true);
      await windowManager.setPreventClose(true);
      await windowManager.hide();
    }
  }
}

/// 托盘事件监听：左键单击显示窗口，右键弹出菜单。
class _TrayListener extends TrayListener {
  @override
  void onTrayIconMouseDown() {
    // 左键点击托盘图标，恢复窗口
    windowManager.show();
  }

  @override
  void onTrayIconRightMouseDown() {
    // 右键点击托盘图标，弹出菜单
    trayManager.popUpContextMenu();
  }
}
