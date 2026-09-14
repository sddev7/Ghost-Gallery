// ═══════════════════════════════════════════════════════════════════════════
// thumbnail_cache_service.dart
//
// Aves-style two-stage image loading for Ghost Gallery:
//   Stage 1 (fast):  Low-res thumbnail — from disk cache or generated on demand.
//                    Never decodes the full original; uses the native
//                    channel's getThumbnail on Android/iOS, or
//                    video_thumbnail for videos.
//   Stage 2 (zoom):  Full resolution — only loaded when the viewer is open
//                    and the user zooms in.
//
// Thumbnail cache strategy:
//   • In-memory LRU: up to 200 entries (evicts oldest when full)
//   • Disk cache dir: <appCacheDir>/gh_thumbs/
//   • Key:       SHA1-like hash of "id_WxH" → filename "{hash}.jpg"
//   • Max files: 1500 (LRU eviction: delete oldest by modified date)
//   • Thread:    All thumbnail generation runs in a separate Isolate to keep
//                the UI at 60 fps during fast scroll.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:video_thumbnail/video_thumbnail.dart' as vt;

class ThumbnailCacheService {
  ThumbnailCacheService._();
  static final ThumbnailCacheService instance = ThumbnailCacheService._();

  // ── Config ─────────────────────────────────────────────────────────────────
  static const int _thumbWidth    = 512;
  static const int _thumbHeight   = 512;
  static const int _thumbQuality  = 85;
  static const int _maxCacheFiles = 1500;   // disk limit (reduced from 4000)
  static const int _maxMemEntries = 200;    // in-memory LRU limit

  Directory? _cacheDir;

  // ── In-memory LRU cache (LinkedHashMap preserves insertion order) ──────────
  final LinkedHashMap<String, Uint8List> _memCache =
      LinkedHashMap<String, Uint8List>();

  // ── Init ───────────────────────────────────────────────────────────────────
  Future<Directory> _getThumbDir() async {
    _cacheDir ??= await () async {
      final base = await getApplicationCacheDirectory();
      final dir  = Directory(p.join(base.path, 'gh_thumbs'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    }();
    return _cacheDir!;
  }

  // ── Cache key ──────────────────────────────────────────────────────────────
  String _cacheKey(String id) {
    final hash = '${id.hashCode.abs().toRadixString(36)}_${id.length.toRadixString(36)}';
    return '$hash.jpg';
  }

  // ── In-memory LRU helpers ──────────────────────────────────────────────────
  Uint8List? _memGet(String key) {
    final val = _memCache.remove(key); // remove + re-insert = promote to MRU
    if (val != null) _memCache[key] = val;
    return val;
  }

  void _memPut(String key, Uint8List bytes) {
    _memCache.remove(key); // ensure no duplicate
    if (_memCache.length >= _maxMemEntries) {
      // Evict oldest (first) entry
      _memCache.remove(_memCache.keys.first);
    }
    _memCache[key] = bytes;
  }

  // ── Public: synchronous memory cache lookup ───────────────────────────────
  Uint8List? getFromMemoryCache(String assetId) {
    final memKey = _cacheKey('${assetId}_${_thumbWidth}x$_thumbHeight');
    return _memGet(memKey);
  }

  // ── Public: get thumbnail bytes (from memory → disk → generate) ────────────
  Future<Uint8List?> getThumbnail({
    required String assetId,
    required String filePath,
    bool isVideo = false,
  }) async {
    try {
      final memKey = _cacheKey('${assetId}_${_thumbWidth}x$_thumbHeight');

      // ── Memory hit ───────────────────────────────────────────────────────
      final memHit = _memGet(memKey);
      if (memHit != null) return memHit;

      final dir  = await _getThumbDir();
      final file = File(p.join(dir.path, memKey));

      // ── Disk hit ─────────────────────────────────────────────────────────
      if (file.existsSync()) {
        file.setLastModifiedSync(DateTime.now());
        final bytes = file.readAsBytesSync();
        _memPut(memKey, bytes);
        return bytes;
      }

      // ── Cache miss: generate thumbnail ───────────────────────────────────
      final bytes = await _generateThumbnail(
        assetId:  assetId,
        filePath: filePath,
        isVideo:  isVideo,
      );

      if (bytes != null && bytes.isNotEmpty) {
        _memPut(memKey, bytes);
        await compute(_writeThumbnailIsolate, _ThumbWriteArgs(file.path, bytes));
        _evictIfNeeded(dir);
      }
      return bytes;
    } catch (e) {
      debugPrint('ThumbnailCacheService: error for $assetId → $e');
      return null;
    }
  }

  // ── Generation ─────────────────────────────────────────────────────────────
  Future<Uint8List?> _generateThumbnail({
    required String assetId,
    required String filePath,
    required bool isVideo,
  }) async {
    // ── Mobile: use native getThumbnail (fastest, hardware-decoded)
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      try {
        final bytes = await const MethodChannel(
          'in.sddev.ghost_gallery/media_manager',
        ).invokeMethod<Uint8List>(
          'getThumbnail',
          {
            'id': assetId,
            'isVideo': isVideo,
            'width': _thumbWidth,
            'height': _thumbHeight,
            'quality': _thumbQuality,
          },
        );
        if (bytes != null && bytes.isNotEmpty) return bytes;
      } catch (e) {
        debugPrint('ThumbnailCacheService: native getThumbnail failed for $assetId → $e');
      }
    }

    // ── Video fallback ────────────────────────────────────────────────────
    if (isVideo && filePath.isNotEmpty && !filePath.startsWith('http')) {
      try {
        final bytes = await vt.VideoThumbnail.thumbnailData(
          video:    filePath,
          imageFormat: vt.ImageFormat.JPEG,
          maxWidth: _thumbWidth,
          quality:  _thumbQuality,
        );
        if (bytes != null && bytes.isNotEmpty) return bytes;
      } catch (_) {}
    }

    return null;
  }

  // ── LRU eviction (disk) ────────────────────────────────────────────────────
  void _evictIfNeeded(Directory dir) async {
    try {
      final files = dir.listSync().whereType<File>().toList();
      if (files.length <= _maxCacheFiles) return;
      files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      final toDelete = files.take(files.length - _maxCacheFiles);
      for (final f in toDelete) {
        try { f.deleteSync(); } catch (_) {}
      }
    } catch (_) {}
  }

  // ── Public: invalidate single item ─────────────────────────────────────────
  Future<void> evict(String assetId) async {
    try {
      final key = _cacheKey('${assetId}_${_thumbWidth}x$_thumbHeight');
      _memCache.remove(key);
      final dir  = await _getThumbDir();
      final file = File(p.join(dir.path, key));
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  // ── Public: clear all ──────────────────────────────────────────────────────
  Future<void> clearAll() async {
    _memCache.clear();
    try {
      final dir = await _getThumbDir();
      if (dir.existsSync()) {
        for (final f in dir.listSync().whereType<File>()) {
          try { f.deleteSync(); } catch (_) {}
        }
      }
    } catch (_) {}
  }

  // ── Public: cache size ─────────────────────────────────────────────────────
  Future<String> getCacheSizeString() async {
    try {
      final dir   = await _getThumbDir();
      final files = dir.listSync().whereType<File>().toList();
      final total = files.fold<int>(0, (s, f) => s + f.lengthSync());
      if (total < 1024 * 1024) return '${(total / 1024).toStringAsFixed(1)} KB';
      return '${(total / (1024 * 1024)).toStringAsFixed(1)} MB';
    } catch (_) {
      return '0 KB';
    }
  }

  // ── Isolate helpers ────────────────────────────────────────────────────────
  static void _writeThumbnailIsolate(_ThumbWriteArgs args) {
    try { File(args.path).writeAsBytesSync(args.bytes); } catch (_) {}
  }
}

// ── Isolate argument wrappers ─────────────────────────────────────────────────
class _ThumbWriteArgs {
  final String path;
  final Uint8List bytes;
  _ThumbWriteArgs(this.path, this.bytes);
}
