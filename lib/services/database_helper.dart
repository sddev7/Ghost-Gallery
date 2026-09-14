import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ghost_gallery/models/recommend_models.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'face_cache_helper.dart';
import 'objectbox_service.dart';
import '../models/media_vector.dart';

// ═══════════════════════════════════════════════════════════════════════════
// SEARCH FIX
// The old searchMedia() ran ALL queries on the main isolate — every item
// triggered getFacesForMedia + getOcrTextsForMedia + getObjectsForMedia,
// each a separate DB round-trip. With 500+ items this hangs the UI.
//
// Fixes applied:
//   1. searchMedia() now uses Isolate.run() (via compute) so it is fully
//      off the main thread.
//   2. Inside the search we bulk-load all faces/OCR/objects once, then
//      join in memory — O(1) DB calls instead of O(n).
//   3. Results are truncated to 200 items max (no UI needs more at once).
//   4. getTopPeopleByFaceCount() returns only the top-N people sorted by
//      how many faces they have — the People grid uses this instead of
//      getAllPeople(), limiting noise clusters to the most-seen faces.
// ═══════════════════════════════════════════════════════════════════════════

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  bool _useFallback = false;
  final Map<String, List<Map<String, dynamic>>> _fallbackDb = {
    'media_items': [],
    'people': [],
    'faces': [],
    'ocr_texts': [],
    'objects': [],
    'recommend_groups': [],
    'recommend_items': [],
    'recommend_generation_status': [],
  };

  DatabaseHelper._init() {
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
      _useFallback = true;
      debugPrint("DatabaseHelper: Fallback mode (non-mobile).");
    }
    // DatabaseHelper.instance.resetBlankMetadataItems().then((_) {
    //   DeviceMediaScanner.instance.scanAndSyncDeviceMedia();
    // });
  }

  Future<Database> get database async {
    if (_useFallback) throw Exception("Fallback mode — use APIs.");
    if (_database != null) return _database!;
    try {
      _database = await _initDB('ghost_gallery.db');
      return _database!;
    } catch (e) {
      debugPrint(
        "DatabaseHelper: Failed to open SQLite database. Enabling database-less fallback mode: $e",
      );
      _useFallback = true;
      throw Exception("Fallback mode — use APIs.");
    }
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);
    final db = await openDatabase(
      path,
      version: 14,
      onCreate: _createDB,
      onUpgrade: _onUpgrade,
    );
    try {
      // Use rawQuery for result-returning PRAGMAs — sqflite rejects execute()
      // for statements that produce a result row (journal_mode returns one).
      await db.rawQuery('PRAGMA journal_mode=WAL;');
      await db.rawQuery('PRAGMA busy_timeout=5000;');
      debugPrint("DatabaseHelper: WAL and busy_timeout enabled successfully.");
    } catch (e) {
      debugPrint(
        "DatabaseHelper: Failed to configure WAL/busy_timeout mode: $e",
      );
    }
    try {
      await db.execute(
        'ALTER TABLE media_items ADD COLUMN metadata_ready INTEGER NOT NULL DEFAULT 0',
      );
      debugPrint(
        "DatabaseHelper: Successfully ensured metadata_ready column exists.",
      );
    } catch (_) {}
    try {
      await db.execute('ALTER TABLE media_items ADD COLUMN description TEXT');
      debugPrint(
        "DatabaseHelper: Successfully ensured description column exists.",
      );
    } catch (_) {}
    try {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS recommend_generation_status (
          id           TEXT    PRIMARY KEY,
          status       TEXT    NOT NULL,
          progress     REAL    NOT NULL,
          message      TEXT,
          started_at   INTEGER NOT NULL,
          expires_at   INTEGER NOT NULL
        )
      ''');
      debugPrint(
        "DatabaseHelper: Successfully ensured recommend_generation_status table exists.",
      );
    } catch (_) {}
    try {
      await db.execute('ALTER TABLE people ADD COLUMN is_custom_cover INTEGER NOT NULL DEFAULT 0');
      await db.execute("UPDATE people SET is_custom_cover = 1 WHERE cover_image LIKE '%profile_pictures%'");
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      final migrated = prefs.getBool('rotation_migration_v1') ?? false;
      if (!migrated) {
        await db.execute('UPDATE media_items SET rotation_degrees = 0, is_flipped = 0');
        await prefs.setBool('rotation_migration_v1', true);
        debugPrint("DatabaseHelper: Reset rotation_degrees and is_flipped to 0 for all items.");
      }
    } catch (e) {
      debugPrint("DatabaseHelper: Failed to run rotation migration: $e");
    }
    
    // Trigger SQLite to ObjectBox migration asynchronously on startup
    migrateEmbeddingsToObjectBox(db);

    return db;
  }

  Future<void> migrateEmbeddingsToObjectBox(Database db) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Use v3 flag — v2 may already be set on devices that ran a partial migration
      // without nulling the SQLite column.
      final migrated = prefs.getBool('objectbox_migration_v3') ?? false;
      if (migrated) return;

      debugPrint("DatabaseHelper: Starting SQLite-to-ObjectBox embeddings migration (v3)...");
      
      // 1. Fetch all media items that have embeddings
      final List<Map<String, dynamic>> items = await db.query(
        'media_items',
        columns: ['id', 'media_embedding'],
        where: 'media_embedding IS NOT NULL AND media_embedding != ""',
      );

      if (items.isEmpty) {
        await prefs.setBool('objectbox_migration_v3', true);
        debugPrint("DatabaseHelper: No embeddings found in SQLite to migrate.");
        return;
      }

      // 2. Initialize ObjectBox
      final box = await ObjectBoxService.getBox();
      if (box == null) {
        debugPrint("DatabaseHelper: ObjectBox box is null. Migration deferred.");
        return;
      }

      final List<MediaVector> toPut = [];
      for (final item in items) {
        final id = item['id'] as String;
        final embStr = item['media_embedding'] as String;
        try {
          final vector = embStr.split(',').map((s) => double.tryParse(s) ?? 0.0).toList();
          if (vector.isNotEmpty) {
            toPut.add(MediaVector(mediaId: id, embedding: vector));
          }
        } catch (e) {
          debugPrint("DatabaseHelper: Error parsing vector for media $id: $e");
        }
      }

      if (toPut.isNotEmpty) {
        box.putMany(toPut);
        debugPrint("DatabaseHelper: Successfully migrated ${toPut.length} embeddings to ObjectBox.");
      }

      // 3. Null out the SQLite column to free storage — no longer needed
      try {
        await db.execute('UPDATE media_items SET media_embedding = NULL');
        debugPrint("DatabaseHelper: Nulled media_embedding column in SQLite after ObjectBox migration.");
      } catch (e) {
        debugPrint("DatabaseHelper: Failed to null media_embedding column: $e");
      }

      await prefs.setBool('objectbox_migration_v3', true);
    } catch (e) {
      debugPrint("DatabaseHelper: Failed to run ObjectBox migration: $e");
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // SCHEMA
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE media_items (
        id               TEXT    PRIMARY KEY,
        path             TEXT    NOT NULL,
        media_type       TEXT    NOT NULL,
        date             TEXT,
        date_timestamp   INTEGER,
        location         TEXT    NOT NULL DEFAULT '',
        latitude         REAL    DEFAULT 0.0,
        longitude        REAL    DEFAULT 0.0,
        width            INTEGER NOT NULL DEFAULT 0,
        height           INTEGER NOT NULL DEFAULT 0,
        size             TEXT    NOT NULL DEFAULT '',
        camera_info      TEXT    NOT NULL DEFAULT '',
        duration         REAL,
        album_name       TEXT,
        album_id         TEXT,
        album_category   TEXT,
        is_processed     INTEGER NOT NULL DEFAULT 0,
        is_faces_processed INTEGER NOT NULL DEFAULT 0,
        media_embedding  TEXT,
        preview_base64   TEXT,
        clip_embedding   TEXT,
        -- v6: rich metadata
        flags            INTEGER NOT NULL DEFAULT 0,
        rotation_degrees INTEGER NOT NULL DEFAULT 0,
        is_flipped       INTEGER NOT NULL DEFAULT 0,
        mime_type        TEXT,
        aperture         REAL,
        iso              INTEGER,
        focal_length     REAL,
        exposure_time    TEXT,
        flash            INTEGER,
        xmp_subjects     TEXT,
        xmp_title        TEXT,
        rating           INTEGER NOT NULL DEFAULT 0,
        country_code     TEXT,
        country_name     TEXT,
        admin_area       TEXT,
        locality         TEXT,
        sub_locality     TEXT,
        feature_name     TEXT,
        metadata_ready   INTEGER NOT NULL DEFAULT 0,
        description      TEXT,
        modified_timestamp INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE people (
        id            TEXT PRIMARY KEY,
        name          TEXT NOT NULL,
        dob           TEXT,
        relation      TEXT,
        cover_image   TEXT,
        cover_x       INTEGER NOT NULL DEFAULT 0,
        cover_y       INTEGER NOT NULL DEFAULT 0,
        cover_w       INTEGER NOT NULL DEFAULT 0,
        cover_h       INTEGER NOT NULL DEFAULT 0,
        is_custom_cover INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE faces (
        id           TEXT PRIMARY KEY,
        media_id     TEXT NOT NULL,
        bounding_box TEXT NOT NULL,
        embedding    TEXT NOT NULL,
        person_id    TEXT,
        FOREIGN KEY (media_id)  REFERENCES media_items (id) ON DELETE CASCADE,
        FOREIGN KEY (person_id) REFERENCES people (id)      ON DELETE SET NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE ocr_texts (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        media_id   TEXT    NOT NULL,
        text       TEXT    NOT NULL,
        confidence REAL    NOT NULL,
        FOREIGN KEY (media_id) REFERENCES media_items (id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE objects (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        media_id   TEXT NOT NULL,
        label      TEXT NOT NULL,
        confidence REAL NOT NULL,
        FOREIGN KEY (media_id) REFERENCES media_items (id) ON DELETE CASCADE
      )
    ''');

    // ── Indexes for fast joins ─────────────────────────────────────────────
    await db.execute('CREATE INDEX idx_faces_media    ON faces (media_id)');
    await db.execute('CREATE INDEX idx_faces_person   ON faces (person_id)');
    await db.execute('CREATE INDEX idx_ocr_media      ON ocr_texts (media_id)');
    await db.execute('CREATE INDEX idx_objects_media  ON objects (media_id)');

    // ── Hash cache (duplicate detection) ──────────────────────────────────
    await db.execute('''
      CREATE TABLE file_hashes (
        media_id    TEXT    PRIMARY KEY,
        md5_hash    TEXT    NOT NULL,
        file_size   INTEGER,
        computed_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE recommend_groups (
        id           TEXT    PRIMARY KEY,
        type         TEXT    NOT NULL,
        title        TEXT    NOT NULL,
        subtitle     TEXT    NOT NULL,
        generated_at INTEGER NOT NULL,
        expires_at   INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE recommend_items (
        id                  TEXT    PRIMARY KEY,
        group_id            TEXT    NOT NULL,
        item_type           TEXT    NOT NULL,
        source_item_id      TEXT,
        source_item_path    TEXT,
        origin_album_name   TEXT,
        generated_file_path TEXT,
        text_overlay        TEXT,
        FOREIGN KEY (group_id) REFERENCES recommend_groups (id) ON DELETE CASCADE
      )
    ''');

    debugPrint("DatabaseHelper: Tables created (v9 schema).");
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
        'ALTER TABLE media_items ADD COLUMN date_timestamp INTEGER',
      );
      await db.execute(
        'ALTER TABLE media_items ADD COLUMN latitude  REAL DEFAULT 0.0',
      );
      await db.execute(
        'ALTER TABLE media_items ADD COLUMN longitude REAL DEFAULT 0.0',
      );
      await db.execute(
        'ALTER TABLE media_items ADD COLUMN album_name     TEXT',
      );
      await db.execute(
        'ALTER TABLE media_items ADD COLUMN album_id       TEXT',
      );
      await db.execute(
        'ALTER TABLE media_items ADD COLUMN album_category TEXT',
      );
    }
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE people ADD COLUMN cover_image TEXT');
      await db.execute(
        'ALTER TABLE people ADD COLUMN cover_x INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE people ADD COLUMN cover_y INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE people ADD COLUMN cover_w INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE people ADD COLUMN cover_h INTEGER NOT NULL DEFAULT 0',
      );
      try {
        await db.execute('CREATE INDEX idx_faces_media    ON faces (media_id)');
        await db.execute(
          'CREATE INDEX idx_faces_person   ON faces (person_id)',
        );
        await db.execute(
          'CREATE INDEX idx_ocr_media      ON ocr_texts (media_id)',
        );
        await db.execute(
          'CREATE INDEX idx_objects_media  ON objects (media_id)',
        );
      } catch (_) {}
    }
    if (oldVersion < 4) {
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN media_embedding TEXT',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN preview_base64 TEXT',
        );
      } catch (_) {}
    }
    if (oldVersion < 5) {
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN clip_embedding TEXT',
        );
      } catch (_) {}
    }
    if (oldVersion < 6) {
      // Special-type bitmask + orientation
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN flags            INTEGER NOT NULL DEFAULT 0',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN rotation_degrees INTEGER NOT NULL DEFAULT 0',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN is_flipped       INTEGER NOT NULL DEFAULT 0',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN mime_type        TEXT',
        );
      } catch (_) {}
      // Camera settings
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN aperture         REAL',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN iso              INTEGER',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN focal_length     REAL',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN exposure_time    TEXT',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN flash            INTEGER',
        );
      } catch (_) {}
      // XMP metadata
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN xmp_subjects     TEXT',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN xmp_title        TEXT',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN rating           INTEGER NOT NULL DEFAULT 0',
        );
      } catch (_) {}
      // Structured address
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN country_code     TEXT',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN country_name     TEXT',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN admin_area       TEXT',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN locality         TEXT',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN sub_locality     TEXT',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN feature_name     TEXT',
        );
      } catch (_) {}
      // Index for map queries
      try {
        await db.execute(
          'CREATE INDEX idx_media_locality ON media_items (locality)',
        );
      } catch (_) {}
      try {
        await db.execute(
          'CREATE INDEX idx_media_flags    ON media_items (flags)',
        );
      } catch (_) {}
      debugPrint('DatabaseHelper: Migrated to schema v6.');
    }
    if (oldVersion < 7) {
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN metadata_ready INTEGER NOT NULL DEFAULT 0',
        );
      } catch (_) {}
    }
    if (oldVersion < 8) {
      try {
        await db.execute(
          'UPDATE media_items SET media_embedding = NULL, is_processed = 0',
        );
        debugPrint(
          'DatabaseHelper: Migrated to schema v8 - cleared media_embedding and reset is_processed for re-embedding.',
        );
      } catch (e) {
        debugPrint('DatabaseHelper: Failed to migrate to schema v8: $e');
      }
    }
    if (oldVersion < 9) {
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS file_hashes (
            media_id    TEXT    PRIMARY KEY,
            md5_hash    TEXT    NOT NULL,
            file_size   INTEGER,
            computed_at INTEGER NOT NULL
          )
        ''');
        debugPrint(
          'DatabaseHelper: Migrated to schema v9 - added file_hashes table.',
        );
      } catch (e) {
        debugPrint('DatabaseHelper: Failed to migrate to schema v9: $e');
      }
    }
    if (oldVersion < 10) {
      try {
        await db.execute(
          'UPDATE media_items SET media_embedding = NULL, is_processed = 0',
        );
        debugPrint(
          'DatabaseHelper: Migrated to schema v10 - cleared media_embedding and reset is_processed for MediaPipe embedding migration.',
        );
      } catch (e) {
        debugPrint('DatabaseHelper: Failed to migrate to schema v10: $e');
      }
    }
    if (oldVersion < 11) {
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN is_faces_processed INTEGER NOT NULL DEFAULT 0',
        );
        debugPrint(
          'DatabaseHelper: Migrated to schema v11 - added is_faces_processed column.',
        );
      } catch (e) {
        debugPrint('DatabaseHelper: Failed to migrate to schema v11: $e');
      }
    }
    if (oldVersion < 12) {
      try {
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN modified_timestamp INTEGER',
        );
        await db.execute(
          'UPDATE media_items SET modified_timestamp = date_timestamp WHERE modified_timestamp IS NULL',
        );
        debugPrint(
          'DatabaseHelper: Migrated to schema v12 - added modified_timestamp column.',
        );
      } catch (e) {
        debugPrint('DatabaseHelper: Failed to migrate to schema v12: $e');
      }
    }
    if (oldVersion < 13) {
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS recommend_groups (
            id           TEXT    PRIMARY KEY,
            type         TEXT    NOT NULL,
            title        TEXT    NOT NULL,
            subtitle     TEXT    NOT NULL,
            generated_at INTEGER NOT NULL,
            expires_at   INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS recommend_items (
            id                  TEXT    PRIMARY KEY,
            group_id            TEXT    NOT NULL,
            item_type           TEXT    NOT NULL,
            source_item_id      TEXT,
            source_item_path    TEXT,
            origin_album_name   TEXT,
            generated_file_path TEXT,
            text_overlay        TEXT,
            FOREIGN KEY (group_id) REFERENCES recommend_groups (id) ON DELETE CASCADE
          )
        ''');
        debugPrint(
          'DatabaseHelper: Migrated to schema v13 - added recommend tables.',
        );
      } catch (e) {
        debugPrint('DatabaseHelper: Failed to migrate to schema v13: $e');
      }
    }
    if (oldVersion < 14) {
      // v14: SQLite media_embedding column is now superseded by ObjectBox.
      // Null out the column to reclaim storage for users upgrading from v2.5.0.
      // The actual ObjectBox data migration is handled separately by
      // migrateEmbeddingsToObjectBox() which is called on every DB open (guarded
      // by the 'objectbox_migration_v3' SharedPreferences flag).
      try {
        await db.execute('UPDATE media_items SET media_embedding = NULL');
        debugPrint(
          'DatabaseHelper: Migrated to schema v14 - nulled media_embedding column (ObjectBox migration).',
        );
      } catch (e) {
        debugPrint('DatabaseHelper: Failed to migrate to schema v14: $e');
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // HASH CACHE — used by DuplicateDetector for persistent MD5 storage
  // ══════════════════════════════════════════════════════════════════════════

  /// Returns all cached MD5 hashes as { media_id → md5_hash }.
  Future<Map<String, String>> getHashCache() async {
    if (_useFallback) return {};
    try {
      final db = await database;
      final rows = await db.query(
        'file_hashes',
        columns: ['media_id', 'md5_hash'],
      );
      return {
        for (final r in rows) r['media_id'] as String: r['md5_hash'] as String,
      };
    } catch (e) {
      debugPrint('DatabaseHelper: getHashCache failed: $e');
      return {};
    }
  }

  /// Batch-inserts/replaces hash records. { media_id → md5_hash }
  Future<void> upsertHashCache(Map<String, String> hashes) async {
    if (_useFallback || hashes.isEmpty) return;
    try {
      final db = await database;
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (final entry in hashes.entries) {
          batch.insert('file_hashes', {
            'media_id': entry.key,
            'md5_hash': entry.value,
            'computed_at': now,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
      });
    } catch (e) {
      debugPrint('DatabaseHelper: upsertHashCache failed: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // MEDIA ITEMS CRUD
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> insertMediaItem(Map<String, dynamic> item) async {
    if (_useFallback) {
      _fallbackDb['media_items']!.removeWhere((x) => x['id'] == item['id']);
      _fallbackDb['media_items']!.add(item);
      return;
    }
    final db = await database;
    await db.insert(
      'media_items',
      item,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getAllMediaItems() async {
    if (_useFallback) return List.from(_fallbackDb['media_items']!);
    try {
      final db = await database;
      return await db.query(
        'media_items',
        orderBy: 'COALESCE(modified_timestamp, date_timestamp, rowid) DESC',
      );
    } catch (e) {
      debugPrint(
        "DatabaseHelper: getAllMediaItems failed, using in-memory fallback: $e",
      );
      // ⚠ Do NOT set _useFallback = true here.
      // OOM and database-locked are TRANSIENT errors — permanently disabling the
      // database causes all subsequent calls to return the empty in-memory map,
      // making the UI appear empty until the app restarts.
      return List.from(_fallbackDb['media_items']!);
    }
  }

  /// Lightweight version for gallery display — excludes heavy binary columns.
  ///
  /// `preview_base64`  — base64-encoded JPEG thumbnail, can be 50–200 KB each
  /// `media_embedding` — 384 comma-separated floats (~3 KB each)
  /// `clip_embedding`  — 384 comma-separated floats (~3 KB each)
  ///
  /// Loading 3000 items × these columns = 100–600 MB just for display.
  /// Use getAllMediaItems() only when embeddings are actually needed (search/ML).
  Future<List<Map<String, dynamic>>> getAllMediaItemsLite() async {
    if (_useFallback) return List.from(_fallbackDb['media_items']!);
    try {
      final db = await database;
      // Explicitly list every column except the 3 heavy ones
      return await db.query(
        'media_items',
        columns: [
          'id', 'path', 'media_type', 'date', 'date_timestamp',
          'location', 'latitude', 'longitude', 'width', 'height',
          'size', 'camera_info', 'duration', 'album_name', 'album_id',
          'album_category', 'is_processed', 'flags', 'rotation_degrees',
          'is_flipped', 'mime_type', 'aperture', 'iso', 'focal_length',
          'exposure_time', 'flash', 'xmp_subjects', 'xmp_title', 'rating',
          'country_code', 'country_name', 'admin_area', 'locality',
          'sub_locality', 'feature_name', 'metadata_ready', 'description',
          'modified_timestamp',
          // preview_base64, media_embedding, clip_embedding intentionally omitted
        ],
        orderBy: 'COALESCE(modified_timestamp, date_timestamp, rowid) DESC',
      );
    } catch (e) {
      debugPrint(
        "DatabaseHelper: getAllMediaItemsLite failed, using in-memory fallback: $e",
      );
      return List.from(_fallbackDb['media_items']!);
    }
  }

  /// Camera-roll only query — returns only items where album_category = 'Camera'
  /// or id starts with 'imported'. This is the fast Phase-1 query that lets
  /// the Photos tab render immediately on startup without loading the full library.
  ///
  /// Includes preview_base64 so thumbnails show instantly from cached data.
  Future<List<Map<String, dynamic>>> getCameraMediaItemsLite() async {
    if (_useFallback) {
      return _fallbackDb['media_items']!
          .where((m) {
            final cat = (m['album_category'] as String? ?? '').toLowerCase();
            final id = (m['id'] as String? ?? '').toLowerCase();
            return cat == 'camera' || id.startsWith('imported');
          })
          .toList();
    }
    try {
      final db = await database;
      return await db.query(
        'media_items',
        columns: [
          'id', 'path', 'media_type', 'date', 'date_timestamp',
          'location', 'latitude', 'longitude', 'width', 'height',
          'size', 'camera_info', 'duration', 'album_name', 'album_id',
          'album_category', 'is_processed', 'flags', 'rotation_degrees',
          'is_flipped', 'mime_type', 'rating', 'description',
          'modified_timestamp', 'preview_base64',
        ],
        where: "album_category = 'Camera' OR id LIKE 'imported%'",
        orderBy: 'COALESCE(modified_timestamp, date_timestamp, rowid) DESC',
      );
    } catch (e) {
      debugPrint('DatabaseHelper: getCameraMediaItemsLite failed: $e');
      return [];
    }
  }

  Future<Map<String, dynamic>?> getMediaItemById(String id) async {
    if (_useFallback) {
      final m = _fallbackDb['media_items']!.where((x) => x['id'] == id);
      return m.isEmpty ? null : m.first;
    }
    final db = await database;
    final r = await db.query('media_items', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : r.first;
  }

  Future<List<Map<String, dynamic>>> getMediaItemsByIds(List<String> ids) async {
    if (ids.isEmpty) return [];
    if (_useFallback) {
      final idSet = ids.toSet();
      return _fallbackDb['media_items']!
          .where((m) => idSet.contains(m['id']))
          .toList();
    }
    final db = await database;
    final List<Map<String, dynamic>> results = [];
    const chunkSize = 500;
    for (int i = 0; i < ids.length; i += chunkSize) {
      final chunk = ids.sublist(i, i + chunkSize > ids.length ? ids.length : i + chunkSize);
      final placeholders = List.filled(chunk.length, '?').join(',');
      final chunkResults = await db.query(
        'media_items',
        where: 'id IN ($placeholders)',
        whereArgs: chunk,
      );
      results.addAll(chunkResults);
    }
    return results;
  }

  Future<Map<String, dynamic>?> getMediaItemByPath(String path) async {
    if (_useFallback) {
      final m = _fallbackDb['media_items']!.where((x) => x['path'] == path);
      return m.isEmpty ? null : m.first;
    }
    try {
      final db = await database;
      final r = await db.query('media_items', where: 'path = ?', whereArgs: [path]);
      return r.isEmpty ? null : r.first;
    } catch (e) {
      debugPrint('DatabaseHelper.getMediaItemByPath error: $e');
      return null;
    }
  }

  Future<void> updateMediaItemProcessedStatus(String id, int status) async {
    if (_useFallback) {
      for (var item in _fallbackDb['media_items']!) {
        if (item['id'] == id) {
          item['is_processed'] = status;
          break;
        }
      }
      return;
    }
    final db = await database;
    await db.update(
      'media_items',
      {'is_processed': status},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateMediaItemEmbedding(String id, String embedding) async {
    if (_useFallback) {
      for (var item in _fallbackDb['media_items']!) {
        if (item['id'] == id) {
          item['media_embedding'] = embedding;
          break;
        }
      }
      return;
    }
    final db = await database;
    await db.update(
      'media_items',
      {'media_embedding': null},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateMediaItemEmbeddingsBatch(
    Map<String, String> embeddings,
  ) async {
    if (_useFallback) {
      for (final entry in embeddings.entries) {
        for (var item in _fallbackDb['media_items']!) {
          if (item['id'] == entry.key) {
            item['media_embedding'] = entry.value;
            break;
          }
        }
      }
      return;
    }
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final entry in embeddings.entries) {
        batch.update(
          'media_items',
          {'media_embedding': entry.value},
          where: 'id = ?',
          whereArgs: [entry.key],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> updateMediaItemClipEmbedding(
    String id,
    String clipEmbedding,
  ) async {
    if (_useFallback) {
      for (var item in _fallbackDb['media_items']!) {
        if (item['id'] == id) {
          item['clip_embedding'] = clipEmbedding;
          break;
        }
      }
      return;
    }
    final db = await database;
    await db.update(
      'media_items',
      {'clip_embedding': clipEmbedding},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateMediaItemClipEmbeddingsBatch(
    Map<String, String> clipEmbeddings,
  ) async {
    if (_useFallback) {
      for (final entry in clipEmbeddings.entries) {
        for (var item in _fallbackDb['media_items']!) {
          if (item['id'] == entry.key) {
            item['clip_embedding'] = entry.value;
            break;
          }
        }
      }
      return;
    }
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final entry in clipEmbeddings.entries) {
        batch.update(
          'media_items',
          {'clip_embedding': entry.value},
          where: 'id = ?',
          whereArgs: [entry.key],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> updateMediaItemResolutionAndSize(
    String id,
    String resolution,
    String size,
  ) async {
    int w = 1920, h = 1080;
    if (resolution.contains('x') || resolution.contains('×')) {
      final parts = resolution.split(RegExp(r'[x×]'));
      if (parts.length == 2) {
        w = int.tryParse(parts[0].trim()) ?? 1920;
        h = int.tryParse(parts[1].trim()) ?? 1080;
      }
    }
    if (_useFallback) {
      for (var item in _fallbackDb['media_items']!) {
        if (item['id'] == id) {
          item['width'] = w;
          item['height'] = h;
          item['size'] = size;
          break;
        }
      }
      return;
    }
    final db = await database;
    await db.update(
      'media_items',
      {'width': w, 'height': h, 'size': size},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<Map<String, dynamic>>> getAndLockUnprocessedItems(
    int limit,
  ) async {
    if (_useFallback) {
      final unprocessed = _fallbackDb['media_items']!
          .where((x) => x['is_processed'] == 0 || x['is_processed'] == 4)
          .take(limit)
          .toList();
      for (var item in unprocessed) {
        item['original_is_processed'] = item['is_processed'];
        item['is_processed'] = 2;
      }
      return List.from(unprocessed);
    }
    final db = await database;
    return await db.transaction((txn) async {
      final results = await txn.query(
        'media_items',
        where: 'is_processed = 0 OR is_processed = 4',
        limit: limit,
      );
      if (results.isEmpty) return [];
      final locked = <Map<String, dynamic>>[];
      for (final row in results) {
        final id = row['id'] as String;
        await txn.update(
          'media_items',
          {'is_processed': 2},
          where: 'id = ?',
          whereArgs: [id],
        );
        final m = Map<String, dynamic>.from(row);
        m['original_is_processed'] = row['is_processed'];
        m['is_processed'] = 2;
        locked.add(m);
      }
      return locked;
    });
  }

  Future<void> resetStuckProcessingItems() async {
    if (_useFallback) {
      for (var item in _fallbackDb['media_items']!) {
        if (item['is_processed'] == 2) item['is_processed'] = 0;
      }
      // Also reset fallback items that have faces with null/invalid embeddings so they get rescanned
      final failedMediaIds = _fallbackDb['faces']!
          .where((f) {
            final emb = f['embedding'] as String?;
            return emb == null || emb == 'null' || emb.isEmpty;
          })
          .map((f) => f['media_id'] as String)
          .toSet();
      for (var item in _fallbackDb['media_items']!) {
        if (failedMediaIds.contains(item['id'])) {
          item['is_processed'] = 0;
        }
      }
      return;
    }
    final db = await database;
    await db.update('media_items', {
      'is_processed': 0,
    }, where: 'is_processed = 2');

    // Also reset media items that have faces with null/invalid embeddings so they get rescanned
    await db.rawUpdate('''
      UPDATE media_items
      SET is_processed = 0
      WHERE id IN (
        SELECT DISTINCT media_id FROM faces 
        WHERE embedding IS NULL OR embedding = '' OR embedding = 'null'
      )
    ''');
  }

  Future<List<Map<String, dynamic>>> getAndLockUnprocessedFacesItems(
    int limit,
  ) async {
    if (_useFallback) {
      final pending = _fallbackDb['media_items']!
          .where((x) {
            final s = x['is_faces_processed'] as int? ?? 0;
            // Process both images and videos
            final t = (x['media_type'] as String? ?? '').toLowerCase();
            return (s == 0 || s == 4) && (t == 'image' || t == 'video');
          })
          .take(limit)
          .toList();
      for (var item in pending) {
        item['original_is_faces_processed'] = item['is_faces_processed'];
        item['is_faces_processed'] = 2; // In progress
      }
      return List.from(pending);
    }
    final db = await database;
    return await db.transaction((txn) async {
      final results = await txn.query(
        'media_items',
        columns: ['id', 'path', 'media_type', 'duration', 'is_faces_processed'],
        // Query both images and videos
        where:
            '(is_faces_processed = 0 OR is_faces_processed = 4) AND (media_type = \'image\' OR media_type = \'video\')',
        limit: limit,
      );
      if (results.isEmpty) return [];
      final lockedItems = <Map<String, dynamic>>[];
      for (final row in results) {
        final id = row['id'] as String;
        await txn.update(
          'media_items',
          {'is_faces_processed': 2},
          where: 'id = ?',
          whereArgs: [id],
        );
        final m = Map<String, dynamic>.from(row);
        m['original_is_faces_processed'] = row['is_faces_processed'];
        m['is_faces_processed'] = 2;
        lockedItems.add(m);
      }
      return lockedItems;
    });
  }

  Future<void> updateMediaItemFacesProcessedStatus(
    String id,
    int status,
  ) async {
    if (_useFallback) {
      for (var item in _fallbackDb['media_items']!) {
        if (item['id'] == id) {
          item['is_faces_processed'] = status;
          break;
        }
      }
      return;
    }
    final db = await database;
    await db.update(
      'media_items',
      {'is_faces_processed': status},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> resetStuckFacesProcessingItems() async {
    if (_useFallback) {
      for (var item in _fallbackDb['media_items']!) {
        if ((item['is_faces_processed'] as int? ?? 0) == 2) {
          item['is_faces_processed'] = 0;
        }
      }
      return;
    }
    final db = await database;
    await db.update('media_items', {
      'is_faces_processed': 0,
    }, where: 'is_faces_processed = 2');
  }

  Future<void> clearAllFacesAndPeopleData() async {
    if (_useFallback) {
      _fallbackDb['faces']!.clear();
      _fallbackDb['people']!.clear();
      for (var item in _fallbackDb['media_items']!) {
        item['is_faces_processed'] = 0;
      }
      return;
    }
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('faces');
      await txn.delete('people');
      await txn.update('media_items', {'is_faces_processed': 0});
    });
    debugPrint(
      "DatabaseHelper: Cleared all faces and people data. Reset is_faces_processed.",
    );
  }

  Future<void> deleteMediaItem(String id) async {
    if (_useFallback) {
      final item = _fallbackDb['media_items']!.firstWhere((x) => x['id'] == id, orElse: () => <String, dynamic>{});
      final path = item['path'] as String?;
      if (path != null) {
        await FaceCacheHelper.evictFacesForImage(path);
      }
      for (final tbl in ['media_items', 'faces', 'ocr_texts', 'objects']) {
        final key = tbl == 'media_items' ? 'id' : 'media_id';
        _fallbackDb[tbl]!.removeWhere((x) => x[key] == id);
      }
      return;
    }
    final db = await database;
    final item = await getMediaItemById(id);
    final path = item?['path'] as String?;
    if (path != null) {
      await FaceCacheHelper.evictFacesForImage(path);
    }
    await db.transaction((txn) async {
      await txn.delete('faces', where: 'media_id = ?', whereArgs: [id]);
      await txn.delete('ocr_texts', where: 'media_id = ?', whereArgs: [id]);
      await txn.delete('objects', where: 'media_id = ?', whereArgs: [id]);
      await txn.delete('media_items', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> clearMLFeaturesForMedia(String mediaId) async {
    if (_useFallback) {
      final item = _fallbackDb['media_items']!.firstWhere((x) => x['id'] == mediaId, orElse: () => <String, dynamic>{});
      final path = item['path'] as String?;
      if (path != null) {
        await FaceCacheHelper.evictFacesForImage(path);
      }
      for (final tbl in ['faces', 'ocr_texts', 'objects']) {
        _fallbackDb[tbl]!.removeWhere((x) => x['media_id'] == mediaId);
      }
      return;
    }
    final db = await database;
    final item = await getMediaItemById(mediaId);
    final path = item?['path'] as String?;
    if (path != null) {
      await FaceCacheHelper.evictFacesForImage(path);
    }
    await db.transaction((txn) async {
      await txn.delete('faces', where: 'media_id = ?', whereArgs: [mediaId]);
      await txn.delete(
        'ocr_texts',
        where: 'media_id = ?',
        whereArgs: [mediaId],
      );
      await txn.delete('objects', where: 'media_id = ?', whereArgs: [mediaId]);
    });
  }

  Future<void> clearFacesForMedia(String mediaId) async {
    if (_useFallback) {
      final item = _fallbackDb['media_items']!.firstWhere((x) => x['id'] == mediaId, orElse: () => <String, dynamic>{});
      final path = item['path'] as String?;
      if (path != null) {
        await FaceCacheHelper.evictFacesForImage(path);
      }
      _fallbackDb['faces']!.removeWhere((x) => x['media_id'] == mediaId);
      return;
    }
    final db = await database;
    final item = await getMediaItemById(mediaId);
    final path = item?['path'] as String?;
    if (path != null) {
      await FaceCacheHelper.evictFacesForImage(path);
    }
    await db.delete('faces', where: 'media_id = ?', whereArgs: [mediaId]);
  }

  Future<void> clearOcrAndObjectsForMedia(String mediaId) async {
    if (_useFallback) {
      _fallbackDb['ocr_texts']!.removeWhere((x) => x['media_id'] == mediaId);
      _fallbackDb['objects']!.removeWhere((x) => x['media_id'] == mediaId);
      return;
    }
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'ocr_texts',
        where: 'media_id = ?',
        whereArgs: [mediaId],
      );
      await txn.delete('objects', where: 'media_id = ?', whereArgs: [mediaId]);
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BATCH INSERT — much faster than sequential await db.insert() calls
  // Commits the entire batch in one transaction. Duplicate IDs are replaced.
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> batchInsertMediaItems(List<Map<String, dynamic>> items) async {
    if (items.isEmpty) return;
    if (_useFallback) {
      for (final item in items) {
        _fallbackDb['media_items']!.removeWhere((x) => x['id'] == item['id']);
        _fallbackDb['media_items']!.add(item);
      }
      return;
    }
    try {
      final db = await database;
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (final item in items) {
          batch.insert(
            'media_items',
            item,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      });
    } catch (e) {
      debugPrint(
        "DatabaseHelper: batchInsertMediaItems failed, using fallback: $e",
      );
      _useFallback = true;
      for (final item in items) {
        _fallbackDb['media_items']!.removeWhere((x) => x['id'] == item['id']);
        _fallbackDb['media_items']!.add(item);
      }
    }
  }

  /// Returns a map of asset id → date_timestamp for all known items.
  /// Used by scanner to skip unchanged items on subsequent scans.
  Future<Map<String, int>> getKnownItemDateMap() async {
    if (_useFallback) {
      return {
        for (final item in _fallbackDb['media_items']!)
          item['id'] as String: (item['date_timestamp'] as int?) ?? 0,
      };
    }
    final db = await database;
    final rows = await db.query(
      'media_items',
      columns: ['id', 'date_timestamp', 'path'],
    );
    return {
      for (final r in rows)
        r['id'] as String: (r['date_timestamp'] as int?) ?? 0,
    };
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FAST PENDING-WORK CHECKS
  // Used as early-exit guards so tiers don't schedule themselves when all
  // items are already fully processed. Both use COUNT(*) — no row data loaded.
  // ══════════════════════════════════════════════════════════════════════════

  /// Returns true if any item still needs EXIF/GPS metadata (Tier 2).
  Future<bool> hasTier2PendingWork() async {
    if (_useFallback) {
      return _fallbackDb['media_items']!.any(
        (x) => (x['metadata_ready'] as int? ?? 0) == 0,
      );
    }
    try {
      final db = await database;
      final result = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM media_items WHERE metadata_ready = 0',
      );
      return (result.first['c'] as int? ?? 0) > 0;
    } catch (_) {
      return false;
    }
  }

  /// Returns true if any item still needs ML/embedding processing (Tier 3).
  Future<bool> hasTier3PendingWork() async {
    if (_useFallback) {
      return _fallbackDb['media_items']!.any((x) {
        final s = x['is_processed'] as int? ?? 0;
        return s == 0 || s == 4;
      });
    }
    try {
      final db = await database;
      final result = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM media_items WHERE is_processed = 0 OR is_processed = 4',
      );
      return (result.first['c'] as int? ?? 0) > 0;
    } catch (_) {
      return false;
    }
  }

  /// Returns the exact count of items still needing ML/embedding (Tier 3).
  /// Use this for progress notifications instead of loading all rows.
  Future<int> countTier3PendingItems() async {
    if (_useFallback) {
      return _fallbackDb['media_items']!.where((x) {
        final s = x['is_processed'] as int? ?? 0;
        return s == 0 || s == 4;
      }).length;
    }
    try {
      final db = await database;
      final result = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM media_items WHERE is_processed = 0 OR is_processed = 4',
      );
      return result.first['c'] as int? ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<bool> hasTier4PendingWork() async {
    if (_useFallback) {
      return _fallbackDb['media_items']!.any((x) {
        final s = x['is_faces_processed'] as int? ?? 0;
        final t = (x['media_type'] as String? ?? '').toLowerCase();
        return (s == 0 || s == 4) && (t == 'image' || t == 'video');
      });
    }
    try {
      final db = await database;
      final result = await db.rawQuery(
        "SELECT COUNT(*) AS c FROM media_items WHERE (is_faces_processed = 0 OR is_faces_processed = 4) AND (media_type = 'image' OR media_type = 'video')",
      );
      return (result.first['c'] as int? ?? 0) > 0;
    } catch (_) {
      return false;
    }
  }

  Future<int> countTier4PendingItems() async {
    if (_useFallback) {
      return _fallbackDb['media_items']!.where((x) {
        final s = x['is_faces_processed'] as int? ?? 0;
        final t = (x['media_type'] as String? ?? '').toLowerCase();
        return (s == 0 || s == 4) && (t == 'image' || t == 'video');
      }).length;
    }
    try {
      final db = await database;
      final result = await db.rawQuery(
        "SELECT COUNT(*) AS c FROM media_items WHERE (is_faces_processed = 0 OR is_faces_processed = 4) AND (media_type = 'image' OR media_type = 'video')",
      );
      return result.first['c'] as int? ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Lock and return items pending metadata enrichment (Tier 2).
  Future<List<Map<String, dynamic>>> getMetadataPendingItems(int limit) async {
    if (_useFallback) {
      final pending = _fallbackDb['media_items']!
          .where(
            (x) =>
                (x['metadata_ready'] as int? ?? 0) == 0 &&
                x['is_processed'] != 2,
          )
          .take(limit)
          .toList();
      for (var item in pending) {
        item['is_processed'] = 3; // in-progress
      }
      return List.from(pending);
    }
    final db = await database;
    return await db.transaction((txn) async {
      final results = await txn.query(
        'media_items',
        where: 'metadata_ready = 0 AND is_processed != 2 AND is_processed != 3',
        limit: limit,
      );
      if (results.isEmpty) return [];
      final locked = <Map<String, dynamic>>[];
      for (final row in results) {
        final id = row['id'] as String;
        await txn.update(
          'media_items',
          {'is_processed': 3},
          where: 'id = ? AND is_processed != 2',
          whereArgs: [id],
        );
        locked.add(Map<String, dynamic>.from(row));
      }
      return locked;
    });
  }

  /// Resets metadata_ready for blank items. Disabled to prevent infinite EXIF retry loops on screenshots/WhatsApp images.
  Future<void> resetBlankMetadataItems() async {
    // Disabled: screenshots, WhatsApp media, and downloaded images naturally have
    // no EXIF/camera/location data. Resetting them causes infinite extraction loops on every app resume.
  }

  Future<void> updateMetadataReady(String id) async {
    if (_useFallback) {
      for (var item in _fallbackDb['media_items']!) {
        if (item['id'] == id) {
          item['metadata_ready'] = 1;
          // Only reset is_processed if it was locked as in-progress (3)
          // Never reset it if Tier 3 already finished (1)
          if ((item['is_processed'] as int? ?? 0) == 3) {
            item['is_processed'] = 0;
          }
          break;
        }
      }
      return;
    }
    final db = await database;
    // Only reset the lock status (3 = metadata in-progress), never touch
    // completed items (is_processed = 1)
    await db.rawUpdate(
      '''UPDATE media_items 
       SET metadata_ready = 1,
           is_processed = CASE WHEN is_processed = 3 THEN 0 ELSE is_processed END
       WHERE id = ?''',
      [id],
    );
  }

  /// In-memory flag: true when app is in foreground.
  /// Workmanager checks this before competing with UI.
  static bool isAppInForeground = true;

  // ══════════════════════════════════════════════════════════════════════════
  // RICH METADATA UPDATE — update v6 fields for a single media item
  // Called after full EXIF extraction during scan
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> updateMediaRichMetadata(
    String id,
    Map<String, dynamic> fields,
  ) async {
    if (_useFallback) {
      for (var item in _fallbackDb['media_items']!) {
        if (item['id'] == id) {
          item.addAll(fields);
          break;
        }
      }
      return;
    }
    final db = await database;
    await db.update('media_items', fields, where: 'id = ?', whereArgs: [id]);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BATCH RICH METADATA UPDATE — bulk update v6 fields for many items
  // Used after scanning a batch of images for full EXIF
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> batchUpdateRichMetadata(
    Map<String, Map<String, dynamic>> metadataById,
  ) async {
    if (metadataById.isEmpty) return;
    if (_useFallback) {
      for (final entry in metadataById.entries) {
        for (var item in _fallbackDb['media_items']!) {
          if (item['id'] == entry.key) {
            item.addAll(entry.value);
            break;
          }
        }
      }
      return;
    }
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final entry in metadataById.entries) {
        batch.update(
          'media_items',
          entry.value,
          where: 'id = ?',
          whereArgs: [entry.key],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // CONVENIENCE QUERIES
  // ══════════════════════════════════════════════════════════════════════════

  Future<List<Map<String, dynamic>>> getMediaWithLocation() async {
    if (_useFallback) {
      return _fallbackDb['media_items']!
          .where(
            (x) =>
                (x['latitude'] ?? 0.0) != 0.0 && (x['longitude'] ?? 0.0) != 0.0,
          )
          .toList();
    }
    final db = await database;
    return await db.query(
      'media_items',
      where: 'latitude != 0.0 AND longitude != 0.0',
      orderBy: 'COALESCE(date_timestamp, rowid) DESC',
    );
  }

  Future<List<Map<String, dynamic>>> getAlbumSummaries() async {
    if (_useFallback) {
      final Map<String, Map<String, dynamic>> buckets = {};
      for (var item in _fallbackDb['media_items']!) {
        final cat = (item['album_category'] as String?) ?? 'Other';
        buckets.putIfAbsent(
          cat,
          () => {'album_category': cat, 'count': 0, 'latest': 0},
        );
        buckets[cat]!['count'] = (buckets[cat]!['count'] as int) + 1;
        final ts = (item['date_timestamp'] as int?) ?? 0;
        if (ts > (buckets[cat]!['latest'] as int)) buckets[cat]!['latest'] = ts;
      }
      final list = buckets.values.toList();
      list.sort((a, b) => (b['latest'] as int).compareTo(a['latest'] as int));
      return list;
    }
    final db = await database;
    return await db.rawQuery('''
      SELECT album_category,
             COUNT(*)            AS count,
             MAX(date_timestamp) AS latest,
             MIN(id)             AS cover_id
      FROM media_items
      GROUP BY album_category
      ORDER BY latest DESC
    ''');
  }

  // ══════════════════════════════════════════════════════════════════════════
  // SPECIAL TYPE QUERIES — filter by MediaFlags bitmask
  // ══════════════════════════════════════════════════════════════════════════

  /// Returns all items that have [flagBit] set (e.g. MediaFlags.hdr)
  Future<List<Map<String, dynamic>>> getMediaByFlags(int flagBit) async {
    if (_useFallback) {
      return _fallbackDb['media_items']!
          .where((x) => ((x['flags'] as int? ?? 0) & flagBit) != 0)
          .toList();
    }
    final db = await database;
    return await db.rawQuery(
      'SELECT * FROM media_items WHERE (flags & ?) != 0 ORDER BY COALESCE(modified_timestamp, date_timestamp, rowid) DESC',
      [flagBit],
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // MAP / LOCATION QUERIES
  // ══════════════════════════════════════════════════════════════════════════

  /// Returns all distinct localities that have at least one geotagged item.
  Future<List<String>> getDistinctLocalities() async {
    if (_useFallback) {
      return _fallbackDb['media_items']!
          .map((x) => x['locality'] as String? ?? '')
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList();
    }
    final db = await database;
    final rows = await db.rawQuery(
      "SELECT DISTINCT locality FROM media_items WHERE locality IS NOT NULL AND locality != '' ORDER BY locality",
    );
    return rows.map((r) => r['locality'] as String).toList();
  }

  /// Returns items grouped by ~0.1° lat/lng cell for map clustering.
  /// Each row has: cell_lat, cell_lng, count, cover_path, lat, lng, locality
  Future<List<Map<String, dynamic>>> getGpsClusterSummaries() async {
    if (_useFallback) {
      final Map<String, Map<String, dynamic>> clusters = {};
      for (final item in _fallbackDb['media_items']!) {
        final lat = (item['latitude'] as double? ?? 0.0);
        final lng = (item['longitude'] as double? ?? 0.0);
        if (lat == 0.0 && lng == 0.0) continue;
        final key = '${(lat * 10).floor()}_${(lng * 10).floor()}';
        clusters.putIfAbsent(
          key,
          () => {
            'cell_lat': (lat * 10).floor() / 10.0,
            'cell_lng': (lng * 10).floor() / 10.0,
            'count': 0,
            'cover_path': item['path'],
            'lat': lat,
            'lng': lng,
            'locality': item['locality'] ?? '',
          },
        );
        clusters[key]!['count'] = (clusters[key]!['count'] as int) + 1;
      }
      return clusters.values.toList();
    }
    final db = await database;
    return await db.rawQuery('''
      SELECT
        ROUND(latitude  / 0.1) * 0.1 AS cell_lat,
        ROUND(longitude / 0.1) * 0.1 AS cell_lng,
        COUNT(*)            AS count,
        MIN(path)           AS cover_path,
        AVG(latitude)       AS lat,
        AVG(longitude)      AS lng,
        MAX(locality)       AS locality,
        MAX(country_name)   AS country_name
      FROM media_items
      WHERE latitude != 0.0 AND longitude != 0.0
      GROUP BY cell_lat, cell_lng
      ORDER BY count DESC
    ''');
  }

  /// Returns all items within a ~0.1° radius of the given cluster cell.
  Future<List<Map<String, dynamic>>> getMediaInCluster(
    double cellLat,
    double cellLng,
  ) async {
    if (_useFallback) {
      return _fallbackDb['media_items']!.where((x) {
        final lat = (x['latitude'] as double? ?? 0.0);
        final lng = (x['longitude'] as double? ?? 0.0);
        return ((lat - cellLat).abs() < 0.1) && ((lng - cellLng).abs() < 0.1);
      }).toList();
    }
    final db = await database;
    return await db.rawQuery(
      '''SELECT * FROM media_items
         WHERE latitude  BETWEEN ? AND ?
           AND longitude BETWEEN ? AND ?
         ORDER BY COALESCE(modified_timestamp, date_timestamp, rowid) DESC''',
      [cellLat - 0.05, cellLat + 0.05, cellLng - 0.05, cellLng + 0.05],
    );
  }

  Future<List<Map<String, dynamic>>> getMediaByAlbumCategory(
    String category,
  ) async {
    if (_useFallback) {
      return _fallbackDb['media_items']!
          .where((x) => (x['album_category'] as String?) == category)
          .toList();
    }
    final db = await database;
    return await db.query(
      'media_items',
      where: 'album_category = ?',
      whereArgs: [category],
      orderBy: 'COALESCE(modified_timestamp, date_timestamp, rowid) DESC',
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // PEOPLE CRUD
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> insertPerson(Map<String, dynamic> person) async {
    final personMap = Map<String, dynamic>.from(person);
    personMap.putIfAbsent('is_custom_cover', () => 0);
    if (_useFallback) {
      final existing = _fallbackDb['people']!.where((x) => x['id'] == personMap['id']).firstOrNull;
      if (existing != null && (existing['is_custom_cover'] as int? ?? 0) == 1) {
        personMap['cover_image'] = existing['cover_image'];
        personMap['cover_x'] = existing['cover_x'];
        personMap['cover_y'] = existing['cover_y'];
        personMap['cover_w'] = existing['cover_w'];
        personMap['cover_h'] = existing['cover_h'];
        personMap['is_custom_cover'] = 1;
      }
      _fallbackDb['people']!.removeWhere((x) => x['id'] == personMap['id']);
      _fallbackDb['people']!.add(personMap);
      return;
    }
    final db = await database;
    final existing = await db.query('people', where: 'id = ?', whereArgs: [personMap['id']]);
    if (existing.isNotEmpty && (existing.first['is_custom_cover'] as int? ?? 0) == 1) {
      personMap['cover_image'] = existing.first['cover_image'];
      personMap['cover_x'] = existing.first['cover_x'];
      personMap['cover_y'] = existing.first['cover_y'];
      personMap['cover_w'] = existing.first['cover_w'];
      personMap['cover_h'] = existing.first['cover_h'];
      personMap['is_custom_cover'] = 1;
    }
    await db.insert(
      'people',
      personMap,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getAllPeople() async {
    if (_useFallback) return List.from(_fallbackDb['people']!);
    final db = await database;
    return await db.query('people');
  }


  Future<List<Map<String, dynamic>>> getEligiblePeopleForUi() async {
    final prefs = await SharedPreferences.getInstance();
    final threshold = prefs.getInt('face_eligible_threshold') ?? 10;

    if (_useFallback) {
      final Map<String, int> counts = {};
      for (final f in _fallbackDb['faces']!) {
        final pid = f['person_id'] as String?;
        if (pid == null) continue;
        counts[pid] = (counts[pid] ?? 0) + 1;
      }
      final eligible = _fallbackDb['people']!
          .where((p) => (counts[p['id'] as String] ?? 0) >= threshold)
          .toList();
      eligible.sort((a, b) {
        final countA = counts[a['id']] ?? 0;
        final countB = counts[b['id']] ?? 0;
        return countB.compareTo(countA);
      });
      return eligible;
    }
    final db = await database;
    return await db.rawQuery(
      '''
      SELECT people.*, COUNT(faces.id) as face_count FROM people
      INNER JOIN faces ON faces.person_id = people.id
      GROUP BY people.id
      HAVING COUNT(faces.id) >= ?
      ORDER BY face_count DESC
      ''',
      [threshold],
    );
  }

  /// Returns up to [limit] people sorted by face count (most-photographed first).
  /// Use this for the People grid to avoid showing noise clusters.
  Future<List<Map<String, dynamic>>> getTopPeopleByFaceCount({
    int limit = 10,
  }) async {
    if (_useFallback) {
      // Count faces per person
      final Map<String, int> counts = {};
      for (final f in _fallbackDb['faces']!) {
        final pid = f['person_id'] as String?;
        if (pid == null) continue;
        counts[pid] = (counts[pid] ?? 0) + 1;
      }
      final people = List<Map<String, dynamic>>.from(_fallbackDb['people']!);
      people.sort((a, b) {
        final ca = counts[a['id'] as String] ?? 0;
        final cb = counts[b['id'] as String] ?? 0;
        return cb.compareTo(ca);
      });
      return people.take(limit).toList();
    }
    final db = await database;
    return await db.rawQuery(
      '''
      SELECT people.*,
             COUNT(faces.id) AS face_count
      FROM people
      LEFT JOIN faces ON faces.person_id = people.id
      GROUP BY people.id
      ORDER BY face_count DESC
      LIMIT ?
    ''',
      [limit],
    );
  }

  Future<Map<String, dynamic>?> getPersonById(String id) async {
    if (_useFallback) {
      final m = _fallbackDb['people']!.where((x) => x['id'] == id);
      return m.isEmpty ? null : Map<String, dynamic>.from(m.first);
    }
    final db = await database;
    final r = await db.query('people', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : r.first;
  }

  Future<void> updatePerson(
    String id,
    String name,
    String dob,
    String relation,
  ) async {
    if (_useFallback) {
      for (var p in _fallbackDb['people']!) {
        if (p['id'] == id) {
          p['name'] = name;
          p['dob'] = dob;
          p['relation'] = relation;
          break;
        }
      }
      return;
    }
    final db = await database;
    await db.update(
      'people',
      {'name': name, 'dob': dob, 'relation': relation},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updatePersonName(String id, String name) async {
    if (_useFallback) {
      for (var p in _fallbackDb['people']!) {
        if (p['id'] == id) {
          p['name'] = name;
          break;
        }
      }
      return;
    }
    final db = await database;
    await db.update('people', {'name': name}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updatePersonCover(
    String personId,
    String? imagePath,
    int x,
    int y,
    int w,
    int h, {
    bool? isCustomCover,
  }) async {
    String? oldCoverImage;
    bool hasCustomCover = false;
    if (_useFallback) {
      final p = _fallbackDb['people']!.firstWhere((x) => x['id'] == personId, orElse: () => <String, dynamic>{});
      oldCoverImage = p['cover_image'] as String?;
      hasCustomCover = (p['is_custom_cover'] as int? ?? 0) == 1 ||
          (oldCoverImage != null && oldCoverImage.contains('/profile_pictures/'));
    } else {
      final db = await database;
      final pList = await db.query('people', columns: ['cover_image', 'is_custom_cover'], where: 'id = ?', whereArgs: [personId]);
      if (pList.isNotEmpty) {
        oldCoverImage = pList.first['cover_image'] as String?;
        hasCustomCover = (pList.first['is_custom_cover'] as int? ?? 0) == 1 ||
            (oldCoverImage != null && oldCoverImage.contains('/profile_pictures/'));
      }
    }

    // Preserve custom cover against automatic background/face processing updates
    if (isCustomCover == null && hasCustomCover) {
      return;
    }

    final int customFlag = isCustomCover == true ? 1 : (isCustomCover == false ? 0 : (hasCustomCover ? 1 : 0));

    if (isCustomCover != null && oldCoverImage != null && oldCoverImage != imagePath && oldCoverImage.contains('/profile_pictures/')) {
      try {
        final file = File(oldCoverImage);
        if (file.existsSync()) {
          file.deleteSync();
        }
      } catch (e) {
        debugPrint("DatabaseHelper: Error deleting old custom profile picture: $e");
      }
    }

    if (_useFallback) {
      for (var p in _fallbackDb['people']!) {
        if (p['id'] == personId) {
          p['cover_image'] = imagePath;
          p['cover_x'] = x;
          p['cover_y'] = y;
          p['cover_w'] = w;
          p['cover_h'] = h;
          p['is_custom_cover'] = customFlag;
          break;
        }
      }
      return;
    }
    final db = await database;
    await db.update(
      'people',
      {
        'cover_image': imagePath,
        'cover_x': x,
        'cover_y': y,
        'cover_w': w,
        'cover_h': h,
        'is_custom_cover': customFlag,
      },
      where: 'id = ?',
      whereArgs: [personId],
    );
  }

  Future<void> mergePeople(
    String targetPersonId,
    List<String> sourcePersonIds,
  ) async {
    final List<String> coverImagesToDelete = [];
    if (_useFallback) {
      for (final src in sourcePersonIds) {
        final p = _fallbackDb['people']!.firstWhere((x) => x['id'] == src, orElse: () => <String, dynamic>{});
        final cov = p['cover_image'] as String?;
        if (cov != null) coverImagesToDelete.add(cov);
      }
    } else {
      final db = await database;
      for (final src in sourcePersonIds) {
        final pList = await db.query('people', columns: ['cover_image'], where: 'id = ?', whereArgs: [src]);
        if (pList.isNotEmpty) {
          final cov = pList.first['cover_image'] as String?;
          if (cov != null) coverImagesToDelete.add(cov);
        }
      }
    }

    for (final cov in coverImagesToDelete) {
      if (cov.contains('/profile_pictures/')) {
        try {
          final file = File(cov);
          if (file.existsSync()) {
            file.deleteSync();
            debugPrint("DatabaseHelper: Deleted old custom profile picture on merge: $cov");
          }
        } catch (e) {
          debugPrint("DatabaseHelper: Error deleting old custom profile picture: $e");
        }
      }
    }

    if (_useFallback) {
      for (var face in _fallbackDb['faces']!) {
        if (sourcePersonIds.contains(face['person_id'])) {
          face['person_id'] = targetPersonId;
        }
      }
      _fallbackDb['people']!.removeWhere(
        (x) => sourcePersonIds.contains(x['id']),
      );
      return;
    }
    final db = await database;
    await db.transaction((txn) async {
      for (final src in sourcePersonIds) {
        await txn.update(
          'faces',
          {'person_id': targetPersonId},
          where: 'person_id = ?',
          whereArgs: [src],
        );
        await txn.delete('people', where: 'id = ?', whereArgs: [src]);
      }
    });
  }

  Future<void> deletePerson(String personId) async {
    String? coverImageToDelete;
    if (_useFallback) {
      final p = _fallbackDb['people']!.firstWhere((x) => x['id'] == personId, orElse: () => <String, dynamic>{});
      coverImageToDelete = p['cover_image'] as String?;
    } else {
      final db = await database;
      final pList = await db.query('people', columns: ['cover_image'], where: 'id = ?', whereArgs: [personId]);
      if (pList.isNotEmpty) {
        coverImageToDelete = pList.first['cover_image'] as String?;
      }
    }

    if (coverImageToDelete != null && coverImageToDelete.contains('/profile_pictures/')) {
      try {
        final file = File(coverImageToDelete);
        if (file.existsSync()) {
          file.deleteSync();
          debugPrint("DatabaseHelper: Deleted custom profile picture on person delete: $coverImageToDelete");
        }
      } catch (e) {
        debugPrint("DatabaseHelper: Error deleting custom profile picture: $e");
      }
    }

    if (_useFallback) {
      final faces = _fallbackDb['faces']!.where((x) => x['person_id'] == personId).toList();
      for (final f in faces) {
        final mediaId = f['media_id'] as String?;
        if (mediaId != null) {
          final item = _fallbackDb['media_items']!.firstWhere((x) => x['id'] == mediaId, orElse: () => <String, dynamic>{});
          final path = item['path'] as String?;
          if (path != null) {
            await FaceCacheHelper.evictFacesForImage(path);
          }
        }
      }
      _fallbackDb['people']!.removeWhere((x) => x['id'] == personId);
      for (var face in _fallbackDb['faces']!) {
        if (face['person_id'] == personId) {
          face['person_id'] = null;
        }
      }
      return;
    }
    final db = await database;
    final faces = await db.query('faces', columns: ['media_id'], where: 'person_id = ?', whereArgs: [personId]);
    for (final f in faces) {
      final mediaId = f['media_id'] as String?;
      if (mediaId != null) {
        final item = await getMediaItemById(mediaId);
        final path = item?['path'] as String?;
        if (path != null) {
          await FaceCacheHelper.evictFacesForImage(path);
        }
      }
    }
    await db.transaction((txn) async {
      await txn.update(
        'faces',
        {'person_id': null},
        where: 'person_id = ?',
        whereArgs: [personId],
      );
      await txn.delete('people', where: 'id = ?', whereArgs: [personId]);
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FACES CRUD
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> insertFace(Map<String, dynamic> face) async {
    if (_useFallback) {
      _fallbackDb['faces']!.removeWhere((x) => x['id'] == face['id']);
      _fallbackDb['faces']!.add(face);
      return;
    }
    final db = await database;
    await db.insert(
      'faces',
      face,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getFacesForMedia(String mediaId) async {
    if (_useFallback) {
      return _fallbackDb['faces']!
          .where((x) => x['media_id'] == mediaId)
          .toList();
    }
    final db = await database;
    return await db.query('faces', where: 'media_id = ?', whereArgs: [mediaId]);
  }

  Future<List<Map<String, dynamic>>> getAllFaces() async {
    if (_useFallback) return List.from(_fallbackDb['faces']!);
    final db = await database;
    // Don't load embeddings for clustering — we only need what we use
    return await db.query('faces');
  }

  Future<List<Map<String, dynamic>>> getMediaItemsForPerson(
    String personId,
  ) async {
    if (_useFallback) {
      final ids = _fallbackDb['faces']!
          .where((f) => f['person_id'] == personId)
          .map((f) => f['media_id'] as String)
          .toSet();
      return _fallbackDb['media_items']!
          .where((m) => ids.contains(m['id']))
          .toList();
    }
    final db = await database;
    return await db.rawQuery(
      '''
      SELECT media_items.* FROM media_items
      INNER JOIN faces ON media_items.id = faces.media_id
      WHERE faces.person_id = ?
      GROUP BY media_items.id
      ORDER BY COALESCE(media_items.modified_timestamp, media_items.date_timestamp, media_items.rowid) DESC
    ''',
      [personId],
    );
  }

  Future<List<Map<String, dynamic>>> getMediaItemsWithOnlyPerson(
    String personId,
  ) async {
    if (_useFallback) {
      final ids = _fallbackDb['faces']!
          .where((f) => f['person_id'] == personId)
          .map((f) => f['media_id'] as String)
          .toSet();
      return _fallbackDb['media_items']!.where((m) {
        if (!ids.contains(m['id'])) return false;
        // Check if there are any faces for this media that belong to other people or are null
        final otherFaces = _fallbackDb['faces']!.where(
          (f) =>
              f['media_id'] == m['id'] &&
              (f['person_id'] != personId || f['person_id'] == null),
        );
        return otherFaces.isEmpty;
      }).toList();
    }
    final db = await database;
    return await db.rawQuery(
      '''
      SELECT media_items.* FROM media_items
      INNER JOIN faces ON media_items.id = faces.media_id
      WHERE faces.person_id = ?
      AND media_items.id NOT IN (
        SELECT DISTINCT media_id FROM faces WHERE person_id != ? OR person_id IS NULL
      )
      GROUP BY media_items.id
      ORDER BY COALESCE(media_items.modified_timestamp, media_items.date_timestamp, media_items.rowid) DESC
    ''',
      [personId, personId],
    );
  }

  Future<void> updateFacePersonAssociation(
    String faceId,
    String? personId,
  ) async {
    if (_useFallback) {
      for (var f in _fallbackDb['faces']!) {
        if (f['id'] == faceId) {
          f['person_id'] = personId;
          break;
        }
      }
      return;
    }
    final db = await database;
    await db.update(
      'faces',
      {'person_id': personId},
      where: 'id = ?',
      whereArgs: [faceId],
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // OCR / OBJECTS CRUD
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> insertOcrText(Map<String, dynamic> ocr) async {
    if (_useFallback) {
      _fallbackDb['ocr_texts']!.add(ocr);
      return;
    }
    final db = await database;
    await db.insert('ocr_texts', ocr);
  }

  Future<List<Map<String, dynamic>>> getOcrTextsForMedia(String mediaId) async {
    if (_useFallback) {
      return _fallbackDb['ocr_texts']!
          .where((x) => x['media_id'] == mediaId)
          .toList();
    }
    final db = await database;
    return await db.query(
      'ocr_texts',
      where: 'media_id = ?',
      whereArgs: [mediaId],
    );
  }

  Future<void> insertObject(Map<String, dynamic> obj) async {
    if (_useFallback) {
      _fallbackDb['objects']!.add(obj);
      return;
    }
    final db = await database;
    await db.insert('objects', obj);
  }

  Future<List<Map<String, dynamic>>> getObjectsForMedia(String mediaId) async {
    if (_useFallback) {
      return _fallbackDb['objects']!
          .where((x) => x['media_id'] == mediaId)
          .toList();
    }
    final db = await database;
    return await db.query(
      'objects',
      where: 'media_id = ?',
      whereArgs: [mediaId],
    );
  }

  Future<List<Map<String, dynamic>>> getAllOcrTexts() async {
    if (_useFallback) return List.from(_fallbackDb['ocr_texts']!);
    final db = await database;
    return await db.query('ocr_texts');
  }

  Future<List<Map<String, dynamic>>> getAllObjects() async {
    if (_useFallback) return List.from(_fallbackDb['objects']!);
    final db = await database;
    return await db.query('objects');
  }

  Future<List<Map<String, dynamic>>> getTopTags({int limit = 5}) async {
    if (_useFallback) {
      final Map<String, List<String>> tagMap = {};
      for (final obj in _fallbackDb['objects']!) {
        final label = obj['label'] as String? ?? '';
        final mediaId = obj['media_id'] as String? ?? '';
        if (label.isNotEmpty && mediaId.isNotEmpty) {
          tagMap.putIfAbsent(label, () => []).add(mediaId);
        }
      }
      final List<Map<String, dynamic>> list = tagMap.entries.map((entry) {
        return {
          'label': entry.key,
          'count': entry.value.length,
          'media_ids': entry.value,
        };
      }).toList();
      list.sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));
      return list.take(limit).toList();
    }
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT label, COUNT(*) as count, GROUP_CONCAT(media_id) as media_ids
      FROM objects
      GROUP BY label
      ORDER BY count DESC
      LIMIT ?
    ''',
      [limit],
    );
    return rows.map((r) {
      final idsStr = r['media_ids'] as String? ?? '';
      final ids = idsStr.split(',').where((s) => s.isNotEmpty).toList();
      return {
        'label': r['label'] as String,
        'count': r['count'] as int,
        'media_ids': ids,
      };
    }).toList();
  }

  Future<List<String>> getDocumentMediaIds() async {
    final Set<String> ids = {};
    if (_useFallback) {
      for (final obj in _fallbackDb['objects']!) {
        final label = (obj['label'] as String? ?? '').toLowerCase();
        if (label.contains('document') ||
            label.contains('paper') ||
            label.contains('receipt') ||
            label.contains('invoice') ||
            label.contains('sheet') ||
            label.contains('page') ||
            label.contains('text') ||
            label.contains('book')) {
          ids.add(obj['media_id'] as String);
        }
      }
      for (final ocr in _fallbackDb['ocr_texts']!) {
        final txt = (ocr['text'] as String? ?? '').toLowerCase();
        if (txt.contains('document') ||
            txt.contains('paper') ||
            txt.contains('receipt') ||
            txt.contains('invoice') ||
            txt.contains('sheet') ||
            txt.contains('page') ||
            txt.contains('text')) {
          ids.add(ocr['media_id'] as String);
        }
      }
      return ids.toList();
    }

    final db = await database;
    final objRows = await db.rawQuery('''
      SELECT DISTINCT media_id FROM objects 
      WHERE LOWER(label) LIKE '%document%' 
         OR LOWER(label) LIKE '%paper%' 
         OR LOWER(label) LIKE '%receipt%' 
         OR LOWER(label) LIKE '%invoice%'
         OR LOWER(label) LIKE '%sheet%'
         OR LOWER(label) LIKE '%page%'
         OR LOWER(label) LIKE '%text%'
         OR LOWER(label) LIKE '%book%'
    ''');
    for (final r in objRows) {
      ids.add(r['media_id'] as String);
    }

    // final ocrRows = await db.rawQuery('''
    //   SELECT DISTINCT media_id FROM ocr_texts
    //   WHERE LOWER(text) LIKE '%document%'
    //      OR LOWER(text) LIKE '%paper%'
    //      OR LOWER(text) LIKE '%receipt%'
    //      OR LOWER(text) LIKE '%invoice%'
    //      OR LOWER(text) LIKE '%sheet%'
    //      OR LOWER(text) LIKE '%page%'
    //      OR LOWER(text) LIKE '%text%'
    // ''');
    // for (final r in ocrRows) {
    //   ids.add(r['media_id'] as String);
    // }

    return ids.toList();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ADVANCED SEARCH  ← fixed: off-thread, bulk-join, 200-item cap
  //
  // Old code did O(n × 3) async DB calls on the main thread.
  // New code:
  //   1. Bulk-loads all secondary tables once.
  //   2. Builds in-memory maps for O(1) lookup per item.
  //   3. Runs entirely in compute() so UI never freezes.
  //   4. Returns max 200 results.
  // ══════════════════════════════════════════════════════════════════════════

  Future<List<Map<String, dynamic>>> searchMedia({
    required String query,
    String? personId,
    String? location,
    String? date,
    String? mediaType,
    double? minDuration,
    double? maxDuration,
  }) async {
    // Bulk-load everything we need, then hand off to isolate
    final allItems = await getAllMediaItems();
    final allOcr = await getAllOcrTexts();
    final allTags = await getAllObjects();
    final allFaces = await getAllFaces();

    // Package into plain-data maps (isolates can't pass complex objects)
    final args = _SearchArgs(
      items: allItems,
      ocr: allOcr,
      tags: allTags,
      faces: allFaces,
      query: query,
      personId: personId,
      location: location,
      date: date,
      mediaType: mediaType,
      minDuration: minDuration,
      maxDuration: maxDuration,
    );

    return await compute(_searchIsolateEntry, args);
  }

  static List<Map<String, dynamic>> _searchIsolateEntry(_SearchArgs args) {
    // Build lookup maps
    final Map<String, List<String>> ocrByMedia = {};
    final Map<String, List<String>> tagsByMedia = {};
    final Map<String, List<String>> personsByMedia = {};

    for (final o in args.ocr) {
      ocrByMedia
          .putIfAbsent(o['media_id'] as String, () => [])
          .add((o['text'] as String).toLowerCase());
    }
    for (final t in args.tags) {
      tagsByMedia
          .putIfAbsent(t['media_id'] as String, () => [])
          .add((t['label'] as String).toLowerCase());
    }
    for (final f in args.faces) {
      final pid = f['person_id'] as String?;
      if (pid != null) {
        personsByMedia.putIfAbsent(f['media_id'] as String, () => []).add(pid);
      }
    }

    final String q = args.query.toLowerCase().trim();
    final results = <Map<String, dynamic>>[];
    const int maxResults = 200;

    for (final item in args.items) {
      if (results.length >= maxResults) break;

      final String itemId = item['id'] as String;

      // ── Text query match ─────────────────────────────────────────────────
      if (q.isNotEmpty) {
        final pathLower = (item['path'] as String).toLowerCase();
        final locLower = ((item['location'] as String?) ?? '').toLowerCase();
        final camLower = ((item['camera_info'] as String?) ?? '').toLowerCase();

        final ocrMatch = (ocrByMedia[itemId] ?? []).any((t) => t.contains(q));
        final tagMatch = (tagsByMedia[itemId] ?? []).any((t) => t.contains(q));

        if (!pathLower.contains(q) &&
            !locLower.contains(q) &&
            !camLower.contains(q) &&
            !ocrMatch &&
            !tagMatch) {
          continue;
        }
      }

      // ── Person filter ────────────────────────────────────────────────────
      if (args.personId != null) {
        if (!(personsByMedia[itemId] ?? []).contains(args.personId)) continue;
      }

      // ── Location filter ──────────────────────────────────────────────────
      if (args.location != null && args.location!.isNotEmpty) {
        final loc = ((item['location'] as String?) ?? '').toLowerCase();
        if (!loc.contains(args.location!.toLowerCase())) continue;
      }

      // ── Date filter ──────────────────────────────────────────────────────
      if (args.date != null && args.date!.isNotEmpty) {
        final d = ((item['date'] as String?) ?? '').toLowerCase();
        if (!d.contains(args.date!.toLowerCase())) continue;
      }

      // ── Media type filter ────────────────────────────────────────────────
      if (args.mediaType != null && args.mediaType!.isNotEmpty) {
        if (item['media_type'] != args.mediaType) continue;
      }

      // ── Duration filter ──────────────────────────────────────────────────
      if (item['media_type'] == 'video') {
        final dur = (item['duration'] as double?) ?? 0.0;
        if (args.minDuration != null && dur < args.minDuration!) continue;
        if (args.maxDuration != null && dur > args.maxDuration!) continue;
      } else if (args.mediaType == 'video') {
        continue;
      }

      results.add(item);
    }

    return results;
  }

  Future<int> countTotalMediaItems() async {
    if (_useFallback) {
      return _fallbackDb['media_items']?.length ?? 0;
    }
    try {
      final db = await database;
      final res = await db.rawQuery('SELECT COUNT(*) as cnt FROM media_items');
      return res.first['cnt'] as int? ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> clearDatabase() async {
    if (_useFallback) {
      for (final tbl in _fallbackDb.values) {
        tbl.clear();
      }
      return;
    }
    final db = await database;
    for (final tbl in [
      'media_items',
      'people',
      'faces',
      'ocr_texts',
      'objects',
    ]) {
      await db.delete(tbl);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // XMP / TAGS SEARCH — search by xmp_subjects field
  // ══════════════════════════════════════════════════════════════════════════

  Future<List<Map<String, dynamic>>> getMediaByXmpSubject(
    String subject,
  ) async {
    if (_useFallback) {
      final q = subject.toLowerCase();
      return _fallbackDb['media_items']!
          .where(
            (x) =>
                (x['xmp_subjects'] as String? ?? '').toLowerCase().contains(q),
          )
          .toList();
    }
    final db = await database;
    return await db.query(
      'media_items',
      where: "xmp_subjects LIKE ?",
      whereArgs: ['%$subject%'],
      orderBy: 'COALESCE(date_timestamp, rowid) DESC',
    );
  }

  /// Returns all distinct XMP subject tags across the library.
  Future<List<String>> getAllXmpSubjects() async {
    if (_useFallback) {
      final Set<String> tags = {};
      for (final item in _fallbackDb['media_items']!) {
        final s = item['xmp_subjects'] as String? ?? '';
        tags.addAll(s.split(';').where((t) => t.isNotEmpty));
      }
      return tags.toList()..sort();
    }
    final db = await database;
    final rows = await db.rawQuery(
      "SELECT DISTINCT xmp_subjects FROM media_items WHERE xmp_subjects IS NOT NULL AND xmp_subjects != ''",
    );
    final Set<String> tags = {};
    for (final row in rows) {
      final s = row['xmp_subjects'] as String? ?? '';
      tags.addAll(s.split(';').where((t) => t.isNotEmpty));
    }
    return tags.toList()..sort();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // RECOMMEND GROUPS CRUD
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> insertRecommendGroup(RecommendGroup group) async {
    if (_useFallback) {
      _fallbackDb['recommend_groups']!.removeWhere((g) => g['id'] == group.id);
      _fallbackDb['recommend_groups']!.add({
        'id': group.id,
        'type': group.type.name,
        'title': group.title,
        'subtitle': group.subtitle,
        'generated_at': group.generatedAt.millisecondsSinceEpoch,
        'expires_at': group.expiresAt.millisecondsSinceEpoch,
      });

      _fallbackDb['recommend_items']!.removeWhere(
        (i) => i['group_id'] == group.id,
      );
      for (final item in group.items) {
        _fallbackDb['recommend_items']!.add({
          'id': item.id,
          'group_id': group.id,
          'item_type': item.itemType.name,
          'source_item_id': item.sourceItemId,
          'source_item_path': item.sourceItemPath,
          'origin_album_name': item.originAlbumName,
          'generated_file_path': item.generatedFilePath,
          'text_overlay': item.textOverlay,
        });
      }
      return;
    }

    final db = await database;
    await db.transaction((txn) async {
      await txn.insert('recommend_groups', {
        'id': group.id,
        'type': group.type.name,
        'title': group.title,
        'subtitle': group.subtitle,
        'generated_at': group.generatedAt.millisecondsSinceEpoch,
        'expires_at': group.expiresAt.millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      await txn.delete(
        'recommend_items',
        where: 'group_id = ?',
        whereArgs: [group.id],
      );

      for (final item in group.items) {
        await txn.insert('recommend_items', {
          'id': item.id,
          'group_id': group.id,
          'item_type': item.itemType.name,
          'source_item_id': item.sourceItemId,
          'source_item_path': item.sourceItemPath,
          'origin_album_name': item.originAlbumName,
          'generated_file_path': item.generatedFilePath,
          'text_overlay': item.textOverlay,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<List<RecommendGroup>> getRecommendGroups() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_useFallback) {
      final groupsRaw = _fallbackDb['recommend_groups']!
          .where((g) => (g['expires_at'] as int) > nowMs)
          .toList();

      final List<RecommendGroup> groups = [];
      for (final g in groupsRaw) {
        final groupId = g['id'] as String;
        final itemsRaw = _fallbackDb['recommend_items']!
            .where((i) => i['group_id'] == groupId)
            .toList();

        final items = itemsRaw.map((i) {
          return RecommendItem(
            id: i['id'] as String,
            itemType: RecommendItemType.values.firstWhere(
              (e) => e.name == i['item_type'],
              orElse: () => RecommendItemType.libraryMedia,
            ),
            sourceItemId: i['source_item_id'] as String?,
            sourceItemPath: i['source_item_path'] as String?,
            originAlbumName: i['origin_album_name'] as String?,
            generatedFilePath: i['generated_file_path'] as String?,
            textOverlay: i['text_overlay'] as String?,
          );
        }).toList();

        groups.add(
          RecommendGroup(
            id: groupId,
            type: RecommendType.values.firstWhere(
              (e) => e.name == g['type'],
              orElse: () => RecommendType.onThisDay,
            ),
            title: g['title'] as String,
            subtitle: g['subtitle'] as String,
            generatedAt: DateTime.fromMillisecondsSinceEpoch(
              g['generated_at'] as int,
            ),
            expiresAt: DateTime.fromMillisecondsSinceEpoch(
              g['expires_at'] as int,
            ),
            items: items,
          ),
        );
      }
      return groups;
    }

    final db = await database;
    try {
      final groupRows = await db.query(
        'recommend_groups',
        where: 'expires_at > ?',
        whereArgs: [nowMs],
      );

      final List<RecommendGroup> groups = [];
      for (final g in groupRows) {
        final groupId = g['id'] as String;
        final itemRows = await db.query(
          'recommend_items',
          where: 'group_id = ?',
          whereArgs: [groupId],
        );

        final items = itemRows.map((i) {
          return RecommendItem(
            id: i['id'] as String,
            itemType: RecommendItemType.values.firstWhere(
              (e) => e.name == i['item_type'],
              orElse: () => RecommendItemType.libraryMedia,
            ),
            sourceItemId: i['source_item_id'] as String?,
            sourceItemPath: i['source_item_path'] as String?,
            originAlbumName: i['origin_album_name'] as String?,
            generatedFilePath: i['generated_file_path'] as String?,
            textOverlay: i['text_overlay'] as String?,
          );
        }).toList();

        groups.add(
          RecommendGroup(
            id: groupId,
            type: RecommendType.values.firstWhere(
              (e) => e.name == g['type'],
              orElse: () => RecommendType.onThisDay,
            ),
            title: g['title'] as String,
            subtitle: g['subtitle'] as String,
            generatedAt: DateTime.fromMillisecondsSinceEpoch(
              g['generated_at'] as int,
            ),
            expiresAt: DateTime.fromMillisecondsSinceEpoch(
              g['expires_at'] as int,
            ),
            items: items,
          ),
        );
      }
      return groups;
    } catch (e) {
      debugPrint("DatabaseHelper: getRecommendGroups error: $e");
      return [];
    }
  }

  Future<void> deleteRecommendGroup(String groupId) async {
    if (_useFallback) {
      _fallbackDb['recommend_groups']!.removeWhere((g) => g['id'] == groupId);
      _fallbackDb['recommend_items']!.removeWhere(
        (i) => i['group_id'] == groupId,
      );
      return;
    }
    final db = await database;
    try {
      final appDocs = await getApplicationDocumentsDirectory();
      final dir = Directory('${appDocs.path}/ghost_recommends/$groupId');
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        debugPrint('DatabaseHelper: Deleted recommend group directory: ${dir.path}');
      }
    } catch (_) {}
    await db.transaction((txn) async {
      await txn.delete(
        'recommend_items',
        where: 'group_id = ?',
        whereArgs: [groupId],
      );
      await txn.delete(
        'recommend_groups',
        where: 'id = ?',
        whereArgs: [groupId],
      );
    });
  }

  Future<void> clearExpiredRecommendGroups() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_useFallback) {
      final expiredIds = _fallbackDb['recommend_groups']!
          .where((g) => (g['expires_at'] as int) <= nowMs)
          .map((g) => g['id'] as String)
          .toSet();

      // Delete physical directories
      final appDocs = await getApplicationDocumentsDirectory();
      for (final id in expiredIds) {
        final dir = Directory('${appDocs.path}/ghost_recommends/$id');
        if (await dir.exists()) {
          try {
            await dir.delete(recursive: true);
          } catch (_) {}
        }
      }

      _fallbackDb['recommend_groups']!.removeWhere(
        (g) => expiredIds.contains(g['id']),
      );
      _fallbackDb['recommend_items']!.removeWhere(
        (i) => expiredIds.contains(i['group_id']),
      );
      return;
    }
    final db = await database;
    try {
      final expired = await db.query(
        'recommend_groups',
        columns: ['id'],
        where: 'expires_at <= ?',
        whereArgs: [nowMs],
      );
      if (expired.isNotEmpty) {
        final expiredIds = expired.map((e) => e['id'] as String).toList();

        // Retrieve and delete physical directories from disk
        final appDocs = await getApplicationDocumentsDirectory();
        for (final id in expiredIds) {
          final dir = Directory('${appDocs.path}/ghost_recommends/$id');
          if (await dir.exists()) {
            try {
              await dir.delete(recursive: true);
              debugPrint('DatabaseHelper: Deleted expired recommend directory: ${dir.path}');
            } catch (e) {
              debugPrint('DatabaseHelper: Error deleting expired recommend directory: $e');
            }
          }
        }

        // Individual file delete fallback
        final List<Map<String, dynamic>> items = await db.query(
          'recommend_items',
          columns: ['generated_file_path'],
          where: 'group_id IN (${expiredIds.map((_) => '?').join(',')})',
          whereArgs: expiredIds,
        );
        for (final item in items) {
          final path = item['generated_file_path'] as String?;
          if (path != null && path.isNotEmpty) {
            try {
              final file = File(path);
              if (await file.exists()) {
                await file.delete();
              }
            } catch (_) {}
          }
        }

        await db.transaction((txn) async {
          for (final id in expiredIds) {
            await txn.delete(
              'recommend_items',
              where: 'group_id = ?',
              whereArgs: [id],
            );
            await txn.delete(
              'recommend_groups',
              where: 'id = ?',
              whereArgs: [id],
            );
          }
        });
      }
    } catch (e) {
      debugPrint("DatabaseHelper: clearExpiredRecommendGroups error: $e");
    }
  }

  Future<void> clearAllRecommendGroups() async {
    if (_useFallback) {
      _fallbackDb['recommend_groups']!.clear();
      _fallbackDb['recommend_items']!.clear();
      return;
    }
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('recommend_items');
      await txn.delete('recommend_groups');
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // RECOMMEND GENERATION STATUS CRUD
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> setGenerationStatus(
    String status,
    double progress,
    String? message, {
    int? durationSeconds,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final expires = now + (durationSeconds ?? 300) * 1000;

    if (_useFallback) {
      _fallbackDb['recommend_generation_status']!.removeWhere(
        (x) => x['id'] == 'current_job',
      );
      _fallbackDb['recommend_generation_status']!.add({
        'id': 'current_job',
        'status': status,
        'progress': progress,
        'message': message ?? '',
        'started_at': now,
        'expires_at': expires,
      });
      return;
    }

    final db = await database;
    await db.insert('recommend_generation_status', {
      'id': 'current_job',
      'status': status,
      'progress': progress,
      'message': message ?? '',
      'started_at': now,
      'expires_at': expires,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> getGenerationStatus() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_useFallback) {
      final list = _fallbackDb['recommend_generation_status']!;
      if (list.isEmpty) return null;
      final job = list.first;
      if (job['expires_at'] as int <= now) {
        list.clear();
        return null;
      }
      return job;
    }

    final db = await database;
    try {
      final rows = await db.query(
        'recommend_generation_status',
        where: 'id = ?',
        whereArgs: ['current_job'],
      );
      if (rows.isEmpty) return null;
      final job = rows.first;
      if (job['expires_at'] as int <= now) {
        await db.delete(
          'recommend_generation_status',
          where: 'id = ?',
          whereArgs: ['current_job'],
        );
        return null;
      }
      return job;
    } catch (e) {
      debugPrint("DatabaseHelper: getGenerationStatus error: $e");
      return null;
    }
  }

  Future<void> clearGenerationStatus() async {
    if (_useFallback) {
      _fallbackDb['recommend_generation_status']!.clear();
      return;
    }
    final db = await database;
    try {
      await db.delete('recommend_generation_status');
    } catch (_) {}
  }
}

// ══════════════════════════════════════════════════════════════════════════
// SEARCH ARGS (serialisable across isolate boundary)
// ══════════════════════════════════════════════════════════════════════════

class _SearchArgs {
  final List<Map<String, dynamic>> items;
  final List<Map<String, dynamic>> ocr;
  final List<Map<String, dynamic>> tags;
  final List<Map<String, dynamic>> faces;
  final String query;
  final String? personId;
  final String? location;
  final String? date;
  final String? mediaType;
  final double? minDuration;
  final double? maxDuration;

  const _SearchArgs({
    required this.items,
    required this.ocr,
    required this.tags,
    required this.faces,
    required this.query,
    this.personId,
    this.location,
    this.date,
    this.mediaType,
    this.minDuration,
    this.maxDuration,
  });
}
