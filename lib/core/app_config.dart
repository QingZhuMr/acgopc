import 'dart:io';

/// 应用全局配置
///
/// ══════════════════════════════════════════════════════════════════
///   【快速编辑区】以下常量改动即可全局生效，无需搜索散落代码：
///     appName        应用中文标题（窗口标题、托盘 tooltip、登录页等）
///     appNameEn      应用英文名（目录名、进程名、快捷方式、缓存目录）
///     appVersion     应用版本号（配合后端 version 表检查更新）
///     appLogoUrl     通用 Logo 网络地址（登录页/关于页展示，留空用 assetLogo）
///     assetLogo      App Logo（assets 资源相对路径）
///     assetTrayIcon  托盘图标（Windows 需 .ico）
///     apiBase        后端 API 接口地址
///     apiSecret      签名密钥（须与后端 .env 的 API_SECRET 一致）
/// ══════════════════════════════════════════════════════════════════
/// 其他文件统一从本类取值，避免散落硬编码，改一处全局生效。
abstract final class AppConfig {
  /// 应用中文名称（界面展示用；窗口标题、托盘 tooltip、快捷方式名）
  static const String appName = '耶熊';

  /// 应用英文名称（目录名、进程名、配置 key 等）
  static const String appNameEn = 'Yeahbear';

  /// 应用版本
  static const String appVersion = '0.1.5';

  /// 通用 Logo 网络地址（登录页/关于页展示；留空则回退 assetLogo）
  static const String appLogoUrl = '';

  /// 应用通用 logo（asset 相对路径）
  static const String assetLogo = 'assets/images/app_logo.png';

  /// 登录/注册页白色水印 logo（asset 相对路径）
  static const String assetLogoWhite = 'assets/images/logo_white.png';

  /// 托盘图标（asset 相对路径，Windows 需 .ico）
  static const String assetTrayIcon = 'assets/images/app_icon.ico';

  /// 后端 API 接口地址（对接 api 应用）
  /// 生产环境改为 https://你的域名
  static const String apiBase = 'https://api.yeahbear.cn';

  /// WebSocket 实时推送地址（完整 URL，含 scheme 与可选 path）
  ///
  /// 由服务端 `user/domain` 接口返回的 `ws_url` 决定，客户端启动时写入：
  ///  - 开发环境：`ws://127.0.1.3:2346`（直连 Swoole）
  ///  - 生产环境：`wss://api域名/ws`（经 Nginx 反向代理）
  ///
  /// 客户端不自作主张选择 ws/wss，完全以服务端返回为准。
  static String wsBase = 'wss://api.yeahbear.cn/ws';

  /// 客户端与服务端的时钟偏移（秒），默认 0
  ///
  /// 由 `user/domain` 接口返回的 `server_time` 计算得到：
  ///   clockOffset = server_time - 本地时间戳
  /// 签名请求生成时间戳时用"本地时间 + offset"，使签名时间与服务端一致，
  /// 避免设备时钟不准（尤其国外/时钟漂移）导致"签名已过期"。
  static int clockOffset = 0;

  /// 当前用于签名的校准时间戳（本地时间 + 时钟偏移）
  static int nowTimestamp() => (DateTime.now().millisecondsSinceEpoch ~/ 1000) + clockOffset;

  /// 签名密钥（与后端 .env 的 API_SECRET 一致，用于请求签名 HMAC-SHA256）
  /// 注意：不直接作为明文请求头传输，而是参与签名，防重放防伪造
  static const String apiSecret = 'acgo_secret_2026_K9x!qZ';

  /// 默认头像兜底地址（相对 API 域名）
  static const String defaultAvatarPath = '/static/admin/img/default-avatar.png';

  // ==================== 平台判断 ====================

  /// 桌面平台（Windows / macOS / Linux）
  static bool get isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// 移动端平台（Android / iOS）
  static bool get isMobile => !isDesktop;

  /// 是否为平板（pad）。由入口 `DeviceGate` 启动判定后写入：
  /// 屏幕最短边 >= 600dp（Material 官方 tablet 断点）视为平板。
  /// pad 走 PC 端界面布局（AcgoPcApp），顶栏高度 0px，支持横竖屏切换。
  static bool isPad = false;

  /// 内容区顶部与自绘顶栏的间隙：
  /// pad 顶栏高度 0px；Windows 顶栏下 5px；macOS/其他 20px。
  static double get topBarGap => isPad ? 0 : (Platform.isWindows ? 5 : 20);

  // ==================== 目录 / 文件 ====================

  /// 应用数据根目录：系统"文档"目录下的 appNameEn 子目录
  /// 例如：C:\Users\xxx\Documents\acgo\
  static String get dataDir => _documentsDir();

  /// 配置目录（用户偏好：记住的账号密码、忽略的更新版本等）
  /// 退出登录**保留**；仅在用户主动清理时删除。
  static String get configDir => _ensureDir('$dataDir${_sep}config');

  /// 应用数据目录（设备标识、登录态设备密钥等）
  /// 退出登录清除登录态（device_key），但保留设备标识（device_id）。
  static String get appDataDir => _ensureDir('$dataDir${_sep}data');

  /// 日志目录（预留）
  static String get logsDir => _ensureDir('$dataDir${_sep}logs');

  static String get _sep => Platform.pathSeparator;

  /// 确保目录存在并返回
  static String _ensureDir(String path) {
    if (!Directory(path).existsSync()) {
      try {
        Directory(path).createSync(recursive: true);
      } catch (_) {}
    }
    return path;
  }

  /// 解析系统文档目录并拼接应用英文名子目录（不存在则创建）
  static String _documentsDir() {
    try {
      final home = Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          Directory.current.path;
      // Windows 文档目录：用户主目录\Documents
      var docs = '$home${Platform.pathSeparator}Documents';
      if (!Directory(docs).existsSync()) {
        // 文档目录可能被重定向到 OneDrive 等，兜底用用户主目录
        docs = home;
      }
      final dir = '$docs${Platform.pathSeparator}$appNameEn';
      if (!Directory(dir).existsSync()) {
        try {
          Directory(dir).createSync(recursive: true);
        } catch (_) {}
      }
      return dir;
    } catch (_) {
      return Directory.current.path;
    }
  }

  // ==================== 星球页 · 星星背景预设 ====================

  /// 星星数量
  static const int starCount = 120;

  /// 星星整体漂移一圈耗时（秒）
  static const int starDriftSeconds = 60;

  /// 星星最小半径（像素）
  static const double starMinRadius = 0.4;

  /// 星星最大半径（像素）
  static const double starMaxRadius = 2.5;

  /// 星星最小亮度
  static const double starMinAlpha = 0.30;

  /// 星星最大亮度
  static const double starMaxAlpha = 0.90;

  /// 星星光晕半径系数（相对星核半径的倍数）
  static const double starGlowRatio = 4.5;

  /// 星星光晕透明度上限（0..1，防过曝）
  static const double starGlowMaxAlpha = 0.30;

  /// 星星速度系数范围（min..max）
  static const double starSpeedMin = 0.7;
  static const double starSpeedMax = 1.3;

  /// 完整接口 URL（拼接 apiBase + 相对路径）
  static String api(String path) => '$apiBase$path';

  /// 补全资源 URL（相对路径自动拼 apiBase，绝对地址原样返回）
  static String resolveUrl(String? path) {
    if (path == null || path.isEmpty) return '';
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    return '$apiBase$path';
  }
}
