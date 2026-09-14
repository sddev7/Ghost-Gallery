import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

class FaceCacheHelper {
  static Directory? _faceCacheDir;

  static Future<Directory> _getFaceCacheDir() async {
    if (_faceCacheDir != null) return _faceCacheDir!;
    final base = await getApplicationCacheDirectory();
    final dir = Directory(p.join(base.path, 'gh_faces'));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    _faceCacheDir = dir;
    return dir;
  }

  // Generates a unique cached filename. Uses image path hash and crop coordinates.
  static String getCacheKey(String imagePath, int x, int y, int w, int h) {
    final normalizedPath = imagePath.replaceAll('\\', '/');
    final pathHash = md5.convert(utf8.encode(normalizedPath)).toString();
    return '${pathHash}_${x}_${y}_${w}_$h.png';
  }

  static Future<File?> getCachedFaceFile(
    String imagePath,
    int x,
    int y,
    int w,
    int h,
  ) async {
    try {
      final dir = await _getFaceCacheDir();
      final key = getCacheKey(imagePath, x, y, w, h);
      final file = File(p.join(dir.path, key));
      if (file.existsSync()) {
        return file;
      }
    } catch (e) {
      debugPrint("FaceCacheHelper.getCachedFaceFile error: $e");
    }
    return null;
  }

  // Crops and scales a face from a local image file, saves it to cache and returns the File.
  static Future<File?> cropAndCacheFace(
    String imagePath,
    int x,
    int y,
    int w,
    int h,
  ) async {
    String? tempThumbPath;
    try {
      final isVideo = imagePath.toLowerCase().endsWith('.mp4') ||
          imagePath.toLowerCase().endsWith('.mkv') ||
          imagePath.toLowerCase().endsWith('.mov') ||
          imagePath.toLowerCase().endsWith('.avi') ||
          imagePath.toLowerCase().endsWith('.webm') ||
          imagePath.toLowerCase().endsWith('.3gp') ||
          imagePath.toLowerCase().endsWith('.m4v');

      String sourcePath = imagePath;
      if (isVideo) {
        final tempDir = await getTemporaryDirectory();
        tempThumbPath = await VideoThumbnail.thumbnailFile(
          video: imagePath,
          thumbnailPath: tempDir.path,
          imageFormat: ImageFormat.JPEG,
          timeMs: 2000,
          maxHeight: 720,
          quality: 85,
        );
        if (tempThumbPath != null) {
          sourcePath = tempThumbPath;
        } else {
          return null;
        }
      }

      final file = File(sourcePath);
      if (!file.existsSync()) return null;

      final cacheDir = await _getFaceCacheDir();
      final key = getCacheKey(imagePath, x, y, w, h);
      final cacheFile = File(p.join(cacheDir.path, key));

      // Asynchronously decode image bytes
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final originalImage = frame.image;

      // Clamp coordinates to prevent clipping exceptions
      final cropX = x.clamp(0, originalImage.width - 1);
      final cropY = y.clamp(0, originalImage.height - 1);
      final cropW = w.clamp(1, originalImage.width - cropX);
      final cropH = h.clamp(1, originalImage.height - cropY);

      // Target size for thumbnails (180x180) to maximize performance and save storage
      const double targetSize = 180.0;
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(
        recorder,
        const Rect.fromLTWH(0, 0, targetSize, targetSize),
      );

      canvas.drawImageRect(
        originalImage,
        Rect.fromLTWH(
          cropX.toDouble(),
          cropY.toDouble(),
          cropW.toDouble(),
          cropH.toDouble(),
        ),
        const Rect.fromLTWH(0, 0, targetSize, targetSize),
        Paint()
          ..isAntiAlias = true
          ..filterQuality = ui.FilterQuality.high,
      );

      final picture = recorder.endRecording();
      final croppedImage = await picture.toImage(
        targetSize.toInt(),
        targetSize.toInt(),
      );
      final byteData = await croppedImage.toByteData(
        format: ui.ImageByteFormat.png,
      );

      if (byteData != null) {
        final pngBytes = byteData.buffer.asUint8List();
        await cacheFile.writeAsBytes(pngBytes, flush: true);
        originalImage.dispose();
        croppedImage.dispose();
        return cacheFile;
      }
    } catch (e) {
      debugPrint("FaceCacheHelper.cropAndCacheFace error: $e");
    } finally {
      if (tempThumbPath != null) {
        try {
          await File(tempThumbPath).delete();
        } catch (_) {}
      }
    }
    return null;
  }

  // Pre-crops a face from an already extracted/available frame image and caches it with the target (video/image) key.
  static Future<File?> saveFaceToCache({
    required String targetPath,
    required int x,
    required int y,
    required int w,
    required int h,
    required String frameImagePath,
  }) async {
    try {
      final file = File(frameImagePath);
      if (!file.existsSync()) return null;

      final cacheDir = await _getFaceCacheDir();
      final key = getCacheKey(targetPath, x, y, w, h);
      final cacheFile = File(p.join(cacheDir.path, key));

      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final originalImage = frame.image;

      // Clamp coordinates to prevent clipping exceptions
      final cropX = x.clamp(0, originalImage.width - 1);
      final cropY = y.clamp(0, originalImage.height - 1);
      final cropW = w.clamp(1, originalImage.width - cropX);
      final cropH = h.clamp(1, originalImage.height - cropY);

      const double targetSize = 180.0;
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(
        recorder,
        const Rect.fromLTWH(0, 0, targetSize, targetSize),
      );

      canvas.drawImageRect(
        originalImage,
        Rect.fromLTWH(
          cropX.toDouble(),
          cropY.toDouble(),
          cropW.toDouble(),
          cropH.toDouble(),
        ),
        const Rect.fromLTWH(0, 0, targetSize, targetSize),
        Paint()
          ..isAntiAlias = true
          ..filterQuality = ui.FilterQuality.high,
      );

      final picture = recorder.endRecording();
      final croppedImage = await picture.toImage(
        targetSize.toInt(),
        targetSize.toInt(),
      );
      final byteData = await croppedImage.toByteData(
        format: ui.ImageByteFormat.png,
      );

      if (byteData != null) {
        final pngBytes = byteData.buffer.asUint8List();
        await cacheFile.writeAsBytes(pngBytes, flush: true);
        originalImage.dispose();
        croppedImage.dispose();
        return cacheFile;
      }
    } catch (e) {
      debugPrint("FaceCacheHelper.saveFaceToCache error: $e");
    }
    return null;
  }

  // Deletes any cached face files matching the given image path.
  static Future<void> evictFacesForImage(String imagePath) async {
    try {
      final dir = await _getFaceCacheDir();
      if (!dir.existsSync()) return;
      final normalizedPath = imagePath.replaceAll('\\', '/');
      final pathHash = md5.convert(utf8.encode(normalizedPath)).toString();
      final prefix = '${pathHash}_';

      final list = dir.listSync();
      for (final entity in list) {
        if (entity is File) {
          final name = p.basename(entity.path);
          if (name.startsWith(prefix)) {
            await entity.delete();
          }
        }
      }
    } catch (e) {
      debugPrint("FaceCacheHelper.evictFacesForImage error: $e");
    }
  }
}
