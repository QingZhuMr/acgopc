import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../widgets/notify.dart';

/// 更新包目标平台（与后端 admin 枚举一致）
enum UpdatePlatform { win, mac, linux, android, ios, ipados, harmony }

/// 更新版本信息（后端推送内容）
class UpdateInfo {
  final String version; // 版本号，如 "0.2.0"
  final String title;
  final String message;
  final UpdatePlatform platform;
  final String downloadUrl; // 安装包 URL 或 App Store 地址
  final bool mandatory; // 是否强制更新

  UpdateInfo({
    required this.version,
    required this.title,
    required this.message,
    required this.platform,
    required this.downloadUrl,
    this.mandatory = false,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    return UpdateInfo(
      version: json['version'] as String? ?? '',
      title: json['title'] as String? ?? '新版本发布',
      message: json['message'] as String? ?? '',
      platform: _parsePlatform(json['platform'] as String?),
      downloadUrl: json['download_url'] as String? ?? '',
      mandatory: json['mandatory'] as bool? ?? false,
    );
  }

  static UpdatePlatform _parsePlatform(String? p) {
    switch (p) {
      case 'win':
        return UpdatePlatform.win;
      case 'mac':
        return UpdatePlatform.mac;
      case 'linux':
        return UpdatePlatform.linux;
      case 'android':
        return UpdatePlatform.android;
      case 'ios':
        return UpdatePlatform.ios;
      case 'ipados':
        return UpdatePlatform.ipados;
      case 'harmony':
        return UpdatePlatform.harmony;
      default:
        return UpdatePlatform.win;
    }
  }
}

/// 更新服务：检查新版本、下载安装包、忽略版本记录
class Updater {
  Updater._();

  static final Updater instance = Updater._();

  /// 客户端当前平台标识（按本机系统判断，只接受本平台更新）
  static UpdatePlatform get _clientPlatform {
    if (Platform.isAndroid) return UpdatePlatform.android;
    if (Platform.isIOS) return UpdatePlatform.ios;
    if (Platform.isLinux) return UpdatePlatform.linux;
    if (Platform.isMacOS) return UpdatePlatform.mac;
    return UpdatePlatform.win;
    // iPadOS / 鸿蒙OS：Flutter 无直接 API，iOS 判断覆盖 iPadOS；鸿蒙暂走 Android
  }

  /// 缓存目录：忽略版本记录（config 目录，属用户偏好，退出登录保留）
  File get _ignoredFile =>
      File('${AppConfig.configDir}${Platform.pathSeparator}ignored_versions.json');

  /// 已忽略的版本集合
  Set<String> _ignored = {};

  /// 加载忽略列表
  Future<void> _loadIgnored() async {
    try {
      if (await _ignoredFile.exists()) {
        final list = jsonDecode(await _ignoredFile.readAsString()) as List;
        _ignored = list.cast<String>().toSet();
      }
    } catch (_) {
      _ignored = {};
    }
  }

  /// 持久化忽略列表
  Future<void> _saveIgnored() async {
    try {
      await _ignoredFile.writeAsString(jsonEncode(_ignored.toList()));
    } catch (_) {}
  }

  /// 检查更新：调用后端接口，检查是否有比当前版本新的版本
  ///
  /// [ignoreFilter] 为 true（默认）时，忽略列表中的版本不通知；
  /// **手动检查应传 false**，绕开本地忽略缓存，始终返回服务端最新版本，
  /// 让用户手动检查能看到被忽略过的新版本。
  ///
  /// 返回 UpdateInfo 表示有新版本；null 表示无更新
  Future<UpdateInfo?> checkUpdate({bool ignoreFilter = true}) async {
    await _loadIgnored();
    try {
      final resp = await ApiClient.instance
          .getUpdateCheck(
            platform: _platformName(_clientPlatform),
            clientVersion: AppConfig.appVersion,
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(resp.body) as Map<String, dynamic>?;
      if (json == null || json['code'] != 0) return null;
      final data = json['data'] as Map<String, dynamic>?;
      if (data == null) return null;
      final info = UpdateInfo.fromJson(data);
      // 当前已是最新
      if (info.version.isEmpty) return null;
      // 该版本已被忽略 => 不通知（仅 ignoreFilter=true 时）
      if (ignoreFilter && _ignored.contains(info.version)) return null;
      return info;
    } catch (_) {
      return null;
    }
  }

  String _platformName(UpdatePlatform p) {
    switch (p) {
      case UpdatePlatform.win:
        return 'win';
      case UpdatePlatform.mac:
        return 'mac';
      case UpdatePlatform.linux:
        return 'linux';
      case UpdatePlatform.android:
        return 'android';
      case UpdatePlatform.ios:
        return 'ios';
      case UpdatePlatform.ipados:
        return 'ipados';
      case UpdatePlatform.harmony:
        return 'harmony';
    }
  }

  /// 显示更新通知
  ///
  /// [info] 非空时直接使用（手动检查场景，已拿到结果，避免重复请求/再次被忽略过滤）；
  /// 为空时自动 checkUpdate()。
  Future<void> showUpdateIfAvailable([UpdateInfo? info]) async {
    final target = info ?? await checkUpdate();
    if (target == null) return;
    // push 常驻的更新通知（id 用版本号，去重）
    // 点 X 会先弹"是否忽略当前版本"确认框，确认后调用 ignore 忽略该版本
    _pushUpdateNotify(target);
  }

  /// 从 WebSocket 推送数据直接展示更新通知（避免重复请求 update/check）
  Future<void> showUpdateFromPush(Map<String, dynamic> updateJson) async {
    await _loadIgnored();
    final info = UpdateInfo.fromJson(updateJson);
    if (info.version.isEmpty) return;
    if (_ignored.contains(info.version)) return;
    // push 常驻的更新通知（id 用版本号，去重）
    _pushUpdateNotify(info);
  }

  /// 推送常驻更新通知：点击=下载，点 X=确认忽略
  void _pushUpdateNotify(UpdateInfo info) {
    NotifyStack.instance.dismiss('update_${info.version}');
    NotifyStack.instance.push(NotifyItem(
      id: 'update_${info.version}',
      title: info.title,
      message: info.message,
      type: NotifyType.update,
      persistent: true,
      // 点 X 弹"是否忽略当前版本"确认框（confirmOnDismiss），确认后才调用 onDismiss
      confirmOnDismiss: true,
      dismissConfirmTitle: '忽略更新',
      dismissConfirmMessage: '是否忽略当前版本 ${info.version}？\n忽略后将不再提示该版本更新。',
      dismissConfirmText: '忽略',
      onTap: () => _onUpdateTap(info),
      onDismiss: () => ignore(info.version),
    ));
  }

  /// 手动忽略某版本（不再通知该版本）
  Future<void> ignore(String version) async {
    await _loadIgnored();
    _ignored.add(version);
    await _saveIgnored();
    if (kDebugMode) debugPrint('ignored update: $version');
  }

  /// 点击更新通知：开始下载
  Future<void> _onUpdateTap(UpdateInfo info) async {
    NotifyStack.instance.push(NotifyItem(
      id: 'update_progress_${info.version}',
      title: '正在下载 ${info.version}',
      message: '下载完成后将自动重启安装',
      type: NotifyType.info,
      persistent: true,
      onDismiss: null,
    ));
    final method = await _downloadAndPrepare(info);
    if (method != null) {
      NotifyStack.instance.dismiss('update_progress_${info.version}');
      NotifyStack.instance.dismiss('update_${info.version}');
      NotifyStack.success('更新包已就绪，即将重启…');
      // 延迟一点让用户看到成功提示，然后安装
      final installMethod = method;
      Future.delayed(const Duration(seconds: 2), () async {
        await _installByMethod(installMethod);
      });
    } else {
      NotifyStack.instance.dismiss('update_progress_${info.version}');
      NotifyStack.warning('下载失败，请稍后重试');
    }
  }

  /// 下载安装包到临时目录，并按包类型准备安装方式。
  ///
  /// 安装包类型由 URL 扩展名 / 平台推断：
  /// - Windows `.exe`：直接启动安装器（安装器会等待当前进程退出）
  /// - Windows `.zip`：解压到临时目录，替换运行目录下的可执行文件
  /// - macOS `.dmg` / `.pkg`：用 `open` 打开安装
  ///
  /// 返回安装准备就绪后需要执行的安装方式；失败返回 null。
  Future<String?> _downloadAndPrepare(UpdateInfo info) async {
    try {
      final resp = await http.get(Uri.parse(info.downloadUrl));
      if (resp.statusCode != 200) return null;
      final bytes = resp.bodyBytes;
      if (bytes.isEmpty) return null;
      final tmp = Directory.systemTemp;
      final fileName = _fileNameFromUrl(info.downloadUrl);
      final outFile =
          File('${tmp.path}${Platform.pathSeparator}acgo_update_$fileName');
      await outFile.writeAsBytes(bytes, flush: true);
      return _installMethodFor(fileName);
    } catch (_) {
      return null;
    }
  }

  /// 从 URL 取文件名
  String _fileNameFromUrl(String url) {
    try {
      final seg = Uri.parse(url).pathSegments;
      if (seg.isNotEmpty && seg.last.isNotEmpty) return seg.last;
    } catch (_) {}
    return 'update.bin';
  }

  /// 根据文件名推断安装方式：
  /// 'exe' / 'zip' / 'dmg' / 'pkg' / 'apk'；未知扩展名按平台回退
  String _installMethodFor(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.exe')) return 'exe';
    if (lower.endsWith('.zip')) return 'zip';
    if (lower.endsWith('.dmg')) return 'dmg';
    if (lower.endsWith('.pkg')) return 'pkg';
    if (lower.endsWith('.apk')) return 'apk';
    // 未知：按平台回退（win→exe，mac→pkg）
    return Platform.isMacOS ? 'pkg' : 'exe';
  }

  /// 安装更新：
  /// - exe：启动安装器（installer 等待进程退出后安装）→ 退出当前进程
  /// - zip：弹不可关闭的"正在安装"提示 → 写独立安装脚本 → 启动脚本 →
  ///   退出进程；脚本等主进程退出后自动解压覆盖安装目录并启动新 exe
  /// - dmg/pkg（mac）：open 打开安装包 → 退出当前进程
  /// - apk：启动安装（移动端不适用，跳过）
  Future<bool> _installByMethod(String method) async {
    final tmp = Directory.systemTemp;
    final candidates = Directory(tmp.path)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('acgo_update_'))
        .toList();
    if (candidates.isEmpty) return false;
    final updateFile = candidates.first;

    try {
      switch (method) {
        case 'exe':
          if (!Platform.isWindows) return false;
          await Process.start(updateFile.path, [],
              mode: ProcessStartMode.detached);
          exit(0);
        case 'zip':
          if (!Platform.isWindows) return false;
          return await _installZip(updateFile.path);
        case 'dmg':
        case 'pkg':
          if (!Platform.isMacOS) return false;
          await Process.start('open', [updateFile.path],
              mode: ProcessStartMode.detached);
          exit(0);
        default:
          return false;
      }
    } catch (_) {
      return false;
    }
  }

  /// zip 更新（**仅 Windows 生效**）：静默覆盖安装。
  /// 写独立安装脚本 → detached 启动 → 退出当前进程；
  /// 脚本等旧进程退出后解压覆盖安装目录、启动新 exe、删除 zip 与脚本。
  /// 全程无弹窗（静默）。
  Future<bool> _installZip(String zipPath) async {
    try {
      // 1. 写安装脚本（等主进程退出 → 解压覆盖 → 启动新 exe → 清理安装文件）
      final exePath = Platform.resolvedExecutable; // 当前运行的 exe 绝对路径
      final installDir = File(exePath).parent.path; // 安装目录
      final exeName = File(exePath).path.split(Platform.pathSeparator).last;
      final scriptPath =
          '${Directory.systemTemp.path}${Platform.pathSeparator}acgo_install.bat';
      // 脚本：等待主进程退出（最多 30s）→ 解压 zip 覆盖安装目录 → 启动新 exe
      // → 删除下载的 zip 与安装脚本（静默覆盖，无任何弹窗）
      final script = '''
@echo off
setlocal
rem 等待旧进程退出
for /L %%i in (1,1,30) do (
  tasklist /FI "IMAGENAME eq ${exeName}" 2>nul | find /I "${exeName}" >nul
  if errorlevel 1 goto :done_wait
  timeout /t 1 /nobreak >nul
)
:done_wait
rem 静默解压 zip 覆盖安装目录
powershell -NoProfile -Command "Expand-Archive -Path '${zipPath}' -DestinationPath '${installDir}' -Force"
rem 创建桌面快捷方式"耶熊"（带图标，Win10/11 通知提示显示 ICO 依赖快捷方式）
powershell -NoProfile -Command "\$ws = New-Object -ComObject WScript.Shell; \$desktop = [Environment]::GetFolderPath('Desktop'); \$lnk = \$ws.CreateShortcut((Join-Path \$desktop '${AppConfig.appName}.lnk')); \$lnk.TargetPath = '${installDir}\${exeName}'; \$lnk.WorkingDirectory = '${installDir}'; \$lnk.IconLocation = '${installDir}\${exeName},0'; \$lnk.Save()"
rem 启动新 exe：优先启动主 exe 固定路径（zip 解压到安装目录根目录，
rem 覆盖安装后该路径即为新版本）；若主 exe 不存在（zip 带子目录结构）则递归找第一个 exe
set "NEW_EXE="
if exist "${installDir}\${exeName}" (
  set "NEW_EXE=${installDir}\${exeName}"
) else (
  for /R "${installDir}" %%f in (*.exe) do (
    set "NEW_EXE=%%f"
    goto :launched
  )
)
:launched
if defined NEW_EXE (
  start "" "%NEW_EXE%"
)
rem 静默删除下载的 zip 与安装脚本
del /f /q "${zipPath}" >nul 2>&1
del /f /q "%~f0" >nul 2>&1
exit
''';
      final scriptFile = File(scriptPath);
      await scriptFile.writeAsString(script, flush: true);

      // 2. 后台静默启动安装脚本（PowerShell 隐藏窗口，避免闪黑窗）
      await Process.start('powershell', [
        '-NoProfile',
        '-WindowStyle',
        'Hidden',
        '-Command',
        'Start-Process -FilePath "$scriptPath" -WindowStyle Hidden',
      ], mode: ProcessStartMode.detached);

      // 3. 退出当前进程（脚本会接管后续，静默覆盖）
      exit(0);
    } catch (_) {
      return false;
    }
  }
}