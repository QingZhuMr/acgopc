import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

import '../core/app_config.dart';

/// 记住密码存储（用户偏好，存入 config 目录）。
///
/// 使用 AES-256-CBC 加密记住的账号密码，
/// 密钥由「固定 salt + 机器标识」派生（HMAC-SHA256），避免明文。
///
/// 语义（见 docs/安全规范.md）：
///  - **记住密码 ≠ 自动登录**：只用于登录页自动填充账号密码，用户仍需手动点登录。
///  - 退出登录**保留**记住的密码（属用户偏好，非登录态）。
///  - 仅当用户主动清理或切换账号不勾选"记住密码"时清除。
///
/// 登录态（token / device_key）不在此处持久化：
///  - token 仅在内存中持有（本次会话），退出即释放。
///  - device_key 由 DeviceService 存 data 目录（退出登录清除）。

/// 登录偏好模型（account = 手机号或 UID）
class LoginPreference {
  final String account;
  final String password;
  final bool rememberPwd;
  final bool autoLogin;

  const LoginPreference({
    required this.account,
    required this.password,
    required this.rememberPwd,
    required this.autoLogin,
  });
}

class SecureStorage {
  SecureStorage._();

  static final SecureStorage instance = SecureStorage._();

  /// 固定 salt（可调整，但改后历史加密数据将无法解密）
  static const String _salt = 'acgo_pc_v1_salt_#8kF!';

  /// 登录偏好文件路径（config 目录）
  File get _credFile =>
      File('${AppConfig.configDir}${Platform.pathSeparator}credentials.dat');

  /// 派生密钥：HMAC-SHA256(机器标识, salt) 截取 32 字节
  enc.Key _deriveKey() {
    final machineId = _machineId();
    final digest = Hmac(sha256, utf8.encode(_salt))
        .convert(utf8.encode(machineId))
        .bytes;
    return enc.Key.fromBase64(base64Encode(digest));
  }

  /// 机器标识（跨重启稳定）：主机名 + 用户名，不足时补随机
  String _machineId() {
    try {
      final host = Platform.localHostname;
      final user = Platform.environment['USERNAME'] ?? '';
      return 'acgo|$host|$user';
    } catch (_) {
      return 'acgo|fallback|${Random().nextInt(1 << 32)}';
    }
  }

  /// 保存登录偏好（加密写入 config/credentials.dat）
  ///
  /// [rememberPwd] 是否记住密码；[autoLogin] 是否自动登录。
  /// 自动登录的前置条件是记住密码（autoLogin=true 时必须 rememberPwd=true）。
  Future<void> savePreferences({
    required String account,
    required String password,
    required bool rememberPwd,
    required bool autoLogin,
  }) async {
    try {
      final iv = enc.IV.fromSecureRandom(16);
      final encrypter = enc.Encrypter(enc.AES(_deriveKey(), mode: enc.AESMode.cbc));
      final payload = jsonEncode({
        'account': account,
        'password': password,
        'remember_pwd': rememberPwd,
        'auto_login': autoLogin,
        'saved_at': DateTime.now().toIso8601String(),
      });
      final encrypted = encrypter.encrypt(payload, iv: iv);
      // 格式：IV(16字节 base64) + 密文
      final data = '${base64Encode(iv.bytes)}:${encrypted.base64}';
      await _credFile.writeAsString(data, flush: true);
    } catch (_) {
      // 写入失败静默（不影响主流程）
    }
  }

  /// 读取登录偏好；无记录或解密失败返回 null
  Future<LoginPreference?> readPreferences() async {
    try {
      if (!await _credFile.exists()) return null;
      final raw = await _credFile.readAsString();
      final parts = raw.split(':');
      if (parts.length != 2) return null;
      final iv = enc.IV(base64Decode(parts[0]));
      final encrypter = enc.Encrypter(enc.AES(_deriveKey(), mode: enc.AESMode.cbc));
      final decrypted = encrypter.decrypt64(parts[1], iv: iv);
      final json = jsonDecode(decrypted) as Map<String, dynamic>;
      return LoginPreference(
        account: json['account'] as String? ?? '',
        password: json['password'] as String? ?? '',
        rememberPwd: json['remember_pwd'] == true,
        autoLogin: json['auto_login'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  /// 清除登录偏好（用户主动"清理本地数据"时调用）
  Future<void> clearPreferences() async {
    try {
      if (await _credFile.exists()) {
        await _credFile.delete();
      }
    } catch (_) {}
  }

  /// 用本机派生密钥加密本地敏感数据（AES-256-GCM）
  ///
  /// 返回格式 `g1:{iv}:{tag}:{cipher}`，供 ChatStore 加密私钥用。
  /// 同一台机器可解密；换机器/换系统（机器标识改变）将无法解密，
  /// 上层应降级处理（如重新生成密钥对）。
  Future<String> encryptLocal(String plain) async {
    final iv = enc.IV.fromSecureRandom(12);
    final encrypter = enc.Encrypter(
        enc.AES(_deriveKey(), mode: enc.AESMode.gcm, padding: null));
    final encrypted = encrypter.encrypt(plain, iv: iv);
    // encrypt 库 GCM 输出 = ciphertext + tag（16 字节），一并存储
    return 'g1:${base64Encode(iv.bytes)}:${encrypted.base64}';
  }

  /// 解密 [encryptLocal] 加密的数据；格式不符或解密失败返回 null
  Future<String?> decryptLocal(String payload) async {
    try {
      final parts = payload.split(':');
      if (parts.length != 3 || parts[0] != 'g1') return null;
      final iv = enc.IV(base64Decode(parts[1]));
      final encrypter = enc.Encrypter(
          enc.AES(_deriveKey(), mode: enc.AESMode.gcm, padding: null));
      return encrypter.decrypt64(parts[2], iv: iv);
    } catch (_) {
      return null;
    }
  }
}
