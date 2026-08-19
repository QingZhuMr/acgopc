import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/api_client.dart';
import '../core/app_config.dart';

/// 发动态草稿（内容 + 图片文件名）
class PostDraft {
  final String content;
  final List<String> imageNames; // 草稿目录内的文件名

  const PostDraft({required this.content, required this.imageNames});

  bool get isEmpty => content.trim().isEmpty && imageNames.isEmpty;
}

/// 发动态草稿本地存储（config 目录下 `draft/<uid>` 子目录）
///
/// 草稿在「暂存」时写入、发布成功后清除；退出登录不清除（属用户内容草稿）。
/// **按账号隔离**：登录后 `openForUser(uid)` 设置账号目录，不同账号草稿互不可见。
/// 图片以文件形式存磁盘，meta.json 记录内容与图片文件名。
class PostDraftStore {
  PostDraftStore._();

  static final PostDraftStore instance = PostDraftStore._();

  /// 当前账号 id（0=未登录，用公共子目录兜底）
  int _uid = 0;

  /// 登录/切换账号时调用：草稿目录切换到该账号（`draft/<uid>/`）
  void openForUser(int uid) {
    _uid = uid > 0 ? uid : 0;
  }

  String get _dir =>
      '${AppConfig.configDir}${Platform.pathSeparator}draft${Platform.pathSeparator}$_uid';
  File get _metaFile => File('$_dir${Platform.pathSeparator}meta.json');

  Directory _ensureDir() {
    final d = Directory(_dir);
    if (!d.existsSync()) {
      try {
        d.createSync(recursive: true);
      } catch (_) {}
    }
    return d;
  }

  /// 从文件名提取小写扩展名（不含点）；非法时兜底 jpg
  static String _ext(String filename) {
    final i = filename.lastIndexOf('.');
    if (i <= 0 || i == filename.length - 1) return 'jpg';
    return filename.substring(i + 1).toLowerCase();
  }

  /// 保存草稿（覆盖旧草稿）
  Future<void> save(String content, List<PostImage> images) async {
    try {
      final dir = _ensureDir();
      // 清空旧图片文件（保留 meta.json 位置，逐个删文件即可）
      if (dir.existsSync()) {
        for (final f in dir.listSync()) {
          if (f is File) {
            try {
              f.deleteSync();
            } catch (_) {}
          }
        }
      }
      // 写新图片
      final names = <String>[];
      for (var i = 0; i < images.length; i++) {
        final img = images[i];
        final name = 'img_$i.${_ext(img.filename)}';
        await File('$_dir${Platform.pathSeparator}$name')
            .writeAsBytes(img.bytes, flush: true);
        names.add(name);
      }
      // 写 meta
      await _metaFile.writeAsString(
        jsonEncode({'content': content, 'images': names}),
        flush: true,
      );
    } catch (_) {
      // 写失败静默，不影响主流程
    }
  }

  /// 读取草稿；无记录或为空返回 null
  Future<PostDraft?> load() async {
    try {
      if (!await _metaFile.exists()) return null;
      final raw = await _metaFile.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final content = json['content'] as String? ?? '';
      final names = (json['images'] as List<dynamic>? ?? [])
          .whereType<String>()
          .toList();
      final draft = PostDraft(content: content, imageNames: names);
      return draft.isEmpty ? null : draft;
    } catch (_) {
      return null;
    }
  }

  /// 读取草稿中某张图片的字节；失败返回 null
  Future<Uint8List?> readImage(String name) async {
    try {
      final f = File('$_dir${Platform.pathSeparator}$name');
      if (!await f.exists()) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// 清除草稿（发布成功后调用）
  Future<void> clear() async {
    try {
      final dir = Directory(_dir);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    } catch (_) {}
  }
}
