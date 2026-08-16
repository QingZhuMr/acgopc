import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'app_config.dart';
import 'device_service.dart';
import 'notify.dart';

/// 实时推送服务（WebSocket 长连接，对接后端 Workerman 服务）。
///
/// 功能：
///   - 建立连接后发送 device_key 认证
///   - 接收服务端主动推送（force_logout / update 等）
///   - 断线自动重连（指数退避，登录态有效时持续重连）
///   - 周期性发送 ping 保持连接
///
/// 本服务是客户端唯一的状态同步通道：
///   - 实时接收封禁/踢下线/密码变更/更新等主动推送
///   - WS 断线时自动重连；重连成功后再恢复实时同步
class WsService {
  WsService._();

  static final WsService instance = WsService._();

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _pingTimer;
  bool _running = false;
  bool _connecting = false;

  /// 主动断开（如退出登录），区别于网络断线
  bool _stopped = false;

  /// 重连退避（秒），1,2,4,8,16,30 封顶
  int _retry = 1;

  /// 首次断线时间；用于"重连总超时强制下线"
  DateTime? _disconnectSince;

  /// 重连总超时（行业标准：连续 60 秒连不上即视为离线，强制下线）
  static const Duration reconnectTimeout = Duration(seconds: 60);

  /// 强制退出回调（收到 force_logout 或重连超时）
  void Function(String reason)? onForceLogout;

  /// 更新推送回调（收到 update 类型推送）
  void Function(Map<String, dynamic> update)? onUpdate;

  /// 维护状态推送回调（收到 maintenance 类型推送）
  void Function(Map<String, dynamic> maintenance)? onMaintenance;

  /// 钱包余额推送回调（收到 wallet 类型推送，含 paw/cny 最新余额）
  void Function(Map<String, dynamic> wallet)? onWallet;

  /// 帖子回复通知回调（收到 reply_notice 推送，含 notification 对象）
  void Function(Map<String, dynamic> notification)? onReplyNotice;

  /// 连接状态回调（可选，用于 UI 展示）
  void Function(bool connected)? onConnectionChange;

  /// 是否已连接
  bool get isConnected => _channel != null && _sub != null;

  /// 启动连接（登录成功后调用）
  void start({
    void Function(String reason)? onForceLogout,
    void Function(Map<String, dynamic> update)? onUpdate,
    void Function(Map<String, dynamic> maintenance)? onMaintenance,
    void Function(Map<String, dynamic> notification)? onReplyNotice,
  }) {
    this.onForceLogout = onForceLogout;
    this.onUpdate = onUpdate;
    this.onMaintenance = onMaintenance;
    this.onReplyNotice = onReplyNotice;
    if (_running) return;
    _running = true;
    _stopped = false;
    _retry = 1;
    _connect();
  }

  /// 停止并断开（退出登录时调用）
  void stop() {
    _running = false;
    _stopped = true;
    _retry = 1;
    _pingTimer?.cancel();
    _pingTimer = null;
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
    onConnectionChange?.call(false);
  }

  void _connect() {
    if (!_running || _connecting) return;
    _connecting = true;

    final deviceKey = DeviceService.instance.getDeviceKey();
    if (deviceKey.isEmpty) {
      // 未登录，无需连接
      _connecting = false;
      _running = false;
      return;
    }

    try {
      final channel = WebSocketChannel.connect(Uri.parse(AppConfig.wsBase));
      _channel = channel;

      _sub = channel.stream.listen(
        (data) => _onMessage(data),
        onDone: () => _onClosed(),
        onError: (_) => _onClosed(),
      );

      // 连接建立后发送认证（WebSocketChannel.connect 返回后即可 send）
      channel.sink.add(jsonEncode({'type': 'auth', 'device_key': deviceKey}));
      _connecting = false;
      _disconnectSince = null; // 重连成功，清空断线计时
      onConnectionChange?.call(true);

      // 启动心跳
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) => _sendPing());
    } catch (_) {
      _connecting = false;
      _onClosed();
    }
  }

  void _sendPing() {
    final ch = _channel;
    if (ch != null) {
      try {
        ch.sink.add(jsonEncode({'type': 'ping'}));
      } catch (_) {
        _onClosed();
      }
    }
  }

  void _onMessage(dynamic data) {
    final Map<String, dynamic>? msg;
    try {
      final decoded = jsonDecode(data as String);
      msg = decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return;
    }
    if (msg == null) return;

    final type = msg['type'] as String? ?? '';

    switch (type) {
      case 'auth_result':
        final ok = msg['ok'] == true;
        if (!ok) {
          // 设备密钥失效：断开，交由上层重新登录
          NotifyStack.warning(msg['msg'] as String? ?? '连接已失效', title: '账号提示');
          _forceStopAndNotify();
        }
        break;

      case 'force_logout':
        final reason = msg['reason'] as String? ?? '登录状态已失效';
        // 断开连接，交由上层处理退出登录
        _stopped = true;
        _sub?.cancel();
        _channel?.sink.close();
        onForceLogout?.call(reason);
        break;

      case 'update':
        final update = msg['update'];
        if (update is Map<String, dynamic>) {
          onUpdate?.call(update);
        }
        break;

      case 'wallet':
        final wallet = msg['wallet'];
        if (wallet is Map<String, dynamic>) {
          onWallet?.call(wallet);
        }
        break;

      case 'maintenance':
        onMaintenance?.call(msg);
        break;

      case 'reply_notice':
        final notification = msg['notification'];
        if (notification is Map<String, dynamic>) {
          onReplyNotice?.call(notification);
        }
        break;

      case 'pong':
      case 'error':
        // 心跳响应/错误提示，暂不处理
        break;
    }
  }

  void _forceStopAndNotify() {
    _running = false;
    _stopped = true;
    _pingTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    onConnectionChange?.call(false);
  }

  void _onClosed() {
    if (_sub != null) {
      _sub?.cancel();
      _sub = null;
    }
    _pingTimer?.cancel();
    _pingTimer = null;
    _channel = null;
    _connecting = false;
    onConnectionChange?.call(false);

    // 记录首次断线时间（用于重连总超时判断）
    _disconnectSince ??= DateTime.now();

    // 需要重连（非主动停止且运行中）
    if (_running && !_stopped) {
      final delay = Duration(seconds: _retry);
      Timer(delay, () {
        if (!_running || _stopped) return;
        // 重连总超时：连续 reconnectTimeout 未连上 → 强制下线
        final elapsed =
            DateTime.now().difference(_disconnectSince ?? DateTime.now());
        if (elapsed >= reconnectTimeout) {
          _running = false;
          onConnectionChange?.call(false);
          onForceLogout?.call('连接服务器超时，请重新登录');
          return;
        }
        _retry = (_retry * 2 > 30) ? 30 : _retry * 2;
        _connect();
      });
    }
  }
}
