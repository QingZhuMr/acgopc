import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:window_manager/window_manager.dart';

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../core/app_theme.dart';
import '../core/device_service.dart';
import 'maintenance.dart';
import 'register_page.dart';
import '../services/secure_storage.dart';
import '../widgets/text_input_menu.dart';

/// 登录成功回调（携带用户信息）
typedef LoginSuccess = void Function(Map<String, dynamic> user);

/// 用户登录页：启动时显示，登录成功进入主界面。
class LoginPage extends StatefulWidget {
  final LoginSuccess onSuccess;

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
  bool _autoLogin = true; // 是否自动登录/保持登录（默认勾选；前置：必须记住密码）
  bool _loading = false; // 是否登录中
  String? _error; // 错误提示

  @override
  void initState() {
    super.initState();
    // 读取登录偏好：填充账号密码 + 恢复勾选状态（含自动登录）
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
            // 应用标识 + 设备唯一ID（后端据此签发设备密钥，实现单设备在线）
            platform: DeviceService.instance.platform,
            deviceId: DeviceService.instance.getDeviceId(),
          )
          .timeout(const Duration(seconds: 10));

      final Map<String, dynamic> json =
          (jsonDecode(resp.body) as Map<String, dynamic>?) ?? {};

      final code = json['code'];
      if (code == 0) {
        // 登录成功
        final user = (json['data']?['user'] as Map<String, dynamic>?) ?? {};
        // 保存封禁状态到 user，供个人中心显示"正常/封禁"
        final banned = (json['data']?['banned'] as bool?) ?? false;
        if (user.isNotEmpty) user['banned'] = banned;
        // 保存后端签发的设备密钥（每次请求校验用）
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
          // 未勾选记住密码：清除偏好（自动登录必然也为 false）
          await SecureStorage.instance.clearPreferences();
        }
        if (mounted) widget.onSuccess(user);
      } else if (code == 503) {
        // 平台维护中：禁止登录，展示维护公告
        MaintenanceService.instance.updateFromLogin(json['data'] as Map<String, dynamic>?);
        MaintenanceService.instance.pushNotify();
        setState(() => _error = (json['msg'] as String?) ?? '平台维护中，请稍后再试');
      } else {
        setState(() => _error = (json['msg'] as String?) ?? '登录失败');
      }
    } catch (_) {
      setState(() => _error = '网络错误，请检查后端服务是否启动');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final accent = kPrimary;
    final fieldBg = bgColor(b);
    final textCol = textColor(b);
    final mutedCol = textMutedColor(b);

    return Scaffold(
      backgroundColor: bgSoftColor(b),
      body: Stack(
        children: [
          // ===== 背景 logo（右下角对齐，水印） =====
          Positioned(
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.5,
                child: Image.asset(
                  AppConfig.assetLogoWhite,
                  width: 340,
                  height: 340,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
          Column(
            children: [
              // ===== 自绘顶栏（左侧 logo，右侧窗口控制） =====
              _LoginTitleBar(brightness: b),
              // ===== 登录主体 =====
              Expanded(
                child: Center(
                  child: SilkySingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    scrollSpeed: 1.6,
                    silkyScrollDuration: const Duration(milliseconds: 600),
                    animationCurve: Curves.easeOutCubic,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 380),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // 应用 Logo + 标题
                            // const Image(
                            //   image: AssetImage('assets/images/app_logo.png'),
                            //   width: 256,
                            //   height: 256,
                            //   fit: BoxFit.contain,
                            // ),
                            const SizedBox(height: 12),
                            Text(
                              AppConfig.appName,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w700,
                                color: textCol,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '让把烦恼和不爽抛脑后，只许傻乐',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 13, color: mutedCol),
                            ),
                            const SizedBox(height: 32),

                            // 账号输入（手机号或 UID）
                            TextInputBubbleMenu(
                              controller: _usernameCtrl,
                              child: TextFormField(
                                controller: _usernameCtrl,
                                // 禁用系统右键菜单（统一用气泡方案）
                                contextMenuBuilder: (_, __) =>
                                    const SizedBox.shrink(),
                                style: TextStyle(color: textCol),
                                decoration: InputDecoration(
                                  labelText: '手机号 / UID',
                                  labelStyle: TextStyle(color: mutedCol),
                                  filled: true,
                                  fillColor: fieldBg,
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius:
                                        BorderRadius.circular(kRadiusMd),
                                    borderSide: BorderSide(
                                        color: textFaintColor(b)
                                            .withValues(alpha: .3)),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius:
                                        BorderRadius.circular(kRadiusMd),
                                    borderSide: const BorderSide(
                                        color: kPrimary, width: 1.5),
                                  ),
                                ),
                                validator: (v) =>
                                    (v == null || v.trim().isEmpty)
                                        ? '请输入手机号或 UID'
                                        : null,
                              ),
                            ),
                            const SizedBox(height: 16),

                            // 密码输入
                            TextInputBubbleMenu(
                              controller: _passwordCtrl,
                              obscure: true,
                              child: TextFormField(
                                controller: _passwordCtrl,
                                obscureText: _obscure,
                                // 禁用系统右键菜单（统一用气泡方案）
                                contextMenuBuilder: (_, __) =>
                                    const SizedBox.shrink(),
                                // 仅允许英文/数字/英文标点（行业通用密码字符集，禁止中文、空格、emoji）
                                inputFormatters: [
                                  FilteringTextInputFormatter.allow(
                                      RegExp(r'[\x21-\x7E]')),
                                ],
                                style: TextStyle(color: textCol),
                                decoration: InputDecoration(
                                  labelText: '密码',
                                  labelStyle: TextStyle(color: mutedCol),
                                  // ExcludeFocus：Tab 键跳过「显示密码」按钮
                                  suffixIcon: ExcludeFocus(
                                    child: IconButton(
                                      icon: Icon(
                                        _obscure
                                            ? Icons.visibility_off_outlined
                                            : Icons.visibility_outlined,
                                        color: mutedCol,
                                        size: 20,
                                      ),
                                      onPressed: () =>
                                          setState(() => _obscure = !_obscure),
                                    ),
                                  ),
                                  filled: true,
                                  fillColor: fieldBg,
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius:
                                        BorderRadius.circular(kRadiusMd),
                                    borderSide: BorderSide(
                                        color: textFaintColor(b)
                                            .withValues(alpha: .3)),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius:
                                        BorderRadius.circular(kRadiusMd),
                                    borderSide: const BorderSide(
                                        color: kPrimary, width: 1.5),
                                  ),
                                ),
                                onFieldSubmitted: (_) => _login(),
                                validator: (v) => (v == null || v.isEmpty)
                                    ? '请输入密码'
                                    : null,
                              ),
                            ),

                            // 错误提示
                            if (_error != null) ...[
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
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

                            const SizedBox(height: 16),

                            // 记住密码 + 保持登录勾选（联动：保持登录依赖记住密码）
                            // 两端对齐：记住密码靠左，保持登录靠右
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
                            const SizedBox(height: 16),

                            // 登录按钮
                            SizedBox(
                              height: 44,
                              child: FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: accent,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(kRadiusBtn),
                                  ),
                                ),
                                onPressed: _loading ? null : _login,
                                child: _loading
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white),
                                      )
                                    : const Text('登 录',
                                        style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600)),
                              ),
                            ),
                            const SizedBox(height: 8),

                            // 去注册入口
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text('没有账号？',
                                    style: TextStyle(
                                        fontSize: 13, color: mutedCol)),
                                TextButton(
                                  onPressed: _loading
                                      ? null
                                      : () => Navigator.of(context).push(
                                            MaterialPageRoute(
                                              builder: (_) => RegisterPage(
                                                  onSuccess: widget.onSuccess),
                                            ),
                                          ),
                                  child: Text('去注册',
                                      style: TextStyle(
                                          fontSize: 13, color: accent)),
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
            ],
          ),
        ],
      ),
    );
  }
}

/// 登录页顶栏：左侧 logo，右侧窗口控制
class _LoginTitleBar extends StatelessWidget {
  final Brightness brightness;

  const _LoginTitleBar({required this.brightness});

  @override
  Widget build(BuildContext context) {
    // macOS：左侧预留红黄绿按钮安全距离，右侧仅拖拽（无窗口按钮）
    if (Platform.isMacOS) {
      return SizedBox(
        height: 40,
        child: Row(
          children: [
            SizedBox(
              width: kMacTrafficLightWidth,
              child: Container(color: bgSoftColor(brightness)),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => windowManager.startDragging(),
                child: Container(color: bgSoftColor(brightness)),
              ),
            ),
          ],
        ),
      );
    }
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          // 左侧：与内容同色（可拖拽区域）
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => windowManager.startDragging(),
              child: Container(color: bgSoftColor(brightness)),
            ),
          ),
          // 窗口控制按钮
          _LoginWinButton(
            icon: Icons.remove,
            onTap: () => windowManager.minimize(),
          ),
          _LoginWinButton(
            icon: Icons.crop_square_rounded,
            onTap: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
          _LoginWinButton(
            icon: Icons.close,
            isClose: true,
            onTap: () => windowManager.close(),
          ),
        ],
      ),
    );
  }
}

/// 登录页勾选项（记住密码 / 自动登录）
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

/// 登录页窗口控制按钮
class _LoginWinButton extends StatelessWidget {
  final IconData icon;
  final bool isClose;
  final VoidCallback onTap;

  const _LoginWinButton({
    required this.icon,
    this.isClose = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return SizedBox(
      width: 46,
      height: 40,
      child: InkWell(
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click, // 悬停显示手指
        hoverColor: isClose ? const Color(0xFFE81123) : bgHoverColor(b),
        child: Icon(
          icon,
          size: 16,
          color: isClose ? null : textMutedColor(b),
        ),
      ),
    );
  }
}
