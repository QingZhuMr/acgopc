import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_config.dart';
import '../../core/app_theme.dart';
import '../../services/chat_image_cache.dart';
import '../../utils/net_image.dart';
import '../../widgets/bubble_menu.dart';
import '../widgets/mobile_toast.dart';

/// 移动端聊天气泡组件（时间线 / 文本 / 图片 / 表情 / 引用 / 撤回 / 发送状态）
class ChatBubble extends StatelessWidget {
  final Map<String, dynamic> message;
  final bool isMine;
  final String peerNickname;
  final String? peerAvatar;
  final String? myAvatar;
  final int nowSec;
  final String? timeLabel; // 组头时间标签
  final bool groupHead; // 是否组头（显示头像）
  final VoidCallback onQuote; // 引用该消息
  final VoidCallback? onRecall; // 撤回（仅自己且可撤回时非空）
  final VoidCallback onRetry;
  final VoidCallback? onForward; // 转发（表情包长按）
  final VoidCallback? onAddSticker; // 添加到表情（表情包长按，仅对方发的表情非空）
  final VoidCallback? onDelete; // 删除消息（表情包长按）

  const ChatBubble({
    super.key,
    required this.message,
    required this.isMine,
    required this.peerNickname,
    this.peerAvatar,
    this.myAvatar,
    required this.nowSec,
    this.timeLabel,
    this.groupHead = true,
    required this.onQuote,
    this.onRecall,
    required this.onRetry,
    this.onForward,
    this.onAddSticker,
    this.onDelete,
  });

  // ---- 解析 ----
  (Map<String, dynamic>?, String) _parseBody() {
    final plaintext = message['plaintext']?.toString() ?? '';
    if (plaintext.startsWith('{')) {
      try {
        final j = jsonDecode(plaintext);
        if (j is Map && j['text'] is String && j['reply_to'] is Map) {
          return (
            Map<String, dynamic>.from(j['reply_to'] as Map),
            j['text'] as String
          );
        }
      } catch (_) {}
    }
    return (null, plaintext);
  }

  int get _msgType => (message['msg_type'] as num?)?.toInt() ?? 1;
  bool get _recalled => (message['recalled'] as num?)?.toInt() == 1;
  int get _sendStatus => (message['send_status'] as num?)?.toInt() ?? 2;
  int get _readStatus => (message['read_status'] as num?)?.toInt() ?? 0;
  bool get _groupTail {
    // 组尾：当前是组头，或下一条消息属于不同发件人/时间间隔 > 5 分钟
    return true; // 移动端简化：始终显示组尾状态
  }

  /// 本地缓存文件路径（存在才返回非空）。发送方本地缓存 / 接收方下载缓存
  /// 都会回填到 image_local_path；用 File.existsSync 兜底防止路径失效。
  String get _localPath {
    final p = message['image_local_path']?.toString() ?? '';
    if (p.isEmpty) return '';
    try {
      return File(p).existsSync() ? p : '';
    } catch (_) {
      return '';
    }
  }

  /// 云端图片 URL（从 plaintext JSON 的 url 字段解析）
  String get _remoteUrl =>
      ChatImageCache.parseUrl(message['plaintext']?.toString() ?? '');

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final dark = b == Brightness.dark;

    final topPad = groupHead ? 6.0 : 1.0;

    Widget bubble;
    if (_recalled) {
      bubble = _buildRecalled(dark);
    } else {
      switch (_msgType) {
        case 2:
          bubble = _buildImage(context, dark);
          break;
        case 3:
          bubble = _buildSticker(context, dark);
          break;
        default:
          bubble = _buildText(context, dark);
      }
    }

    final bubbleWidget = Padding(
      padding: EdgeInsets.only(top: topPad, bottom: 1),
      child: Column(
        crossAxisAlignment: isMine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: isMine
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!isMine) ...[
                groupHead ? _buildAvatar(dark) : const SizedBox(width: 40),
                const SizedBox(width: 8),
              ],
              Flexible(child: bubble),
            ],
          ),
          // 气泡下方：发送状态 / 已读未读（仅组尾显示）
          if (isMine && _groupTail) ...[
            const SizedBox(height: 2),
            _buildStatusRow(dark),
          ],
        ],
      ),
    );

    // 时间胶囊：独立一行渲染在气泡上方，气泡照常显示（修复：原实现
    // timeLabel != null 时直接 return 时间胶囊，导致该条气泡被替换、头像消失，
    // 表现为「连续气泡被打断 + 下一气泡无头像 / 凭空多出时间胶囊」）
    if (timeLabel == null) return bubbleWidget;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: dark
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.black.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                timeLabel!,
                style: TextStyle(
                  fontSize: 11,
                  color: dark
                      ? Colors.white.withValues(alpha: 0.45)
                      : Colors.black.withValues(alpha: 0.45),
                ),
              ),
            ),
          ),
        ),
        bubbleWidget,
      ],
    );
  }

  Widget _buildAvatar(bool dark) {
    final url = peerAvatar ?? '';
    if (url.isEmpty) {
      return Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: kPrimary.withValues(alpha: 0.15),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Text(
          peerNickname.isEmpty ? '?' : peerNickname.characters.first,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: kPrimary,
          ),
        ),
      );
    }
    return ClipOval(
      child: SizedBox(
        width: 40,
        height: 40,
        child: NetImage(url: AppConfig.resolveUrl(url), fit: BoxFit.cover),
      ),
    );
  }

  Widget _buildStatusRow(bool dark) {
    // 仅展示发送成功后的已读/未读状态；发送中（转圈）与失败（红感叹号）
    // 已由 _withStatus 放在气泡左侧，此处不再重复显示
    if (_sendStatus != 1) return const SizedBox.shrink();
    final statusColor = dark ? Colors.white.withValues(alpha: 0.4) : Colors.black.withValues(alpha: 0.4);
    final readColor = const Color(0xFF4A90E2);
    final icon = _readStatus == 1
        ? Icon(Icons.done_all, size: 14, color: readColor)
        : Icon(Icons.done, size: 14, color: statusColor);
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 2),
      child: icon,
    );
  }

  Widget _buildRecalled(bool dark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          '消息已撤回',
          style: TextStyle(
            fontSize: 12,
            color: dark
                ? Colors.white.withValues(alpha: 0.35)
                : Colors.black.withValues(alpha: 0.35),
          ),
        ),
      ),
    );
  }

  Widget _buildText(BuildContext context, bool dark) {
    final (quote, text) = _parseBody();
    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: isMine
            ? kPrimary
            : (dark ? const Color(0xFF23232A) : const Color(0xFFF2F3F5)),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.2 : 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (quote != null) _buildQuoteBar(quote, dark),
          Text(
            text,
            style: TextStyle(
              fontSize: 15.5,
              height: 1.4,
              color: isMine ? Colors.white : textBodyColor(dark ? Brightness.dark : Brightness.light),
            ),
          ),
        ],
      ),
    );
    // 文字气泡长按弹微信式菜单（复制 / 转发 / 引用 / 撤回 / 删除）
    return _withStatus(_buildBubbleMenu(context, bubble));
  }

  Widget _buildQuoteBar(Map<String, dynamic> q, bool dark) {
    final nickname = q['nickname']?.toString() ?? '';
    final preview = q['preview']?.toString() ?? '';
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: (isMine ? Colors.white : kPrimary)
            .withValues(alpha: isMine ? 0.15 : 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(color: isMine ? Colors.white : kPrimary, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            nickname,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isMine
                  ? Colors.white.withValues(alpha: 0.9)
                  : kPrimary,
            ),
          ),
          if (preview.isNotEmpty)
            Text(
              preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: (isMine ? Colors.white : textBodyColor(dark ? Brightness.dark : Brightness.light))
                    .withValues(alpha: 0.75),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildImage(BuildContext context, bool dark) {
    final bubble = GestureDetector(
      onTap: () => _previewImage(context),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 180,
          height: 220,
          child: _imageWidget(dark, fit: BoxFit.cover),
        ),
      ),
    );
    return _withStatus(_buildBubbleMenu(context, bubble));
  }

  /// 图片 widget：本地缓存文件优先，其次云端 URL，最后占位。
  /// 修复：原实现把本地绝对路径直接丢给 NetImage（网络组件），
  /// 导致「No host specified in URI」崩溃（自己/对方图片都显示不出来）。
  Widget _imageWidget(bool dark, {required BoxFit fit}) {
    final local = _localPath;
    if (local.isNotEmpty) {
      return Image.file(
        File(local),
        fit: fit,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => _imageFallback(dark),
      );
    }
    final url = _remoteUrl;
    if (url.isNotEmpty) {
      return NetImage(url: AppConfig.resolveUrl(url), fit: fit);
    }
    return _imageFallback(dark);
  }

  Widget _imageFallback(bool dark) {
    return Container(
      color: dark ? const Color(0xFF23232A) : const Color(0xFFF2F3F5),
      alignment: Alignment.center,
      child: Icon(Icons.image_outlined,
          color: Colors.black.withValues(alpha: 0.2), size: 40),
    );
  }

  /// 所有气泡类型统一的长按菜单（微信式，气泡优先在按压点上方弹出）：
  /// 复制（仅文本）/ 转发 / 添加到表情（仅对方发的表情）/ 引用 / 撤回（自己+可撤回）/ 删除
  Widget _buildBubbleMenu(BuildContext context, Widget child) {
    return BubbleMenu(
      triggerOnLongPress: true,
      wechatStyle: true,
      preferUp: true,
      itemHeight: 48,
      verticalPadding: 4,
      radius: 10,
      gap: 10,
      duration: const Duration(milliseconds: 180),
      items: [
        // 复制（仅文本，复制纯文本不含引用 JSON 结构）
        if (_msgType == 1)
          BubbleMenuItem(
            icon: Icons.copy_rounded,
            label: '复制',
            onTap: () {
              final (_, text) = _parseBody();
              Clipboard.setData(ClipboardData(text: text));
              MobileToast.success(context, '已复制');
            },
          ),
        // 转发（所有类型）
        if (onForward != null)
          BubbleMenuItem(
            icon: Icons.forward_outlined,
            label: '转发',
            onTap: onForward!,
          ),
        // 添加到表情（仅对方发的表情）
        if (onAddSticker != null)
          BubbleMenuItem(
            icon: Icons.add_box_outlined,
            label: '添加到表情',
            onTap: onAddSticker!,
          ),
        // 引用（所有类型）
        BubbleMenuItem(
          icon: Icons.format_quote_rounded,
          label: '引用',
          onTap: onQuote,
        ),
        // 撤回（自己发的且可撤回）
        if (onRecall != null)
          BubbleMenuItem(
            icon: Icons.undo_rounded,
            label: '撤回',
            color: kDanger,
            onTap: onRecall!,
          ),
        // 删除（本设备删除，所有类型）
        if (onDelete != null)
          BubbleMenuItem.delete('删除', onTap: onDelete!),
      ],
      child: child,
    );
  }

  Widget _buildSticker(BuildContext context, bool dark) {
    // 表情：最长边 <=120，等比
    int w = 120;
    int h = 120;
    try {
      final j = jsonDecode(message['plaintext']?.toString() ?? '');
      if (j is Map) {
        final ww = j['w'];
        final hh = j['h'];
        if (ww is num && hh is num && ww > 0 && hh > 0) {
          final scale = 120 / maxNum(ww.toInt(), hh.toInt());
          w = (ww.toInt() * scale).round();
          h = (hh.toInt() * scale).round();
        }
      }
    } catch (_) {}
    final sticker = SizedBox(
      width: w.toDouble(),
      height: h.toDouble(),
      child: _imageWidget(dark, fit: BoxFit.contain),
    );
    return _withStatus(_buildBubbleMenu(context, sticker));
  }

  int maxNum(int a, int b) => a > b ? a : b;

  /// 发送状态包裹（发送中转圈 / 失败红点可重发），状态图标置于气泡左侧
  Widget _withStatus(Widget child) {
    if (_sendStatus == 0) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.8),
          ),
          const SizedBox(width: 6),
          child,
        ],
      );
    }
    if (_sendStatus == 2) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          GestureDetector(
            onTap: onRetry,
            child: const Icon(Icons.error_outline,
                color: Colors.red, size: 16),
          ),
          const SizedBox(width: 6),
          child,
        ],
      );
    }
    return child;
  }

  void _previewImage(BuildContext context) {
    final local = _localPath;
    final url = _remoteUrl;
    if (local.isEmpty && url.isEmpty) return;
    // 预览优先本地缓存文件，其次云端 URL（避免本地路径被当网络 URL 加载崩溃）
    final Widget image = local.isNotEmpty
        ? Image.file(File(local), fit: BoxFit.contain)
        : Image.network(AppConfig.resolveUrl(url), fit: BoxFit.contain);
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          // 点击图片以外区域关闭（无关闭按钮）；图片区域点击不关闭，用于缩放/拖拽
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.pop(context),
            child: Center(
              child: GestureDetector(
                onTap: () {},
                child: InteractiveViewer(
                  maxScale: 4,
                  minScale: 1,
                  child: image,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
