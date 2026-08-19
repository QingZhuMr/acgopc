import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/app_theme.dart';
import 'notify.dart';

/// 「开始寻找」动态表单弹窗结果
///
/// status=0 已开始寻找（未匹配到）；status=1 配对成功（含 matched_user）
class FindFormResult {
  final int status;
  final Map<String, dynamic>? matchedUser;
  final Map<String, dynamic>? bind;
  final bool isFree;
  final int cost;

  const FindFormResult({
    required this.status,
    this.matchedUser,
    this.bind,
    this.isFree = false,
    this.cost = 0,
  });
}

/// 「开始寻找」动态表单弹窗
///
/// 按后台星球配置的 find_fields 动态渲染「我的资料」与「目标条件」表单：
/// - 我的资料：首填后自动复用（profile 传入已存资料自动带出，可修改）
/// - 目标条件：性别 + 年龄范围 必填，其余字段跟随 find_fields 配置
/// 提交后调用 /find/start；配对成功时返回匹配到的对象信息。
class FindFormDialog extends StatefulWidget {
  final int planetId;
  final String planetName;
  final List<String> findFields;
  final Map<String, dynamic>? profile;
  final bool forceFaceAuth;
  final bool forceEduAuth;
  final bool forceAssetAuth;
  final Map<String, dynamic>? auth;
  // 付费 / 免费次数展示信息（来自 /find/config）
  final int findCost;
  final int freeRemaining;
  final int balancePaw;
  final String costNotice;

  const FindFormDialog({
    super.key,
    required this.planetId,
    required this.planetName,
    required this.findFields,
    this.profile,
    this.forceFaceAuth = false,
    this.forceEduAuth = false,
    this.forceAssetAuth = false,
    this.auth,
    this.findCost = 0,
    this.freeRemaining = 0,
    this.balancePaw = 0,
    this.costNotice = '',
  });

  @override
  State<FindFormDialog> createState() => _FindFormDialogState();
}

class _FindFormDialogState extends State<FindFormDialog> {
  /// 提交中
  bool _submitting = false;

  // ---- 我的资料 ----
  int? _gender;
  final _ageCtrl = TextEditingController();

  // 可选字段（按 find_fields 渲染）
  final _incomeCtrl = TextEditingController();
  final _personalityCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  double _faceScore = 0;
  final _eduCtrl = TextEditingController();

  // ---- 目标条件 ----
  int _targetGender = 0; // 0不限 1男 2女
  final _targetAgeMinCtrl = TextEditingController();
  final _targetAgeMaxCtrl = TextEditingController();
  final _targetIncomeCtrl = TextEditingController();
  final _targetPersonalityCtrl = TextEditingController();
  final _targetCityCtrl = TextEditingController();
  double _targetFaceScore = 0; // 0不限
  final _targetEduCtrl = TextEditingController();
  bool _sameCity = false;

  /// 是否配置了某「我的资料」字段
  bool _hasField(String key) => widget.findFields.contains(key);

  static const _incomeOptions = ['1万以内', '1-2万', '2-5万', '5万以上'];
  static const _eduOptions = ['高中及以下', '大专', '本科', '硕士', '博士'];

  @override
  void initState() {
    super.initState();
    final p = widget.profile;
    if (p != null) {
      _gender = (p['gender'] as num?)?.toInt() ?? 0;
      _ageCtrl.text = '${p['age'] ?? ''}';
      _incomeCtrl.text = '${p['income_range'] ?? ''}';
      _personalityCtrl.text = '${p['personality'] ?? ''}';
      _cityCtrl.text = '${p['city'] ?? ''}';
      _faceScore = (p['face_score'] as num?)?.toDouble() ?? 0;
      _eduCtrl.text = '${p['edu_level'] ?? ''}';
    }
  }

  @override
  void dispose() {
    _ageCtrl.dispose();
    _incomeCtrl.dispose();
    _personalityCtrl.dispose();
    _cityCtrl.dispose();
    _eduCtrl.dispose();
    _targetAgeMinCtrl.dispose();
    _targetAgeMaxCtrl.dispose();
    _targetIncomeCtrl.dispose();
    _targetPersonalityCtrl.dispose();
    _targetCityCtrl.dispose();
    _targetEduCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;

    // 必填校验
    if (_gender == null) return _toast('请选择你的性别');
    final age = int.tryParse(_ageCtrl.text.trim()) ?? 0;
    if (age < 18 || age > 99) return _toast('请填写有效的年龄（18-99）');

    final targetAgeMin = int.tryParse(_targetAgeMinCtrl.text.trim()) ?? 0;
    final targetAgeMax = int.tryParse(_targetAgeMaxCtrl.text.trim()) ?? 0;
    if (targetAgeMin < 18 || targetAgeMax < 18 || targetAgeMax < targetAgeMin) {
      return _toast('请填写有效的目标年龄范围');
    }

    final params = <String, String>{
      'my_gender': '$_gender',
      'my_age': '$age',
    };

    // 可选我的资料字段
    if (_hasField('income_range')) {
      final v = _incomeCtrl.text.trim();
      if (v.isEmpty) return _toast('请填写你的月收入范围');
      params['my_income_range'] = v;
    }
    if (_hasField('personality')) {
      final v = _personalityCtrl.text.trim();
      if (v.isEmpty) return _toast('请填写你的性格');
      params['my_personality'] = v;
    }
    if (_hasField('city')) {
      final v = _cityCtrl.text.trim();
      if (v.isEmpty) return _toast('请填写你的城市');
      params['my_city'] = v;
    }
    if (_hasField('face_score')) {
      if (_faceScore < 1) return _toast('请选择你的颜值打分');
      params['my_face_score'] = '${_faceScore.toInt()}';
    }
    if (_hasField('edu_level')) {
      final v = _eduCtrl.text.trim();
      if (v.isEmpty) return _toast('请选择你的学历');
      params['my_edu_level'] = v;
    }

    // 目标条件
    params['target_gender'] = '$_targetGender';
    params['target_age_min'] = '$targetAgeMin';
    params['target_age_max'] = '$targetAgeMax';
    if (_hasField('income_range')) {
      final v = _targetIncomeCtrl.text.trim();
      if (v.isEmpty) return _toast('请填写目标月收入范围');
      params['target_income_range'] = v;
    }
    if (_hasField('personality')) {
      final v = _targetPersonalityCtrl.text.trim();
      if (v.isEmpty) return _toast('请填写目标性格');
      params['target_personality'] = v;
    }
    if (_hasField('city')) {
      params['target_same_city'] = _sameCity ? '1' : '0';
    }
    if (_hasField('face_score')) {
      if (_targetFaceScore < 1) return _toast('请选择目标颜值打分');
      params['target_face_score'] = '${_targetFaceScore.toInt()}';
    }
    if (_hasField('edu_level')) {
      final v = _targetEduCtrl.text.trim();
      if (v.isEmpty) return _toast('请选择目标学历');
      params['target_edu_level'] = v;
    }

    setState(() => _submitting = true);
    try {
      final resp = await ApiClient.instance
          .startFind(planetId: widget.planetId, params: params)
          .timeout(const Duration(seconds: 12));
      final body = ApiClient.safeJsonDecode(resp.body);
      if (body['code'] != 0) {
        if (mounted) {
          NotifyStack.warning(body['msg'] as String? ?? '发起失败', title: '提示');
        }
        return;
      }
      final data = body['data'] as Map<String, dynamic>? ?? {};
      final status = (data['status'] as num?)?.toInt() ?? 0;
      if (!mounted) return;
      Navigator.of(context).pop(
        FindFormResult(
          status: status,
          matchedUser: data['matched_user'] as Map<String, dynamic>?,
          bind: data['bind'] as Map<String, dynamic>?,
          isFree: (data['is_free'] as bool?) ?? false,
          cost: (data['cost'] as num?)?.toInt() ?? 0,
        ),
      );
    } catch (_) {
      if (mounted) NotifyStack.warning('网络异常，请稍后重试', title: '提示');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _toast(String msg) => NotifyStack.warning(msg, title: '提示');

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = dark ? DarkColors.text : LightColors.text;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        width: 440,
        constraints: const BoxConstraints(maxHeight: 640),
        decoration: BoxDecoration(
          color: dark ? DarkColors.bg : LightColors.bg,
          borderRadius: kRadiusCardAll,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题栏
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '开始寻找 · ${widget.planetName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: titleColor,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '在相同星球发起寻找，配对成功后你们将成为绑定人',
                          style: TextStyle(
                            fontSize: 12,
                            color: dark
                                ? DarkColors.textMuted
                                : LightColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close_rounded,
                      color: dark
                          ? DarkColors.textSecondary
                          : LightColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            // 表单区
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionCard(context, '我的资料', [
                      _genderSelector(context),
                      _textField(context, _ageCtrl, '我的年龄', '18-99'),
                      if (_hasField('income_range'))
                        _dropdownField(context, _incomeCtrl, _incomeOptions,
                            '我的月收入范围', '请选择'),
                      if (_hasField('personality'))
                        _textField(context, _personalityCtrl, '我的性格',
                            '如：开朗、幽默'),
                      if (_hasField('city'))
                        _textField(context, _cityCtrl, '我的城市', '如：北京'),
                      if (_hasField('face_score'))
                        _scoreSlider(
                          context,
                          value: _faceScore,
                          label: '我的颜值打分',
                          onChanged: (v) => setState(() => _faceScore = v),
                        ),
                      if (_hasField('edu_level'))
                        _dropdownField(
                            context, _eduCtrl, _eduOptions, '我的学历', '请选择'),
                    ]),
                    _sectionCard(context, '目标条件', [
                      _targetGenderSelector(context),
                      _ageRangeRow(context),
                      if (_hasField('income_range'))
                        _dropdownField(context, _targetIncomeCtrl, _incomeOptions,
                            '目标月收入范围', '不限'),
                      if (_hasField('personality'))
                        _textField(context, _targetPersonalityCtrl, '目标性格',
                            '不限（留空）'),
                      if (_hasField('city')) ...[
                        _textField(context, _targetCityCtrl, '目标城市',
                            '如：北京'),
                        _sameCityRow(context),
                      ],
                      if (_hasField('face_score'))
                        _scoreSlider(
                          context,
                          value: _targetFaceScore,
                          label: '目标颜值打分',
                          onChanged: (v) =>
                              setState(() => _targetFaceScore = v),
                        ),
                      if (_hasField('edu_level'))
                        _dropdownField(context, _targetEduCtrl, _eduOptions,
                            '目标学历', '不限'),
                    ]),
                    _authHint(context),
                  ],
                ),
              ),
            ),
            _buildCostHint(context),
            // 底部按钮
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _submitting ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: kPrimary,
                    disabledBackgroundColor: kPrimary.withValues(alpha: 0.4),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: kRadiusBtnAll),
                  ),
                  child: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('开始寻找',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionCard(
      BuildContext context, String title, List<Widget> children) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: dark ? const Color(0x14FFFFFF) : Colors.grey.shade50,
        borderRadius: kRadiusCardAll,
        border: Border.all(
          color: dark ? const Color(0x1AFFFFFF) : Colors.grey.shade200,
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 14,
                  decoration: BoxDecoration(
                    color: kPrimary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: dark ? DarkColors.text : LightColors.text,
                  ),
                ),
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _genderSelector(BuildContext context) {
    return _labelWrap(
      context,
      '我的性别',
      _pillSelector(
        context,
        options: const [
          (value: 1, label: '男'),
          (value: 2, label: '女'),
        ],
        selected: _gender ?? -1,
        onChanged: (v) => setState(() => _gender = v),
      ),
    );
  }

  Widget _targetGenderSelector(BuildContext context) {
    return _labelWrap(
      context,
      '目标性别',
      _pillSelector(
        context,
        options: const [
          (value: 0, label: '不限'),
          (value: 1, label: '男'),
          (value: 2, label: '女'),
        ],
        selected: _targetGender,
        onChanged: (v) => setState(() => _targetGender = v),
      ),
    );
  }

  /// 现代化低对比度胶囊选择器
  ///
  /// 整组为柔和的灰底胶囊容器，选中项用主题蓝浅底 + 主题蓝文字
  /// （无实色填充、无高对比），hover 有柔和高亮，选中切换带平滑过渡。
  Widget _pillSelector(
    BuildContext context, {
    required List<({int value, String label})> options,
    required int selected,
    required ValueChanged<int> onChanged,
  }) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final soft =
        dark ? DarkColors.primarySoft : LightColors.primarySoft;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: dark ? DarkColors.bgHover : LightColors.bgHover,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          for (final opt in options)
            Expanded(
              child: _pillItem(
                context,
                label: opt.label,
                selected: opt.value == selected,
                hoverColor: soft.withValues(alpha: 0.5),
                onTap: () => onChanged(opt.value),
              ),
            ),
        ],
      ),
    );
  }

  Widget _pillItem(
    BuildContext context, {
    required String label,
    required bool selected,
    required Color hoverColor,
    required VoidCallback onTap,
  }) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      margin: const EdgeInsets.symmetric(horizontal: 1),
      decoration: BoxDecoration(
        color: selected
            ? (dark ? DarkColors.primarySoft : LightColors.primarySoft)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
      ),
      child: InkWell(
        onTap: onTap,
        hoverColor: hoverColor,
        borderRadius: BorderRadius.circular(7),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected
                  ? kPrimary
                  : (dark ? DarkColors.textMuted : LightColors.textMuted),
            ),
          ),
        ),
      ),
    );
  }

  Widget _ageRangeRow(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final inputColor =
        dark ? DarkColors.bgHover : LightColors.bgHover;
    final textStyle = TextStyle(
        fontSize: 13, color: dark ? DarkColors.text : LightColors.text);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('目标年龄范围',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: dark ? DarkColors.textBody : LightColors.textBody)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _targetAgeMinCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '最小',
                    hintStyle: TextStyle(
                        fontSize: 13,
                        color: dark
                            ? DarkColors.textFaint
                            : LightColors.textFaint),
                    filled: true,
                    fillColor: inputColor,
                    border: OutlineInputBorder(
                      borderRadius: kRadiusBtnAll,
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                  style: textStyle,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text('至',
                    style: TextStyle(
                        fontSize: 13,
                        color: dark
                            ? DarkColors.textFaint
                            : LightColors.textFaint)),
              ),
              Expanded(
                child: TextField(
                  controller: _targetAgeMaxCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '最大',
                    hintStyle: TextStyle(
                        fontSize: 13,
                        color: dark
                            ? DarkColors.textFaint
                            : LightColors.textFaint),
                    filled: true,
                    fillColor: inputColor,
                    border: OutlineInputBorder(
                      borderRadius: kRadiusBtnAll,
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                  style: textStyle,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sameCityRow(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Text('只寻找同城',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: dark ? DarkColors.textBody : LightColors.textBody)),
          const Spacer(),
          Switch(
            value: _sameCity,
            onChanged: (v) => setState(() => _sameCity = v),
          ),
        ],
      ),
    );
  }

  Widget _textField(BuildContext context, TextEditingController ctrl,
      String label, String hint) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final inputColor = dark ? DarkColors.bgHover : LightColors.bgHover;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: dark ? DarkColors.textBody : LightColors.textBody)),
          const SizedBox(height: 8),
          TextField(
            controller: ctrl,
            style: TextStyle(
                fontSize: 13,
                color: dark ? DarkColors.text : LightColors.text),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: TextStyle(
                  fontSize: 13,
                  color:
                      dark ? DarkColors.textFaint : LightColors.textFaint),
              filled: true,
              fillColor: inputColor,
              enabledBorder: OutlineInputBorder(
                borderRadius: kRadiusBtnAll,
                borderSide: BorderSide(
                    color: dark ? Colors.white24 : Colors.grey.shade300,
                    width: 1),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: kRadiusBtnAll,
                borderSide: BorderSide(color: kPrimary, width: 1.5),
              ),
              border: OutlineInputBorder(
                borderRadius: kRadiusBtnAll,
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dropdownField(BuildContext context, TextEditingController ctrl,
      List<String> options, String label, String hint) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final inputColor = dark ? DarkColors.bgHover : LightColors.bgHover;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: dark ? DarkColors.textBody : LightColors.textBody)),
          const SizedBox(height: 8),
          InkWell(
            onTap: () => _pickOption(ctrl, options, hint),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: inputColor,
                borderRadius: kRadiusBtnAll,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      ctrl.text.isEmpty ? hint : ctrl.text,
                      style: TextStyle(
                        fontSize: 13,
                        color: ctrl.text.isEmpty
                            ? (dark
                                ? DarkColors.textFaint
                                : LightColors.textFaint)
                            : (dark
                                ? DarkColors.text
                                : LightColors.text),
                      ),
                    ),
                  ),
                  Icon(Icons.arrow_drop_down_rounded,
                      size: 20,
                      color: dark
                          ? DarkColors.textFaint
                          : LightColors.textFaint),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickOption(
      TextEditingController ctrl, List<String> options, String hint) async {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: dark ? DarkColors.bgSoft : LightColors.bgSoft,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final items = [hint, ...options];
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(labelOf(ctrl, hint),
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color:
                            dark ? DarkColors.text : LightColors.text)),
              ),
              const Divider(height: 1),
              ...items.map((opt) => ListTile(
                    dense: true,
                    title: Text(opt,
                        style: TextStyle(
                            fontSize: 14,
                            color: dark
                                ? DarkColors.text
                                : LightColors.text)),
                    onTap: () => Navigator.of(ctx).pop(opt),
                  )),
            ],
          ),
        );
      },
    );
    if (selected != null && mounted) {
      setState(() {
        if (selected == hint) {
          ctrl.clear();
        } else {
          ctrl.text = selected;
        }
      });
    }
  }

  String labelOf(TextEditingController ctrl, String hint) {
    // 通过 ctrl 对应的字段决定弹窗标题（简化：用 hint 作为标题）
    return hint.contains('请选择') ? '选择' : '选择';
  }

  Widget _scoreSlider(BuildContext context,
      {required double value,
      required String label,
      required ValueChanged<double> onChanged}) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color:
                          dark ? DarkColors.textBody : LightColors.textBody)),
              const Spacer(),
              Text(
                value < 1 ? '未选择' : '${value.toInt()}分',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: kPrimary),
              ),
            ],
          ),
          Slider(
            value: value,
            min: 0,
            max: 10,
            divisions: 10,
            label: value < 1 ? '不限' : '${value.toInt()}分',
            activeColor: kPrimary,
            thumbColor: kPrimary,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildCostHint(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final free = widget.freeRemaining > 0;
    final paid = !free && widget.findCost > 0;
    final mainText = free
        ? '本次免费（剩余 ${widget.freeRemaining} 次）'
        : (paid
            ? '本次消耗 ${widget.findCost} 熊爪（余额 ${widget.balancePaw}）'
            : '本次免费');
    final notice = widget.costNotice.trim();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: kPrimary.withValues(alpha: 0.1),
        borderRadius: kRadiusMdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, size: 15, color: kPrimary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(mainText,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: kPrimary)),
              ),
            ],
          ),
          if (notice.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(notice,
                style: TextStyle(
                    fontSize: 11,
                    color: dark
                        ? DarkColors.textFaint
                        : LightColors.textFaint)),
          ],
        ],
      ),
    );
  }

  Widget _authHint(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final needs = <String>[
      if (widget.forceFaceAuth) '颜值',
      if (widget.forceEduAuth) '学历',
      if (widget.forceAssetAuth) '资产',
    ];
    if (needs.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: kWarning.withValues(alpha: 0.12),
        borderRadius: kRadiusMdAll,
      ),
      child: Text(
        '该星球要求完成${needs.join('、')}认证后才能配对',
        style: TextStyle(
            fontSize: 12,
            color: dark ? kWarning : kWarning.withValues(alpha: 0.9)),
      ),
    );
  }

  /// 带标签的控件容器
  Widget _labelWrap(BuildContext context, String label, Widget child) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: dark ? DarkColors.textBody : LightColors.textBody)),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}
