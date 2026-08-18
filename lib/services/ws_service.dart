import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/app_config.dart';
import '../core/device_service.dart';
import '../widgets/notify.dart';

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
  Timer? _retryTimer;
  bool _running = false;
  bool _connecting = false;

  /// 主动断开（如退出登录），区别于网络断线
  bool _stopped = false;

  /// 重连退避（秒），1,2,4,8,16,30 封顶
  int _retry = 1;

  /// 首次断线时间；用于"重连总超时强制下线"
  DateTime? _disconnectSince;

  /// 最近一次收到心跳响应（pong）的时间；用于探测"假连接"
  DateTime _lastPongAt = DateTime.now();

  /// 重连总超时（行业标准：连续 60 秒连不上即视为离线，强制下线）
  static const Duration reconnectTimeout = Duration(seconds: 60);

  /// 心跳发送间隔
  static const Duration pingInterval = Duration(seconds: 25);

  /// 建立连接超时（TCP + 握手超过该时长视为本次连接失败）
  static const Duration connectTimeout = Duration(seconds: 8);

  /// 心跳响应超时：超过该时长未收到 pong，判定连接已死，主动触发重连
  static const Duration pongTimeout = Duration(seconds: 40);

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

  /// 被关注通知回调（收到 follow_notice 推送，含 notification 对象）
  void Function(Map<String, dynamic> notification)? onFollowNotice;

  /// 聊天消息流（收到 chat_message 推送，密文透传，客户端解密）
  final _chatMsgCtrl = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onChatMessage => _chatMsgCtrl.stream;

  /// 连接状态回调（可选，用于 UI 展示）
  void Function(bool connected)? onConnectionChange;

  /// 重连成功回调（登录态有效；用于聊天补发失败消息等）
  void Function()? onReconnected;

  /// 是否已连接
  bool get isConnected => _channel != null && _sub != null;

  /// 启动连接（登录成功后调用）
  void start({
    void Function(String reason)? onForceLogout,
    void Function(Map<String, dynamic> update)? onUpdate,
    void Function(Map<String, dynamic> maintenance)? onMaintenance,
    void Function(Map<String, dynamic> notification)? onReplyNotice,
    void Function(Map<String, dynamic> notification)? onFollowNotice,
    void Function()? onReconnected,
  }) {
    this.onForceLogout = onForceLogout;
    this.onUpdate = onUpdate;
    this.onMaintenance = onMaintenance;
    this.onReplyNotice = onReplyNotice;
    this.onFollowNotice = onFollowNotice;
    this.onReconnected = onReconnected;
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
    _retryTimer?.cancel();
    _retryTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
    onConnectionChange?.call(false);
  }

  Future<void> _connect() async {
    if (!_running || _connecting) return;
    _connecting = true;

    final deviceKey = DeviceService.instance.getDeviceKey();
    if (deviceKey.isEmpty) {
      // 未登录，无需连接
      _connecting = false;
      _running = false;
      return;
    }

    WebSocketChannel? channel;
    try {
      channel = WebSocketChannel.connect(Uri.parse(AppConfig.wsBase));
      // 等待连接真正建立（TCP + 握手），避免"看似已连接实则未建立"的假在线
      await channel.ready.timeout(connectTimeout);
      if (!_running || _stopped) {
        channel.sink.close();
        _connecting = false;
        return;
      }

      _channel = channel;
      _sub = channel.stream.listen(
        (data) => _onMessage(data),
        onDone: () => _onClosed(),
        onError: (_) => _onClosed(),
      );

      // 连接建立后发送认证
      channel.sink.add(jsonEncode({'type': 'auth', 'device_key': deviceKey}));
      _connecting = false;
      final wasDisconnected = _disconnectSince != null;
      _disconnectSince = null; // 重连成功，清空断线计时
      _lastPongAt = DateTime.now();
      onConnectionChange?.call(true);
      // 曾断线后重连成功：触发上层补偿（补发失败消息/增量同步）
      if (wasDisconnected) {
        onReconnected?.call();
      }

      // 启动心跳
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(pingInterval, (_) => _sendPing());
    } catch (_) {
      _connecting = false;
      // 释放未建立成功的连接，避免资源泄漏
      try {
        channel?.sink.close();
      } catch (_) {}
      _onClosed();
    }
  }

  void _sendPing() {
    final ch = _channel;
    if (ch == null) return;
    // 心跳响应超时：超过 pongTimeout 未收到 pong，说明连接已"假死"
    // （网络断开但 TCP 层未感知，onDone/onError 不会触发），主动断开交由重连逻辑处理
    if (DateTime.now().difference(_lastPongAt) >= pongTimeout) {
      _onClosed();
      return;
    }
    try {
      ch.sink.add(jsonEncode({'type': 'ping'}));
    } catch (_) {
      _onClosed();
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

      case 'follow_notice':
        final notification = msg['notification'];
        if (notification is Map<String, dynamic>) {
          onFollowNotice?.call(notification);
        }
        break;

      case 'chat_message':
        final message = msg['message'];
        if (message is Map<String, dynamic>) {
          _chatMsgCtrl.add(message);
        }
        break;

      case 'pong':
        // 心跳响应：刷新最近响应时间，用于连接健康检测
        _lastPongAt = DateTime.now();
        break;

      case 'error':
        // 错误提示，暂不处理
        break;
    }
  }

  void _forceStopAndNotify() {
    _running = false;
    _stopped = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _pingTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    onConnectionChange?.call(false);
  }

  void _onClosed() {
    // 取消正在等待的重连定时器，避免重复调度
    _retryTimer?.cancel();
    _retryTimer = null;
    if (_sub != null) {
      _sub?.cancel();
      _sub = null;
    }
    _pingTimer?.cancel();
    _pingTimer = null;
    _channel?.sink.close();
    _channel = null;
    _connecting = false;
    onConnectionChange?.call(false);

    // 记录首次断线时间（用于重连总超时判断）
    _disconnectSince ??= DateTime.now();

    // 需要重连（非主动停止且运行中）
    if (_running && !_stopped) {
      final delay = Duration(seconds: _retry);
      _retryTimer = Timer(delay, () {
        _retryTimer = null;
        if (!_running || _stopped) return;
        // 重连总超时：连续 reconnectTimeout 未连上 → 提示并强制下线
        final elapsed =
            DateTime.now().difference(_disconnectSince ?? DateTime.now());
        if (elapsed >= reconnectTimeout) {
          _running = false;
          onConnectionChange?.call(false);
          onForceLogout?.call('网络连接不稳定，重连服务器失败，请检查网络后重新登录');
          return;
        }
        _retry = (_retry * 2 > 30) ? 30 : _retry * 2;
        _connect();
      });
    }
  }
}
