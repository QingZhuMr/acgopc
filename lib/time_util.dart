import 'app_config.dart';

/// 时间本地化工具（所有客户端：win/安卓/iOS/H5 统一实现同一套）
///
/// 原则（见 docs/安全规范.md 2.7）：
///  - 时间传输与存储统一用 **Unix 秒级时间戳（UTC）**，与时区无关、全球一致。
///  - 服务端 → 客户端（展示）：以客户端本地时区为准。
///  - 客户端 → 服务端（上传）：转成 Unix 时间戳（服务器时间）。
///  - 生成"当前时间戳"用校时后的时间（AppConfig.nowTimestamp）。
///
/// 各端必须复用本类，禁止在业务代码里散落拼接时区字符串。
class TimeUtil {
  TimeUtil._();

  /// 当前服务器时间戳（秒）＝ 本地时间 + 时钟偏移（见 AppConfig.nowTimestamp）
  static int nowServer() => AppConfig.nowTimestamp();

  /// 服务端时间戳（秒）→ 客户端本地时区的 DateTime
  ///
  /// 关键：`isUtc: true` 把时间戳解释为 UTC 绝对时刻，再 `.toLocal()` 转本地时区。
  /// 若漏掉 isUtc:true，会把时间戳误当"本地时间"，导致东京/北京等非 UTC 时区显示错误。
  static DateTime serverTsToLocal(int serverTs) =>
      DateTime.fromMillisecondsSinceEpoch(serverTs * 1000, isUtc: true).toLocal();

  /// 本地时间 → 服务端 Unix 时间戳（UTC 秒），用于上传
  static int localToServerTs(DateTime local) =>
      local.toUtc().millisecondsSinceEpoch ~/ 1000;

  /// 当前本地时间 → 服务端 Unix 时间戳（UTC 秒），用于上传"现在"类字段
  static int nowLocalToServerTs() =>
      DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

  /// 服务端时间戳（秒）→ 本地时区格式化字符串
  ///
  /// [serverTs] 为 0 或负数时返回 [emptyText]（默认 '-'）。
  /// 支持 pattern 占位符：yyyy MM dd HH mm ss。
  static String formatServerTime(int serverTs,
      {String pattern = 'yyyy-MM-dd HH:mm:ss', String emptyText = '-'}) {
    if (serverTs <= 0) return emptyText;
    final local = serverTsToLocal(serverTs);
    return _formatDateTime(local, pattern);
  }

  /// 把本地时间按 pattern 格式化为字符串（占位符：yyyy/MM/dd/HH/mm/ss）
  static String formatLocal(DateTime t,
      {String pattern = 'yyyy-MM-dd HH:mm:ss'}) {
    return _formatDateTime(t.toLocal(), pattern);
  }

  static String _formatDateTime(DateTime t, String pattern) {
    String two(int n) => n.toString().padLeft(2, '0');
    return pattern
        .replaceAll('yyyy', t.year.toString().padLeft(4, '0'))
        .replaceAll('MM', two(t.month))
        .replaceAll('dd', two(t.day))
        .replaceAll('HH', two(t.hour))
        .replaceAll('mm', two(t.minute))
        .replaceAll('ss', two(t.second));
  }
}
