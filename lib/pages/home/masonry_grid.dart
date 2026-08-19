import 'package:flutter/material.dart';

import '../../widgets/bubble_menu.dart';
import 'post_card.dart';

/// 瀑布流网格：按估算高度贪心分配到最短列
class MasonryGrid extends StatelessWidget {
  final List<Map<String, dynamic>> posts;
  final int columns;
  final void Function(Map<String, dynamic>) onPostTap;

  /// 右键菜单项构建器（收藏/历史 tab；null 不监听右键）
  final List<BubbleMenuItem> Function(Map<String, dynamic> post)? onContextMenu;

  const MasonryGrid({
    super.key,
    required this.posts,
    required this.columns,
    required this.onPostTap,
    this.onContextMenu,
  });

  @override
  Widget build(BuildContext context) {
    // 估算每张卡片高度用于贪心分配（近似即可，不影响实际渲染高度）。
    // 封面高度用占位估算（图片解码完成后 CoverImage 按真实宽高比自适应）。
    double estHeight(Map<String, dynamic> p) {
      final content = p['content']?.toString() ?? '';
      final lines =
          content.isEmpty ? 0 : (content.length / 14).ceil().clamp(1, 2).toInt();
      return coverHeightFor(p) +
          (content.isEmpty ? 0 : 10 + lines * 20) +
          56;
    }

    // 用 LayoutBuilder 拿列宽布局（占位高度不需要真实列宽，图片解码后自适应）
    return LayoutBuilder(
      builder: (ctx, c) {
        final gap = 12.0;

        final cols = List.generate(columns, (_) => <Map<String, dynamic>>[]);
        final heights = List.filled(columns, 0.0);
        for (final p in posts) {
          var idx = 0;
          var minH = heights[0];
          for (var i = 1; i < columns; i++) {
            if (heights[i] < minH) {
              minH = heights[i];
              idx = i;
            }
          }
          cols[idx].add(p);
          heights[idx] += estHeight(p);
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < columns; i++) ...[
              if (i > 0) SizedBox(width: gap),
              Expanded(
                child: Column(
                  children: [
                    for (final p in cols[i])
                      RepaintBoundary(
                        child: Padding(
                          padding: EdgeInsets.only(bottom: gap),
                          child: PostCard(
                            post: p,
                            onTap: () => onPostTap(p),
                            menuItems: onContextMenu?.call(p),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
