// ═══════════════════════════════════════════════════════════════════════════
// media_metadata_service.dart
//
// On-demand rich metadata loader — used by the photo viewer to display
// detailed EXIF / XMP information without blocking the grid.
//
// For scanner-time (eager) extraction see device_media_scanner.dart which
// calls _ExifExtractor directly and batch-commits results to the DB.
//
// This service is for the VIEWER — loads any missing EXIF lazily when the
// user opens a photo and taps the details panel.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:io';
import 'dart:typed_data';
import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';
import 'database_helper.dart';
import 'trash_persistence.dart';

// ── Parsed camera settings ────────────────────────────────────────────────────

class CameraSettings {
  final double? aperture; // f-number e.g. 1.8
  final int? iso; // ISO speed
  final double? focalLength; // mm e.g. 26.0
  final String? exposureTime; // "1/250" or "1/30"
  final int? flash; // EXIF Flash integer
  final String? whiteBalance; // "Auto" / "Manual"
  final String? meteringMode; // "Center-weighted" / "Spot" etc.
  final String? sceneCaptureType; // "Standard" / "Night"

  const CameraSettings({
    this.aperture,
    this.iso,
    this.focalLength,
    this.exposureTime,
    this.flash,
    this.whiteBalance,
    this.meteringMode,
    this.sceneCaptureType,
  });

  String? get apertureDisplay =>
      aperture != null ? 'f/${aperture!.toStringAsFixed(1)}' : null;
  String? get focalLengthDisplay =>
      focalLength != null ? '${focalLength!.toStringAsFixed(0)}mm' : null;
  String? get isoDisplay => iso != null ? 'ISO $iso' : null;
  String? get flashDisplay => flash != null
      ? ((flash! & 0x01) != 0 ? 'Flash Fired' : 'No Flash')
      : null;

  bool get hasData =>
      aperture != null ||
      iso != null ||
      focalLength != null ||
      exposureTime != null;
}

class PanoramaInfo {
  final bool usePanoramaViewer;
  final int? croppedAreaLeft;
  final int? croppedAreaTop;
  final int? croppedAreaWidth;
  final int? croppedAreaHeight;
  final int? fullPanoWidthPixels;
  final int? fullPanoHeightPixels;
  final double? initialViewHeadingDegrees;
  final double? initialViewPitchDegrees;

  const PanoramaInfo({
    required this.usePanoramaViewer,
    this.croppedAreaLeft,
    this.croppedAreaTop,
    this.croppedAreaWidth,
    this.croppedAreaHeight,
    this.fullPanoWidthPixels,
    this.fullPanoHeightPixels,
    this.initialViewHeadingDegrees,
    this.initialViewPitchDegrees,
  });

  bool get is360 =>
      fullPanoWidthPixels != null &&
      fullPanoHeightPixels != null &&
      (fullPanoWidthPixels! / (fullPanoHeightPixels ?? 1)) >= 1.9;
}

// ── Service ───────────────────────────────────────────────────────────────────

class MediaMetadataService {
  MediaMetadataService._();
  static final MediaMetadataService instance = MediaMetadataService._();

  // Session cache: filePath → parsed result
  final Map<String, CameraSettings> _settingsCache = {};
  final Map<String, Map<String, dynamic>> _rawExifCache = {};

  // ── Camera Settings ────────────────────────────────────────────────────────

  /// Returns camera settings for [path]. Result is cached in-session.
  Future<CameraSettings> getCameraSettings(String path) async {
    if (_settingsCache.containsKey(path)) return _settingsCache[path]!;
    final exif = await _readExif(path);
    final s = ExifExtractor.parseCameraSettings(exif);
    _settingsCache[path] = s;
    return s;
  }

  // ── Raw EXIF ───────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> getFullExif(String path) async {
    if (_rawExifCache.containsKey(path)) return _rawExifCache[path]!;
    final tags = await _readExif(path);
    final map = tags.map((k, v) => MapEntry(k, v.printable));
    _rawExifCache[path] = map;
    return map;
  }

  // ── XMP Subjects / Tags ────────────────────────────────────────────────────

  Future<List<String>> getXmpSubjects(String path) async {
    final exif = await _readExif(path);
    return ExifExtractor.parseXmpSubjects(exif);
  }

  // ── XMP Rating ────────────────────────────────────────────────────────────

  Future<int> getRating(String path) async {
    final exif = await _readExif(path);
    return ExifExtractor.parseRating(exif);
  }

  // ── Panorama Info ──────────────────────────────────────────────────────────

  Future<PanoramaInfo?> getPanoramaInfo(String path) async {
    final exif = await _readExif(path);
    return ExifExtractor.parsePanoramaInfo(exif);
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  Future<Map<String, IfdTag>> _readExif(String path) async {
    if (path.isEmpty || path.startsWith('http')) return {};
    try {
      final file = File(path);
      if (!file.existsSync()) return {};
      
      Uint8List? bytes;
      if (Platform.isAndroid) {
        final item = await DatabaseHelper.instance.getMediaItemByPath(path);
        if (item != null) {
          bytes = await TrashPersistence.getMediaBytes(
            mediaId: item['id'] as String,
            filePath: path,
          );
        }
      }
      bytes ??= await file.readAsBytes();
      return await readExifFromBytes(bytes);
    } catch (e) {
      debugPrint('MediaMetadataService._readExif error ($path): $e');
      return {};
    }
  }

  void clearCache() {
    _settingsCache.clear();
    _rawExifCache.clear();
  }
}

// ── EXIF parsing utilities (also used by scanner) ─────────────────────────────

class ExifExtractor {
  ExifExtractor._();

  // ── Camera settings ────────────────────────────────────────────────────────
  static CameraSettings parseCameraSettings(Map<String, IfdTag> tags) {
    return CameraSettings(
      aperture: _rational(tags['EXIF FNumber']),
      iso: _int(tags['EXIF ISOSpeedRatings']),
      focalLength: _rational(tags['EXIF FocalLength']),
      exposureTime: _exposureString(tags['EXIF ExposureTime']),
      flash: _int(tags['EXIF Flash']),
      whiteBalance: _whiteBalance(tags['EXIF WhiteBalance']),
      meteringMode: _meteringMode(tags['EXIF MeteringMode']),
      sceneCaptureType: _sceneCaptureType(tags['EXIF SceneCaptureType']),
    );
  }

  // ── GPS ────────────────────────────────────────────────────────────────────
  static double? parseGpsLatitude(Map<String, IfdTag> tags) {
    return _gpsToDecimal(tags['GPS GPSLatitude'], tags['GPS GPSLatitudeRef']);
  }

  static double? parseGpsLongitude(Map<String, IfdTag> tags) {
    return _gpsToDecimal(tags['GPS GPSLongitude'], tags['GPS GPSLongitudeRef']);
  }

  // ── Orientation ────────────────────────────────────────────────────────────
  static int parseRotationDegrees(Map<String, IfdTag> tags) {
    final v = _int(tags['Image Orientation']) ?? 1;
    switch (v) {
      case 3:
        return 180;
      case 6:
        return 90;
      case 8:
        return 270;
      default:
        return 0;
    }
  }

  static bool parseIsFlipped(Map<String, IfdTag> tags) {
    final v = _int(tags['Image Orientation']) ?? 1;
    return [2, 4, 5, 7].contains(v);
  }

  // ── MIME from extension or EXIF ───────────────────────────────────────────
  static String? parseMimeType(Map<String, IfdTag> tags, String path) {
    // Try from EXIF Make / Model / File FileType (rarely present, but check)
    final ext = path.split('.').last.toLowerCase();
    const map = {
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'heic': 'image/heic',
      'heif': 'image/heif',
      'tif': 'image/tiff',
      'tiff': 'image/tiff',
      'bmp': 'image/bmp',
      'mp4': 'video/mp4',
      'mov': 'video/quicktime',
      'mkv': 'video/x-matroska',
      'avi': 'video/x-msvideo',
      'webm': 'video/webm',
    };
    return map[ext];
  }

  // ── Special type detection ─────────────────────────────────────────────────

  /// HDR: XMP hdrGainMap present, filename contains "HDR", or SubjectDistanceRange 3
  static bool detectHdr(Map<String, IfdTag> tags, String path) {
    final filename = path.split('/').last.split('\\').last.toUpperCase();
    if (filename.contains('_HDR') || filename.contains('-HDR')) return true;
    // SubjectDistanceRange == 3 indicates very close / macro (used by some HDR pipelines)
    // Not reliable; rely on filename heuristic for now
    return false;
  }

  /// 360/Panorama: XMP GPano tags or extreme aspect ratio
  static bool detectIs360(Map<String, IfdTag> tags, int width, int height) {
    // A true equirectangular 360 is exactly 2:1 (±5%)
    if (width > 0 && height > 0) {
      final ratio = width / height;
      if (ratio >= 1.9 && ratio <= 2.1) return true;
    }
    return false;
  }

  static bool detectIsPanorama(
    Map<String, IfdTag> tags,
    int width,
    int height,
  ) {
    if (width > 0 && height > 0 && width / height >= 3.0) return true;
    return false;
  }

  /// Burst: EXIF BurstID tag, BurstSequenceIndex, or filename pattern
  static bool detectIsBurst(Map<String, IfdTag> tags, String path) {
    if (tags.containsKey('Image BurstID')) return true;
    if (tags.containsKey('Image BurstSequenceIndex')) return true;
    final filename = path.split('/').last.split('\\').last;
    // Common patterns: IMG_20240101_BURST001, BURST_001, _BURST0001_COVER
    if (RegExp(r'_?BURST[_\d]', caseSensitive: false).hasMatch(filename)) {
      return true;
    }
    if (RegExp(r'_?b\d{3,}[_.]', caseSensitive: false).hasMatch(filename)) {
      return true;
    }
    return false;
  }

  /// Motion photo: XMP GCamera:MicroVideo, or special MIME type
  static bool detectIsMotionPhoto(Map<String, IfdTag> tags, String? mimeType) {
    // Samsung / Google motion photos embed XMP with GCamera:MicroVideo=1
    // The exif package doesn't parse XMP, so check MIME type
    if (mimeType == 'image/jpeg+mp4') return true;
    return false;
  }

  static bool detectIsPortrait(Map<String, IfdTag> tags, String path) {
    final filename = path.split('/').last.split('\\').last.toUpperCase();
    if (filename.contains('_PORTRAIT') || filename.contains('-PORTRAIT')) {
      return true;
    }
    // SubjectDistanceRange == 3 indicates very close / macro (used by some HDR pipelines)
    // Not reliable; rely on filename heuristic for now
    return false;
  }

  /// Animated: GIF or WebP with multiple frames
  static bool detectIsAnimated(String path) {
    final ext = path.split('.').last.toLowerCase();
    return ext == 'gif' || ext == 'webp';
  }

  // ── XMP Subjects ──────────────────────────────────────────────────────────
  static List<String> parseXmpSubjects(Map<String, IfdTag> tags) {
    // The Dart exif package exposes some XMP tags via custom parsing
    // XMP Subject is stored as "Image XPSubject" in some EXIF tags
    final raw = tags['Image XPSubject']?.printable ?? '';
    if (raw.isEmpty) return [];
    return raw
        .split(RegExp(r'[;,]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  // ── XMP Rating ────────────────────────────────────────────────────────────
  static int parseRating(Map<String, IfdTag> tags) {
    // Windows "Rating" stored in EXIF as "Image Rating"
    return _int(tags['Image Rating']) ?? 0;
  }

  // ── XMP Title ─────────────────────────────────────────────────────────────
  static String? parseXmpTitle(Map<String, IfdTag> tags) {
    return tags['Image XPTitle']?.printable;
  }

  // ── Panorama Info ──────────────────────────────────────────────────────────
  static PanoramaInfo? parsePanoramaInfo(Map<String, IfdTag> tags) {
    // Full XMP GPano parsing requires raw XMP byte parsing — return null if no
    // relevant EXIF clues. Detection relies on aspect ratio in detectIs360/isPanorama.
    return null;
  }

  // ── Date ───────────────────────────────────────────────────────────────────
  static DateTime? parseDateTaken(Map<String, IfdTag> tags) {
    final raw =
        tags['EXIF DateTimeOriginal']?.printable ??
        tags['Image DateTime']?.printable;
    if (raw == null || raw.isEmpty) return null;
    try {
      // Format: "2024:01:15 12:30:45"
      final normalized = raw.replaceFirst(':', '-').replaceFirst(':', '-');
      return DateTime.tryParse(normalized.replaceFirst(' ', 'T'));
    } catch (_) {
      return null;
    }
  }

  // ── Camera make/model ──────────────────────────────────────────────────────
  static String parseCameraInfo(Map<String, IfdTag> tags) {
    final makeTag = tags['Image Make'] ?? tags['Make'] ?? tags['EXIF Make'] ?? tags['EXIF Image Make'];
    final modelTag = tags['Image Model'] ?? tags['Model'] ?? tags['EXIF Model'] ?? tags['EXIF Image Model'];

    final make = _cleanCameraValue(makeTag?.printable ?? '');
    final model = _cleanCameraValue(modelTag?.printable ?? '');

    if (make.isNotEmpty && model.isNotEmpty) {
      if (model.toLowerCase().startsWith(make.toLowerCase())) return model;
      return '$make $model';
    }
    return model.isNotEmpty
        ? model
        : make.isNotEmpty
        ? make
        : 'Unknown Camera';
  }

  static String _cleanCameraValue(String val) {
    final s = val.trim();
    final lower = s.toLowerCase();
    if (lower == 'unknown' || lower == 'null' || lower == 'default' || lower == 'none' || lower == 'standard' || lower.isEmpty) {
      return '';
    }
    return s;
  }

  // ── Private helpers ────────────────────────────────────────────────────────
  static double? _rational(IfdTag? tag) {
    if (tag == null) return null;
    try {
      final s = tag.printable;
      // Format "a/b" or decimal
      if (s.contains('/')) {
        final parts = s.split('/');
        final a = double.tryParse(parts[0]);
        final b = double.tryParse(parts[1]);
        if (a != null && b != null && b != 0) return a / b;
      }
      return double.tryParse(s);
    } catch (_) {
      return null;
    }
  }

  static int? _int(IfdTag? tag) {
    if (tag == null) return null;
    return int.tryParse(tag.printable);
  }

  static String? _exposureString(IfdTag? tag) {
    if (tag == null) return null;
    final s = tag.printable.trim();
    if (s.contains('/')) return s; // already "1/250"
    // Convert decimal to fraction
    final v = double.tryParse(s);
    if (v == null) return s;
    if (v >= 1.0) return '${v.toStringAsFixed(0)}s';
    final denom = (1.0 / v).round();
    return '1/$denom';
  }

  static String? _whiteBalance(IfdTag? tag) {
    if (tag == null) return null;
    switch (_int(tag) ?? -1) {
      case 0:
        return 'Auto';
      case 1:
        return 'Manual';
      default:
        return null;
    }
  }

  static String? _meteringMode(IfdTag? tag) {
    if (tag == null) return null;
    switch (_int(tag) ?? -1) {
      case 1:
        return 'Average';
      case 2:
        return 'Center-weighted';
      case 3:
        return 'Spot';
      case 4:
        return 'Multi-spot';
      case 5:
        return 'Pattern';
      case 6:
        return 'Partial';
      default:
        return null;
    }
  }

  static String? _sceneCaptureType(IfdTag? tag) {
    if (tag == null) return null;
    switch (_int(tag) ?? -1) {
      case 0:
        return 'Standard';
      case 1:
        return 'Landscape';
      case 2:
        return 'Portrait';
      case 3:
        return 'Night';
      default:
        return null;
    }
  }

  static double? _gpsToDecimal(IfdTag? degTag, IfdTag? refTag) {
    if (degTag == null) return null;
    try {
      // printable format: "[d, m, s]" or "d/1,m/1,s/100"
      final parts = degTag.printable
          .replaceAll('[', '')
          .replaceAll(']', '')
          .split(',')
          .map((s) => s.trim())
          .toList();
      if (parts.length < 3) return null;

      // Tracks whether every rational was a valid, non-zero-denominator value.
      // A "0/0" entry (no GPS fix) must NOT be silently coerced to 0.0 —
      // that produces a fake, valid-looking coordinate at the equator/prime
      // meridian instead of correctly signaling "no location data".
      bool sawInvalidRational = false;

      double toD(String s) {
        if (s.contains('/')) {
          final p = s.split('/');
          final a = double.tryParse(p[0]);
          final b = double.tryParse(p[1]);
          if (a == null || b == null || b == 0) {
            sawInvalidRational = true;
            return 0;
          }
          return a / b;
        }
        final v = double.tryParse(s);
        if (v == null) {
          sawInvalidRational = true;
          return 0;
        }
        return v;
      }

      final deg = toD(parts[0]);
      final min = toD(parts[1]);
      final sec = toD(parts[2]);

      // No GPS fix was written (all-zero / malformed rationals) — treat as
      // absent rather than fabricating 0.0, 0.0 (a real ocean coordinate).
      if (sawInvalidRational) return null;
      if (deg == 0 && min == 0 && sec == 0) return null;

      // A real fix always carries a hemisphere ref ('N'/'S'/'E'/'W').
      // An empty ref usually accompanies zeroed-out "no fix" rationals.
      final ref = refTag?.printable.trim().toUpperCase() ?? '';
      if (ref.isEmpty) return null;

      double dec = deg + min / 60.0 + sec / 3600.0;
      if (ref == 'S' || ref == 'W') dec = -dec;
      return dec;
    } catch (_) {
      return null;
    }
  }
}
