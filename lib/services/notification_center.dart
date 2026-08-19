import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../widgets/notify.dart';
import '../widgets/match_dialog.dart';
import '../controllers/system_notifier.dart';

/// 客户端通知中心（单例，ChangeNotifier）
///
/// 统一管理「帖子回复通知」：
///   - 未读数（铃铛角标）
///   - 定时轮询未读数（WS 不在线 / 断线时的兜底）
///   - 收到 WS `reply_notice` 推送时：弹应用内通知 + Windows 系统通知 + 刷新角标
///
/// 生命周期：登录成功后 `start()`，退出登录 `stop()`。
class NotificationCenter extends ChangeNotifier {
  NotificationCenter._();

  static final NotificationCenter instance = NotificationCenter._();

  /// 未读通知数（铃铛角标）
  int _unread = 0;
  int get unread => _unread;

  /// 定时轮询定时器
  Timer? _pollTimer;

  /// 已处理的 WS 推送（去重，避免同一条重复弹窗）
  final Set<int> _seenIds = {};

  /// 当前是否有登录用户（控制轮询开关）
  bool _active = false;

  /// 跳转帖子详情的回调（由 main.dart 注入，避免通知中心依赖具体页面构造）
  void Function(int postId, String postContent)? onOpenPost;

  /// 跳转他人主页的回调（type=3 被关注通知点击）
  void Function(int uid, String nickname, String avatar)? onOpenUserProfile;

  /// 弹配对成功全局弹窗的回调（由 main.dart 注入）
  ///
  /// 返回 true 表示用户点击了「去聊天」按钮（通知流程结束）。
  Future<bool> Function(MatchInfo info)? onShowMatchDialog;

  /// 已弹过配对弹窗的时间（按对方 uid，短时间去重）
  final Map<int, DateTime> _lastMatchShownAt = {};

  /// 启动通知中心（登录成功后调用）
  ///
  /// 初始化系统通知插件 + 拉取一次未读数 + 启动定时轮询。
  void start({
    void Function(int postId, String postContent)? onOpenPost,
    void Function(int uid, String nickname, String avatar)? onOpenUserProfile,
    Future<bool> Function(MatchInfo info)? onShowMatchDialog,
  }) {
    this.onOpenPost = onOpenPost;
    this.onOpenUserProfile = onOpenUserProfile;
    this.onShowMatchDialog = onShowMatchDialog;
    _active = true;
    // 初始化 Windows 系统通知（失败不影响）
    SystemNotifier.instance.init();
    // 启动时立即拉取一次未读数
    _fetchUnread();
    // 定期轮询未读数（兜底：WS 推送可能因断线丢失）
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_active) _fetchUnread();
    });
  }

  /// 停止通知中心（退出登录时调用）
  void stop() {
    _active = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    _unread = 0;
    _seenIds.clear();
    _lastMatchShownAt.clear();
    notifyListeners();
  }

  /// 公开：主动拉取未读数并刷新角标（通知页关闭/标记已读后调用）
  Future<void> fetchUnreadForce() async {
    if (!_active) return;
    await _fetchUnread();
  }

  /// 拉取未读数（定时轮询 / 刷新角标）
  Future<void> _fetchUnread() async {
    try {
      final resp = await ApiClient.instance
          .getNotificationUnreadCount()
          .timeout(const Duration(seconds: 8));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] == 0) {
        final data = json['data'] as Map<String, dynamic>? ?? {};
        final count = (data['unread_count'] as num?)?.toInt() ?? 0;
        if (count != _unread) {
          _unread = count;
          notifyListeners();
        }
      }
    } catch (_) {
      // 网络异常忽略，下轮重试
    }
  }

  /// 收到 WS reply_notice 推送
  ///
  /// 弹应用内通知 + 系统通知，并刷新角标。
  void handleWsReply(Map<String, dynamic> notification) {
    // 解析
    final id = (notification['id'] as num?)?.toInt() ?? 0;
    final type = (notification['type'] as num?)?.toInt() ?? 1;
    final fromName = (notification['from_nickname'] as String?) ?? '有人';
    final commentContent = (notification['comment_content'] as String?) ?? '';
    final postContent = (notification['post_content'] as String?) ?? '';
    final postId = (notification['post_id'] as num?)?.toInt() ?? 0;

    // 去重：同一条推送不重复弹窗
    if (id > 0) {
      if (_seenIds.contains(id)) return;
      _seenIds.add(id);
    }

    // 标题：type=1 评论了我的帖子，type=2 回复了我的评论
    final title = type == 2 ? '$fromName 回复了你' : '$fromName 评论了你的帖子';
    final body = commentContent.isNotEmpty ? commentContent : postContent;

    // 应用内通知（前台可见）：第一行标题 + 第二行动态正文摘要
    NotifyStack.notify(
      title: title,
      message: body,
      onTap: postId > 0 ? () => _openPost(postId, postContent) : null,
      persistent: false,
    );

    // Windows 系统通知（Toast）：窗口被遮挡/托盘时也能看到，点击可跳转帖子
    SystemNotifier.instance.show(
      title: title,
      subtitle: AppConfig.appName,
      body: body,
      onClick: postId > 0 ? () => _openPost(postId, postContent) : null,
    );

    // 刷新角标
    _unread += 1;
    notifyListeners();
  }

  /// 收到 WS follow_notice 推送（被关注）
  ///
  /// 弹应用内通知 + 系统通知，并刷新角标。
  void handleWsFollow(Map<String, dynamic> notification) {
    final fromUid = (notification['from_uid'] as num?)?.toInt() ?? 0;
    final fromName = (notification['from_nickname'] as String?) ?? '有人';
    final fromAvatar = (notification['from_avatar'] as String?) ?? '';

    // 标题：xx 关注了你
    final title = '$fromName 关注了你';
    final body = '快去看看 TA 的主页吧';

    // 应用内通知（前台可见）
    NotifyStack.notify(
      title: title,
      message: body,
      onTap: fromUid > 0
          ? () => _openUserProfile(fromUid, fromName, fromAvatar)
          : null,
      persistent: false,
    );

    // Windows 系统通知（Toast）
    SystemNotifier.instance.show(
      title: title,
      subtitle: AppConfig.appName,
      body: body,
      onClick: fromUid > 0
          ? () => _openUserProfile(fromUid, fromName, fromAvatar)
          : null,
    );

    // 刷新角标
    _unread += 1;
    notifyListeners();
  }

  /// 收到 WS match_notice 推送（星球配对/解绑）
  ///
  /// type=6 配对成功：弹全局配对弹窗（头像/昵称/资料 + 去聊天按钮，
  /// 仅可点击按钮关闭）。type=7 对方解除了绑定：应用内 + 系统通知。
  void handleWsMatch(Map<String, dynamic> notification) {
    final id = (notification['id'] as num?)?.toInt() ?? 0;
    final type = (notification['type'] as num?)?.toInt() ?? 6;
    final fromUid = (notification['from_uid'] as num?)?.toInt() ?? 0;
    final fromName = (notification['from_nickname'] as String?) ?? '有人';
    final fromAvatar = (notification['from_avatar'] as String?) ?? '';

    // 去重：同一条推送不重复处理
    if (id > 0) {
      if (_seenIds.contains(id)) return;
      _seenIds.add(id);
    }

    if (type == 6) {
      // 配对成功：弹全局配对弹窗
      final rawProfile = notification['from_profile'];
      showMatchDialog(
        MatchInfo(
          uid: fromUid,
          nickname: fromName,
          avatar: AppConfig.resolveUrl(fromAvatar),
          profile: rawProfile is Map
              ? rawProfile.cast<String, dynamic>()
              : null,
          planetName: (notification['planet_name'] as String?) ?? '',
          notificationId: id,
        ),
      );
    } else if (type == 7) {
      // type=7 对方解除绑定：应用内 + 系统通知（点击跳转对方主页）
      final title = '已解除绑定';
      final body = '$fromName 解除了与你的绑定关系';
      NotifyStack.notify(
        title: title,
        message: body,
        onTap: fromUid > 0
            ? () => _openUserProfile(fromUid, fromName, fromAvatar)
            : null,
        persistent: false,
      );
      SystemNotifier.instance.show(
        title: title,
        subtitle: AppConfig.appName,
        body: body,
        onClick: fromUid > 0
            ? () => _openUserProfile(fromUid, fromName, fromAvatar)
            : null,
      );
    } else if (type == 8) {
      // type=8 绑定对象长期未上线，系统自动解除绑定（补偿信息在 comment_content）
      final comp = (notification['comment_content'] as String?) ?? '';
      final title = '绑定已自动解除';
      final body = comp.isNotEmpty
          ? '$fromName 长期未上线，绑定已自动解除（$comp）'
          : '$fromName 长期未上线，绑定已自动解除';
      NotifyStack.notify(
        title: title,
        message: body,
        onTap: fromUid > 0
            ? () => _openUserProfile(fromUid, fromName, fromAvatar)
            : null,
        persistent: false,
      );
      SystemNotifier.instance.show(
        title: title,
        subtitle: AppConfig.appName,
        body: body,
        onClick: fromUid > 0
            ? () => _openUserProfile(fromUid, fromName, fromAvatar)
            : null,
      );
    }

    // 刷新角标
    _unread += 1;
    notifyListeners();
  }

  /// 公开：弹配对成功全局弹窗（本地配对成功与 WS 推送共用入口）
  ///
  /// 短时间（30 秒）内同一 uid 已弹过则跳过，避免「本地配对成功弹窗」
  /// 与随后到达的 WS 推送重复弹出。用户点击「去聊天」后自动标记通知已读。
  Future<bool> showMatchDialog(MatchInfo info) async {
    if (info.uid <= 0) return false;
    // 去重：30 秒内同 uid 已弹过则跳过
    final last = _lastMatchShownAt[info.uid];
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 30)) {
      return false;
    }
    _lastMatchShownAt[info.uid] = DateTime.now();

    final cb = onShowMatchDialog;
    if (cb == null) return false;
    final done = await cb(info);

    // 点击「去聊天」后：该通知视为已读，刷新角标
    if (done && (info.notificationId ?? 0) > 0) {
      try {
        await ApiClient.instance.readNotification(id: info.notificationId!);
      } catch (_) {
        // 标记已读失败不影响主流程
      }
      await fetchUnreadForce();
    }
    return done;
  }

  /// 跳转他人主页（应用内/系统通知点击）
  void _openUserProfile(int uid, String nickname, String avatar) {
    final cb = onOpenUserProfile;
    if (cb != null) {
      cb(uid, nickname, avatar);
    }
  }

  /// 跳转帖子详情（应用内通知点击）
  void _openPost(int postId, String postContent) {
    final cb = onOpenPost;
    if (cb != null) {
      cb(postId, postContent);
    }
  }
}
