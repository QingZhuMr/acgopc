import 'package:flutter/services.dart';

/// 清洗字符串中的非法 UTF-16 代理项（孤立的高/低代理项）。
///
/// 崩溃根因：E2EE 解密/网络解码/剪贴板粘贴可能产生**未配对的 surrogate**
/// （如 `\uD800`），Flutter 渲染 TextSpan 时抛
/// `Invalid argument(s): string is not well-formed UTF-16`。
///
/// 处理规则：
/// - 合法代理对（高+低）保留
/// - 孤立的高代理项（后面不是低代理项）/ 孤立的低代理项 → 丢弃
/// - 其余 code unit 原样保留
String sanitizeUtf16(String? input) {
  if (input == null || input.isEmpty) return input ?? '';
  final buffer = StringBuffer();
  final len = input.length;
  for (var i = 0; i < len; i++) {
    final unit = input.codeUnitAt(i);
    // 高代理项 0xD800-0xDBFF
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (i + 1 < len) {
        final next = input.codeUnitAt(i + 1);
        if (next >= 0xDC00 && next <= 0xDFFF) {
          // 合法代理对（emoji 等）
          buffer.writeCharCode(unit);
          buffer.writeCharCode(next);
          i++;
          continue;
        }
      }
      // 孤立高代理项 → 丢弃
      continue;
    }
    // 孤立低代理项 0xDC00-0xDFFF → 丢弃
    if (unit >= 0xDC00 && unit <= 0xDFFF) continue;
    buffer.writeCharCode(unit);
  }
  return buffer.toString();
}

/// 输入框格式化器：过滤粘贴/输入进来的非法 UTF-16 代理项，
/// 防止坏字符串进入 TextField controller 后渲染崩溃。
class Utf16SanitizeTextInputFormatter extends TextInputFormatter {
  const Utf16SanitizeTextInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final cleaned = sanitizeUtf16(newValue.text);
    if (identical(cleaned, newValue.text) || cleaned == newValue.text) {
      return newValue;
    }
    // 清掉非法字符后，光标移到清洗后文本末尾
    return TextEditingValue(
      text: cleaned,
      selection: TextSelection.collapsed(offset: cleaned.length),
    );
  }
}
