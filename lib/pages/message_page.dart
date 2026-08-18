import 'package:flutter/material.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../core/app_theme.dart';
import '../utils/net_image.dart';
import '../widgets/notify.dart';

/// 消息页（左侧导航栏「消息」入口）
///
/// 左侧：好友列表（互相关注的用户），分页加载；右侧：聊天界面。
/// 聊天功能（第二期）开发中，当前右侧为占位界面。
///
/// 样式遵循 docs/UI规范.md：颜色一律用 app_theme.dart 函数/常量。
class MessagePage extends StatefulWidget {
  final int currentUserId;

  const MessagePage({super.key, required this.currentUserId});

  @override
  State<MessagePage> createState() => _MessagePageState();
}

class _MessagePageState extends State<MessagePage> {
  final List<Map<String, dynamic>> _friends = [];
  int _page = 1;
  bool _loading = false;
  bool _loadingMore = false;
  bool _allLoaded = false;
  bool _loadFailed = false;

  /// 当前选中好友
  Map<String, dynamic>? _selectedFriend;

  @override
  void initState() {
    super.initState();
    _loadFriends();
  }

  Future<void> _loadFriends() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final resp = await ApiClient.instance
          .getFriends(page: 1, pageSize: 50)
          .timeout(const Duration(seconds: 15));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (!mounted) return;
      if (json['code'] != 0) {
        NotifyStack.warning(json['msg']?.toString() ?? '加载失败', title: '提示');
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
        return;
      }
      final data = (json['data'] ?? {}) as Map<String, dynamic>;
      final list = (data['list'] ?? []) as List;
      setState(() {
        _friends.clear();
        _friends.addAll(list.map((e) => Map<String, dynamic>.from(e)));
        _page = 1;
        _allLoaded = !(data['has_more'] ?? false);
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      }
    }
  }

  Future<void> _loadMoreFriends() async {
    if (_loadingMore || _allLoaded) return;
    setState(() => _loadingMore = true);
    try {
      final resp = await ApiClient.instance
          .getFriends(page: _page + 1, pageSize: 50)
          .timeout(const Duration(seconds: 15));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (!mounted) return;
      if (json['code'] == 0) {
        final data = (json['data'] ?? {}) as Map<String, dynamic>;
        final list = (data['list'] ?? []) as List;
        setState(() {
          _friends.addAll(list.map((e) => Map<String, dynamic>.from(e)));
          _page++;
          _allLoaded = !(data['has_more'] ?? false);
          _loadingMore = false;
        });
      } else {
        setState(() => _loadingMore = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Scaffold(
      // 聊天内容页用主背景色
      backgroundColor: bgColor(b),
      body: Row(
        children: [
          // ===== 左侧好友列表（无分割线）：颜色比聊天区深（用 bgSoft，同左侧导航栏） =====
          Container(
            width: 260,
            color: bgSoftColor(b),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 列表标题
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                  child: Text(
                    '好友',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: textColor(b),
                    ),
                  ),
                ),
                Expanded(
                  child: _buildFriendList(b),
                ),
              ],
            ),
          ),
          // ===== 右侧聊天区 =====
          Expanded(
            child: _buildChatArea(b),
          ),
        ],
      ),
    );
  }

  Widget _buildFriendList(Brightness b) {
    if (_loading && _friends.isEmpty) {
      return Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: kPrimary),
      );
    }
    if (_loadFailed && _friends.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败', style: TextStyle(fontSize: 13, color: textMutedColor(b))),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _loadFriends,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_friends.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_rounded,
                size: 40, color: textFaintColor(b)),
            const SizedBox(height: 12),
            Text(
              '还没有好友',
              style: TextStyle(fontSize: 14, color: textSecondaryColor(b)),
            ),
            const SizedBox(height: 4),
            Text(
              '互相关注后即可成为好友',
              style: TextStyle(fontSize: 12, color: textMutedColor(b)),
            ),
          ],
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels >= n.metrics.maxScrollExtent - 80) {
          _loadMoreFriends();
        }
        return false;
      },
      child: SilkyListView(
        children: [
          for (final friend in _friends) _buildFriendItem(b, friend),
          if (!_allLoaded)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
        scrollSpeed: 1.6,
        silkyScrollDuration: const Duration(milliseconds: 600),
        animationCurve: Curves.easeOutCubic,
      ),
    );
  }

  Widget _buildFriendItem(Brightness b, Map<String, dynamic> friend) {
    final selected = _selectedFriend?['user_id'] == (friend['user_id'] as num?)?.toInt();
    final avatar = friend['avatar']?.toString() ?? '';
    final nickname = friend['nickname']?.toString() ?? '';
    return InkWell(
      onTap: () => setState(() => _selectedFriend = friend),
      hoverColor: bgHoverColor(b),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        color: selected ? primarySoftColor(b) : Colors.transparent,
        child: Row(
          children: [
            ClipOval(
              child: avatar.isNotEmpty
                  ? NetImage(
                      url: AppConfig.resolveUrl(avatar),
                      width: 40,
                      height: 40,
                      fit: BoxFit.cover,
                      loadingSize: 16,
                    )
                  : _avatarPlaceholder(b, nickname),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                nickname,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: textColor(b),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _avatarPlaceholder(Brightness b, String nickname) {
    final text = nickname.trim();
    final initial = text.isEmpty ? '?' : (text.length <= 2 ? text : text.substring(0, 2));
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(color: primarySoftColor(b), shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: kPrimary),
      ),
    );
  }

  /// 右侧聊天区（第二期填充聊天功能，当前为占位）
  Widget _buildChatArea(Brightness b) {
    final friend = _selectedFriend;
    if (friend == null) {
      return Center(
        // 圆润聊天气泡占位：白天很浅、晚上很深（用 textFaintColor 随主题），无文字
        child: Icon(
          Icons.chat_bubble_rounded,
          size: 64,
          color: textFaintColor(b),
        ),
      );
    }
    final nickname = friend['nickname']?.toString() ?? '';
    final avatar = friend['avatar']?.toString() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 聊天对象标题栏（无分割线，主背景色）
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: bgColor(b),
          child: Row(
            children: [
              ClipOval(
                child: avatar.isNotEmpty
                    ? NetImage(
                        url: AppConfig.resolveUrl(avatar),
                        width: 32,
                        height: 32,
                        fit: BoxFit.cover,
                        loadingSize: 14,
                      )
                    : _avatarPlaceholder(b, nickname),
              ),
              const SizedBox(width: 10),
              Text(
                nickname,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: textColor(b),
                ),
              ),
            ],
          ),
        ),
        // 消息区（第二期填充）：圆润气泡占位（白天浅/晚上深，随主题）
        Expanded(
          child: Center(
            child: Icon(
              Icons.chat_bubble_rounded,
              size: 48,
              color: textFaintColor(b),
            ),
          ),
        ),
        // 输入区（第二期填充，无分割线，主背景色）
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: bgColor(b),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: bgColor(b),
                    borderRadius: BorderRadius.circular(kRadiusMd),
                  ),
                  child: TextField(
                    enabled: false,
                    style: TextStyle(fontSize: 14, color: textColor(b)),
                    decoration: InputDecoration(
                      hintText: '聊天功能开发中…',
                      hintStyle:
                          TextStyle(fontSize: 14, color: textFaintColor(b)),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
