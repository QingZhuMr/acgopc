import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/app_theme.dart';
import 'notify.dart';

/// 举报弹窗：选择原因 + 可选补充说明，提交后调用服务端举报接口
///
/// 支持三种对象：
/// - 举报用户：传 `targetUid`（>0）
/// - 举报帖子：传 `postId`（>0）
/// - 举报评论：传 `postId` + `commentId`（>0）
class ReportDialog extends StatefulWidget {
  final int targetUid;
  final int postId;
  final int commentId;

  const ReportDialog({
    super.key,
    this.targetUid = 0,
    this.postId = 0,
    this.commentId = 0,
  });

  @override
  State<ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<ReportDialog> {
  static const List<(String, String)> _reasons = [
    ('spam', '垃圾广告'),
    ('porn', '色情低俗'),
    ('abuse', '人身攻击'),
    ('ad', '恶意营销'),
    ('infringe', '侵犯权益'),
    ('other', '其他'),
  ];

  String _reason = 'spam';
  final _contentCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _contentCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      final resp = await ApiClient.instance.report(
        targetUid: widget.targetUid,
        postId: widget.postId,
        commentId: widget.commentId,
        reason: _reason,
        content: _contentCtrl.text.trim(),
      );
      final json = ApiClient.safeJsonDecode(resp.body);
      if (!mounted) return;
      if (json['code'] != 0) {
        NotifyStack.warning(json['msg']?.toString() ?? '举报失败', title: '提示');
        return;
      }
      NotifyStack.success('举报成功，我们会尽快处理', title: '提示');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) NotifyStack.warning('举报失败：$e', title: '提示');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return AlertDialog(
      backgroundColor: bgColor(b),
      title: const Text('举报'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('请选择举报原因：'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final (val, label) in _reasons)
                  ChoiceChip(
                    label: Text(label),
                    selected: _reason == val,
                    onSelected: (_) => setState(() => _reason = val),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _contentCtrl,
              maxLength: 500,
              maxLines: 3,
              style: TextStyle(fontSize: 13, color: textColor(b)),
              decoration: InputDecoration(
                hintText: '补充说明（选填）',
                hintStyle: TextStyle(fontSize: 13, color: textFaintColor(b)),
                isDense: true,
                filled: true,
                fillColor: bgHoverColor(b),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(kRadiusMd),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('取消', style: TextStyle(color: textMutedColor(b))),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          style: FilledButton.styleFrom(backgroundColor: kPrimary),
          child: _submitting
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Text('提交举报'),
        ),
      ],
    );
  }
}
