// ═══════════════════════════════════════════════════════════════════════════
// gallery_item.dart
//
// Rich media item model for Ghost Gallery — upgraded to Aves-grade metadata:
//   ✅ Special type flags: HDR, 360°, Panorama, Burst, Motion Photo, Animated
//   ✅ Full EXIF camera settings: aperture, ISO, focal length, exposure, flash
//   ✅ Structured address: countryCode, countryName, adminArea, locality
//   ✅ XMP metadata: subjects (tags), title, star rating
//   ✅ Orientation: rotationDegrees + isFlipped
//   ✅ Actual MIME type (from EXIF cataloguing, not guessed)
//   ✅ Bitmask flags stored as single INTEGER column via MediaFlags
// ═══════════════════════════════════════════════════════════════════════════

import 'media_flags.dart';

class GalleryItem {
  // ── Core ──────────────────────────────────────────────────────────────────
  final String id;
  final String imageUrl;       // file path or asset URI
  final String date;           // human-readable date string
  final String mediaType;      // 'image' or 'video'
  final double? duration;      // video duration in seconds
  final int dateTimestamp;     // milliseconds since epoch for sorting
  final int? modifiedTimestamp; // milliseconds since epoch for last modified

  // ── Dimensions & file info ────────────────────────────────────────────────
  String resolution;           // "3060x4080" (mutable — can change after scan)
  String size;                 // "3.2 MB" (mutable)
  final int width;
  final int height;
  final String? mimeType;      // actual MIME: "image/heic", "image/jpeg", etc.

  // ── Orientation (from EXIF) ───────────────────────────────────────────────
  final int rotationDegrees;   // 0, 90, 180, 270
  final bool isFlipped;        // horizontal flip from EXIF orientation

  // ── Camera hardware info ──────────────────────────────────────────────────
  final String cameraInfo;     // "Apple iPhone 15 Pro" or "Samsung Galaxy S24"
  final String albumName;      // raw album name from MediaStore
  final String albumCategory;  // bucketed: Camera, Screenshots, WhatsApp, etc.

  // ── Camera settings (EXIF) ────────────────────────────────────────────────
  final double? aperture;      // f-number e.g. 1.8  → displayed as "f/1.8"
  final int? iso;              // ISO speed e.g. 100
  final double? focalLength;   // in mm e.g. 26.0
  final String? exposureTime;  // "1/250" or "1/30"
  final int? flash;            // EXIF Flash integer (0 = no flash, 1 = fired, etc.)

  // ── Special type bitmask ─────────────────────────────────────────────────
  final int flags;             // MediaFlags bitmask integer

  // ── Convenient flag accessors ─────────────────────────────────────────────
  bool get isHdr         => MediaFlags.isHdr(flags);
  bool get isPortrait         => MediaFlags.isPortrait(flags);
  bool get is360         => MediaFlags.is360Deg(flags);
  bool get isPanorama    => MediaFlags.isPanorama(flags);
  bool get isBurst       => MediaFlags.isBurst(flags);
  bool get isMotionPhoto => MediaFlags.isMotionPhoto(flags);
  bool get isAnimated    => MediaFlags.isAnimated(flags);
  bool get isGeotiff     => MediaFlags.isGeotiff(flags);
  bool get isMultiPage   => MediaFlags.isMultiPage(flags);
  bool get hasSpecialType => flags != 0;

  // ── Location ─────────────────────────────────────────────────────────────
  final double latitude;
  final double longitude;
  bool get hasGps => (latitude != 0.0 || longitude != 0.0) &&
      !(latitude == 0.0 && longitude == 0.0);

  // ── Structured address (from reverse geocoding) ───────────────────────────
  final String location;       // display string e.g. "Mapo-gu, Seoul, South Korea"
  final String? countryCode;   // ISO 3166-1 e.g. "IN", "US"
  final String? countryName;   // e.g. "India"
  final String? adminArea;     // state/province e.g. "Odisha"
  final String? locality;      // city/district e.g. "Sonepur"
  final String? subLocality;   // neighbourhood e.g. "Connaught Place"
  final String? featureName;   // named place e.g. "India Gate"

  String get shortAddress {
    final parts = <String>[];
    if (locality?.isNotEmpty == true) parts.add(locality!);
    if (adminArea?.isNotEmpty == true) parts.add(adminArea!);
    if (countryCode?.isNotEmpty == true) parts.add(countryCode!);
    return parts.isNotEmpty ? parts.join(', ') : location;
  }

  // ── XMP metadata ──────────────────────────────────────────────────────────
  final String? xmpSubjects;   // ";"-separated tags e.g. "Nature;Travel;Sunset"
  final String? xmpTitle;      // XMP title
  final int rating;            // star rating 0–5 (from XMP)

  List<String> get tags =>
      xmpSubjects?.split(';').where((t) => t.isNotEmpty).toList() ?? [];

  // ── ML / AI data ─────────────────────────────────────────────────────────
  final bool isProcessed;
  final String? previewBase64;
  final List<double>? mediaEmbedding;
  final List<double>? clipEmbedding;

  // ── Ghost app fields ──────────────────────────────────────────────────────
  final String category;
  final String description;
  final String ghostComment;
  final DateTime? deletedAt;

  // ─────────────────────────────────────────────────────────────────────────

  GalleryItem({
    required this.id,
    required this.imageUrl,
    required this.date,
    required this.dateTimestamp,
    required this.location,
    required this.category,
    required this.description,
    required this.ghostComment,
    required this.resolution,
    required this.size,
    this.mediaType = 'image',
    this.duration,
    this.width = 0,
    this.height = 0,
    this.mimeType,
    this.rotationDegrees = 0,
    this.isFlipped = false,
    this.cameraInfo = 'Unknown Camera',
    this.albumName = '',
    this.albumCategory = 'Other',
    this.aperture,
    this.iso,
    this.focalLength,
    this.exposureTime,
    this.flash,
    this.flags = 0,
    this.latitude = 0.0,
    this.longitude = 0.0,
    this.countryCode,
    this.countryName,
    this.adminArea,
    this.locality,
    this.subLocality,
    this.featureName,
    this.xmpSubjects,
    this.xmpTitle,
    this.rating = 0,
    this.isProcessed = false,
    this.previewBase64,
    this.mediaEmbedding,
    this.clipEmbedding,
    this.deletedAt,
    this.modifiedTimestamp,
  });

  // ── copyWith ──────────────────────────────────────────────────────────────
  GalleryItem copyWith({
    String? id,
    String? imageUrl,
    String? date,
    int? dateTimestamp,
    String? location,
    String? category,
    String? description,
    String? ghostComment,
    String? resolution,
    String? size,
    String? mediaType,
    double? duration,
    int? width,
    int? height,
    String? mimeType,
    int? rotationDegrees,
    bool? isFlipped,
    String? cameraInfo,
    String? albumName,
    String? albumCategory,
    double? aperture,
    int? iso,
    double? focalLength,
    String? exposureTime,
    int? flash,
    int? flags,
    double? latitude,
    double? longitude,
    String? countryCode,
    String? countryName,
    String? adminArea,
    String? locality,
    String? subLocality,
    String? featureName,
    String? xmpSubjects,
    String? xmpTitle,
    int? rating,
    bool? isProcessed,
    String? previewBase64,
    List<double>? mediaEmbedding,
    List<double>? clipEmbedding,
    DateTime? deletedAt,
    int? modifiedTimestamp,
  }) {
    return GalleryItem(
      id: id ?? this.id,
      imageUrl: imageUrl ?? this.imageUrl,
      date: date ?? this.date,
      dateTimestamp: dateTimestamp ?? this.dateTimestamp,
      location: location ?? this.location,
      category: category ?? this.category,
      description: description ?? this.description,
      ghostComment: ghostComment ?? this.ghostComment,
      resolution: resolution ?? this.resolution,
      size: size ?? this.size,
      mediaType: mediaType ?? this.mediaType,
      duration: duration ?? this.duration,
      width: width ?? this.width,
      height: height ?? this.height,
      mimeType: mimeType ?? this.mimeType,
      rotationDegrees: rotationDegrees ?? this.rotationDegrees,
      isFlipped: isFlipped ?? this.isFlipped,
      cameraInfo: cameraInfo ?? this.cameraInfo,
      albumName: albumName ?? this.albumName,
      albumCategory: albumCategory ?? this.albumCategory,
      aperture: aperture ?? this.aperture,
      iso: iso ?? this.iso,
      focalLength: focalLength ?? this.focalLength,
      exposureTime: exposureTime ?? this.exposureTime,
      flash: flash ?? this.flash,
      flags: flags ?? this.flags,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      countryCode: countryCode ?? this.countryCode,
      countryName: countryName ?? this.countryName,
      adminArea: adminArea ?? this.adminArea,
      locality: locality ?? this.locality,
      subLocality: subLocality ?? this.subLocality,
      featureName: featureName ?? this.featureName,
      xmpSubjects: xmpSubjects ?? this.xmpSubjects,
      xmpTitle: xmpTitle ?? this.xmpTitle,
      rating: rating ?? this.rating,
      isProcessed: isProcessed ?? this.isProcessed,
      previewBase64: previewBase64 ?? this.previewBase64,
      mediaEmbedding: mediaEmbedding ?? this.mediaEmbedding,
      clipEmbedding: clipEmbedding ?? this.clipEmbedding,
      deletedAt: deletedAt ?? this.deletedAt,
      modifiedTimestamp: modifiedTimestamp ?? this.modifiedTimestamp,
    );
  }

  // ── fromMap (SQLite → GalleryItem) ───────────────────────────────────────
  factory GalleryItem.fromMap(Map<String, dynamic> map) {
    final mediaTypeVal = map['media_type'] as String? ?? 'image';
    final w = map['width'] as int? ?? 0;
    final h = map['height'] as int? ?? 0;
    final res = w > 0 && h > 0 ? '${w}x$h' : '0x0';

    // Dynamic ghost comments based on location / media type
    String comment = 'A lovely visual memory captured locally!';
    if (mediaTypeVal == 'video') {
      comment = 'A video memory! 🎥 I love seeing things in motion. No lagging allowed!';
    } else {
      final loc = map['location'] as String? ?? '';
      if (loc.toLowerCase().contains('sonepur')) {
        comment = 'Ah, Sonepur! 🏠 The air is crisp, the trees are tall, and my spooky signals are strong!';
      } else if (loc.toLowerCase().contains('delhi')) {
        comment = 'New Delhi flight times! ✈️ Traveling at high speeds makes my ghostly form lag!';
      }
    }

    // Parse embeddings
    List<double>? parsedEmbedding;
    final embStr = map['media_embedding'] as String?;
    if (embStr != null && embStr.isNotEmpty) {
      try {
        parsedEmbedding = embStr.split(',').map((s) => double.tryParse(s) ?? 0.0).toList();
      } catch (_) {}
    }

    List<double>? parsedClip;
    final clipStr = map['clip_embedding'] as String?;
    if (clipStr != null && clipStr.isNotEmpty) {
      try {
        parsedClip = clipStr.split(',').map((s) => double.tryParse(s) ?? 0.0).toList();
      } catch (_) {}
    }

    return GalleryItem(
      id:             map['id'] as String,
      imageUrl:       map['path'] as String,
      date:           map['date'] as String? ?? 'Today',
      dateTimestamp:  map['date_timestamp'] as int? ?? 0,
      location:       map['location'] as String? ?? 'Unknown Location',
      category:       mediaTypeVal == 'video' ? 'Video' : 'Photo',
      description:    map['description'] as String? ?? (mediaTypeVal == 'video' ? 'Local video capture' : 'Device photo image'),
      ghostComment:   comment,
      resolution:     res,
      size:           map['size'] as String? ?? '0 B',
      mediaType:      mediaTypeVal,
      duration:       map['duration'] as double?,
      width:          w,
      height:         h,
      mimeType:       map['mime_type'] as String?,
      rotationDegrees: map['rotation_degrees'] as int? ?? 0,
      isFlipped:      (map['is_flipped'] as int? ?? 0) == 1,
      cameraInfo:     map['camera_info'] as String? ?? 'Unknown Camera',
      albumName:      map['album_name'] as String? ?? '',
      albumCategory:  map['album_category'] as String? ?? 'Other',
      aperture:       _toDouble(map['aperture']),
      iso:            _toInt(map['iso']),
      focalLength:    _toDouble(map['focal_length']),
      exposureTime:   map['exposure_time'] as String?,
      flash:          _toInt(map['flash']),
      flags:          map['flags'] as int? ?? 0,
      latitude:       _toDouble(map['latitude']) ?? 0.0,
      longitude:      _toDouble(map['longitude']) ?? 0.0,
      countryCode:    map['country_code'] as String?,
      countryName:    map['country_name'] as String?,
      adminArea:      map['admin_area'] as String?,
      locality:       map['locality'] as String?,
      subLocality:    map['sub_locality'] as String?,
      featureName:    map['feature_name'] as String?,
      xmpSubjects:    map['xmp_subjects'] as String?,
      xmpTitle:       map['xmp_title'] as String?,
      rating:         _toInt(map['rating']) ?? 0,
      isProcessed:    (map['is_processed'] as int? ?? 0) == 1,
      previewBase64:  map['preview_base64'] as String?,
      mediaEmbedding: parsedEmbedding,
      clipEmbedding:  parsedClip,
      modifiedTimestamp: map['modified_timestamp'] as int?,
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  static double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    return double.tryParse(v.toString());
  }

  static int? _toInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return int.tryParse(v.toString());
  }

  /// Formatted aperture string: "f/1.8" or null
  String? get apertureDisplay => aperture != null ? 'f/${aperture!.toStringAsFixed(1)}' : null;

  /// Formatted focal length: "26mm" or null
  String? get focalLengthDisplay => focalLength != null ? '${focalLength!.toStringAsFixed(0)}mm' : null;

  /// Formatted ISO: "ISO 100" or null
  String? get isoDisplay => iso != null ? 'ISO $iso' : null;

  /// Human-readable flash status
  String? get flashDisplay {
    if (flash == null) return null;
    return (flash! & 0x01) != 0 ? 'Flash Fired' : 'No Flash';
  }

  /// Display aspect ratio (accounts for rotation)
  double get displayAspectRatio {
    if (width == 0 || height == 0) return 1.0;
    final isRotated = rotationDegrees == 90 || rotationDegrees == 270;
    return isRotated ? height / width : width / height;
  }

  /// Whether this item looks like a wide panorama based on aspect ratio
  bool get looksLikePanorama {
    if (isPanorama || is360) return true;
    if (width == 0 || height == 0) return false;
    final ratio = width / height;
    return ratio >= 3.0; // typical panorama threshold
  }
}
