import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:window_manager/window_manager.dart';

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../core/app_theme.dart';
import '../widgets/notify.dart';
import '../widgets/pick_images.dart';
import 'post_detail_page.dart';
import '../services/post_draft_store.dart';
import '../widgets/sticker_panel.dart';

/// 发动态页：类小红书发帖。
///
/// 布局（自上而下）：标题栏 → 头像昵称 → 图片区（横向滑动缩略图，最多 5 张）
/// → 内容输入 → 底部（左下「暂存」+ 右下「发布」）。
/// 发布成功后 `Navigator.pop(true)` 通知上层刷新，并清除本地草稿。
class PublishPostPage extends StatefulWidget {
  final Map<String, dynamic> user;

  /// 是否以内嵌模式展示（macOS 内容区 tab）：无窗口按钮
  final bool embedded;

  /// 内嵌模式下点击返回按钮的回调（macOS 用，由宿主清空内容区覆盖层）
  final VoidCallback? onBack;

  /// 内嵌模式下发布成功的回调（macOS 用，由宿主在内容区展示新帖子详情）
  final void Function(int postId, Map<String, dynamic> brief)? onPublished;

  const PublishPostPage({
    super.key,
    required this.user,
    this.embedded = false,
    this.onBack,
    this.onPublished,
  });

  @override
  State<PublishPostPage> createState() => _PublishPostPageState();
}

class _PublishPostPageState extends State<PublishPostPage> {
  static const int _maxImages = 5;
  static const int _maxContent = 2000;
  static const double _thumbSize = 88;

  final TextEditingController _contentCtrl = TextEditingController();
  final FocusNode _contentFocus = FocusNode();
  final List<Uint8List> _images = [];
  final List<String> _imageNames = [];
  bool _publishing = false;
  bool _saving = false;
  bool _showPanel = false; // emoji 表情面板开关

  @override
  void initState() {
    super.initState();
    _loadDraft();
  }

  @override
  void dispose() {
    _contentCtrl.dispose();
    _contentFocus.dispose();
    super.dispose();
  }

  /// 从用户 map 解析用户 id（兼容 'id'/'user_id'，值可能是 int/num/String）
  static int _resolveUid(Map<String, dynamic> user) {
    for (final key in const ['id', 'user_id', 'uid']) {
      final raw = user[key];
      if (raw is num) return raw.toInt();
      if (raw is String) {
        final v = int.tryParse(raw);
        if (v != null) return v;
      }
    }
    return 0;
  }

  String get _nickname {
    final n = widget.user['nickname'] as String?;
    if (n != null && n.trim().isNotEmpty) return n.trim();
    return (widget.user['phone'] as String?) ?? '我';
  }

  String? get _avatarUrl {
    final raw = widget.user['avatar'] as String?;
    if (raw == null || raw.isEmpty) return null;
    return AppConfig.resolveUrl(raw);
  }

  bool get _hasContent =>
      _contentCtrl.text.trim().isNotEmpty || _images.isNotEmpty;

  /// 打开发动态页时加载本地暂存草稿
  Future<void> _loadDraft() async {
    final draft = await PostDraftStore.instance.load();
    if (draft == null || !mounted) return;
    final imgs = <Uint8List>[];
    final names = <String>[];
    for (final name in draft.imageNames) {
      final bytes = await PostDraftStore.instance.readImage(name);
      if (bytes != null) {
        imgs.add(bytes);
        names.add(name);
      }
    }
    if (!mounted) return;
    setState(() {
      _contentCtrl.text = draft.content;
      _images.addAll(imgs);
      _imageNames.addAll(names);
    });
  }

  /// 选择图片（最多 5 张；单张 >5MB 跳过并提示）
  Future<void> _pickImages() async {
    final remain = _maxImages - _images.length;
    if (remain <= 0) {
      NotifyStack.warning('最多上传 $_maxImages 张图片', title: '提示');
      return;
    }
    if (!mounted) return;
    final picked = await pickImages(allowMultiple: true);

    for (final img in picked.take(remain)) {
      if (img.bytes.length > 10 * 1024 * 1024) {
        NotifyStack.warning('图片「${img.name}」超过 10MB，已跳过', title: '提示');
        continue;
      }
      _images.add(img.bytes);
      _imageNames.add(img.name);
    }
    if (mounted) setState(() {});
  }

  void _removeImage(int index) {
    setState(() {
      _images.removeAt(index);
      _imageNames.removeAt(index);
    });
  }

  /// 暂存到本地并退出
  Future<void> _saveDraft() async {
    final content = _contentCtrl.text.trim();
    if (content.isEmpty && _images.isEmpty) {
      NotifyStack.warning('暂无可暂存的内容', title: '提示');
      return;
    }
    setState(() => _saving = true);
    try {
      await PostDraftStore.instance.save(
        content,
        [
          for (var i = 0; i < _images.length; i++)
            PostImage(_images[i], _imageNames[i]),
        ],
      );
      if (!mounted) return;
      NotifyStack.success('已暂存到本地', title: '提示');
      Navigator.of(context).pop(false);
    } catch (e) {
      if (!mounted) return;
      NotifyStack.warning('暂存失败：$e', title: '提示');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 发布动态（成功后清草稿）
  Future<void> _publish() async {
    final content = _contentCtrl.text.trim();
    if (content.isEmpty) {
      NotifyStack.warning('说点什么吧', title: '提示');
      return;
    }
    setState(() => _publishing = true);
    try {
      final resp = await ApiClient.instance
          .publishPost(
            content: content,
            images: _images.isEmpty
                ? null
                : [
                    for (var i = 0; i < _images.length; i++)
                      PostImage(_images[i], _imageNames[i]),
                  ],
          )
          .timeout(const Duration(seconds: 30));
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] != 0) {
        // 业务失败：直接显示后端返回的文案（如「内容敏感，请重新编辑。」）
        if (!mounted) return;
        NotifyStack.warning((json['msg'] as String?) ?? '发布失败', title: '提示');
        return;
      }
      await PostDraftStore.instance.clear();
      final postId = (json['data']?['id'] as num?)?.toInt() ?? 0;
      if (!mounted) return;
      NotifyStack.success('发布成功', title: '耶熊');
      if (postId > 0) {
        // 直接跳转到新帖子的详情页（替换发布页），详情页返回时回到广场页
        final brief = <String, dynamic>{
          'id': postId,
          'content': content,
          'nickname': _nickname,
          'avatar': _avatarUrl?.replaceFirst(AppConfig.apiBase, ''),
          'create_time_text': '刚刚',
          'images': <String>[],
        };
        final curUid = _resolveUid(widget.user);
        // macOS 内嵌模式：通过回调在内容区展示新帖子详情（保留左侧导航栏，不遮盖）
        if (widget.embedded && widget.onPublished != null) {
          widget.onPublished!(postId, brief);
        } else {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => PostDetailPage(
                postBrief: brief,
                postId: postId,
                currentUserId: curUid,
              ),
            ),
          );
        }
      } else {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (!mounted) return;
      NotifyStack.warning('发布失败，请稍后重试', title: '提示');
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  /// 返回：有内容时二次确认，避免误触丢失
  Future<void> _handleBack() async {
    if (!_hasContent) {
      Navigator.of(context).pop(false);
      return;
    }
    final b = Theme.of(context).brightness;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: bgColor(b),
        title: const Text('放弃发布？'),
        content: const Text('内容尚未发布，确定要离开吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('继续编辑', style: TextStyle(color: textMutedColor(b))),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: kDanger),
            child: const Text('放弃'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) {
      Navigator.of(context).pop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Scaffold(
      backgroundColor: bgColor(b),
      body: Column(
        children: [
          _buildTitleBar(b),
          Expanded(child: _buildBody(b)),
        ],
      ),
    );
  }

  /// 标题栏：返回 + 标题 + 拖拽区 + 窗口控制
  /// macOS 使用原生标题栏：仅保留返回按钮 + 标题，移除拖拽区与窗口控制
  Widget _buildTitleBar(Brightness b) {
    final title = Text(
      '发动态',
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: textColor(b),
      ),
    );
    // macOS 内嵌模式：保留返回按钮（返回上一层），无红黄绿安全区、无窗口按钮
    if (widget.embedded) {
      return SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              // macOS 风格返回按钮
              SizedBox(
                width: 40,
                height: 40,
                child: InkWell(
                  borderRadius: BorderRadius.circular(kRadiusMd),
                  onTap: () {
                    if (widget.onBack != null) {
                      widget.onBack!();
                    } else {
                      Navigator.of(context).maybePop();
                    }
                  },
                  mouseCursor: SystemMouseCursors.click,
                  hoverColor: bgHoverColor(b),
                  child: Center(
                    // 图标下移 1px，与 15px 标题文字视觉中线对齐（Material 箭头基线偏上）
                    child: Transform.translate(
                      offset: const Offset(0, 1),
                      child: Icon(Icons.arrow_back_ios_new_rounded,
                          size: 16, color: textMutedColor(b)),
                    ),
                  ),
                ),
              ),
              title,
              const Spacer(),
            ],
          ),
        ),
      );
    }
    final back = SizedBox(
      width: 46,
      height: 40,
      child: InkWell(
        onTap: _handleBack,
        mouseCursor: SystemMouseCursors.click, // 悬停显示手指
        hoverColor: bgHoverColor(b),
        child: Icon(Icons.arrow_back,
            size: 18, color: textMutedColor(b)),
      ),
    );
    if (Platform.isMacOS) {
      return SizedBox(
        height: 40,
        child: Row(
          children: [
            // 红黄绿按钮安全距离
            SizedBox(
              width: kMacTrafficLightWidth,
              child: Container(color: bgColor(b)),
            ),
            // macOS 风格返回按钮（更细箭头 + 圆角 hover，与安全区间距合理）
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: SizedBox(
                width: 40,
                height: 40,
                child: InkWell(
                  borderRadius: BorderRadius.circular(kRadiusMd),
                  onTap: _handleBack,
                  mouseCursor: SystemMouseCursors.click,
                  hoverColor: bgHoverColor(b),
                  child: Icon(Icons.arrow_back_ios_new_rounded,
                      size: 16, color: textMutedColor(b)),
                ),
              ),
            ),
            title,
            // 拖拽区（整个标题栏空白处可拖动窗口）
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => windowManager.startDragging(),
              ),
            ),
          ],
        ),
      );
    }
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          back,
          title,
          // 拖拽区（整个标题栏空白处可拖动窗口）
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => windowManager.startDragging(),
            ),
          ),
          _WinButton(icon: Icons.remove, onTap: () => windowManager.minimize()),
          _WinButton(
            icon: Icons.crop_square_rounded,
            onTap: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
          _WinButton(
              icon: Icons.close, isClose: true, onTap: () => windowManager.close()),
        ],
      ),
    );
  }

  /// 主体：头像昵称 → 图片区 → 内容输入 → 底部操作栏
  Widget _buildBody(Brightness b) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 头像 + 昵称
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
          child: Row(
            children: [
              _Avatar(url: _avatarUrl, nickname: _nickname, size: 38),
              const SizedBox(width: 10),
              Text(
                _nickname,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: textColor(b),
                ),
              ),
            ],
          ),
        ),
        // 图片区（横向滑动，内容文本上方）
        _buildImageBar(b),
        // 内容输入
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: TextField(
              controller: _contentCtrl,
              focusNode: _contentFocus,
              maxLength: _maxContent,
              minLines: null,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              style: TextStyle(fontSize: 15, color: textColor(b), height: 1.6),
              decoration: InputDecoration(
                hintText: '分享你的新鲜事…',
                hintStyle: TextStyle(fontSize: 15, color: textFaintColor(b)),
                border: InputBorder.none,
                counterStyle: TextStyle(fontSize: 11, color: textFaintColor(b)),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ),
        // emoji 表情面板（紧贴底部栏上方，限制宽度靠左）
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: _showPanel
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: EmojiPanel(
                        onEmoji: (e) {
                          final idx = _contentCtrl.selection.baseOffset;
                          final text = _contentCtrl.text;
                          final newText = idx >= 0 && idx <= text.length
                              ? text.replaceRange(idx, idx, e)
                              : text + e;
                          _contentCtrl.text = newText;
                          _contentCtrl.selection = TextSelection.collapsed(
                              offset: (idx >= 0 ? idx : text.length) + e.length);
                          _contentFocus.requestFocus();
                        },
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        // 底部：暂存（左） + 发布（右）
        _buildBottomBar(b),
      ],
    );
  }

  /// 图片区：横向滑动的缩略图 + 上传按钮（按页面宽度显示，溢出左右滑动）
  Widget _buildImageBar(Brightness b) {
    return SizedBox(
      height: _thumbSize + 24,
      child: SilkyListView(
        scrollDirection: Axis.horizontal,
        scrollSpeed: 1.6,
        silkyScrollDuration: const Duration(milliseconds: 600),
        animationCurve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        children: [
          if (_images.length < _maxImages) _addButton(b),
          for (var i = 0; i < _images.length; i++)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: _thumb(i),
            ),
        ],
      ),
    );
  }

  Widget _addButton(Brightness b) {
    return InkWell(
      onTap: _pickImages,
      mouseCursor: SystemMouseCursors.click, // 悬停显示手指
      borderRadius: BorderRadius.circular(kRadiusBtn),
      child: Container(
        width: _thumbSize,
        height: _thumbSize,
        decoration: BoxDecoration(
          color: bgSoftColor(b),
          borderRadius: BorderRadius.circular(kRadiusBtn),
          border: Border.all(color: textFaintColor(b).withValues(alpha: 0.6)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_photo_alternate_outlined,
                size: 24, color: textMutedColor(b)),
            const SizedBox(height: 4),
            Text(
              '${_images.length}/$_maxImages',
              style: TextStyle(fontSize: 11, color: textMutedColor(b)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _thumb(int index) {
    return SizedBox(
      width: _thumbSize,
      height: _thumbSize,
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(kRadiusBtn),
            child: Image.memory(
              _images[index],
              width: _thumbSize,
              height: _thumbSize,
              fit: BoxFit.cover,
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: MouseRegion(
              cursor: SystemMouseCursors.click, // 悬停显示手指
              child: GestureDetector(
                onTap: () => _removeImage(index),
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close, size: 12, color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(Brightness b) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 左侧：emoji 表情按钮 + 暂存
          Row(
            children: [
              IconButton(
                onPressed: () {
                  setState(() => _showPanel = !_showPanel);
                  _contentFocus.requestFocus();
                },
                tooltip: '表情',
                icon: Icon(
                  _showPanel
                      ? Icons.emoji_emotions
                      : Icons.emoji_emotions_outlined,
                  size: 22,
                  color: _showPanel ? kPrimary : textMutedColor(b),
                ),
              ),
              const SizedBox(width: 4),
              OutlinedButton.icon(
                onPressed: _saving ? null : _saveDraft,
                icon: const Icon(Icons.save_outlined, size: 16),
                label: const Text('暂存'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: textMutedColor(b),
                  side: BorderSide(color: textFaintColor(b).withValues(alpha: 0.8)),
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(kRadiusCard)),
                ),
              ),
            ],
          ),
          // 发布
          FilledButton(
            onPressed: _publishing ? null : _publish,
            style: FilledButton.styleFrom(
              backgroundColor: kPrimary,
              disabledBackgroundColor: kPrimary.withValues(alpha: 0.4),
              minimumSize: const Size(0, 40),
              padding:
                  const EdgeInsets.symmetric(horizontal: 28, vertical: 0),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(kRadiusCard)),
            ),
            child: _publishing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.send_rounded, size: 16, color: Colors.white),
                      SizedBox(width: 6),
                      Text(
                        '发布',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// 头像（网络图 + 首字兜底）
class _Avatar extends StatelessWidget {
  final String? url;
  final String nickname;
  final double size;

  const _Avatar({required this.url, required this.nickname, this.size = 36});

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final text = nickname.trim();
    final initial =
        text.isEmpty ? '?' : (text.length <= 2 ? text : text.substring(0, 2));
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: primarySoftColor(b),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          fontSize: size * 0.38,
          fontWeight: FontWeight.w700,
          color: kPrimary,
        ),
      ),
    );
    if (url == null || url!.isEmpty) return placeholder;
    return ClipOval(
      child: Image.network(
        url!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        loadingBuilder: (c, child, progress) =>
            progress == null ? child : placeholder,
        errorBuilder: (c, e, s) => placeholder,
      ),
    );
  }
}

/// 窗口控制按钮（最小化 / 最大化 / 关闭）
class _WinButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool isClose;

  const _WinButton({required this.icon, required this.onTap, this.isClose = false});

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return SizedBox(
      width: 46,
      height: 40,
      child: InkWell(
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click, // 悬停显示手指
        hoverColor: isClose ? kDanger.withValues(alpha: 0.15) : bgHoverColor(b),
        child: Icon(icon, size: 16, color: textMutedColor(b)),
      ),
    );
  }
}
