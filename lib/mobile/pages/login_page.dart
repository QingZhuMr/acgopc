import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../../core/api_client.dart';
import '../../core/app_config.dart';
import '../../core/app_theme.dart';
import '../../core/device_service.dart';
import '../../services/secure_storage.dart';
import '../theme/mobile_theme.dart';
import '../widgets/glass_button.dart';
import '../widgets/mobile_form_pane.dart';
import 'register_page.dart';

/// 移动端登录成功回调（携带用户信息）
typedef MobileLoginSuccess = void Function(Map<String, dynamic> user);

/// 移动端用户登录页
///
/// 遵守 `docs/移动端UI规范.md`：渐变背景、二级玻璃输入框、胶囊按钮、
/// silky_scroll 滚动、系统字体；不 import 桌面页面 / 组件。
class LoginPage extends StatefulWidget {
  final MobileLoginSuccess onSuccess;

  const LoginPage({super.key, required this.onSuccess});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  bool _obscure = true; // 密码是否可见
  bool _rememberPwd = true; // 是否记住密码
  bool _autoLogin = true; // 是否自动登录/保持登录（前置：必须记住密码）
  bool _loading = false; // 是否登录中
  String? _error; // 错误提示

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  /// 读取登录偏好填充登录框与勾选状态
  Future<void> _loadPreferences() async {
    final pref = await SecureStorage.instance.readPreferences();
    if (pref == null || !mounted) return;
    _usernameCtrl.text = pref.account;
    _passwordCtrl.text = pref.password;
    setState(() {
      _rememberPwd = pref.rememberPwd;
      _autoLogin = pref.autoLogin && pref.rememberPwd;
    });
  }

  /// 勾选自动登录：强制同时记住密码（自动登录依赖记住密码）
  void _onAutoLoginChanged(bool? v) {
    setState(() {
      _autoLogin = v ?? false;
      if (_autoLogin) _rememberPwd = true;
    });
  }

  /// 取消记住密码：自动登录一并取消（失去前置条件）
  void _onRememberPwdChanged(bool? v) {
    setState(() {
      _rememberPwd = v ?? false;
      if (!_rememberPwd) _autoLogin = false;
    });
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  /// 发起登录请求
  Future<void> _login() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final resp = await ApiClient.instance
          .postLogin(
            account: _usernameCtrl.text.trim(),
            password: _passwordCtrl.text,
            platform: DeviceService.instance.platform,
            deviceId: DeviceService.instance.getDeviceId(),
          )
          .timeout(const Duration(seconds: 10));

      final json = (jsonDecode(resp.body) as Map<String, dynamic>?) ?? {};

      final code = json['code'];
      if (code == 0) {
        // 登录成功
        final user = (json['data']?['user'] as Map<String, dynamic>?) ?? {};
        final banned = (json['data']?['banned'] as bool?) ?? false;
        if (user.isNotEmpty) user['banned'] = banned;
        final deviceKey = (json['data']?['device_key'] as String?) ?? '';
        if (deviceKey.isNotEmpty) {
          DeviceService.instance.saveDeviceKey(deviceKey);
        }
        // 保存登录偏好（记住密码 + 是否自动登录）
        if (_rememberPwd) {
          await SecureStorage.instance.savePreferences(
            account: _usernameCtrl.text.trim(),
            password: _passwordCtrl.text,
            rememberPwd: _rememberPwd,
            autoLogin: _autoLogin,
          );
        } else {
          await SecureStorage.instance.clearPreferences();
        }
        if (mounted) widget.onSuccess(user);
      } else if (code == 503) {
        // 平台维护中：禁止登录，展示维护公告
        setState(() => _error = (json['msg'] as String?) ?? '平台维护中，请稍后再试');
      } else {
        setState(() => _error = (json['msg'] as String?) ?? '登录失败');
      }
    } catch (_) {
      setState(() => _error = '网络错误，请检查网络连接');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final theme = Theme.of(context);
    final textCol = textColor(b);
    final mutedCol = textMutedColor(b);

    return Scaffold(
      body: Container(
        // 背景必须全屏：强制撑满视口，不能按内容高度收缩（否则底部露主题底色）
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(gradient: MobileTheme.background(b)),
        child: SafeArea(
          child: SilkySingleChildScrollView(
            scrollSpeed: 1.6,
            silkyScrollDuration: const Duration(milliseconds: 600),
            animationCurve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
            child: MobileFormPane(
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ===== 应用 Logo + 标题 =====
                    Center(
                      child: ClipOval(
                        child: Image.asset(
                          AppConfig.assetLogo,
                          width: 84,
                          height: 84,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            width: 84,
                            height: 84,
                            color: bgHoverColor(b),
                            child: Icon(Icons.pets_rounded,
                                size: 40, color: kPrimary),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      AppConfig.appName,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontSize: 28, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '让把烦恼和不爽抛脑后，只许傻乐',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 13),
                    ),
                    const SizedBox(height: 36),

                    // ===== 账号输入（手机号或 UID） =====
                    TextFormField(
                      controller: _usernameCtrl,
                      keyboardType: TextInputType.text,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.next,
                      style: TextStyle(color: textCol, fontSize: 16),
                      decoration: const InputDecoration(
                        labelText: '手机号 / UID',
                        prefixIcon:
                            Icon(Icons.person_outline_rounded, size: 20),
                      ),
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? '请输入手机号或 UID'
                          : null,
                    ),
                    const SizedBox(height: 16),

                    // ===== 密码输入 =====
                    TextFormField(
                      controller: _passwordCtrl,
                      obscureText: _obscure,
                      // 仅允许英文/数字/英文标点（行业通用密码字符集）
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[\x21-\x7E]')),
                      ],
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _login(),
                      style: TextStyle(color: textCol, fontSize: 16),
                      decoration: InputDecoration(
                        labelText: '密码',
                        prefixIcon:
                            const Icon(Icons.lock_outline_rounded, size: 20),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscure
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            size: 20,
                            color: mutedCol,
                          ),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                      validator: (v) =>
                          (v == null || v.isEmpty) ? '请输入密码' : null,
                    ),

                    // ===== 错误提示 =====
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: kDanger.withValues(alpha: .1),
                          borderRadius: BorderRadius.circular(kRadiusSm),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline,
                                size: 16, color: kDanger),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _error!,
                                style: const TextStyle(
                                    fontSize: 13, color: kDanger),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 12),

                    // ===== 记住密码 + 保持登录（联动） =====
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _CheckboxItem(
                          value: _rememberPwd,
                          label: '记住密码',
                          color: mutedCol,
                          onChanged: _onRememberPwdChanged,
                        ),
                        _CheckboxItem(
                          value: _autoLogin,
                          label: '保持登录',
                          color: mutedCol,
                          onChanged: _onAutoLoginChanged,
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // ===== 登录按钮（iOS 26 主操作：kPrimary 实底胶囊） =====
                    GlassButton.primary(
                      label: '登 录',
                      loading: _loading,
                      expanded: true,
                      onPressed: _login,
                    ),
                    const SizedBox(height: 12),

                    // ===== 去注册（iOS 26 文字链接） =====
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('没有账号？',
                            style: TextStyle(fontSize: 14, color: mutedCol)),
                        GlassButton.link(
                          label: '去注册',
                          onPressed: _loading
                              ? null
                              : () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => RegisterPage(
                                          onSuccess: widget.onSuccess),
                                    ),
                                  ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 移动端登录页勾选项（记住密码 / 保持登录）
class _CheckboxItem extends StatelessWidget {
  final bool value;
  final String label;
  final Color color;
  final ValueChanged<bool> onChanged;

  const _CheckboxItem({
    required this.value,
    required this.label,
    required this.color,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 20,
          height: 20,
          child: Checkbox(
            value: value,
            activeColor: kPrimary,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (v) => onChanged(v ?? false),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 13, color: color)),
      ],
    );
  }
}
