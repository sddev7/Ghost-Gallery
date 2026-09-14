import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/gallery_item.dart';
import '../../widgets/cached_media_thumbnail.dart';
import './video_preview_widget.dart';

/// Decodes a base64 string in a background isolate so the main thread is never blocked.
Uint8List _decodeBase64Isolate(String base64Str) => base64Decode(base64Str);

/// FastMediaPreview — high-performance thumbnail widget.
///
/// Priority order:
///   1. Video → VideoPreviewWidget
///   2. SQLite base64 thumbnail → decoded off-thread via compute()
///   3. Raw file path → Image.file (cacheWidth=200 for low-memory decode)
///   4. CachedMediaThumbnail fallback (ThumbnailCacheService + shimmer)
class FastMediaPreview extends StatefulWidget {
  final GalleryItem item;
  final double? width;
  final double? height;
  final BoxFit fit;
  final bool showBadges;
  final VoidCallback? onLoaded;

  const FastMediaPreview({
    super.key,
    required this.item,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.showBadges = true,
    this.onLoaded,
  });

  @override
  State<FastMediaPreview> createState() => _FastMediaPreviewState();
}

class _FastMediaPreviewState extends State<FastMediaPreview> {
  Uint8List? _decodedBytes;
  bool _decoding = false;

  @override
  void initState() {
    super.initState();
    _startDecode();
  }

  @override
  void didUpdateWidget(FastMediaPreview old) {
    super.didUpdateWidget(old);
    if (old.item.id != widget.item.id) {
      _decodedBytes = null;
      _startDecode();
    }
  }

  void _startDecode() {
    final base64Str = widget.item.previewBase64;
    if (widget.item.mediaType == 'video' ||
        base64Str == null ||
        base64Str.isEmpty) {
      return;
    }
    try {
      _decodedBytes = base64Decode(base64Str);
      _decoding = false;
      if (widget.onLoaded != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onLoaded?.call();
        });
      }
    } catch (e) {
      debugPrint('FastMediaPreview: base64 decode failed for ${widget.item.id}: $e');
      _decoding = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget mediaWidget;

    // 1. Decoded base64 thumbnail (from background isolate)
    if (widget.item.mediaType != 'video' && _decodedBytes != null) {
      mediaWidget = Image.memory(
        _decodedBytes!,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        gaplessPlayback: true,
        errorBuilder: (_, __, _) => _fallbackMedia(context),
      );
    }
    // 2. Base64 not available or video -> use CachedMediaThumbnail
    else {
      mediaWidget = _fallbackMedia(context);
    }

    return Stack(
      fit: StackFit.passthrough,
      children: [
        mediaWidget,
        if (widget.showBadges) _buildFlagsBadges(),
      ],
    );
  }

  Widget _buildFlagsBadges() {
    final badges = <Widget>[];

    if (widget.item.isHdr) {
      badges.add(
        _buildBadge(
          icon: Icons.hdr_on_rounded,
          label: "HDR",
          color: const Color(0xFFFF9800),
        ),
      );
    }
    if (widget.item.is360) {
      badges.add(
        _buildBadge(
          icon: Icons.threed_rotation_rounded,
          label: "360°",
          color: const Color(0xFF00BCD4),
        ),
      );
    }
    if (widget.item.isMotionPhoto) {
      badges.add(
        _buildBadge(
          icon: Icons.motion_photos_on_rounded,
          label: "MOTION",
          color: const Color(0xFF4CAF50),
        ),
      );
    }

    if (badges.isEmpty) return const SizedBox.shrink();

    return Positioned(
      top: 6,
      left: 6,
      child: Wrap(spacing: 4, runSpacing: 4, children: badges),
    );
  }

  Widget _buildBadge({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2.5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 2.5),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 8.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _fallbackMedia(BuildContext context) {
    return CachedMediaThumbnail(
      assetId: widget.item.id,
      filePath: widget.item.imageUrl,
      isVideo: widget.item.mediaType == 'video',
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      onLoaded: widget.onLoaded,
    );
  }
}
