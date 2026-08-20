import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../../core/api_client.dart';
import '../../core/app_config.dart';
import '../../core/app_theme.dart';
import '../../core/device_service.dart';
import '../../services/secure_storage.dart';
import '../../utils/text_sanitize.dart';
import '../../widgets/notify.dart';
import '../theme/mobile_theme.dart';
import '../widgets/glass_button.dart';
import '../widgets/mobile_form_pane.dart';

/// 注册成功回调（注册成功自动登录后携带用户信息进入主界面）
typedef MobileRegisterSuccess = void Function(Map<String, dynamic> user);

/// 移动端用户注册页：验证码 + 注册，注册成功自动登录（保持登录方式）。
///
/// 遵守 `docs/移动端UI规范.md`：渐变背景、二级玻璃输入框、胶囊按钮、
/// silky_scroll 滚动、系统字体；不 import 桌面页面 / 组件。
class RegisterPage extends StatefulWidget {
  final MobileRegisterSuccess onSuccess;

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
        setState(() => _captchaImage = json['data']?['image'] as String?);
      }
    } catch (_) {
      // 网络异常：保留空白，用户可重试刷新
    }
  }

  /// 注册（注册成功自动登录，保持登录方式）
  Future<void> _register() async {
    FocusScope.of(context).unfocus();
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
    if (password.length < 6) {
      setState(() => _error = '密码至少 6 位');
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
        widget.onSuccess(user); // 进入主界面
        Navigator.of(context).popUntil((r) => r.isFirst);
      } else {
        // 注册成功但自动登录失败（极少），提示用户手动登录
        if (!mounted) return;
        setState(() => _loading = false);
        NotifyStack.success('注册成功，请手动登录', title: '注册成功');
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
    final theme = Theme.of(context);
    final textCol = textColor(b);
    final mutedCol = textMutedColor(b);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        // 背景必须全屏：强制撑满视口，不能按内容高度收缩（否则底部露主题底色）
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(gradient: MobileTheme.background(b)),
        child: SafeArea(
          child: Column(
            children: [
              // ===== 顶部返回栏（移动端无自绘窗口控制） =====
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    const SizedBox(width: 4),
                    IconButton(
                      icon: Icon(Icons.arrow_back_ios_new_rounded,
                          size: 18, color: textColor(b)),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const Spacer(),
                    Text('注册', style: theme.textTheme.titleMedium),
                    const Spacer(),
                    const SizedBox(width: 48), // 平衡返回按钮宽度
                  ],
                ),
              ),
              // ===== 注册主体 =====
              Expanded(
                child: SilkySingleChildScrollView(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 28, vertical: 8),
                  scrollSpeed: 1.6,
                  silkyScrollDuration: const Duration(milliseconds: 600),
                  animationCurve: Curves.easeOutCubic,
                  child: MobileFormPane(
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '欢迎加入${AppConfig.appName}',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineSmall
                                ?.copyWith(fontSize: 24),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '让我们荡起心头的浆，划走生活的波浪。',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 13, color: mutedCol),
                          ),
                          const SizedBox(height: 28),

                          // 昵称
                          TextFormField(
                            controller: _nicknameCtrl,
                            // 过滤粘贴/输入的非法 UTF-16 代理项（防渲染崩溃）
                            inputFormatters: const [
                              Utf16SanitizeTextInputFormatter(),
                            ],
                            style: TextStyle(color: textCol, fontSize: 16),
                            decoration: const InputDecoration(
                              labelText: '昵称',
                              hintText: '展示昵称',
                            ),
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? '请输入昵称'
                                : null,
                          ),
                          const SizedBox(height: 14),

                          // 手机号
                          TextFormField(
                            controller: _phoneCtrl,
                            keyboardType: TextInputType.phone,
                            inputFormatters: const [
                              Utf16SanitizeTextInputFormatter(),
                            ],
                            style: TextStyle(color: textCol, fontSize: 16),
                            decoration: const InputDecoration(
                              labelText: '手机号',
                              hintText: '用于找回密码',
                            ),
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? '请输入手机号'
                                : null,
                          ),
                          const SizedBox(height: 14),

                          // 密码
                          TextFormField(
                            controller: _passwordCtrl,
                            obscureText: _obscure,
                            // 仅允许英文/数字/英文标点（禁止中文、空格、emoji）
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                  RegExp(r'[\x21-\x7E]')),
                            ],
                            style: TextStyle(color: textCol, fontSize: 16),
                            decoration: InputDecoration(
                              labelText: '密码',
                              hintText: '至少6位',
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscure
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  size: 20,
                                  color: mutedCol,
                                ),
                                onPressed: () =>
                                    setState(() => _obscure = !_obscure),
                              ),
                            ),
                            validator: (v) =>
                                (v == null || v.isEmpty) ? '请输入密码' : null,
                          ),
                          const SizedBox(height: 14),

                          // 确认密码
                          TextFormField(
                            controller: _confirmCtrl,
                            obscureText: _obscure,
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                  RegExp(r'[\x21-\x7E]')),
                            ],
                            style: TextStyle(color: textCol, fontSize: 16),
                            decoration: const InputDecoration(
                              labelText: '确认密码',
                              hintText: '再次输入密码',
                            ),
                            validator: (v) =>
                                (v == null || v.isEmpty) ? '请再次输入密码' : null,
                          ),
                          const SizedBox(height: 14),

                          // 验证码（输入框 + 图片点击刷新）
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: TextFormField(
                                  controller: _captchaCtrl,
                                  inputFormatters: const [
                                    Utf16SanitizeTextInputFormatter(),
                                  ],
                                  style:
                                      TextStyle(color: textCol, fontSize: 16),
                                  decoration: const InputDecoration(
                                    labelText: '验证码',
                                    hintText: '请输入验证码',
                                  ),
                                  validator: (v) =>
                                      (v == null || v.trim().isEmpty)
                                          ? '请输入验证码'
                                          : null,
                                ),
                              ),
                              const SizedBox(width: 12),
                              // 验证码图片（3:1 比例，点击刷新）
                              // 必须给 AspectRatio 有界约束：页面整体在纵向滚动容器中，
                              // Row 对非 flex 子项放开宽度、高度无限，AspectRatio 会因
                              // 宽高双无限而布局崩溃（RenderAspectRatio has unbounded
                              // constraints），故用 SizedBox 锁死高度，宽度按比例推算。
                              GestureDetector(
                                onTap: _refreshCaptcha,
                                child: SizedBox(
                                  height: 44,
                                  child: AspectRatio(
                                    aspectRatio: 3,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        borderRadius:
                                            BorderRadius.circular(kRadiusSm),
                                        image: _captchaImage != null
                                            ? DecorationImage(
                                                image: MemoryImage(base64Decode(
                                                    _captchaImage!.replaceFirst(
                                                        RegExp(
                                                            r'^data:image/\w+;base64,'),
                                                        ''))),
                                                fit: BoxFit.fill,
                                              )
                                            : null,
                                      ),
                                      clipBehavior: Clip.hardEdge,
                                      alignment: Alignment.center,
                                      child: _captchaImage != null
                                          ? null
                                          : const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2),
                                            ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),

                          // 错误提示
                          if (_error != null) ...[
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
                            const SizedBox(height: 14),
                          ],

                          // 注册按钮（iOS 26 主操作：kPrimary 实底胶囊）
                          GlassButton.primary(
                            label: '注 册',
                            loading: _loading,
                            expanded: true,
                            onPressed: _register,
                          ),
                          const SizedBox(height: 12),

                          // 已有账号，去登录（iOS 26 文字链接）
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text('已有账号？',
                                  style:
                                      TextStyle(fontSize: 14, color: mutedCol)),
                              GlassButton.link(
                                label: '去登录',
                                onPressed: _loading
                                    ? null
                                    : () => Navigator.of(context).pop(),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
