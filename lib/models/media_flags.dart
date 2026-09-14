// ═══════════════════════════════════════════════════════════════════════════
// media_flags.dart
//
// Bitmask constants for special media types — stored as a single INTEGER
// column in SQLite, identical to how Aves (CatalogMetadata.flags) works.
//
// Usage:
//   final flags = MediaFlags.compute(isHdr: true, is360: false);
//   final isHdr = MediaFlags.has(flags, MediaFlags.hdr);
// ═══════════════════════════════════════════════════════════════════════════

class MediaFlags {
  MediaFlags._();

  // ── Bit positions ──────────────────────────────────────────────────────────
  static const int animated    = 1 << 0; // animated GIF / WebP
  static const int flipped     = 1 << 1; // horizontally flipped (EXIF orientation)
  static const int hdr         = 1 << 2; // embedded HDR gainmap or HDR video
  static const int is360       = 1 << 3; // equirectangular / spherical (XMP GPano)
  static const int panorama    = 1 << 4; // wide panorama (aspect ratio >3:1 or XMP GPano)
  static const int burst       = 1 << 5; // burst shot (BurstID EXIF, naming pattern)
  static const int motionPhoto = 1 << 6; // motion photo / live photo (XMP GCamera)
  static const int geotiff     = 1 << 7; // GeoTIFF with embedded map metadata
  static const int multiPage   = 1 << 8; // multi-page TIFF / animated GIF frames
  static const int portrait    = 1 << 9; // portrait orientation (height > width)


  // ── Factory ───────────────────────────────────────────────────────────────
  /// Compose a flags integer from individual boolean parameters.
  static int compute({
    bool animated    = false,
    bool flipped     = false,
    bool hdr         = false,
    bool is360       = false,
    bool panorama    = false,
    bool burst       = false,
    bool motionPhoto = false,
    bool geotiff     = false,
    bool multiPage   = false,
    bool portrait    = false,
  }) {
    int f = 0;
    if (animated)    f |= MediaFlags.animated;
    if (flipped)     f |= MediaFlags.flipped;
    if (hdr)         f |= MediaFlags.hdr;
    if (is360)       f |= MediaFlags.is360;
    if (panorama)    f |= MediaFlags.panorama;
    if (burst)       f |= MediaFlags.burst;
    if (motionPhoto) f |= MediaFlags.motionPhoto;
    if (geotiff)     f |= MediaFlags.geotiff;
    if (multiPage)   f |= MediaFlags.multiPage;
    if (portrait)    f |= MediaFlags.portrait;
    return f;
  }

  // ── Query ─────────────────────────────────────────────────────────────────
  /// Returns true if [flags] has the given [bit] set.
  static bool has(int flags, int bit) => (flags & bit) != 0;

  // ── Convenience getters ───────────────────────────────────────────────────
  static bool isAnimated   (int f) => has(f, animated);
  static bool isFlipped    (int f) => has(f, flipped);
  static bool isHdr        (int f) => has(f, hdr);
  static bool is360Deg     (int f) => has(f, is360);
  static bool isPanorama   (int f) => has(f, panorama);
  static bool isBurst      (int f) => has(f, burst);
  static bool isMotionPhoto(int f) => has(f, motionPhoto);
  static bool isGeotiff    (int f) => has(f, geotiff);
  static bool isMultiPage  (int f) => has(f, multiPage);
  static bool isPortrait   (int f) => has(f, portrait);

  // ── Debug ─────────────────────────────────────────────────────────────────
  static String describe(int f) {
    final parts = <String>[];
    if (isAnimated(f))    parts.add('Animated');
    if (isFlipped(f))     parts.add('Flipped');
    if (isHdr(f))         parts.add('HDR');
    if (is360Deg(f))      parts.add('360°');
    if (isPanorama(f))    parts.add('Panorama');
    if (isBurst(f))       parts.add('Burst');
    if (isMotionPhoto(f)) parts.add('Motion');
    if (isGeotiff(f))     parts.add('GeoTIFF');
    if (isMultiPage(f))   parts.add('Multi-page');
    if (isPortrait(f))    parts.add('Portrait');
    return parts.isEmpty ? 'None' : parts.join(' | ');
  }
}
