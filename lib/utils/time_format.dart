/// 时间格式化工具
///
/// [formatRelativeTime] 将服务端返回的 "Y-m-d H:i" 格式时间戳按以下规则格式化为本地相对时间：
///   - < 1 分钟：刚刚
///   - < 1 小时：X分钟前
///   - < 1 天：X小时前
///   - < 7 天：X天前
///   - 同年且 >= 7 天：M月d日（如 "8月16日"）
///   - 跨年：X年前（如 "2年前"）
library;

/// 将服务端返回的 "Y-m-d H:i" 格式时间字符串解析为本地 DateTime。
DateTime? parseServerTime(String? text) {
  if (text == null || text.isEmpty) return null;
  // 格式：2026-08-16 11:22（无秒，解析为本地时间）
  final parts = text.split(' ');
  if (parts.length != 2) return null;
  final ymd = parts[0].split('-');
  final hm = parts[1].split(':');
  if (ymd.length != 3 || hm.length != 2) return null;
  final y = int.tryParse(ymd[0]);
  final m = int.tryParse(ymd[1]);
  final d = int.tryParse(ymd[2]);
  final h = int.tryParse(hm[0]);
  final mi = int.tryParse(hm[1]);
  if (y == null || m == null || d == null || h == null || mi == null) return null;
  return DateTime(y, m, d, h, mi);
}

/// 将服务端时间格式化为本地相对时间
///
/// 规则（从近到远，今天/昨天/X天前优先）：
///   - 今天：刚刚 / X分钟前 / X小时前（不带时分）
///   - 昨天：昨天 HH:mm（带时分）
///   - 前天起 < 7 天：X天前（不带时分）
///   - 同年且 >= 7 天：M月d日（不带时分）
///   - 跨年：YYYY年M月d日（如 "2025年12月31日"）
String formatRelativeTime(String? serverText, {DateTime? now}) {
  final time = parseServerTime(serverText);
  if (time == null) return serverText ?? '';
  final n = now ?? DateTime.now();
  final diff = n.difference(time);

  // 自然日差（按日期判断昨天/今天）
  final today = DateTime(n.year, n.month, n.day);
  final timeDay = DateTime(time.year, time.month, time.day);
  final dayDiff = today.difference(timeDay).inDays;

  if (dayDiff <= 0) {
    // 今天（或未来）：按秒/分/时
    if (diff.inSeconds < 60) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    return '${diff.inHours}小时前';
  }
  if (dayDiff == 1) {
    // 昨天：带时分
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    return '昨天 $hh:$mm';
  }
  if (dayDiff < 7) {
    return '$dayDiff天前';
  }

  // >= 7 天：不再显示"X年前/月前"，直接显示日期
  if (time.year == n.year) {
    // 同年：M月d日
    return '${time.month}月${time.day}日';
  }
  // 跨年：YYYY-MM-DD（用 - 分隔）
  final mm = time.month.toString().padLeft(2, '0');
  final dd = time.day.toString().padLeft(2, '0');
  return '${time.year}-$mm-$dd';
}

/// 拼接展示文本：格式化时间 + 归属地（IP 转省份，空值/未接入时显示"未知"）
String formatTimeWithLocation(String? serverText, {String location = '未知'}) {
  final loc = location.trim().isEmpty ? '未知' : location;
  return '${formatRelativeTime(serverText)} · $loc';
}