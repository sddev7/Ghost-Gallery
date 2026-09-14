import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/gallery_item.dart';
import '../services/database_helper.dart';
import '../services/trash_persistence.dart';

enum SourceState { loading, ready }

/// AVES-grade in-memory thread-safe state controller that serves as the single 
/// source of truth for all media collections in the Ghost Gallery.
/// By maintaining a structural cache of loaded assets, it prevents the UI 
/// thread from calling native platform channels or SQLite scans during rebuilds.
class CollectionSource with ChangeNotifier {
  static final CollectionSource instance = CollectionSource._init();
  CollectionSource._init();

  final List<GalleryItem> _items = [];
  final List<Map<String, dynamic>> _peopleList = [];
  SourceState _state = SourceState.loading;

  List<GalleryItem> get items => List.unmodifiable(_items);
  List<Map<String, dynamic>> get peopleList => List.unmodifiable(_peopleList);
  SourceState get state => _state;
  bool get isLoading => _state == SourceState.loading;

  /// Eagerly loads all media items and people from SQLite database cache.
  /// This mirrors Phase 3 (loadEntries) and Phase 2 (_loadEssentials) of AVES.
  Future<void> init() async {
    _state = SourceState.loading;
    notifyListeners();

    await refresh();

    _state = SourceState.ready;
    notifyListeners();
  }

  /// Refreshes the in-memory state from the Device MediaStore (or SQLite cache fallback) in a highly optimized way.
  /// Excludes items present in the trash and sorts them descending by date taken.
  Future<void> refresh() async {
    try {
      final db = DatabaseHelper.instance;
      final people = await db.getEligiblePeopleForUi();
      final trashIds = await TrashPersistence.loadTrashIds();

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
          debugPrint('CollectionSource: Error fetching native media list: $e');
        }
      }

      final List<GalleryItem> filtered = [];
      final now = DateTime.now();

      if (rawList.isEmpty) {
        // Fallback: load exclusively from SQLite database cache
        final itemsMap = await db.getAllMediaItemsLite();
        final dbFiltered = itemsMap
            .where((m) => !trashIds.contains(m['id'] as String? ?? ''))
            .map((m) => GalleryItem.fromMap(m))
            .toList();
        filtered.addAll(dbFiltered);
      } else {
        // Enrich native items with SQLite metadata
        final dbItemsList = await db.getAllMediaItemsLite();
        final Map<String, Map<String, dynamic>> dbMap = {
          for (final map in dbItemsList) map['id'] as String: map
        };

        for (final raw in rawList) {
          final id = raw['id']?.toString() ?? '';
          if (id.isEmpty || trashIds.contains(id)) continue;

          final dbItem = dbMap[id];
          final Map<String, dynamic> merged = Map<String, dynamic>.from(raw);
          if (dbItem != null) {
            final dbFields = [
              'description', 'location', 'latitude', 'longitude', 'country_code', 'country_name',
              'admin_area', 'locality', 'sub_locality', 'feature_name', 'rating', 'is_processed',
              'preview_base64', 'media_embedding', 'clip_embedding', 'xmp_subjects', 'xmp_title',
              'aperture', 'iso', 'focal_length', 'exposure_time', 'flash', 'flags',
              'camera_info', 'mime_type', 'metadata_ready',
            ];
            for (final field in dbFields) {
              if (dbItem[field] != null) {
                merged[field] = dbItem[field];
              }
            }
          }

          // Format date and size for fromMap compatibility
          final int dateTimestamp = merged['date_timestamp'] as int? ?? 0;
          final DateTime dt = DateTime.fromMillisecondsSinceEpoch(dateTimestamp);
          final String dateString = _formatDateStringToDateLabel(dt, now);

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

          filtered.add(GalleryItem.fromMap(merged));
        }
      }

      final parsed = filtered.map((item) {
        final int ts = item.modifiedTimestamp ?? item.dateTimestamp;
        return _ParsedCollectionEntry(item, DateTime.fromMillisecondsSinceEpoch(ts));
      }).toList()
        ..sort((a, b) {
          final dc = b.parsedDateTime.compareTo(a.parsedDateTime);
          return dc != 0 ? dc : b.entry.imageUrl.compareTo(a.entry.imageUrl);
        });

      _items.clear();
      _items.addAll(parsed.map((p) => p.entry));
      
      _peopleList.clear();
      _peopleList.addAll(people);

      notifyListeners();
    } catch (e) {
      debugPrint("CollectionSource: Failed to refresh from SQLite/Device → $e");
    }
  }

  String _formatDateStringToDateLabel(DateTime dt, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final itemDay = DateTime(dt.year, dt.month, dt.day);

    if (itemDay == today) return 'Today';
    if (itemDay == yesterday) return 'Yesterday';

    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    if (dt.year == now.year) {
      return '${months[dt.month - 1]} ${dt.day}';
    }
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  DateTime _parseDateStringToDateTime(String dateStr, DateTime now) {
    try {
      final clean = dateStr.trim();
      final isDigits = RegExp(r'^\d+$').hasMatch(clean);
      if (isDigits) {
        final ts = int.tryParse(clean);
        if (ts != null) {
          if (ts > 1000000000000) {
            return DateTime.fromMillisecondsSinceEpoch(ts);
          } else {
            return DateTime.fromMillisecondsSinceEpoch(ts * 1000);
          }
        }
      }
      final parsed = DateTime.tryParse(clean);
      if (parsed != null) return parsed;

      final parts = clean.split(' ');
      if (parts.length >= 2) {
        final months = [
          'jan', 'feb', 'mar', 'apr', 'may', 'jun',
          'jul', 'aug', 'sep', 'oct', 'nov', 'dec'
        ];
        int monthIdx = -1;
        int monthPartIndex = -1;
        for (int i = 0; i < parts.length; i++) {
          final mIdx = months.indexOf(parts[i].toLowerCase());
          if (mIdx != -1) {
            monthIdx = mIdx;
            monthPartIndex = i;
            break;
          }
        }
        if (monthIdx != -1) {
          final remainingParts = <String>[];
          for (int i = 0; i < parts.length; i++) {
            if (i != monthPartIndex) remainingParts.add(parts[i]);
          }
          int day = 1;
          int year = now.year;
          if (remainingParts.isNotEmpty) {
            day = int.tryParse(remainingParts[0]) ?? 1;
            if (remainingParts.length >= 2) {
              year = int.tryParse(remainingParts[1]) ?? now.year;
            }
          }
          return DateTime(year, monthIdx + 1, day);
        }
      }
    } catch (_) {}

    return DateTime(1970);
  }
}

class _ParsedCollectionEntry {
  final GalleryItem entry;
  final DateTime parsedDateTime;
  _ParsedCollectionEntry(this.entry, this.parsedDateTime);
}
