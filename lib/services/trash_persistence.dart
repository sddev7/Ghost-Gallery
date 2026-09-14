import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_media_delete/flutter_media_delete.dart';
import '../models/gallery_item.dart';
import 'database_helper.dart';
import 'media_permission_service.dart';

/// Channel that talks to the native Android MediaStore rename logic in MainActivity.kt
const _kMediaManagerChannel = MethodChannel(
  'in.sddev.ghost_gallery/media_manager',
);

class TrashPersistence {
  // ── Helpers ───────────────────────────────────────────────────────────────

  static Future<File> _getTrashFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/recently_deleted.json');
  }

  static bool _isLocalFile(String id) =>
      id.startsWith('win_') ||
      id.startsWith('imported_') ||
      id.startsWith('captured_');

  // ── .trashed-{unixSec}-{name} naming ─────────────────────────────────────

  static String _trashedName(String originalPath) {
    final unixSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final name = p.basename(originalPath);
    return '.trashed-$unixSec-$name';
  }

  static String _restoreName(String trashedName) =>
      trashedName.replaceFirst(RegExp(r'^[_.]*trashed-\d+-'), '');

  // ── MANAGE_MEDIA permission helpers ──────────────────────────────────────

  /// Returns true if the app has the MANAGE_MEDIA special permission (API 31+).
  /// Below API 31 always returns false (we use createWriteRequest per-batch instead).
  static Future<bool> hasManageMediaPermission() async {
    if (!Platform.isAndroid) return false;
    try {
      final bool granted = await _kMediaManagerChannel.invokeMethod(
        'canManageMedia',
      );
      return granted;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system Settings page where the user can grant MANAGE_MEDIA.
  static Future<void> openManageMediaSettings() async {
    try {
      await _kMediaManagerChannel.invokeMethod('requestManageMediaPermission');
    } catch (e) {
      debugPrint('TrashPersistence.openManageMediaSettings error: $e');
    }
  }

  /// Attempts to read the thumbnail bytes of a trashed file natively.
  static Future<Uint8List?> getTrashedMediaThumbnail({
    required String mediaId,
    required String filePath,
    required bool isVideo,
  }) async {
    if (!Platform.isAndroid) return null;

    // If it is a native media item with a numeric ID, try the optimized native thumbnail loader
    if (!_isLocalFile(mediaId)) {
      final bytes = await getTrashedThumbnail(mediaId);
      if (bytes != null && bytes.isNotEmpty) {
        return bytes;
      }
    }

    try {
      final Uint8List? bytes = await _kMediaManagerChannel.invokeMethod(
        'getTrashedMediaThumbnail',
        {
          'mediaId': mediaId,
          'filePath': filePath,
          'isVideo': isVideo,
        },
      );
      return bytes;
    } catch (e) {
      debugPrint('TrashPersistence.getTrashedMediaThumbnail error: $e');
      return null;
    }
  }

  /// Retrieves list of all trashed items directly from the system MediaStore.
  static Future<List<dynamic>> getTrashedMedia() async {
    if (!Platform.isAndroid) return [];
    try {
      final List<dynamic>? list = await _kMediaManagerChannel.invokeMethod(
        'getTrashedMedia',
      );
      return list ?? [];
    } catch (e) {
      debugPrint('TrashPersistence.getTrashedMedia error: $e');
      return [];
    }
  }

  /// Retrieves the thumbnail bytes of a trashed file by its MediaStore ID.
  static Future<Uint8List?> getTrashedThumbnail(String id) async {
    if (!Platform.isAndroid) return null;
    try {
      final Uint8List? bytes = await _kMediaManagerChannel.invokeMethod(
        'getTrashedThumbnail',
        {'id': id},
      );
      return bytes;
    } catch (e) {
      debugPrint('TrashPersistence.getTrashedThumbnail error: $e');
      return null;
    }
  }

  /// Resolves the content URI for a given media file (including trashed items).
  static Future<String?> getMediaContentUri({
    required String mediaId,
    required String filePath,
  }) async {
    if (!Platform.isAndroid) return null;
    try {
      final String? contentUri = await _kMediaManagerChannel.invokeMethod(
        'getMediaContentUri',
        {
          'mediaId': mediaId,
          'filePath': filePath,
        },
      );
      return contentUri;
    } catch (e) {
      debugPrint('TrashPersistence.getMediaContentUri error: $e');
      return null;
    }
  }

  /// Retrieves the full file bytes for a given media file (including trashed items).
  static Future<Uint8List?> getMediaBytes({
    required String mediaId,
    required String filePath,
  }) async {
    if (!Platform.isAndroid) return null;
    try {
      final Uint8List? bytes = await _kMediaManagerChannel.invokeMethod(
        'getMediaBytes',
        {
          'mediaId': mediaId,
          'filePath': filePath,
        },
      );
      return bytes;
    } catch (e) {
      debugPrint('TrashPersistence.getMediaBytes error: $e');
      return null;
    }
  }

  // ── Rename via native MediaStore ──────────────────────────────────────────

  /// Renames a media file (in shared storage or app sandbox) to [newName].
  /// Returns the new absolute path on success, null on failure.
  ///
  /// Strategy:
  ///   API 31 + MANAGE_MEDIA  → direct ContentResolver rename (no dialog)
  ///   API 29-30              → system createWriteRequest dialog, then rename
  ///   App-private file       → File.rename() (always works)
  static Future<String?> renameViaNative(
    BuildContext? context,
    String filePath,
    String newName, {
    String? mediaId,
  }) async {
    String? finalPath;

    if (Platform.isAndroid) {
      final bool hasPerm;
      if (context != null) {
        hasPerm = await MediaPermissionService.ensureManageMediaPermission(
          context,
        );
      } else {
        hasPerm = await hasManageMediaPermission();
      }
      if (!hasPerm) {
        debugPrint(
          'TrashPersistence: Media Manage permission NOT granted. Aborting rename.',
        );
        return null;
      }

      // Try direct file rename first (works for sandbox/private folders)
      finalPath = await _renameFileDirect(filePath, newName);

      if (finalPath == null) {
        // Fallback: Use native MediaStore rename for shared storage files (due to Scoped Storage limits)
        debugPrint(
          'TrashPersistence: Direct File rename failed/unpermitted. Falling back to native MediaStore channel.',
        );
        try {
          finalPath = await _kMediaManagerChannel.invokeMethod(
            'renameMediaFile',
            {
              'filePath': filePath,
              'newName': newName,
              'mediaId': mediaId,
            },
          );
        } on PlatformException catch (e) {
          debugPrint(
            'TrashPersistence.renameViaNative native error: ${e.message}',
          );
        } catch (e) {
          debugPrint('TrashPersistence.renameViaNative native error: $e');
        }
      }
    } else {
      // Non-Android platforms: direct file rename
      finalPath = await _renameFileDirect(filePath, newName);
    }

    // Direct SQLite DB update on any successful media file rename!
    if (finalPath != null) {
      try {
        final db = DatabaseHelper.instance;
        final dbClient = await db.database;
        final rowsAffected = await dbClient.update(
          'media_items',
          {'path': finalPath},
          where: 'path = ?',
          whereArgs: [filePath],
        );
        debugPrint(
          'TrashPersistence.renameViaNative: updated SQLite DB path for $filePath -> $finalPath. Rows affected: $rowsAffected',
        );
      } catch (e) {
        debugPrint('TrashPersistence.renameViaNative: DB update error: $e');
      }
    }

    return finalPath;
  }

  static Future<String?> _renameFileDirect(
    String filePath,
    String newName,
  ) async {
    try {
      final src = File(filePath);
      if (!await src.exists()) return null;
      final dest = File(p.join(src.parent.path, newName));
      final renamed = await src.rename(dest.path);
      return renamed.path;
    } catch (e) {
      debugPrint('TrashPersistence._renameFileDirect error: $e');
      return null;
    }
  }

  // ── Retention setting ─────────────────────────────────────────────────────

  static Future<int> getTrashRetentionDays() async {
    return 30;
  }

  static Future<void> setTrashRetentionDays(int days) async {
    // Deprecated: Retention is now hardcoded to 30 days.
  }

  // ── Load IDs currently in trash ───────────────────────────────────────────

  static Future<Set<String>> loadTrashIds() async {
    try {
      final file = await _getTrashFile();
      if (!await file.exists()) return {};
      final days = await getTrashRetentionDays();
      final cutoff = DateTime.now().subtract(Duration(days: days));
      final Map<String, dynamic> data = json.decode(await file.readAsString());
      final ids = <String>{};
      data.forEach((id, val) {
        final deletedAt = DateTime.tryParse(val['deletedAt'] ?? '');
        if (deletedAt != null && deletedAt.isAfter(cutoff)) ids.add(id);
      });
      return ids;
    } catch (_) {
      return {};
    }
  }

  // ── Soft-delete ───────────────────────────────────────────────────────────
  //
  // For ALL items we write to recently_deleted.json so the item appears in
  // the "Recently Deleted" screen.
  //
  // NATIVE media files (photos from camera/gallery on device):
  //   • Rename to .trashed-{sec}-{originalName} via native MediaStore rename.
  //   • Requires MANAGE_MEDIA (API 31+) OR creates a per-batch system dialog
  //     (API 29-30).  Caller must ensure permission is granted before calling.
  //   • This hides the file from MediaStore (other gallery apps won't show it).
  //   • We still keep the DB record so the "Recently Deleted" screen can
  //     show the thumbnail using the trashed path.
  //
  // LOCAL sandbox files (captured_ / imported_ / win_):
  //   • Rename directly via File.rename() — no permission needed.
  //   • Stores renamed path so restore can reverse it.
  // ─────────────────────────────────────────────────────────────────────────

  static Future<void> softDelete(
    GalleryItem item, {
    BuildContext? context,
  }) async => softDeleteAll([item], context: context);

  static Future<void> softDeleteAll(
    List<GalleryItem> items, {
    BuildContext? context,
    void Function(int processed, int total)? onProgress,
  }) async {
    if (items.isEmpty) return;

    // Load existing trash JSON (merge, don't overwrite)
    final trashFile = await _getTrashFile();
    Map<String, dynamic> existing = {};
    try {
      if (await trashFile.exists()) {
        existing =
            json.decode(await trashFile.readAsString()) as Map<String, dynamic>;
      }
    } catch (_) {}

    bool useNativeTrash = false;
    final Map<String, String> trashedPaths = {};

    if (Platform.isAndroid) {
      try {
        final List<String> filePaths = items.map((e) => e.imageUrl).toList();
        final List<String> mediaIds = items.map((e) => e.id).toList();

        final Map<dynamic, dynamic>? pathsMap = await _kMediaManagerChannel.invokeMethod(
          'trashMedia',
          {
            'filePaths': filePaths,
            'mediaIds': mediaIds,
            'trash': true,
          },
        );

        if (pathsMap != null) {
          useNativeTrash = true;
          for (final item in items) {
            final isLocal = _isLocalFile(item.id);
            final newPath = pathsMap[item.id] ?? item.imageUrl;
            trashedPaths[item.id] = newPath;
            existing[item.id] = {
              'originalPath': item.imageUrl,
              'path': newPath,
              'mediaType': item.mediaType,
              'date': item.date,
              'deletedAt': DateTime.now().toIso8601String(),
              'isLocalFile': isLocal,
              'isNativeTrashed': true,
            };
          }
        } else {
          throw PlatformException(code: 'CANCELLED', message: 'User denied trash request');
        }
      } catch (e) {
        if (e is PlatformException && e.code == 'CANCELLED') {
          rethrow;
        }
        debugPrint('Modern trash failed, falling back to legacy: $e');
      }
    }

    if (!useNativeTrash) {
      for (final item in items) {
        final isLocal = _isLocalFile(item.id);
        String storedPath = item.imageUrl;

        if (item.imageUrl.isNotEmpty && !item.imageUrl.startsWith('http')) {
          final newName = _trashedName(item.imageUrl);
          final renamed = await renameViaNative(
            context,
            item.imageUrl,
            newName,
            mediaId: item.id,
          );
          if (renamed != null) storedPath = renamed;
        }

        trashedPaths[item.id] = storedPath;
        existing[item.id] = {
          'originalPath': item.imageUrl,
          'path': storedPath,
          'mediaType': item.mediaType,
          'date': item.date,
          'deletedAt': DateTime.now().toIso8601String(),
          'isLocalFile': isLocal,
        };
      }
    }

    // SQLite DB update inside a single transaction for ALL trashed items (both native and legacy)
    if (trashedPaths.isNotEmpty) {
      try {
        final db = DatabaseHelper.instance;
        final dbClient = await db.database;
        await dbClient.transaction((txn) async {
          for (final entry in trashedPaths.entries) {
            await txn.update(
              'media_items',
              {'path': entry.value},
              where: 'id = ?',
              whereArgs: [entry.key],
            );
          }
        });
        debugPrint('TrashPersistence: All SQLite paths trashed in a single transaction.');
      } catch (e) {
        debugPrint('TrashPersistence: SQLite trash transaction update error: $e');
      }
    }

    // Trigger progress callbacks
    if (onProgress != null) {
      int processed = 0;
      for (final item in items) {
        processed++;
        onProgress(processed, items.length);
      }
    }

    try {
      await trashFile.writeAsString(json.encode(existing));
    } catch (e) {
      debugPrint('TrashPersistence.softDeleteAll: JSON write error: $e');
    }
  }

  // ── Restore ───────────────────────────────────────────────────────────────
  //
  // Reverse the .trashed-… rename back to the original file name.
  // For native files: rename via MediaStore so other gallery apps see it again.
  // For local files: direct File.rename().
  // ─────────────────────────────────────────────────────────────────────────

  static Future<Map<String, String>> restore(
    List<String> ids, {
    BuildContext? context,
    void Function(int processed, int total)? onProgress,
  }) async {
    final Map<String, String> restoredPaths = {};

    try {
      final trashFile = await _getTrashFile();
      if (!await trashFile.exists()) return restoredPaths;
      final Map<String, dynamic> existing = json.decode(
        await trashFile.readAsString(),
      );

      final List<GalleryItem> nativeTrashedItems = [];
      final List<String> legacyIds = [];

      for (final id in ids) {
        final entry = existing[id];
        if (entry == null) continue;
        final isNativeTrashed = entry['isNativeTrashed'] == true;
        if (isNativeTrashed) {
          nativeTrashedItems.add(
            GalleryItem(
              id: id,
              imageUrl: entry['path'] ?? '',
              date: entry['date'] ?? '',
              dateTimestamp: 0,
              location: '',
              category: '',
              description: '',
              ghostComment: '',
              resolution: '',
              size: '',
              mediaType: entry['mediaType'] ?? 'image',
            ),
          );
        } else {
          legacyIds.add(id);
        }
      }

      bool useNativeRestore = false;
      if (Platform.isAndroid && nativeTrashedItems.isNotEmpty) {
        try {
          final List<String> filePaths = nativeTrashedItems.map((e) => e.imageUrl).toList();
          final List<String> mediaIds = nativeTrashedItems.map((e) => e.id).toList();

          final Map<dynamic, dynamic>? pathsMap = await _kMediaManagerChannel.invokeMethod(
            'trashMedia',
            {
              'filePaths': filePaths,
              'mediaIds': mediaIds,
              'trash': false,
            },
          );

          if (pathsMap != null) {
            useNativeRestore = true;
            for (final item in nativeTrashedItems) {
              final restoredPath = pathsMap[item.id] ?? item.imageUrl;
              restoredPaths[item.id] = restoredPath;
              existing.remove(item.id);
            }
          } else {
            throw PlatformException(code: 'CANCELLED', message: 'User denied restore request');
          }
        } catch (e) {
          if (e is PlatformException && e.code == 'CANCELLED') {
            rethrow;
          }
          debugPrint('Modern restore failed, falling back to legacy: $e');
        }
      }

      final List<String> toProcessLegacy = useNativeRestore ? legacyIds : ids;

      for (final id in toProcessLegacy) {
        final entry = existing[id];
        if (entry == null) continue;

        final trashedPath = entry['path'] as String? ?? '';
        final originalPath = entry['originalPath'] as String? ?? trashedPath;

        if (trashedPath.isNotEmpty && !trashedPath.startsWith('http')) {
          final originalName = _restoreName(p.basename(trashedPath));
          final restored = await renameViaNative(
            context,
            trashedPath,
            originalName,
            mediaId: id,
          );
          final finalPath = restored ?? originalPath;
          restoredPaths[id] = finalPath;
        } else {
          restoredPaths[id] = originalPath;
        }

        existing.remove(id);
      }

      // SQLite DB update inside a single transaction for ALL restored items (both native and legacy)
      if (restoredPaths.isNotEmpty) {
        try {
          final db = DatabaseHelper.instance;
          final dbClient = await db.database;
          await dbClient.transaction((txn) async {
            for (final entry in restoredPaths.entries) {
              await txn.update(
                'media_items',
                {'path': entry.value},
                where: 'id = ?',
                whereArgs: [entry.key],
              );
            }
          });
          debugPrint('TrashPersistence: All SQLite paths restored in a single transaction.');
        } catch (e) {
          debugPrint('TrashPersistence: SQLite restore transaction update error: $e');
        }
      }

      // Invoke progress update
      if (onProgress != null) {
        int processed = 0;
        for (final id in ids) {
          processed++;
          onProgress(processed, ids.length);
        }
      }

      await trashFile.writeAsString(json.encode(existing));
    } catch (e) {
      debugPrint('TrashPersistence.restore error: $e');
      if (e is PlatformException && e.code == 'CANCELLED') {
        rethrow;
      }
    }

    return restoredPaths;
  }

  // ── Permanent delete ──────────────────────────────────────────────────────
  //
  //   1. Remove from recently_deleted.json
  //   2a. Native items  → PhotoManager.editor.deleteWithIds (OS system dialog,
  //       removes file system-wide, other gallery apps updated immediately)
  //   2b. Local files   → File.delete() / FlutterMediaDelete
  //   3. Remove from app SQLite DB
  // ─────────────────────────────────────────────────────────────────────────

  static Future<DeleteResult> permanentlyDeleteItems(
    List<GalleryItem> items, {
    BuildContext? context,
    void Function(int processed, int total)? onProgress,
  }) async {
    if (items.isEmpty) return const DeleteResult(succeeded: 0, failed: 0);

    int succeeded = 0;
    int failed = 0;

    Map<String, dynamic> trashData = {};
    try {
      final file = await _getTrashFile();
      if (await file.exists()) {
        trashData = json.decode(await file.readAsString());
      }
    } catch (_) {}

    final List<GalleryItem> nativeTrashedItems = [];
    final List<GalleryItem> legacyItems = [];

    for (final item in items) {
      final entry = trashData[item.id];
      final isNativeTrashed = entry != null && entry['isNativeTrashed'] == true;
      if (isNativeTrashed) {
        nativeTrashedItems.add(item);
      } else {
        legacyItems.add(item);
      }
    }

    bool useNativeDelete = false;
    if (Platform.isAndroid && nativeTrashedItems.isNotEmpty) {
      try {
        final List<String> filePaths = nativeTrashedItems.map((e) => e.imageUrl).toList();
        final List<String> mediaIds = nativeTrashedItems.map((e) => e.id).toList();

        final bool? success = await _kMediaManagerChannel.invokeMethod(
          'deleteMedia',
          {
            'filePaths': filePaths,
            'mediaIds': mediaIds,
          },
        );

        if (success != null) {
          useNativeDelete = true;
          if (success) {
            succeeded += nativeTrashedItems.length;
            try {
              final file = await _getTrashFile();
              final Map<String, dynamic> existing = file.existsSync()
                  ? json.decode(await file.readAsString())
                  : {};
              for (final item in nativeTrashedItems) {
                existing.remove(item.id);
              }
              await file.writeAsString(json.encode(existing));
            } catch (e) {
              debugPrint('TrashPersistence: trash JSON cleanup error: $e');
            }

            try {
              final db = DatabaseHelper.instance;
              for (final item in nativeTrashedItems) {
                await db.deleteMediaItem(item.id);
              }
            } catch (e) {
              debugPrint('TrashPersistence: DB delete error: $e');
            }
          } else {
            throw PlatformException(code: 'CANCELLED', message: 'User denied permanent delete request');
          }
        }
      } catch (e) {
        if (e is PlatformException && e.code == 'CANCELLED') {
          rethrow;
        }
        debugPrint('Modern delete failed, falling back to legacy: $e');
      }
    }

    final List<GalleryItem> toDeleteLegacy = useNativeDelete ? legacyItems : items;

    if (toDeleteLegacy.isNotEmpty) {
      try {
        final file = await _getTrashFile();
        final Map<String, dynamic> existing = file.existsSync()
            ? json.decode(await file.readAsString())
            : {};
        for (final item in toDeleteLegacy) {
          existing.remove(item.id);
        }
        await file.writeAsString(json.encode(existing));
      } catch (e) {
        debugPrint('TrashPersistence: trash JSON cleanup error: $e');
      }

      final List<String> nativeIds = [];
      final List<GalleryItem> localItems = [];

      final bool hasManagePerm;
      if (Platform.isAndroid) {
        if (context != null) {
          hasManagePerm =
              await MediaPermissionService.ensureManageMediaPermission(context);
        } else {
          hasManagePerm = await hasManageMediaPermission();
        }
      } else {
        hasManagePerm = true;
      }

      for (final item in toDeleteLegacy) {
        if (!_isLocalFile(item.id) && !hasManagePerm) {
          nativeIds.add(item.id);
        } else {
          localItems.add(item);
        }
      }

      if (nativeIds.isNotEmpty) {
        try {
          final List<String> filePaths = toDeleteLegacy
              .where((e) => nativeIds.contains(e.id))
              .map((e) => e.imageUrl)
              .toList();
          final bool? success = await _kMediaManagerChannel.invokeMethod(
            'deleteMedia',
            {
              'filePaths': filePaths,
              'mediaIds': nativeIds,
            },
          );
          if (success == true) {
            succeeded += nativeIds.length;
          } else {
            failed += nativeIds.length;
          }
        } catch (e) {
          debugPrint(
            'TrashPersistence: native deleteMedia failed: $e. Falling back.',
          );
          for (final item in toDeleteLegacy) {
            if (nativeIds.contains(item.id)) localItems.add(item);
          }
        }
        onProgress?.call(succeeded + failed, items.length);
      }

      if (localItems.isNotEmpty) {
        for (final item in localItems) {
          final entry = trashData[item.id];
          final pathToDelete =
              (entry != null ? (entry['path'] as String?) : null) ??
              item.imageUrl;

          bool ok = false;
          if (pathToDelete.startsWith('http')) {
            ok = true;
          } else if (Platform.isAndroid) {
            try {
              final String res = await FlutterMediaDelete.deleteMediaFile(
                pathToDelete,
              );
              if (res.isNotEmpty) ok = true;
            } catch (_) {}
            if (!ok) {
              try {
                final f = File(pathToDelete);
                if (await f.exists()) {
                  await f.delete();
                  ok = true;
                }
              } catch (_) {}
            }
          } else {
            try {
              final f = File(pathToDelete);
              if (await f.exists()) await f.delete();
              ok = true;
            } catch (_) {}
          }

          if (ok) {
            succeeded++;
          } else {
            failed++;
          }

          onProgress?.call(succeeded + failed, items.length);
        }
      }

      try {
        final db = DatabaseHelper.instance;
        for (final item in toDeleteLegacy) {
          await db.deleteMediaItem(item.id);
        }
      } catch (e) {
        debugPrint('TrashPersistence: DB delete error: $e');
      }
    }

    return DeleteResult(succeeded: succeeded, failed: failed);
  }

  // ── Auto-purge expired trash items (call on app start) ───────────────────

  static Future<void> purgeExpired() async {
    try {
      final file = await _getTrashFile();
      if (!await file.exists()) return;
      final days = await getTrashRetentionDays();
      final cutoff = DateTime.now().subtract(Duration(days: days));
      final Map<String, dynamic> data = json.decode(await file.readAsString());

      final expired = <GalleryItem>[];
      data.forEach((id, val) {
        final deletedAt = DateTime.tryParse(val['deletedAt'] ?? '');
        if (deletedAt != null && deletedAt.isBefore(cutoff)) {
          expired.add(
            GalleryItem(
              id: id,
              imageUrl: val['path'] ?? '',
              date: val['date'] ?? '',
              dateTimestamp: 0,
              location: '',
              category: '',
              description: '',
              ghostComment: '',
              resolution: '',
              size: '',
              mediaType: val['mediaType'] ?? 'image',
            ),
          );
        }
      });

      if (expired.isNotEmpty) {
        await permanentlyDeleteItems(expired);
        debugPrint(
          'TrashPersistence.purgeExpired: removed ${expired.length} expired items',
        );
      }
    } catch (e) {
      debugPrint('TrashPersistence.purgeExpired error: $e');
    }
  }
}

// ── Result ────────────────────────────────────────────────────────────────────

class DeleteResult {
  final int succeeded;
  final int failed;

  const DeleteResult({required this.succeeded, required this.failed});

  bool get hasFailures => failed > 0;

  String toMessage() {
    if (failed == 0) {
      return succeeded == 1
          ? 'Item permanently deleted'
          : '$succeeded items permanently deleted';
    }
    return '$succeeded deleted, $failed failed (permission denied or file missing)';
  }
}
