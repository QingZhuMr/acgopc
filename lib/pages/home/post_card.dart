import 'package:flutter/material.dart';

import '../../core/app_config.dart';
import '../../core/app_theme.dart';
import '../../utils/net_image.dart';
import '../../widgets/bubble_menu.dart';
import '../../widgets/user_avatar.dart';

/// 伪随机封面高度（id/内容/图片数混合种子，制造瀑布流错落感）
double coverHeightFor(Map<String, dynamic> post) {
  final id = (post['id'] as num?)?.toInt() ?? 0;
  final content = post['content']?.toString() ?? '';
  final images = (post['images'] as List<dynamic>?) ?? const [];
  final seed = ((id * 31 + content.length + images.length) % 100).abs();
  return 200 + seed * 1.2;
}

/// 帖子卡片（小红书瀑布流：封面图 + 正文 + 头像昵称 + 点赞数）
class PostCard extends StatefulWidget {
  final Map<String, dynamic> post;
  final VoidCallback onTap;

  /// 右键菜单项（统一用全局 BubbleMenu 气泡弹出；null/空则不监听右键）
  final List<BubbleMenuItem>? menuItems;

  const PostCard({
    super.key,
    required this.post,
    required this.onTap,
    this.menuItems,
  });

  @override
  State<PostCard> createState() => PostCardState();
}

class PostCardState extends State<PostCard> {
  bool _hover = false;
  bool _pressed = false;

  /// 封面图解码完成后按真实宽高比算出的高度（null=尚未解码，用占位高度）
  double? _coverH;

  /// 图片解码完成 → 用真实宽高比 + [coverWidth] 重算封面高度（最多 9:16，最小 180）
  void _onCoverLoaded(int w, int h, double coverWidth) {
    if (_coverH != null || w <= 0 || h <= 0 || coverWidth <= 0 || !mounted) {
      return;
    }
    final ratio = (h / w).clamp(180.0 / coverWidth, 16 / 9);
    final real = coverWidth * ratio;
    final placeholder = coverHeightFor(widget.post);
    if ((real - placeholder).abs() < 1) return;
    setState(() => _coverH = real);
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final post = widget.post;

    final nickname = post['nickname']?.toString() ?? '匿名用户';
    final avatar = post['avatar']?.toString() ?? '';
    final content = post['content']?.toString() ?? '';
    final images = ((post['images'] as List<dynamic>?) ?? [])
        .map((e) => e.toString())
        .where((s) => s.isNotEmpty)
        .toList();
    final likeCount = (post['like_count'] as num?)?.toInt() ?? 0;
    final isLiked = (post['is_liked'] as bool?) ?? false;
    final cover = images.isNotEmpty ? images.first : null;

    final borderColor =
        b == Brightness.dark ? DarkColors.border : LightColors.border;

    final card = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        child: AnimatedScale(
        scale: _pressed ? 0.97 : (_hover ? 1.02 : 1.0),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            mouseCursor: SystemMouseCursors.click, // 悬停显示手指
            onHighlightChanged: (v) => setState(() => _pressed = v),
            borderRadius: kRadiusCardAll,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              decoration: BoxDecoration(
                color: bgColor(b),
                borderRadius: kRadiusCardAll,
                border: Border.all(color: borderColor),
                boxShadow: _hover
                    ? [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 14,
                          offset: const Offset(0, 6),
                        ),
                      ]
                    : null,
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 封面：有图用首图，无图用纯色文字封面（客户端算法生成，省服务器开销）
                  // 高度先用占位（伪随机），图片解码完成后按真实宽高比自适应（最大 9:16）
                  LayoutBuilder(
                    builder: (ctx, c) {
                      final h = _coverH ?? coverHeightFor(widget.post);
                      return cover != null
                          ? CoverImage(
                              url: cover,
                              fallbackHeight: h,
                              onLoaded: (w, ih) =>
                                  _onCoverLoaded(w, ih, c.maxWidth),
                            )
                          : TextCover(content: content, height: h);
                    },
                  ),
                  // 正文（最多 2 行；有图时在图片下方，无图时在纯色封面下方，与真图片卡片一致）
                  if (content.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                      child: Text(
                        content,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: textBodyColor(b),
                          height: 1.45,
                        ),
                      ),
                    ),
                  // 底部：头像 + 昵称 + 点赞数
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                    child: Row(
                      children: [
                        UserAvatar(
                          avatarUrl: avatar.isEmpty
                              ? null
                              : AppConfig.resolveUrl(avatar),
                          nickname: nickname,
                          size: 22,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            nickname,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: textMutedColor(b),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Icon(
                              isLiked ? Icons.favorite : Icons.favorite_border,
                              size: 14,
                              color: isLiked ? kDanger : textMutedColor(b),
                            ),
                            const SizedBox(width: 3),
                            Text(
                              '$likeCount',
                              style: TextStyle(
                                fontSize: 12,
                                color: textMutedColor(b),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        ),
      ),
    );
    // 右键菜单：统一用全局 BubbleMenu 气泡弹出（无菜单项则不可右键）
    final menu = widget.menuItems;
    if (menu == null || menu.isEmpty) return card;
    return BubbleMenu(
      triggerOnRightClick: true,
      items: menu,
      child: card,
    );
  }
}

/// 封面图（网络图 + 统一加载 / 错误兜底）
/// 封面图片：铺满裁剪（cover）显示，图片解码完成后通过 [onLoaded] 上报真实宽高，
/// 由卡片（`PostCardState`）重算高度（最多 9:16，最小 120）。
class CoverImage extends StatelessWidget {
  final String url;

  /// 图片解码完成前的占位高度（伪随机，制造瀑布流错落）
  final double fallbackHeight;

  /// 图片解码完成回调（携带实际宽高）
  final void Function(int w, int h)? onLoaded;

  const CoverImage({
    super.key,
    required this.url,
    required this.fallbackHeight,
    this.onLoaded,
  });

  @override
  Widget build(BuildContext context) {
    // 封面图片自身裁剪顶部圆角，确保圆角平滑（比依赖外层整体 clip 更细腻）
    return ClipRRect(
      borderRadius: BorderRadius.vertical(top: Radius.circular(kRadiusCard)),
      child: NetImage(
        url: url,
        width: double.infinity,
        height: fallbackHeight,
        // 封面图片铺满裁剪（cover），保持原有小红书卡片视觉。
        // 区域高度按图片宽高比计算、最多 9:16（9:16 竖图完整显示，超高图封顶）
        fit: BoxFit.cover,
        cacheWidth: 480, // 限制解码尺寸，降低内存与解码开销，提升滚动流畅度
        onLoaded: onLoaded,
      ),
    );
  }
}

/// 无图动态的算法封面：确定性纯色背景 + 内容文字
/// （浅底深字，对比度固定，客户端本地生成，不占服务器开销）。
/// 卡片场景封面内显示内容引文，封面下方正文区再显示完整标题正文（两者都显示）。
class TextCover extends StatelessWidget {
  final String content;
  final double height;

  const TextCover({super.key, required this.content, required this.height});

  // 小红书风柔和浅色背景（均配深色文字，保证「背景色不与文字冲突」）
  static const List<Color> _bgColors = [
    Color(0xFFF6A5A5), // 珊瑚粉
    Color(0xFFF2B98D), // 杏橙
    Color(0xFFF0D18A), // 奶油黄
    Color(0xFFA9D3A9), // 薄荷绿
    Color(0xFF8FC7C9), // 青蓝
    Color(0xFF9BB8E8), // 淡蓝
    Color(0xFFBFA3E3), // 淡紫
    Color(0xFFE3A3C2), // 粉紫
  ];
  static const List<Color> _fgColors = [
    Color(0xFF8C3B3B),
    Color(0xFF5A3412),
    Color(0xFF5A4612),
    Color(0xFF174B22),
    Color(0xFF17494B),
    Color(0xFF17345B),
    Color(0xFF331A5B),
    Color(0xFF541A3A),
  ];

  /// 确定性 hash（同内容固定同色，避免每次 build 变色闪烁）
  static int _stableHash(String s) {
    var h = 0;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h;
  }

  @override
  Widget build(BuildContext context) {
    final text = content.trim();
    final seed = text.isEmpty ? ' ' : text;
    final idx = _stableHash(seed) % _bgColors.length;
    // 截取合适长度：约 30 字内，超长溢出用 "..."；加中文双引号
    final excerpt = text.length <= 30 ? text : '${text.substring(0, 30)}...';

    return Container(
      width: double.infinity,
      height: height,
      color: _bgColors[idx],
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Text(
        '“$excerpt”',
        maxLines: 5,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: _fgColors[idx],
          fontSize: 18,
          fontWeight: FontWeight.w600,
          height: 1.5,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
