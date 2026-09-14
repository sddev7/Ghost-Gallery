import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'database_helper.dart';

class CacheCleanupService {
  static final CacheCleanupService instance = CacheCleanupService._();
  CacheCleanupService._();

  bool _isCleaning = false;

  /// Performs a thorough, silent background sweep of the temporary and cache directories,
  /// deleting useless leftover files like `.rgba` frame caches, picker assets, and shared files.
  Future<void> cleanUselessCacheFiles() async {
    if (_isCleaning) return;
    _isCleaning = true;

    try {
      final tempDir = await getTemporaryDirectory();
      await _cleanDirectory(tempDir);

      Directory? appCacheDir;
      try {
        appCacheDir = await getApplicationCacheDirectory();
      } catch (_) {}

      if (appCacheDir != null && appCacheDir.path != tempDir.path) {
        await _cleanDirectory(appCacheDir);
      }

      // Clean up orphaned recommendation directories
      await _cleanOrphanedRecommendDirectories();
    } catch (e) {
      debugPrint('CacheCleanupService: Error cleaning cache: $e');
    } finally {
      _isCleaning = false;
    }
  }

  Future<void> _cleanDirectory(Directory dir) async {
    if (!await dir.exists()) return;

    try {
      final entities = await dir.list(recursive: true, followLinks: false).toList();
      for (final entity in entities) {
        final path = entity.path;
        final name = p.basename(path);
        final nameLower = name.toLowerCase();

        if (entity is File) {
          // 1. Delete raw video rgba frames
          if (nameLower.endsWith('.rgba') || nameLower.startsWith('raw_video_')) {
            try {
              await entity.delete();
              debugPrint('CacheCleanupService: Deleted raw video frame cache: $path');
            } catch (_) {}
          }
          // 2. Delete temporary wav files or wav.jpg
          else if (nameLower.contains('.wav') || nameLower.endsWith('.wav.jpg')) {
            try {
              await entity.delete();
              debugPrint('CacheCleanupService: Deleted temp wav/jpg file: $path');
            } catch (_) {}
          }
          // 3. Delete trimmed audio files
          else if (nameLower.startsWith('trimmed_') && (nameLower.endsWith('.m4a') || nameLower.endsWith('.mp3') || nameLower.endsWith('.wav'))) {
            try {
              await entity.delete();
              debugPrint('CacheCleanupService: Deleted leftover trimmed audio: $path');
            } catch (_) {}
          }
          // 4. Delete other temporary video/audio files
          else if (nameLower.startsWith('temp_') && (nameLower.endsWith('.mp4') || nameLower.endsWith('.avi') || nameLower.endsWith('.mp3') || nameLower.endsWith('.m4a') || nameLower.endsWith('.wav'))) {
            try {
              await entity.delete();
              debugPrint('CacheCleanupService: Deleted leftover temp media: $path');
            } catch (_) {}
          }
          // 5. Delete collage creator leftovers or text cards
          else if (nameLower == 'collage.png' || (nameLower.startsWith('text_card_') && nameLower.endsWith('.png'))) {
            try {
              await entity.delete();
              debugPrint('CacheCleanupService: Deleted leftover card/collage: $path');
            } catch (_) {}
          }
          // 6. Delete picker or share_plus orphaned files
          else if (nameLower.startsWith('video_thumbnail_')) {
            try {
              await entity.delete();
              debugPrint('CacheCleanupService: Deleted leftover video thumbnail file: $path');
            } catch (_) {}
          }
          // 7. Delete picker or share_plus orphaned files
          else {
            final parentName = p.basename(p.dirname(path)).toLowerCase();
            if (parentName == 'file_picker' || parentName == 'share_plus') {
              try {
                await entity.delete();
                debugPrint('CacheCleanupService: Deleted picker/share child: $path');
              } catch (_) {}
            }
          }
        }
        
        // Delete file_picker / share_plus directories
        else if (entity is Directory) {
          if (nameLower == 'file_picker' || nameLower == 'share_plus') {
            try {
              await entity.delete(recursive: true);
              debugPrint('CacheCleanupService: Deleted cache directory: $path');
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint('CacheCleanupService: Error cleaning directory ${dir.path}: $e');
    }
  }

  /// Scan application documents directory for any recommendations directories
  /// that are no longer associated with an active group in the database.
  Future<void> _cleanOrphanedRecommendDirectories() async {
    try {
      final appDocs = await getApplicationDocumentsDirectory();
      final recommendsParentDir = Directory('${appDocs.path}/ghost_recommends');
      if (!await recommendsParentDir.exists()) return;

      final db = DatabaseHelper.instance;
      final activeGroups = await db.getRecommendGroups();
      final activeGroupIds = activeGroups.map((g) => g.id).toSet();

      final subDirs = await recommendsParentDir.list(recursive: false).toList();
      for (final entity in subDirs) {
        if (entity is Directory) {
          final dirName = p.basename(entity.path);
          if (!activeGroupIds.contains(dirName)) {
            try {
              await entity.delete(recursive: true);
              debugPrint('CacheCleanupService: Deleted orphaned recommend directory: ${entity.path}');
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint('CacheCleanupService: Error cleaning orphaned recommend directories: $e');
    }
  }
}
