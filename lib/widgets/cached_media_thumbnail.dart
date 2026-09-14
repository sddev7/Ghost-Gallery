// ═══════════════════════════════════════════════════════════════════════════
// cached_media_thumbnail.dart
//
// Aves-style thumbnail widget:
//  • Loads from ThumbnailCacheService (disk-cached, low-res JPEG)
//  • Never decodes original full-resolution file during grid scroll
//  • Uses ResizeImage to cap Flutter's internal pixel budget
//  • Shows a shimmering placeholder while loading
//  • Shows a broken-image fallback on error
//
// Performance: shimmer uses a single global AnimationController + ValueNotifier
// shared across all tiles to avoid creating 60+ tickers on startup.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../services/thumbnail_cache_service.dart';
import '../services/trash_persistence.dart';
import '../services/ui_preference_provider.dart';
import '../screens/tabs/video_preview_widget.dart';

// ── Global shimmer controller (one ticker for ALL tiles) ───────────────────
class _GlobalTickerProvider implements TickerProvider {
  const _GlobalTickerProvider();
  @override
  Ticker createTicker(void Function(Duration) onTick) => Ticker(onTick);
}

class _GlobalShimmer {
  static AnimationController? _ctrl;
  static int _refCount = 0;
  /// Ranges 0.0 → 1.0, repeating. All shimmer tiles read this.
  static final ValueNotifier<double> progress = ValueNotifier<double>(0.0);

  static void attach() {
    _refCount++;
    if (_ctrl == null) {
      _ctrl = AnimationController(
        vsync: const _GlobalTickerProvider(),
        duration: const Duration(milliseconds: 1200),
      )..repeat();
      _ctrl!.addListener(_updateProgress);
    }
  }

  static void detach() {
    _refCount--;
    if (_refCount <= 0) {
      _ctrl?.removeListener(_updateProgress);
      _ctrl?.dispose();
      _ctrl = null;
      _refCount = 0;
    }
  }

  static void _updateProgress() {
    if (_ctrl != null) {
      progress.value = _ctrl!.value;
    }
  }
}

class CachedMediaThumbnail extends StatefulWidget {
  final String assetId;
  final String filePath;
  final bool isVideo;
  final BoxFit fit;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final Widget? overlay;   // e.g. type badge or video play button
  final VoidCallback? onLoaded;

  const CachedMediaThumbnail({
    super.key,
    required this.assetId,
    required this.filePath,
    this.isVideo = false,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.borderRadius,
    this.overlay,
    this.onLoaded,
  });

  @override
  State<CachedMediaThumbnail> createState() => _CachedMediaThumbnailState();
}

class _CachedMediaThumbnailState extends State<CachedMediaThumbnail> {
  Uint8List? _bytes;
  bool _loading = true;
  bool _error   = false;

  @override
  void initState() {
    super.initState();
    // Try to load from memory cache synchronously first to prevent 1-frame shimmer flash
    final cachedBytes = ThumbnailCacheService.instance.getFromMemoryCache(widget.assetId);
    if (cachedBytes != null) {
      _bytes = cachedBytes;
      _loading = false;
      _error = false;
      if (widget.onLoaded != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onLoaded?.call();
        });
      }
    } else {
      _load();
    }
  }

  @override
  void didUpdateWidget(CachedMediaThumbnail old) {
    super.didUpdateWidget(old);
    if (old.assetId != widget.assetId || old.filePath != widget.filePath) {
      final cachedBytes = ThumbnailCacheService.instance.getFromMemoryCache(widget.assetId);
      if (cachedBytes != null) {
        setState(() {
          _bytes = cachedBytes;
          _loading = false;
          _error = false;
        });
        if (widget.onLoaded != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onLoaded?.call();
          });
        }
      } else {
        setState(() {
          _bytes = null;
          _loading = true;
          _error = false;
        });
        _load();
      }
    }
  }

  Future<void> _load() async {
    try {
      final bytes = await ThumbnailCacheService.instance.getThumbnail(
        assetId:  widget.assetId,
        filePath: widget.filePath,
        isVideo:  widget.isVideo,
      );
      if (!mounted) return;
      if (bytes != null && bytes.isNotEmpty) {
        setState(() {
          _bytes   = bytes;
          _loading = false;
          _error   = false;
        });
        widget.onLoaded?.call();
        return;
      }

      if (widget.filePath.contains('.trashed')) {
        final trashedBytes = await TrashPersistence.getTrashedMediaThumbnail(
          mediaId: widget.assetId,
          filePath: widget.filePath,
          isVideo: widget.isVideo,
        );
        if (trashedBytes != null && trashedBytes.isNotEmpty) {
          if (!mounted) return;
          setState(() {
            _bytes = trashedBytes;
            _loading = false;
            _error = false;
          });
          widget.onLoaded?.call();
          return;
        }
      }

      setState(() {
        _bytes   = bytes;
        _loading = false;
        _error   = bytes == null || bytes.isEmpty;
      });
      if (bytes != null && bytes.isNotEmpty) {
        widget.onLoaded?.call();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() { _loading = false; _error = true; });
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget content;

    if (widget.isVideo && _bytes == null) {
      content = VideoPreviewWidget(
        videoPath: widget.filePath,
        assetId: widget.assetId,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
      );
    } else if (_loading) {
      // ── Shimmer placeholder ───────────────────────────────────────────────
      content = _ShimmerBox(
        width:  widget.width  ?? double.infinity,
        height: widget.height ?? double.infinity,
      );
    } else if (_error || _bytes == null) {
      // ── Fallback: try file directly (covers imported/win paths) ──────────
      content = _buildFallback(context);
    } else {
      // ── Cached thumbnail ─────────────────────────────────────────────────
      // Use ResizeImage so Flutter only allocates thumbnail-sized pixels in
      // its ImageCache — prevents memory spikes on large grids.
      // Dynamic decode sizing based on column count reduces heap footprint and scroll jank.
      final columns = UIPreferenceProvider.instance.gridColumns;
      final int targetDecodeSize = columns >= 4 ? 256 : 512;

      content = Image(
        image: ResizeImage(
          MemoryImage(_bytes!),
          width:  targetDecodeSize,
          height: targetDecodeSize,
          policy: ResizeImagePolicy.fit,
        ),
        fit:        widget.fit,
        width:      widget.width,
        height:     widget.height,
        gaplessPlayback: true,
        frameBuilder: (ctx, child, frame, _) =>
            frame == null ? _ShimmerBox(
              width:  widget.width  ?? double.infinity,
              height: widget.height ?? double.infinity,
            ) : child,
      );
    }

    Widget result = widget.borderRadius != null
        ? ClipRRect(borderRadius: widget.borderRadius!, child: content)
        : ClipRect(child: content);

    if (widget.overlay != null) {
      result = Stack(
        fit: StackFit.passthrough,
        children: [result, widget.overlay!],
      );
    }
    return result;
  }

  Widget _buildFallback(BuildContext context) {
    // Highly downscaled hardware-accelerated native decoding
    if (widget.filePath.isNotEmpty &&
        !widget.filePath.startsWith('http') &&
        File(widget.filePath).existsSync()) {
      final columns = UIPreferenceProvider.instance.gridColumns;
      final int targetDecodeSize = columns >= 4 ? 256 : 512;
      return Image.file(
        File(widget.filePath),
        cacheWidth: targetDecodeSize, // Caps internal pixel budget natively for ultra-fast decode
        fit:    widget.fit,
        width:  widget.width,
        height: widget.height,
        errorBuilder: (_, _, _) => _errorWidget(context),
        gaplessPlayback: true,
        frameBuilder: (ctx, child, frame, _) {
          if (frame != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              widget.onLoaded?.call();
            });
          }
          return child;
        },
      );
    }
    return _errorWidget(context);
  }

  Widget _errorWidget(BuildContext context) => Container(
    width:  widget.width  ?? double.infinity,
    height: widget.height ?? double.infinity,
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Icon(
      Icons.broken_image_outlined,
      color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5),
      size: 28,
    ),
  );
}

// ── Shimmer placeholder (uses global shared animation) ────────────────────

class _ShimmerBox extends StatefulWidget {
  final double width;
  final double height;
  const _ShimmerBox({required this.width, required this.height});

  @override
  State<_ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<_ShimmerBox> {
  @override
  void initState() {
    super.initState();
    _GlobalShimmer.attach();
  }

  @override
  void dispose() {
    _GlobalShimmer.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base    = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0);
    final shimmer = isDark ? const Color(0xFF3A3A3A) : const Color(0xFFEEEEEE);

    return ValueListenableBuilder<double>(
      valueListenable: _GlobalShimmer.progress,
      builder: (_, t, _) {
        // Map 0→1 to -2→+2 sweep
        final sweep = (t * 4) - 2;
        return Container(
          width:  widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(sweep - 1, 0),
              end:   Alignment(sweep + 1, 0),
              colors: [base, shimmer, base],
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
        );
      },
    );
  }
}
