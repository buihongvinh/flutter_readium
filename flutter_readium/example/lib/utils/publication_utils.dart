import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:flutter/services.dart';

import 'readium_storage.dart';

/// Các định dạng file được hỗ trợ bởi Readium plugin.
const _allowedPublicationExtensions = [
  '.webpub',
  '.epub',
  '.audiobook',
  '.zip',
  '.json',
  '.pdf',
];

class PublicationUtils {
  static Future<Iterable<String>> getAssetPubFiles() async {
    final assetManifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = assetManifest.listAssets().where((asset) => asset.startsWith('assets/pubs/'));
    return assets;
  }

  static Future<List<String>> moveAssetPublicationsToReadiumStorage() async {
    final publicationsDirPath = await ReadiumStorage.publicationsDirPath;

    // Create the local directory if it doesn't exist
    final pubsDir = Directory(publicationsDirPath);
    if (!await pubsDir.exists()) {
      await pubsDir.create(recursive: true);
    }
    // Load the AssetManifest.json file and find all assets in the 'assets/pubs' directory
    final pubAssets = await getAssetPubFiles();
    final pubs = <String>[];

    // Loop through the filtered assets
    for (final assetPath in pubAssets) {
      if (!_allowedPublicationExtensions.any((ext) => assetPath.endsWith(ext))) {
        debugPrint('Skip asset path: $assetPath');
        continue;
      }
      debugPrint('Asset in pubs: $assetPath');

      final basename = path.basename(assetPath);
      final file = File(path.join(pubsDir.path, basename));
      final exists = await file.exists();
      debugPrint('${file.path} already exists? $exists');

      if (!exists) {
        final data = await rootBundle.load(assetPath);
        final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        await file.writeAsBytes(bytes);
        debugPrint('saved ${file.path} size=${await file.length()}');
      } else {
        debugPrint('cached ${file.path} size=${await file.length()}');
      }
      pubs.add(file.path);
    }
    return pubs;
  }

  /// Sao chép file vào thư mục lưu trữ của Readium và trả về đường dẫn mới.
  static Future<String> copyFileToReadiumPubStorage(File file) async {
    final exists = await file.exists();
    if (!exists) {
      throw Exception('File không tồn tại: ${file.path}');
    }

    final publicationsDirPath = await ReadiumStorage.publicationsDirPath;
    // Dùng basename để tránh lỗi khi file.uri.path bao gồm toàn bộ đường dẫn.
    final fileName = path.basename(file.path);
    final newPath = path.join(publicationsDirPath, fileName);
    await file.copy(newPath);
    debugPrint('Đã copy file ${file.path} (${await file.length()} bytes) → $newPath');
    return newPath;
  }

  /// Mở file picker để người dùng chọn file PDF hoặc publication khác từ thiết bị.
  /// Trả về đường dẫn file đã copy vào storage, hoặc null nếu người dùng hủy.
  static Future<String?> pickAndImportPublicationFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: _allowedPublicationExtensions
          .map((ext) => ext.replaceFirst('.', ''))
          .toList(),
      allowMultiple: false,
    );

    if (result == null || result.files.isEmpty) {
      debugPrint('Người dùng đã hủy chọn file');
      return null;
    }

    final platformFile = result.files.first;
    if (platformFile.path == null) {
      debugPrint('Không thể lấy đường dẫn file');
      return null;
    }

    final file = File(platformFile.path!);
    debugPrint('Đã chọn file: ${file.path}');
    return copyFileToReadiumPubStorage(file);
  }

  /// Mở file picker chỉ dành riêng cho file PDF.
  /// Trả về đường dẫn file PDF đã copy vào storage, hoặc null nếu người dùng hủy.
  static Future<String?> pickAndImportPdfFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      allowMultiple: false,
    );

    if (result == null || result.files.isEmpty) {
      debugPrint('Người dùng đã hủy chọn PDF');
      return null;
    }

    final platformFile = result.files.first;
    if (platformFile.path == null) {
      debugPrint('Không thể lấy đường dẫn file PDF');
      return null;
    }

    final file = File(platformFile.path!);
    debugPrint('Đã chọn PDF: ${file.path}');
    return copyFileToReadiumPubStorage(file);
  }

  static Future<void> removePublicationFromReadiumStorage(String pubPath) async {
    final publicationsDirPath = await ReadiumStorage.publicationsDirPath;
    final publicationPath = path.join(publicationsDirPath, pubPath);
    await File(publicationPath).delete();
  }
}
