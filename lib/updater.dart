import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'app_config.dart';
import 'notify.dart';

/// 更新包目标平台
enum UpdatePlatform { android, ios, win, mac }

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
      case 'android':
        return UpdatePlatform.android;
      case 'ios':
        return UpdatePlatform.ios;
      case 'mac':
        return UpdatePlatform.mac;
      default:
        return UpdatePlatform.win;
    }
  }
}

/// 更新服务：检查新版本、下载安装包、忽略版本记录
class Updater {
  Updater._();

  static final Updater instance = Updater._();

  /// 客户端当前平台标识
  static UpdatePlatform get _clientPlatform {
    if (Platform.isAndroid) return UpdatePlatform.android;
    if (Platform.isIOS) return UpdatePlatform.ios;
    if (Platform.isMacOS) return UpdatePlatform.mac;
    return UpdatePlatform.win;
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
      case UpdatePlatform.android:
        return 'android';
      case UpdatePlatform.ios:
        return 'ios';
      case UpdatePlatform.mac:
        return 'mac';
      case UpdatePlatform.win:
        return 'win';
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
    final ok = await _downloadAndPrepare(info);
    if (ok) {
      NotifyStack.instance.dismiss('update_progress_${info.version}');
      NotifyStack.instance.dismiss('update_${info.version}');
      NotifyStack.success('更新包已就绪，即将重启…');
      // 延迟一点让用户看到成功提示，然后重启
      Future.delayed(const Duration(seconds: 2), _restartAndInstall);
    } else {
      NotifyStack.instance.dismiss('update_progress_${info.version}');
      NotifyStack.warning('下载失败，请稍后重试');
    }
  }

  /// 下载安装包到临时目录
  Future<bool> _downloadAndPrepare(UpdateInfo info) async {
    try {
      final resp = await http.get(Uri.parse(info.downloadUrl));
      if (resp.statusCode != 200) return false;
      final tmp = Directory.systemTemp;
      // Windows 解压后启动安装；其他平台直接打开下载的包
      final ext = _platformName(info.platform) == 'win'
          ? '.exe'
          : (_platformName(info.platform) == 'android' ? '.apk' : '.pkg');
      final outFile = File('${tmp.path}${Platform.pathSeparator}acgo_update_$ext');
      await outFile.writeAsBytes(resp.bodyBytes, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 重启并安装更新（Windows：直接启动安装 exe；macOS：open 打开安装包）
  Future<void> _restartAndInstall() async {
    try {
      final tmp = Directory.systemTemp;
      final candidates = [
        '${tmp.path}${Platform.pathSeparator}acgo_update.exe',
        '${tmp.path}${Platform.pathSeparator}acgo_update.apk',
        '${tmp.path}${Platform.pathSeparator}acgo_update.pkg',
      ];
      for (final p in candidates) {
        if (File(p).existsSync()) {
          if (Platform.isMacOS) {
            // macOS：通过 open 打开 pkg 安装包
            await Process.start('open', [p], mode: ProcessStartMode.detached);
          } else {
            await Process.start(p, [], mode: ProcessStartMode.detached);
          }
          exit(0);
        }
      }
    } catch (_) {}
  }
}