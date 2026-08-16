import 'package:flutter/material.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../core/api_client.dart';
import '../core/app_theme.dart';
import 'emoji_data.dart';
import 'image_compressor.dart';
import 'notify.dart';
import 'pick_images.dart';
import '../utils/net_image.dart';

/// 云端表情包条目
class StickerItem {
  final int id;
  final String url;
  final int width;
  final int height;
  final String mime;
  final bool isMine; // 是否当前用户上传（可删除）

  const StickerItem({
    required this.id,
    required this.url,
    required this.width,
    required this.height,
    required this.mime,
    this.isMine = false,
  });

  factory StickerItem.fromJson(Map<String, dynamic> json) => StickerItem(
        id: (json['id'] as num?)?.toInt() ?? 0,
        url: json['url']?.toString() ?? '',
        width: (json['width'] as num?)?.toInt() ?? 0,
        height: (json['height'] as num?)?.toInt() ?? 0,
        mime: json['mime']?.toString() ?? '',
        isMine: (json['is_mine'] as bool?) ?? false,
      );
}

/// 表情面板：emoji（内置 Unicode）+ 表情包（云端图片，可上传）
///
/// [onEmoji]：点击内置 emoji（插入字符）
/// [onSticker]：点击云端表情包（插入 [sticker:id] 占位标记）
/// [onUploaded]：上传成功后回调（可用于提示）
class StickerPanel extends StatefulWidget {
  final ValueChanged<String> onEmoji;
  final ValueChanged<StickerItem> onSticker;
  final VoidCallback? onUploaded;

  const StickerPanel({
    super.key,
    required this.onEmoji,
    required this.onSticker,
    this.onUploaded,
  });

  @override
  State<StickerPanel> createState() => _StickerPanelState();
}

class _StickerPanelState extends State<StickerPanel> {
  int _tab = 0;
  List<StickerItem> _stickers = [];
  bool _loadingStickers = false;
  bool _uploading = false;
  bool _deleteMode = false; // 删除模式：开启后表情包显示删除角标

  @override
  void initState() {
    super.initState();
    _loadStickers();
  }

  Future<void> _loadStickers() async {
    setState(() => _loadingStickers = true);
    try {
      final resp = await ApiClient.instance.getStickerList();
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] == 0) {
        final list = (json['data']?['list'] as List<dynamic>?) ?? [];
        final items = list
            .map((e) => StickerItem.fromJson(
                (e as Map<String, dynamic>?) ?? <String, dynamic>{}))
            .where((s) => s.id > 0 && s.url.isNotEmpty)
            .toList();
        if (mounted) setState(() => _stickers = items);
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingStickers = false);
    }
  }

  /// 上传表情包：选图 → 客户端压缩（240x240 / ≤256KB，GIF 保动画）→ 上传
  Future<void> _upload() async {
    if (_uploading) return;
    final picked = await pickImages(allowMultiple: false);
    if (picked.isEmpty) return;
    final f = picked.single;
    final bytes = f.bytes;
    final name = f.name.isNotEmpty ? f.name : 'sticker.png';
    setState(() => _uploading = true);
    try {
      final r = await StickerCompressor.compress(bytes: bytes, filename: name);
      if (r.error != null) {
        if (mounted) NotifyStack.warning(r.error!, title: '提示');
        return;
      }
      final sticker = r.sticker!;
      final resp = await ApiClient.instance
          .uploadSticker(sticker.bytes, filename: sticker.filename);
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] != 0) {
        if (mounted) {
          NotifyStack.warning(json['msg']?.toString() ?? '上传失败', title: '提示');
        }
        return;
      }
      if (mounted) NotifyStack.success('表情包已上传', title: '提示');
      widget.onUploaded?.call();
      await _loadStickers();
    } catch (e) {
      if (mounted) NotifyStack.warning('上传失败：$e', title: '提示');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// 删除表情包（只能删自己上传的）
  Future<void> _deleteSticker(StickerItem s) async {
    if (!s.isMine) {
      NotifyStack.warning('只能删除自己上传的表情包', title: '提示');
      return;
    }
    try {
      final resp = await ApiClient.instance.deleteSticker(stickerId: s.id);
      final json = ApiClient.safeJsonDecode(resp.body);
      if (json['code'] != 0) {
        if (mounted) {
          NotifyStack.warning(json['msg']?.toString() ?? '删除失败', title: '提示');
        }
        return;
      }
      if (mounted) {
        setState(() => _stickers.removeWhere((e) => e.id == s.id));
        NotifyStack.success('已删除表情包', title: '提示');
      }
      widget.onUploaded?.call(); // 通知上层刷新表情包映射
    } catch (e) {
      if (mounted) NotifyStack.warning('删除失败：$e', title: '提示');
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Container(
      decoration: BoxDecoration(
        color: bgHoverColor(b),
        borderRadius: BorderRadius.circular(kRadiusMd),
        border: Border.all(color: b == Brightness.dark ? DarkColors.border : LightColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 顶栏：tab 切换
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                _tabButton(b, 0, '表情'),
                _tabButton(b, 1, '表情包'),
                const Spacer(),
              ],
            ),
          ),
          Divider(
            height: 1,
            // 浅灰分割线（与个人中心一致：白天黑13%、黑夜白13%）
            color: b == Brightness.dark
                ? const Color(0x22FFFFFF)
                : const Color(0x22000000),
          ),
          SizedBox(
            height: 190,
            child: _tab == 0 ? _buildEmojiGrid(b) : _buildStickerGrid(b),
          ),
        ],
      ),
    );
  }

  Widget _tabButton(Brightness b, int tab, String label) {
    final selected = _tab == tab;
    return InkWell(
      onTap: () => setState(() => _tab = tab),
      mouseCursor: SystemMouseCursors.click, // 悬停显示手指
      borderRadius: BorderRadius.circular(kRadiusMd),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? kPrimary : textMutedColor(b),
          ),
        ),
      ),
    );
  }

  /// emoji 网格（按组分隔）
  Widget _buildEmojiGrid(Brightness b) {
    return SilkyListView(
      padding: const EdgeInsets.all(8),
      scrollSpeed: 1.6,
      silkyScrollDuration: const Duration(milliseconds: 600),
      animationCurve: Curves.easeOutCubic,
      children: [
        for (var gi = 0; gi < EmojiData.groups.length; gi++) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 2),
            child: Text(
              EmojiData.groupTitles[gi],
              style: TextStyle(fontSize: 11, color: textFaintColor(b)),
            ),
          ),
          GridView.count(
            crossAxisCount: 8,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
            childAspectRatio: 1.2,
            children: [
              for (final e in EmojiData.groups[gi])
                InkWell(
                  onTap: () => widget.onEmoji(e),
                  mouseCursor: SystemMouseCursors.click, // 悬停显示手指
                  borderRadius: BorderRadius.circular(kRadiusSm),
                  child: Center(
                    child: Text(e, style: const TextStyle(fontSize: 18)),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// 表情包网格（云端图片，点击插入；网格内左上角为上传 + 号，微信式）
  ///
  /// 无论列表是否为空，第一个格子始终是上传 + 号按钮，保证入口始终可见。
  Widget _buildStickerGrid(Brightness b) {
    if (_loadingStickers && _stickers.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Column(
      children: [
        Expanded(
          child: SilkyGridView.builder(
            padding: const EdgeInsets.all(8),
            scrollSpeed: 1.6,
            silkyScrollDuration: const Duration(milliseconds: 600),
            animationCurve: Curves.easeOutCubic,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 56,
              mainAxisSpacing: 2,
              crossAxisSpacing: 2,
            ),
            // 前两格固定：+ 号（上传）与 - 号（删除模式切换），其余为表情包
            itemCount: _stickers.length + 2,
            itemBuilder: (context, i) {
              if (i == 0) {
                // 上传 + 号（微信式）：上传中显示 loading
                return _uploading
                    ? Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: kPrimary),
                        ),
                      )
                    : Tooltip(
                        message: '上传表情包',
                        child: InkWell(
                          onTap: _upload,
                          mouseCursor: SystemMouseCursors.click, // 悬停显示手指
                          borderRadius: BorderRadius.circular(kRadiusMd),
                          child: Container(
                            decoration: BoxDecoration(
                              color: b == Brightness.dark
                                  ? DarkColors.bg
                                  : LightColors.bg,
                              border: Border.all(
                                  color: b == Brightness.dark
                                      ? DarkColors.border
                                      : LightColors.border),
                              borderRadius: BorderRadius.circular(kRadiusMd),
                            ),
                            alignment: Alignment.center,
                            child: Icon(Icons.add, size: 24, color: kPrimary),
                          ),
                        ),
                      );
              }
              if (i == 1) {
                // 删除模式开关（- 号）：点击进入/退出删除模式
                return Tooltip(
                  message: _deleteMode ? '退出删除' : '删除表情包',
                  child: InkWell(
                    onTap: () => setState(() => _deleteMode = !_deleteMode),
                    mouseCursor: SystemMouseCursors.click, // 悬停显示手指
                    borderRadius: BorderRadius.circular(kRadiusMd),
                    child: Container(
                      decoration: BoxDecoration(
                        color: _deleteMode
                            ? kDanger.withValues(alpha: 0.15)
                            : (b == Brightness.dark ? DarkColors.bg : LightColors.bg),
                        border: Border.all(
                            color: _deleteMode
                                ? kDanger.withValues(alpha: 0.5)
                                : (b == Brightness.dark
                                    ? DarkColors.border
                                    : LightColors.border)),
                        borderRadius: BorderRadius.circular(kRadiusMd),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        _deleteMode ? Icons.check : Icons.remove,
                        size: 24,
                        color: _deleteMode ? kDanger : textMutedColor(b),
                      ),
                    ),
                  ),
                );
              }
              final s = _stickers[i - 2];
              final image = NetImage(
                url: s.url,
                fit: BoxFit.contain,
                width: 56,
                height: 56,
                bgColor: b == Brightness.dark ? DarkColors.bg : LightColors.bg,
                errorIconSize: 18,
              );
              // 删除模式：点击删除（仅自己上传的），否则点击插入
              if (_deleteMode) {
                final canDelete = s.isMine;
                return Tooltip(
                  message: canDelete ? '删除' : '非本人上传，不可删除',
                  child: InkWell(
                    onTap: () {
                      if (canDelete) _deleteSticker(s);
                    },
                    mouseCursor: SystemMouseCursors.click, // 悬停显示手指
                    borderRadius: BorderRadius.circular(kRadiusMd),
                    child: Stack(
                      fit: StackFit.passthrough,
                      children: [
                        Center(child: image),
                        // 删除角标
                        if (canDelete)
                          Positioned(
                            top: 0,
                            right: 0,
                            child: Container(
                              padding: const EdgeInsets.all(1),
                              decoration: const BoxDecoration(
                                color: kDanger,
                                shape: BoxShape.circle,
                              ),
                              child:
                                  const Icon(Icons.close, size: 12, color: Colors.white),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              }
              return InkWell(
                onTap: () => widget.onSticker(s),
                mouseCursor: SystemMouseCursors.click, // 悬停显示手指
                borderRadius: BorderRadius.circular(kRadiusMd),
                child: image,
              );
            },
          ),
        ),
        // 空态提示（列表为空时）
        if (_stickers.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Text(
              '还没有表情包，点左上角 + 上传',
              style: TextStyle(fontSize: 12, color: textMutedColor(b)),
            ),
          ),
        // 删除模式提示
        if (_deleteMode && _stickers.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '点击带红色×的表情包删除',
              style: TextStyle(fontSize: 11, color: kDanger),
            ),
          ),
      ],
    );
  }
}

/// 表情面板（仅内置 emoji，不含表情包）
///
/// 供帖子评论框、发布页使用。[onEmoji] 点击 emoji 插入字符。
/// 表情包（自定义图片）功能保留在 [StickerPanel]，供未来用户聊天使用。
class EmojiPanel extends StatefulWidget {
  final ValueChanged<String> onEmoji;

  const EmojiPanel({super.key, required this.onEmoji});

  @override
  State<EmojiPanel> createState() => _EmojiPanelState();
}

class _EmojiPanelState extends State<EmojiPanel> {
  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Container(
      decoration: BoxDecoration(
        color: bgHoverColor(b),
        borderRadius: BorderRadius.circular(kRadiusMd),
        border: Border.all(
            color: b == Brightness.dark ? DarkColors.border : LightColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 顶栏：标题
          // Padding(
          //   padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          //   child: Row(
          //     children: [
          //       Text(
          //         '表情',
          //         style: TextStyle(
          //           fontSize: 13,
          //           fontWeight: FontWeight.w600,
          //           color: kPrimary,
          //         ),
          //       ),
          //       const Spacer(),
          //     ],
          //   ),
          // ),
          // Divider(
          //   height: 1,
          //   // 浅灰分割线（与个人中心一致：白天黑13%、黑夜白13%）
          //   color: b == Brightness.dark
          //       ? const Color(0x22FFFFFF)
          //       : const Color(0x22000000),
          // ),
          SizedBox(
            height: 190,
            child: _buildEmojiGrid(b),
          ),
        ],
      ),
    );
  }

  /// emoji 网格（按组分隔）
  Widget _buildEmojiGrid(Brightness b) {
    return SilkyListView(
      padding: const EdgeInsets.all(8),
      scrollSpeed: 1.6,
      silkyScrollDuration: const Duration(milliseconds: 600),
      animationCurve: Curves.easeOutCubic,
      children: [
        for (var gi = 0; gi < EmojiData.groups.length; gi++) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 2),
            child: Text(
              EmojiData.groupTitles[gi],
              style: TextStyle(fontSize: 11, color: textFaintColor(b)),
            ),
          ),
          GridView.count(
            crossAxisCount: 8,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
            childAspectRatio: 1.2,
            children: [
              for (final e in EmojiData.groups[gi])
                InkWell(
                  onTap: () => widget.onEmoji(e),
                  mouseCursor: SystemMouseCursors.click, // 悬停显示手指
                  borderRadius: BorderRadius.circular(kRadiusSm),
                  child: Center(
                    child: Text(e, style: const TextStyle(fontSize: 18)),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
