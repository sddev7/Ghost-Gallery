import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import '../../services/trash_persistence.dart';
import '../../services/thumbnail_cache_service.dart';

/// Displays a thumbnail for a local video file.
/// Features a premium visual fallback card for non-mobile platforms (like Windows/Web)
/// where the native video_thumbnail plugin is not available.
class VideoPreviewWidget extends StatefulWidget {
  final String videoPath;
  final String? assetId;

  /// Maximum thumbnail width decoded from the video (keep small for speed).
  final int maxWidth;

  /// JPEG quality 0–100.
  final int quality;

  /// How many times to retry on failure before showing the error state.
  final int maxRetries;

  /// BoxFit for rendering the image.
  final BoxFit fit;

  /// Width constraint for rendering.
  final double? width;

  /// Height constraint for rendering.
  final double? height;

  const VideoPreviewWidget({
    super.key,
    required this.videoPath,
    this.assetId,
    this.maxWidth = 512,
    this.quality = 85,
    this.maxRetries = 3,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
  });

  @override
  State<VideoPreviewWidget> createState() => _VideoPreviewWidgetState();
}

class _VideoPreviewWidgetState extends State<VideoPreviewWidget> {
  // ── Shared in-memory cache: path → raw JPEG bytes ──────────────────────
  static final Map<String, Uint8List> _cache = {};

  // ── Per-widget state ───────────────────────────────────────────────────
  Uint8List? _bytes;
  bool _loading = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _tryLoad();
  }

  @override
  void didUpdateWidget(covariant VideoPreviewWidget old) {
    super.didUpdateWidget(old);
    if (old.videoPath != widget.videoPath) {
      _bytes = null;
      _failed = false;
      _tryLoad();
    }
  }

  /// Attempts to load the thumbnail, retrying up to [widget.maxRetries]
  /// times with exponential back-off (200 ms, 400 ms, 800 ms, …).
  Future<void> _tryLoad() async {
    final bool useFallback =
        kIsWeb || (!Platform.isAndroid && !Platform.isIOS);
    if (useFallback) {
      return; // Skip native loading on Desktop/Web
    }

    // 1. Cache hit — instant render.
    final cached = _cache[widget.videoPath];
    if (cached != null) {
      if (mounted) setState(() => _bytes = cached);
      return;
    }

    // 2. Already in flight for this widget.
    if (_loading) return;

    if (mounted) {
      setState(() {
        _loading = true;
        _failed = false;
      });
    }

    Duration delay = const Duration(milliseconds: 200);

    for (int attempt = 0; attempt < widget.maxRetries; attempt++) {
      try {
        Uint8List? bytes;
        if (widget.videoPath.contains('.trashed')) {
          bytes = await TrashPersistence.getTrashedMediaThumbnail(
            mediaId: widget.assetId ?? '',
            filePath: widget.videoPath,
            isVideo: true,
          );
        }

        if (bytes == null || bytes.isEmpty) {
          if (widget.assetId != null && widget.assetId!.isNotEmpty) {
            bytes = await ThumbnailCacheService.instance.getThumbnail(
              assetId: widget.assetId!,
              filePath: widget.videoPath,
              isVideo: true,
            );
          }
        }

        if (bytes == null || bytes.isEmpty) {
          bytes = await VideoThumbnail.thumbnailData(
            video: widget.videoPath,
            imageFormat: ImageFormat.JPEG,
            maxWidth: widget.maxWidth,
            quality: widget.quality,
          );
        }

        if (bytes != null && bytes.isNotEmpty) {
          _cache[widget.videoPath] = bytes;
          if (mounted) {
            setState(() {
              _bytes = bytes;
              _loading = false;
            });
          }
          return; // ← success
        }
      } catch (e) {
        debugPrint(
          'VideoPreviewWidget: attempt ${attempt + 1} failed '
          'for "${widget.videoPath}": $e',
        );
      }

      // Wait before next retry (skip delay on last attempt).
      if (attempt < widget.maxRetries - 1) {
        await Future.delayed(delay);
        delay *= 2; // exponential back-off
      }
    }

    // All retries exhausted.
    if (mounted) {
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool useFallback =
        kIsWeb || (!Platform.isAndroid && !Platform.isIOS);
    if (useFallback) {
      final fileName = widget.videoPath
          .split(Platform.isWindows ? '\\' : '/')
          .last;
      return Container(
        width: widget.width,
        height: widget.height,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF1E3C72), Color(0xFF2A5298)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            const Icon(
              Icons.play_circle_outline,
              color: Colors.white60,
              size: 40,
            ),
            Positioned(
              bottom: 8,
              left: 8,
              right: 8,
              child: Text(
                fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // ── Success ────────────────────────────────────────────────────────────
    if (_bytes != null) {
      return Image.memory(
        _bytes!,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
      );
    }

    // ── Failure ────────────────────────────────────────────────────────────
    if (_failed) {
      return _FailureTile(
        width: widget.width,
        height: widget.height,
      );
    }

    // ── Loading shimmer ────────────────────────────────────────────────────
    return _LoadingShimmer(
      width: widget.width,
      height: widget.height,
    );
  }
}

/// Animated shimmer placeholder shown while the thumbnail is loading.
class _LoadingShimmer extends StatefulWidget {
  final double? width;
  final double? height;

  const _LoadingShimmer({this.width, this.height});

  @override
  State<_LoadingShimmer> createState() => _LoadingShimmerState();
}

class _LoadingShimmerState extends State<_LoadingShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, _) => Container(
        width: widget.width,
        height: widget.height,
        color: Color.lerp(Colors.grey[850], Colors.grey[750], _anim.value),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: const Color(0xFFD0BCFF).withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown when all thumbnail-load retries are exhausted.
class _FailureTile extends StatelessWidget {
  final double? width;
  final double? height;

  const _FailureTile({this.width, this.height});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      color: Colors.grey[900],
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(Icons.videocam_off_outlined, color: Colors.white38, size: 24),
          SizedBox(height: 4),
          Text(
            "Preview\nunavailable",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 9),
          ),
        ],
      ),
    );
  }
}
