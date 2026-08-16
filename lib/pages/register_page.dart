import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:window_manager/window_manager.dart';

import '../core/api_client.dart';
import '../core/app_theme.dart';
import '../core/device_service.dart';
import '../widgets/notify.dart';
import '../services/secure_storage.dart';

/// 注册成功回调（注册成功自动登录后携带用户信息进入主界面）
typedef RegisterSuccess = void Function(Map<String, dynamic> user);

/// 用户注册页：验证码 + 注册，注册成功自动登录（保持登录方式）。
class RegisterPage extends StatefulWidget {
  final RegisterSuccess onSuccess;

  const RegisterPage({super.key, required this.onSuccess});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _nicknameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _captchaCtrl = TextEditingController();

  bool _obscure = true; // 密码是否可见
  bool _loading = false; // 注册中
  String _captchaId = ''; // 验证码 ID
  String? _captchaImage; // 验证码图片 base64
  String? _error; // 错误提示

  @override
  void initState() {
    super.initState();
    _refreshCaptcha();
  }

  @override
  void dispose() {
    _nicknameCtrl.dispose();
    _phoneCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    _captchaCtrl.dispose();
    super.dispose();
  }

  /// 生成唯一 captcha_id（UUID v4 简化版）
  String _genCaptchaId() {
    final r = Random.secure();
    final hex =
        List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// 获取验证码图片（刷新）
  Future<void> _refreshCaptcha() async {
    setState(() {
      _captchaId = _genCaptchaId();
      _captchaImage = null;
      _captchaCtrl.clear();
    });
    try {
      final resp = await ApiClient.instance
          .getCaptcha(captchaId: _captchaId)
          .timeout(const Duration(seconds: 10));
      final json = (jsonDecode(resp.body) as Map<String, dynamic>?) ?? {};
      if (json['code'] == 0 && mounted) {
        setState(() {
          _captchaImage = json['data']?['image'] as String?;
        });
      }
    } catch (_) {
      // 网络异常：保留空白，用户可重试刷新
    }
  }

  /// 注册（注册成功自动登录，保持登录方式）
  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    final nickname = _nicknameCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();
    final password = _passwordCtrl.text;
    final confirm = _confirmCtrl.text;
    final captcha = _captchaCtrl.text.trim();

    if (password != confirm) {
      setState(() => _error = '两次输入的密码不一致');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // 1. 注册
      final regResp = await ApiClient.instance
          .postRegister(
            nickname: nickname,
            password: password,
            phone: phone,
            captcha: captcha,
            captchaId: _captchaId,
          )
          .timeout(const Duration(seconds: 10));
      final regJson = (jsonDecode(regResp.body) as Map<String, dynamic>?) ?? {};
      if (regJson['code'] != 0) {
        setState(() {
          _loading = false;
          _error = (regJson['msg'] as String?) ?? '注册失败';
        });
        _refreshCaptcha(); // 失败刷新验证码
        return;
      }

      // 2. 自动登录（保持登录：记住密码 + 自动登录）
      final loginResp = await ApiClient.instance
          .postLogin(
            account: phone,
            password: password,
            platform: DeviceService.instance.platform,
            deviceId: DeviceService.instance.getDeviceId(),
          )
          .timeout(const Duration(seconds: 10));
      final loginJson =
          (jsonDecode(loginResp.body) as Map<String, dynamic>?) ?? {};

      if (loginJson['code'] == 0) {
        // 保存设备密钥
        final deviceKey = (loginJson['data']?['device_key'] as String?) ?? '';
        if (deviceKey.isNotEmpty) {
          DeviceService.instance.saveDeviceKey(deviceKey);
        }
        // 保持登录：记住密码 + 自动登录（记住的是手机号）
        await SecureStorage.instance.savePreferences(
          account: phone,
          password: password,
          rememberPwd: true,
          autoLogin: true,
        );
        final user =
            (loginJson['data']?['user'] as Map<String, dynamic>?) ?? {};
        final banned = (loginJson['data']?['banned'] as bool?) ?? false;
        if (user.isNotEmpty) user['banned'] = banned;
        if (!mounted) return;
        NotifyStack.success('注册成功，已自动登录', title: '欢迎');
        widget.onSuccess(user); // 进入主界面
        Navigator.of(context).popUntil((r) => r.isFirst);
      } else {
        // 注册成功但自动登录失败（极少），提示用户手动登录
        if (!mounted) return;
        setState(() => _loading = false);
        NotifyStack.warning((loginJson['msg'] as String?) ?? '注册成功，请手动登录',
            title: '提示');
        Navigator.of(context).pop(); // 返回登录页
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '网络异常，请重试';
        });
      }
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
                  'assets/images/logo_white.png',
                  width: 340,
                  height: 340,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
          Column(
            children: [
              // ===== 标题栏（返回 + 标题 + 窗口控制） =====
              _RegisterTitleBar(brightness: b),
              // ===== 注册主体 =====
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
                            Align(
                              alignment: Alignment.center,
                              child: Text(
                                '欢迎您和我们一起耶熊！',
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700,
                                  color: textCol,
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Align(
                              alignment: Alignment.center,
                              child: Text(
                                '让我们荡起心头的浆，划走生活的波浪。',
                                style: TextStyle(fontSize: 13, color: mutedCol),
                              ),
                            ),
                            const SizedBox(height: 24),

                            // 昵称
                            TextField(
                              controller: _nicknameCtrl,
                              style: TextStyle(color: textCol),
                              decoration: _inputDecoration(
                                  '昵称', '展示昵称', fieldBg, textCol, mutedCol),
                            ),
                            const SizedBox(height: 14),

                            // 手机号
                            TextField(
                              controller: _phoneCtrl,
                              keyboardType: TextInputType.phone,
                              style: TextStyle(color: textCol),
                              decoration: _inputDecoration(
                                  '手机号', '用于找回密码', fieldBg, textCol, mutedCol),
                            ),
                            const SizedBox(height: 14),

                            // 密码
                            TextField(
                              controller: _passwordCtrl,
                              obscureText: _obscure,
                              // 仅允许英文/数字/英文标点（禁止中文、空格、emoji）
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                    RegExp(r'[\x21-\x7E]')),
                              ],
                              style: TextStyle(color: textCol),
                              decoration: _inputDecoration(
                                      '密码', '至少6位', fieldBg, textCol, mutedCol)
                                  .copyWith(
                                // ExcludeFocus：Tab 键跳过「显示密码」按钮
                                suffixIcon: ExcludeFocus(
                                  child: IconButton(
                                    icon: Icon(_obscure
                                        ? Icons.visibility_off
                                        : Icons.visibility),
                                    color: mutedCol,
                                    onPressed: () =>
                                        setState(() => _obscure = !_obscure),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),

                            // 确认密码
                            TextField(
                              controller: _confirmCtrl,
                              obscureText: _obscure,
                              // 仅允许英文/数字/英文标点（禁止中文、空格、emoji）
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                    RegExp(r'[\x21-\x7E]')),
                              ],
                              style: TextStyle(color: textCol),
                              decoration: _inputDecoration(
                                  '确认密码', '再次输入密码', fieldBg, textCol, mutedCol),
                            ),
                            const SizedBox(height: 14),

                            // 验证码（输入框弹性 + 图片占满父容器，等高更协调）
                            IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _captchaCtrl,
                                      style: TextStyle(color: textCol),
                                      decoration: _inputDecoration('验证码',
                                          '请输入验证码', fieldBg, textCol, mutedCol),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  // 验证码图片：按原始比例(120:40=3:1)自适应，高度=输入框高度
                                  // 宽度随高度自动适应（不预设宽度），图片无形变
                                  MouseRegion(
                                    cursor: SystemMouseCursors.click, // 点击刷新验证码
                                    child: GestureDetector(
                                      onTap: _refreshCaptcha,
                                      child: AspectRatio(
                                        aspectRatio: 3,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: fieldBg,
                                            borderRadius:
                                                BorderRadius.circular(kRadiusSm),
                                            image: _captchaImage != null
                                                ? DecorationImage(
                                                    image: MemoryImage(
                                                        base64Decode(
                                                            _captchaImage!
                                                                .replaceFirst(
                                                                    RegExp(
                                                                        r'^data:image/\w+;base64,'),
                                                                    ''))),
                                                    fit: BoxFit.fill,
                                                  )
                                                : null,
                                          ),
                                          clipBehavior: Clip.hardEdge,
                                          alignment: Alignment.center,
                                          // 未加载时显示 loading
                                          child: _captchaImage != null
                                              ? null
                                              : const SizedBox(
                                                  width: 16,
                                                  height: 16,
                                                  child:
                                                      CircularProgressIndicator(
                                                          strokeWidth: 2),
                                                ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),

                            // 错误提示
                            if (_error != null) ...[
                              Text(
                                _error!,
                                style: const TextStyle(
                                    color: kDanger, fontSize: 13),
                              ),
                              const SizedBox(height: 8),
                            ],

                            // 注册按钮
                            SizedBox(
                              height: 44,
                              child: FilledButton(
                                onPressed: _loading ? null : _register,
                                style: FilledButton.styleFrom(
                                  backgroundColor: accent,
                                  disabledBackgroundColor:
                                      accent.withValues(alpha: 0.5),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(kRadiusMd)),
                                ),
                                child: _loading
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white),
                                      )
                                    : const Text('注 册',
                                        style: TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600)),
                              ),
                            ),
                            const SizedBox(height: 12),

                            // 已有账号，去登录
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text('已有账号？',
                                    style: TextStyle(
                                        fontSize: 13, color: mutedCol)),
                                TextButton(
                                  onPressed: _loading
                                      ? null
                                      : () => Navigator.of(context).pop(),
                                  child: Text('去登录',
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

  /// 输入框通用装饰（无前缀图标）
  InputDecoration _inputDecoration(
      String label, String hint, Color fieldBg, Color textCol, Color mutedCol) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: fieldBg,
      labelStyle: TextStyle(color: mutedCol, fontSize: 13),
      hintStyle: TextStyle(color: mutedCol.withValues(alpha: 0.5), fontSize: 12),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusMd),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusMd),
        borderSide: BorderSide(color: kPrimary, width: 1.2),
      ),
    );
  }
}

/// 注册页标题栏（返回 + 标题 + 窗口控制 + 可拖拽）
class _RegisterTitleBar extends StatelessWidget {
  final Brightness brightness;

  const _RegisterTitleBar({required this.brightness});

  @override
  Widget build(BuildContext context) {
    // macOS：最左侧预留红黄绿按钮安全距离，随后返回按钮 + 拖拽区（无窗口按钮）
    if (Platform.isMacOS) {
      return SizedBox(
        height: 40,
        child: Row(
          children: [
            SizedBox(
              width: kMacTrafficLightWidth,
              child: Container(color: bgSoftColor(brightness)),
            ),
            // macOS 风格返回按钮
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: SizedBox(
                width: 40,
                height: 40,
                child: InkWell(
                  borderRadius: BorderRadius.circular(kRadiusMd),
                  onTap: () => Navigator.of(context).maybePop(),
                  mouseCursor: SystemMouseCursors.click,
                  hoverColor: bgHoverColor(brightness),
                  child: Icon(Icons.arrow_back_ios_new_rounded,
                      size: 16, color: textMutedColor(brightness)),
                ),
              ),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => windowManager.startDragging(),
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
          // 返回按钮
          SizedBox(
            width: 46,
            height: 40,
            child: InkWell(
              onTap: () => Navigator.of(context).maybePop(),
              mouseCursor: SystemMouseCursors.click, // 悬停显示手指
              hoverColor: bgHoverColor(brightness),
              child: Icon(Icons.arrow_back,
                  size: 18, color: textMutedColor(brightness)),
            ),
          ),
          // 标题 + 拖拽区域（整个标题区可拖动窗口）
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => windowManager.startDragging(),
            ),
          ),
          // 窗口控制按钮
          _RegisterWinButton(
            icon: Icons.remove,
            onTap: () => windowManager.minimize(),
          ),
          _RegisterWinButton(
            icon: Icons.crop_square_rounded,
            onTap: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
          _RegisterWinButton(
            icon: Icons.close,
            isClose: true,
            onTap: () => windowManager.close(),
          ),
        ],
      ),
    );
  }
}

/// 注册页窗口控制按钮
class _RegisterWinButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool isClose;

  const _RegisterWinButton({
    required this.icon,
    required this.onTap,
    this.isClose = false,
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
        hoverColor: isClose ? kDanger.withValues(alpha: 0.15) : bgHoverColor(b),
        child: Icon(icon, size: 16, color: textMutedColor(b)),
      ),
    );
  }
}
