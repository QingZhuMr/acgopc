import 'dart:io';
import 'dart:math';

import 'app_config.dart';

/// 设备服务：管理设备唯一标识（device_id）与登录后签发的设备密钥（device_key）。
///
/// 存储位置：AppConfig.dataDir（文档目录/appNameEn）
///   - device_id  首次生成后固定（UUID 风格）
///   - device_key 登录时后端签发，加密概念上由本文件持久化，供后续请求携带
class DeviceService {
  DeviceService._();

  static final DeviceService instance = DeviceService._();

  /// 当前应用平台标识（后端约定）
  String get platform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'mac';
    if (Platform.isWindows) return 'win';
    return 'h5';
  }

  /// 设备 ID 文件（appData 目录，行业标准：data/ 存设备数据）
  File get _idFile =>
      File('${AppConfig.appDataDir}${Platform.pathSeparator}device_id');

  /// 设备密钥文件（appData 目录；退出登录清除）
  File get _keyFile =>
      File('${AppConfig.appDataDir}${Platform.pathSeparator}device_key');

  /// 获取设备 ID（不存在则生成并保存）
  String getDeviceId() {
    try {
      if (_idFile.existsSync()) {
        final id = _idFile.readAsStringSync().trim();
        if (id.isNotEmpty) return id;
      }
    } catch (_) {}
    final newId = _generateUuid();
    try {
      _idFile.writeAsStringSync(newId, flush: true);
    } catch (_) {}
    return newId;
  }

  /// 保存设备密钥（登录成功时调用）
  void saveDeviceKey(String key) {
    try {
      _keyFile.writeAsStringSync(key, flush: true);
    } catch (_) {}
  }

  /// 读取设备密钥（请求校验用）；未登录/未保存返回空
  String getDeviceKey() {
    try {
      if (_keyFile.existsSync()) {
        return _keyFile.readAsStringSync().trim();
      }
    } catch (_) {}
    return '';
  }

  /// 清除设备密钥（退出登录时调用，但保留 device_id）
  void clearDeviceKey() {
    try {
      if (_keyFile.existsSync()) _keyFile.deleteSync();
    } catch (_) {}
  }

  /// 生成 UUID（v4 风格）
  String _generateUuid() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant
    final hex =
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
