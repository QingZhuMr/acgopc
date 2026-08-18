import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;

/// 下载图片字节到 Windows 默认下载目录（用户主目录\Downloads）
///
/// [localPath]：图片本地缓存路径（优先直接拷贝，无需网络）；
/// [url]：云端 URL（本地无缓存时 http 下载）。
/// 返回保存后的完整路径；失败返回 null。目录不存在则自动创建。
Future<String?> downloadImageToDownloads(
  String url, {
  String? localPath,
}) async {
  try {
    final bytes = await _loadBytes(url, localPath);
    if (bytes == null || bytes.isEmpty) return null;

    // 解析默认下载目录
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    var downloads = '$home${Platform.pathSeparator}Downloads';
    if (!Directory(downloads).existsSync()) {
      // OneDrive 重定向等场景兜底：用用户主目录
      downloads = home;
    }
    if (!Directory(downloads).existsSync()) {
      try {
        Directory(downloads).createSync(recursive: true);
      } catch (_) {
        return null;
      }
    }

    // 生成唯一文件名：原文件名 + 时间戳，避免覆盖
    final name = _fileNameFromUrl(url);
    final base = name.contains('.') ? name : '$name.png';
    final dot = base.lastIndexOf('.');
    final stem = dot > 0 ? base.substring(0, dot) : base;
    final ext = dot > 0 ? base.substring(dot) : '';
    final file = File(
        '$downloads${Platform.pathSeparator}${stem}_${DateTime.now().millisecondsSinceEpoch}$ext');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  } catch (_) {
    return null;
  }
}

/// 另存为：弹出系统保存对话框，由用户选择保存位置/文件名后写入。
///
/// [localPath]：图片本地缓存路径（优先直接拷贝，无需网络）；
/// [url]：云端 URL（本地无缓存时 http 下载）。
/// 返回保存后的完整路径；用户取消或失败返回 null。
Future<String?> saveImageAs(
  String url, {
  String? localPath,
}) async {
  try {
    final bytes = await _loadBytes(url, localPath);
    if (bytes == null || bytes.isEmpty) return null;

    // 默认文件名：原文件名（带扩展名），无扩展名用 png
    var fileName = _fileNameFromUrl(url);
    if (!fileName.contains('.')) fileName = '$fileName.png';
    String? savePath;
    try {
      savePath = await FilePicker.platform.saveFile(
        dialogTitle: '另存为',
        fileName: fileName,
        type: FileType.image,
      );
    } catch (_) {
      // 某些平台 saveFile 不可用/抛错
      return null;
    }
    // 用户取消 → null
    if (savePath == null || savePath.isEmpty) return null;

    // 确保扩展名存在（部分系统保存框可能不带扩展名）
    if (!savePath.toLowerCase().endsWith('.png') &&
        !savePath.toLowerCase().endsWith('.jpg') &&
        !savePath.toLowerCase().endsWith('.jpeg') &&
        !savePath.toLowerCase().endsWith('.gif') &&
        !savePath.toLowerCase().endsWith('.webp') &&
        !savePath.toLowerCase().endsWith('.bmp')) {
      savePath = '$savePath.png';
    }
    await File(savePath).writeAsBytes(bytes, flush: true);
    return savePath;
  } catch (_) {
    return null;
  }
}

/// 加载图片字节：优先本地缓存文件，无缓存走网络
Future<List<int>?> _loadBytes(String url, String? localPath) async {
  List<int>? bytes;
  if (localPath != null && localPath.isNotEmpty) {
    final f = File(localPath);
    if (f.existsSync()) {
      bytes = await f.readAsBytes();
    }
  }
  bytes ??= await _downloadBytes(url);
  return bytes;
}

Future<List<int>?> _downloadBytes(String url) async {
  final resp = await http.get(Uri.parse(url));
  if (resp.statusCode != 200) return null;
  final bytes = resp.bodyBytes;
  return bytes.isEmpty ? null : bytes;
}

/// 从 URL 提取文件名（含扩展名），无扩展名返回默认名
String _fileNameFromUrl(String url) {
  try {
    final path = Uri.parse(url).pathSegments;
    if (path.isNotEmpty) {
      final last = path.last;
      if (last.isNotEmpty) return last;
    }
  } catch (_) {}
  return 'image';
}
