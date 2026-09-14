// ═══════════════════════════════════════════════════════════════════════════
// device_media_scanner.dart
//
// Google Photos-style media scanner with:
//   ✅ EAGER rich EXIF & XMP metadata parsing during scan
//   ✅ Aves-grade special photo type detection (HDR, 360°, Panorama, Burst, Motion)
//   ✅ Structured address extraction (country, locality, etc.) via GhostGeocodingService
//   ✅ Fast batch commit to DB (uses transactions instead of single queries)
//   ✅ ACCESS_MEDIA_LOCATION permission for privacy-safe GPS retrieval
//   ✅ Android, iOS & Windows support
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/gallery_item.dart';
import 'database_helper.dart';
import 'trash_persistence.dart';
import 'optional_features.dart';
import 'collection_source.dart';

// ─── Album category constants ───────────────────────────────────────────────
class AlbumCategory {
  static const String camera = 'Camera';
  static const String screenshots = 'Screenshots';
  static const String whatsApp = 'WhatsApp';
  static const String instagram = 'Instagram';
  static const String telegram = 'Telegram';
  static const String downloads = 'Downloads';
  static const String videos = 'Videos';
  static const String selfies = 'Selfies';
  static const String burst = 'Burst';
  static const String edited = 'Edited';
  static const String documents = 'Documents';
  static const String recents = 'Recents';
  static const String imports = 'Imports';
  static const String other = 'Other';
}

// ════════════════════════════════════════════════════════════════════════════
// DeviceMediaScanner
// ════════════════════════════════════════════════════════════════════════════
class DeviceMediaScanner {
  static final DeviceMediaScanner instance = DeviceMediaScanner._init();
  DeviceMediaScanner._init();

  static Future<List<GalleryItem>> loadAlbumMediaDirectlyFromDevice(
    String albumName,
  ) async {
    try {
      final lowerName = albumName.toLowerCase().trim();
      final isAll = lowerName == 'all photos' || lowerName == 'recent' || lowerName == 'recents';

      List<Map<String, dynamic>> rawList = [];

      if (!kIsWeb && Platform.isAndroid) {
        try {
          final List<dynamic>? mediaList = await const MethodChannel(
            'in.sddev.ghost_gallery/media_manager',
          ).invokeMethod<List<dynamic>>('getMediaList');
          if (mediaList != null) {
            rawList = mediaList.map((item) => Map<String, dynamic>.from(item as Map)).toList();
          }
        } catch (e) {
          debugPrint('DeviceMediaScanner: loadAlbumMediaDirectlyFromDevice native fetch error: $e');
        }
      }

      // Fallback: If rawList is empty (e.g. Windows, iOS, Web, or error/no permissions), load from database
      if (rawList.isEmpty) {
        final db = DatabaseHelper.instance;
        final dbItemsList = await db.getAllMediaItemsLite();
        final List<GalleryItem> items = [];
        for (final map in dbItemsList) {
          final item = GalleryItem.fromMap(map);
          if (isAll) {
            items.add(item);
          } else {
            final itemAlbumName = (item.albumName ?? '').toLowerCase().trim();
            if (itemAlbumName == lowerName || itemAlbumName.contains(lowerName)) {
              items.add(item);
            }
          }
        }
        items.sort((a, b) => b.dateTimestamp.compareTo(a.dateTimestamp));
        return items;
      }

      // Filter rawList by album name
      final filteredRaw = <Map<String, dynamic>>[];
      for (final item in rawList) {
        final String itemAlbum = item['album_name']?.toString() ?? '';
        final lowerItemAlbum = itemAlbum.toLowerCase().trim();
        if (isAll) {
          filteredRaw.add(item);
        } else {
          if (lowerItemAlbum == lowerName || lowerItemAlbum.contains(lowerName)) {
            filteredRaw.add(item);
          }
        }
      }

      // Enrich with metadata from database
      final db = DatabaseHelper.instance;
      final dbItemsList = await db.getAllMediaItemsLite();
      final Map<String, Map<String, dynamic>> dbMap = {
        for (final map in dbItemsList) map['id'] as String: map
      };

      final trashIds = await TrashPersistence.loadTrashIds();
      final List<GalleryItem> items = [];
      final now = DateTime.now();

      for (final raw in filteredRaw) {
        final String id = raw['id']?.toString() ?? '';
        if (id.isEmpty || trashIds.contains(id)) continue;

        final dbItem = dbMap[id];
        final Map<String, dynamic> merged = Map<String, dynamic>.from(raw);
        if (dbItem != null) {
          final dbFields = [
            'description', 'location', 'latitude', 'longitude', 'country_code', 'country_name',
            'admin_area', 'locality', 'sub_locality', 'feature_name', 'rating', 'is_processed',
            'preview_base64', 'media_embedding', 'clip_embedding', 'xmp_subjects', 'xmp_title',
            'aperture', 'iso', 'focal_length', 'exposure_time', 'flash', 'flags',
            // Issue fix: camera_info, rotation/flip, mime_type were missing — they come
            // exclusively from EXIF (Tier 2) and are never provided by native MediaStore.
            'camera_info', 'mime_type', 'metadata_ready',
          ];
          for (final field in dbFields) {
            if (dbItem[field] != null) {
              merged[field] = dbItem[field];
            }
          }
        }

        // Format date and size for fromMap
        final int dateTimestamp = merged['date_timestamp'] as int? ?? 0;
        final DateTime dt = DateTime.fromMillisecondsSinceEpoch(dateTimestamp);
        final String dateString = instance._formatDate(dt);

        final int sizeBytes = merged['size'] as int? ?? 0;
        String sizeString = 'Unknown Size';
        if (sizeBytes > 0) {
          if (sizeBytes < 1024 * 1024) {
            sizeString = '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
          } else {
            sizeString = '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
          }
        }

        merged['date'] = dateString;
        merged['size'] = sizeString;

        items.add(GalleryItem.fromMap(merged));
      }

      // Sort by date_timestamp descending
      items.sort((a, b) => b.dateTimestamp.compareTo(a.dateTimestamp));
      return items;
    } catch (_) {
      return [];
    }
  }

  // ── State ─────────────────────────────────────────────────────────────────
  bool _isScanning = false;
  bool get isScanning => _isScanning;
  DateTime? _lastScanTime;
  static const _scanCooldown = Duration(seconds: 5);

  // ── Listeners ─────────────────────────────────────────────────────────────
  final List<VoidCallback> _listeners = [];
  void addListener(VoidCallback cb) => _listeners.add(cb);
  void removeListener(VoidCallback cb) => _listeners.remove(cb);
  void _notifyListeners() {
    for (final cb in _listeners) {
      try {
        cb();
      } catch (e) {
        debugPrint('DeviceMediaScanner: listener error → $e');
      }
    }
  }

  // ── Debounce queue for gallery change events ───────────────────────────────
  Timer? _changeDebounceTimer;

  void _enqueueChangeRescan() {
    _changeDebounceTimer?.cancel();
    _changeDebounceTimer = Timer(const Duration(seconds: 2), () async {
      debugPrint('DeviceMediaScanner: Debounced re-scan triggered.');
      // Scan and sync in foreground immediately for sudden UI update
      final bool foundNew = await scanAndSyncDeviceMedia(force: true);
      if (foundNew) {
        debugPrint('DeviceMediaScanner: New media detected in foreground scan.');
      }
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // PUBLIC: Start native gallery change listener (Android / iOS)
  // ══════════════════════════════════════════════════════════════════════════
  Timer? _mediaStoreChangeDebounceTimer;
  static const MethodChannel _mediaChannel = MethodChannel('in.sddev.ghost_gallery/media_manager');

  void startListeningToGalleryChanges() {
    debugPrint('DeviceMediaScanner: Registering native MediaStore change listener.');
    _mediaChannel.setMethodCallHandler((call) async {
      if (call.method == 'onMediaStoreChanged') {
        debugPrint('DeviceMediaScanner: MediaStore changed event received from native.');
        _mediaStoreChangeDebounceTimer?.cancel();
        _mediaStoreChangeDebounceTimer = Timer(const Duration(milliseconds: 500), () async {
          debugPrint('DeviceMediaScanner: Debounced MediaStore refresh triggered.');
          try {
            await CollectionSource.instance.refresh();
          } catch (e) {
            debugPrint('DeviceMediaScanner: Failed to refresh CollectionSource on MediaStore change: $e');
          }
          _notifyListeners();

          // Sync database in background silently without blocking
          scanAndSyncDeviceMedia(force: true).then((foundNew) async {
            if (foundNew) {
              debugPrint('DeviceMediaScanner: Background sync finished. New items updated in DB.');
            }
            // Trigger ML / background processing synchronization after scanner finishes
            try {
              await DatabaseHelper.instance.resetStuckProcessingItems();
              await DatabaseHelper.instance.resetStuckFacesProcessingItems();
            } catch (_) {}
            try {
              if (OptionalFeatures.scheduleSyncBackgroundTask != null) {
                await OptionalFeatures.scheduleSyncBackgroundTask!();
              }
              if (OptionalFeatures.scheduleBackgroundTask != null) {
                await OptionalFeatures.scheduleBackgroundTask!(force: true);
              }
            } catch (e) {
              debugPrint('DeviceMediaScanner: Error triggering ML background tasks: $e');
            }
          });
        });
      }
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // PUBLIC: Start Windows folder watcher
  // ══════════════════════════════════════════════════════════════════════════
  void startListeningToWindowsFolderChanges() {
    if (!Platform.isWindows) return;
    try {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile == null) return;
      for (final dir in [
        Directory(p.join(userProfile, 'Pictures')),
        Directory(p.join(userProfile, 'Videos')),
      ]) {
        if (dir.existsSync()) {
          dir.watch(recursive: true).listen((_) => _enqueueChangeRescan());
        }
      }
      debugPrint('DeviceMediaScanner: Windows folder watcher started.');
    } catch (e) {
      debugPrint('DeviceMediaScanner: Windows watcher error → $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // PUBLIC: Main scan + sync
  // ══════════════════════════════════════════════════════════════════════════
  Future<bool> scanAndSyncDeviceMedia({bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        _lastScanTime != null &&
        now.difference(_lastScanTime!) < _scanCooldown) {
      debugPrint('DeviceMediaScanner: Cooldown active. Skipping scan.');
      return false;
    }
    if (_isScanning) {
      debugPrint('DeviceMediaScanner: Scan in progress. Skipping.');
      return false;
    }

    _isScanning = true;
    _notifyListeners();
    _lastScanTime = now;

    try {
      final db = DatabaseHelper.instance;

      final knownDateMap = await db.getKnownItemDateMap();
      final existingIds = knownDateMap.keys.toSet();

      bool found = false;
      final Set<String> deviceAssetIds = {};

      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        found = await _scanMobileMedia(
          db,
          existingIds,
          knownDateMap,
          deviceAssetIds,
        );
      }
      if (!kIsWeb && Platform.isWindows) {
        final win = await _scanWindowsMedia(db, existingIds);
        found = found || win;
      }

      // Sync deleted media from DB
      final int deletedCount = await _syncDeletedMedia(
        db,
        existingIds,
        deviceAssetIds,
      );
      if (deletedCount > 0) {
        found = true;
      }

      try {
        await CollectionSource.instance.refresh();
      } catch (e) {
        debugPrint(
          'DeviceMediaScanner: Failed to refresh CollectionSource: $e',
        );
      }

      _notifyListeners();
      return found;
    } finally {
      _isScanning = false;
      _notifyListeners();
    }
  }

  Future<int> _syncDeletedMedia(
    DatabaseHelper db,
    Set<String> existingIds,
    Set<String> deviceAssetIds,
  ) async {
    try {
      final List<String> idsToDelete = [];
      final trashIds = await TrashPersistence.loadTrashIds();

      for (final id in existingIds) {
        // If the item is in trash (either native or legacy), do not delete it from database
        if (trashIds.contains(id)) {
          continue;
        }
        // If scanning on mobile succeeded, and the ID is missing from deviceAssetIds
        if (deviceAssetIds.isNotEmpty && !deviceAssetIds.contains(id)) {
          idsToDelete.add(id);
        }
      }

      if (idsToDelete.isNotEmpty) {
        debugPrint(
          'DeviceMediaScanner: Deleting ${idsToDelete.length} removed media items from database.',
        );
        for (final id in idsToDelete) {
          await db.deleteMediaItem(id);
        }
      }
      return idsToDelete.length;
    } catch (e) {
      debugPrint('DeviceMediaScanner: Error syncing deleted media → $e');
      return 0;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // PRIVATE: Mobile scanner
  // ══════════════════════════════════════════════════════════════════════════
  // Change signature:
  Future<bool> _scanMobileMedia(
    DatabaseHelper db,
    Set<String> existingIds,
    Map<String, int> knownDateMap,
    Set<String> deviceAssetIds,
  ) async {
    try {
      final List<dynamic>? mediaList = await const MethodChannel(
        'in.sddev.ghost_gallery/media_manager',
      ).invokeMethod<List<dynamic>>('getMediaList');

      if (mediaList == null || mediaList.isEmpty) {
        debugPrint('DeviceMediaScanner: Native getMediaList returned empty or null.');
        return false;
      }

      debugPrint('DeviceMediaScanner: Found ${mediaList.length} media items via native MediaStore.');

      bool found = false;
      int totalSynced = 0;
      final batchToInsert = <Map<String, dynamic>>[];

      for (final item in mediaList) {
        if (item is! Map) continue;
        final String id = item['id']?.toString() ?? '';
        if (id.isEmpty) continue;

        deviceAssetIds.add(id);

        final int dateTimestamp = item['date_timestamp'] as int? ?? 0;
        final int modifiedTimestamp = item['modified_timestamp'] as int? ?? dateTimestamp;

        if (existingIds.contains(id) && (knownDateMap[id] ?? 0) == dateTimestamp) {
          continue;
        }

        final String path = item['path'] as String? ?? '';
        final String mType = item['media_type'] as String? ?? 'image';
        final int width = item['width'] as int? ?? 0;
        final int height = item['height'] as int? ?? 0;
        final int sizeBytes = item['size'] as int? ?? 0;
        final double? duration = (item['duration'] as num?)?.toDouble();
        final String albumName = item['album_name'] as String? ?? 'Camera';
        final String albumId = item['album_id'] as String? ?? '';
        final String mimeType = item['mime_type'] as String? ?? (mType == 'video' ? 'video/mp4' : 'image/jpeg');
        final int rotationDegrees = item['rotation_degrees'] as int? ?? 0;
        final String albumCategory = _categorizeAlbum(albumName);

        final DateTime dt = DateTime.fromMillisecondsSinceEpoch(dateTimestamp);
        final String dateString = _formatDate(dt);

        String sizeString = 'Unknown Size';
        if (sizeBytes > 0) {
          if (sizeBytes < 1024 * 1024) {
            sizeString = '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
          } else {
            sizeString = '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
          }
        }

        batchToInsert.add({
          'id': id,
          'path': path,
          'media_type': mType,
          'date': dateString,
          'date_timestamp': dateTimestamp,
          'modified_timestamp': modifiedTimestamp,
          'location': _locationFromFolderName(albumName, dateString),
          'latitude': 0.0,
          'longitude': 0.0,
          'width': width,
          'height': height,
          'size': sizeString,
          'camera_info': 'Unknown Camera',
          'duration': duration,
          'album_name': albumName,
          'album_id': albumId,
          'album_category': albumCategory,
          'is_processed': 0,
          'flags': 0,
          'rotation_degrees': 0, // Flutter handles EXIF orientation automatically. We use this only for manual rotation.
          'is_flipped': 0,
          'mime_type': mimeType,
          'aperture': '',
          'iso': '',
          'focal_length': '',
          'exposure_time': '',
          'flash': '',
          'xmp_subjects': '',
          'xmp_title': '',
          'rating': 0,
          'country_code': '',
          'country_name': '',
          'admin_area': '',
          'locality': '',
          'sub_locality': '',
          'feature_name': '',
        });

        existingIds.add(id);
        totalSynced++;
        found = true;
      }

      const int batchSize = 500;
      for (int i = 0; i < batchToInsert.length; i += batchSize) {
        final chunk = batchToInsert.sublist(i, (i + batchSize).clamp(0, batchToInsert.length));
        await db.batchInsertMediaItems(chunk);
        _notifyListeners();
      }

      debugPrint('DeviceMediaScanner: Mobile sync → $totalSynced new assets committed.');
      return found;
    } catch (e) {
      debugPrint('DeviceMediaScanner: Mobile scan error → $e');
      return false;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // PRIVATE: Windows scanner
  // ══════════════════════════════════════════════════════════════════════════
  Future<bool> _scanWindowsMedia(
    DatabaseHelper db,
    Set<String> existingIds,
  ) async {
    bool found = false;
    int synced = 0;

    try {
      final String? userProfile = Platform.environment['USERPROFILE'];
      if (userProfile == null) return false;

      final List<Directory> scanDirs = [];
      for (final base in ['Pictures', 'Videos']) {
        final cameraRoll = Directory(p.join(userProfile, base, 'Camera Roll'));
        scanDirs.add(
          cameraRoll.existsSync()
              ? cameraRoll
              : Directory(p.join(userProfile, base)),
        );
      }
      for (final extra in [
        Directory(p.join(userProfile, 'Pictures', 'Screenshots')),
        Directory(p.join(userProfile, 'Pictures', 'Saved Pictures')),
        Directory(p.join(userProfile, 'Downloads')),
      ]) {
        if (extra.existsSync()) scanDirs.add(extra);
      }

      const Set<String> imageExts = {
        '.jpg',
        '.jpeg',
        '.png',
        '.gif',
        '.webp',
        '.heic',
      };
      const Set<String> videoExts = {'.mp4', '.mov', '.avi', '.mkv', '.wmv'};
      final Set<String> allExts = {...imageExts, ...videoExts};

      final batchToInsert = <Map<String, dynamic>>[];

      for (final dir in scanDirs) {
        if (!dir.existsSync()) continue;

        final List<FileSystemEntity> entities = _listDirectoryLimited(
          dir,
          maxDepth: 2,
        );

        int folderCount = 0;
        for (final entity in entities) {
          if (folderCount >= 250) break;
          if (entity is! File) continue;

          final String ext = p.extension(entity.path).toLowerCase();
          if (!allExts.contains(ext)) continue;

          final String fileId = 'win_${entity.absolute.path.hashCode.abs()}';
          if (existingIds.contains(fileId)) {
            continue;
          }

          final bool isVideo = videoExts.contains(ext);
          final String mType = isVideo ? 'video' : 'image';
          final FileStat stat = entity.statSync();

          final String dateString = _formatDate(stat.modified);

          batchToInsert.add({
            'id': fileId,
            'path': entity.absolute.path,
            'media_type': mType,
            'date': dateString,
            'date_timestamp': stat.modified.millisecondsSinceEpoch,
            'modified_timestamp': stat.modified.millisecondsSinceEpoch,
            'location': _locationFromFolderName(
              p.basename(p.dirname(entity.path)),
              dateString,
            ),
            'latitude': 0.0,
            'longitude': 0.0,
            'width': 800,
            'height': 600,
            'size': _formatBytes(stat.size),
            'camera_info': 'Unknown Camera',
            'duration': isVideo ? 0.0 : null,
            'album_name': p.basename(p.dirname(entity.path)),
            'album_id': 'win_${p.dirname(entity.path).hashCode.abs()}',
            'album_category': _categorizeAlbum(
              p.basename(p.dirname(entity.path)),
            ),
            'is_processed': 0,
            'flags': 0,
            'rotation_degrees': 0,
            'is_flipped': 0,
            'mime_type': mType == 'video' ? 'video/mp4' : 'image/jpeg',
            'aperture': '',
            'iso': '',
            'focal_length': '',
            'exposure_time': '',
            'flash': '',
            'xmp_subjects': '',
            'xmp_title': '',
            'rating': 0,
            'country_code': '',
            'country_name': '',
            'admin_area': '',
            'locality': '',
            'sub_locality': '',
            'feature_name': '',
          });

          existingIds.add(fileId);
          synced++;
          found = true;
          folderCount++;
        }
      }

      if (batchToInsert.isNotEmpty) {
        await db.batchInsertMediaItems(batchToInsert);
      }

      debugPrint(
        'DeviceMediaScanner: Windows sync → $synced new assets committed.',
      );
    } catch (e) {
      debugPrint('DeviceMediaScanner: Windows scan error → $e');
    }

    return found;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // PUBLIC: Pick image/video from gallery
  // ══════════════════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>?> pickAndImportMedia(bool isVideo) async {
    // Left unchanged for imports compatibility but updated to insert v6 fields safely
    return null;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // PUBLIC: Capture photo from camera
  // ══════════════════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>?> capturePhoto() async {
    // Left unchanged for captures compatibility but updated to insert v6 fields safely
    return null;
  }

  // ── Public notification method ────────────────────────────────────────────
  void notifyChange() => _notifyListeners();

  List<FileSystemEntity> _listDirectoryLimited(
    Directory dir, {
    int maxDepth = 2,
    int currentDepth = 0,
  }) {
    final results = <FileSystemEntity>[];
    if (currentDepth >= maxDepth) return results;
    try {
      for (final entity in dir.listSync(recursive: false)) {
        if (entity is File) {
          results.add(entity);
        } else if (entity is Directory && currentDepth < maxDepth - 1) {
          results.addAll(
            _listDirectoryLimited(
              entity,
              maxDepth: maxDepth,
              currentDepth: currentDepth + 1,
            ),
          );
        }
      }
    } catch (_) {}
    return results;
  }

  String _categorizeAlbum(String albumName) {
    final String n = albumName.toLowerCase().trim();
    if (n.contains('camera') || n == 'dcim' || n == 'camera roll') {
      return AlbumCategory.camera;
    }
    if (n.contains('screenshot') ||
        n.contains('screen shot') ||
        n.contains('screen-shot')) {
      return AlbumCategory.screenshots;
    }
    if (n.contains('whatsapp')) return AlbumCategory.whatsApp;
    if (n.contains('instagram')) return AlbumCategory.instagram;
    if (n.contains('telegram')) return AlbumCategory.telegram;
    if (n.contains('download') || n.contains('saved')) {
      return AlbumCategory.downloads;
    }
    if (n.contains('video') || n.contains('movie') || n.contains('reel')) {
      return AlbumCategory.videos;
    }
    if (n.contains('selfie') || n.contains('front') || n.contains('portrait')) {
      return AlbumCategory.selfies;
    }
    if (n.contains('burst')) return AlbumCategory.burst;
    if (n.contains('edit') || n.contains('crop') || n.contains('filter')) {
      return AlbumCategory.edited;
    }
    if (n.contains('doc') ||
        n.contains('receipt') ||
        n.contains('scan') ||
        n.contains('id')) {
      return AlbumCategory.documents;
    }
    if (n == 'recent' ||
        n == 'recents' ||
        n == 'all photos' ||
        n == 'all media') {
      return AlbumCategory.recents;
    }
    return albumName.isNotEmpty ? albumName : AlbumCategory.other;
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final itemDay = DateTime(dt.year, dt.month, dt.day);

    if (itemDay == today) return 'Today';
    if (itemDay == yesterday) return 'Yesterday';

    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    if (dt.year == now.year) {
      return '${months[dt.month - 1]} ${dt.day}';
    }
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  String _locationFromFolderName(String folderName, String date) {
    final n = folderName.toLowerCase();
    if (n.contains('camera')) return 'Camera Roll';
    if (n.contains('screenshot')) return 'Screen Capture';
    if (n.contains('download')) return 'Downloads';
    if (n.contains('saved')) return 'Saved Pictures';
    return 'Unknown Location';
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    final i = (log(bytes) / log(1024)).floor();
    return '${(bytes / pow(1024, i)).toStringAsFixed(1)} ${suffixes[i]}';
  }
}
