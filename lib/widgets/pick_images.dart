import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

/// 选中的图片，包含字节数据与文件名。
typedef PickedImage = ({Uint8List bytes, String name});

/// 照片选择器 MethodChannel（macOS 原生插件）
const MethodChannel _photoPickerChannel = MethodChannel('com.acgo/photopicker');

/// 选择图片。
///
/// - macOS：调起系统照片库选择器（PHPicker），返回照片的 JPEG 字节。
/// - 其他平台：保持原有文件选择器行为（file_picker）。
///
/// 返回选中的图片列表；用户取消或出错时返回空列表。
Future<List<PickedImage>> pickImages({bool allowMultiple = false}) async {
  // macOS 用系统照片选择器
  if (Platform.isMacOS) {
    return _pickFromPhotoLibrary(allowMultiple: allowMultiple);
  }
  return _pickFromFileSystem(allowMultiple: allowMultiple);
}

/// macOS：系统照片选择器
Future<List<PickedImage>> _pickFromPhotoLibrary({required bool allowMultiple}) async {
  try {
    final result = await _photoPickerChannel.invokeMethod<List<dynamic>>(
      'pickImages',
      {'allowMultiple': allowMultiple},
    );
    if (result == null || result.isEmpty) return const [];

    final images = <PickedImage>[];
    for (var i = 0; i < result.length; i++) {
      final base64 = result[i];
      if (base64 is! String) continue;
      try {
        final bytes = base64Decode(base64);
        images.add((
          bytes: bytes,
          name: 'photo_${DateTime.now().millisecondsSinceEpoch}_$i.jpg',
        ));
      } catch (_) {
        // 跳过无法解码的数据
      }
    }
    return images;
  } catch (_) {
    return const [];
  }
}

/// 其他平台：文件选择器
Future<List<PickedImage>> _pickFromFileSystem({required bool allowMultiple}) async {
  try {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: allowMultiple,
      withData: true,
    );
    if (result == null) return const [];

    final images = <PickedImage>[];
    for (final f in result.files) {
      Uint8List? bytes = f.bytes;
      if (bytes == null && f.path != null) {
        try {
          bytes = await File(f.path!).readAsBytes();
        } catch (_) {}
      }
      if (bytes == null) continue;
      images.add((bytes: bytes, name: f.name.isNotEmpty ? f.name : 'image.jpg'));
    }
    return images;
  } catch (_) {
    return const [];
  }
}
