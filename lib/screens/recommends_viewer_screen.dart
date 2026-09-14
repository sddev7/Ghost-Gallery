import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../models/recommend_models.dart';
import '../models/gallery_item.dart';
import '../services/database_helper.dart';
import 'album_detail_screen.dart';
import 'photo_viewer_screen.dart';
import 'person_photos_screen.dart';
import '../widgets/ken_burns_wrapper.dart';
import '../widgets/face_preview.dart';
import 'audio_selection_screen.dart';
import '../services/recommends_algorithm.dart';
import '../services/responsive_helper.dart';

class RecommendsViewerScreen extends StatefulWidget {
  final RecommendGroup group;

  const RecommendsViewerScreen({super.key, required this.group});

  @override
  State<RecommendsViewerScreen> createState() => _RecommendsViewerScreenState();
}

class _RecommendsViewerScreenState extends State<RecommendsViewerScreen> {
  int _currentIndex = 0;
  VideoPlayerController? _videoController;
  bool _isVideoInitialized = false;
  bool _isDarkTheme = false;

  // Progress animation state
  double _currentProgress = 0.0;
  Timer? _progressTimer;
  int _elapsedMs = 0;
  int _totalMs = 5000; // default 5s for photos
  bool _isPaused = false;
  Alignment? _personFaceAlignment;
  String? _profileItemPath;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (widget.group.type == RecommendType.highlight) {
      _loadPersonFaceAlignment();
    }
    _loadCurrentSlide();
  }

  Future<void> _loadPersonFaceAlignment() async {
    try {
      final personId = getPersonIdFromGroupId(widget.group.id);
      if (personId == null) return;
      final person = await DatabaseHelper.instance.getPersonById(personId);
      if (person != null) {
        final path = person['cover_image'] as String?;
        final w = person['cover_w'] as int? ?? 0;
        final h = person['cover_h'] as int? ?? 0;
        final x = person['cover_x'] as int? ?? 0;
        final y = person['cover_y'] as int? ?? 0;
        if (path != null && path.isNotEmpty && w > 0 && h > 0 && File(path).existsSync()) {
          _profileItemPath = path;
          final bytes = await File(path).readAsBytes();
          final decoded = await decodeImageFromList(bytes);
          final imgW = decoded.width.toDouble();
          final imgH = decoded.height.toDouble();
          if (imgW > 0 && imgH > 0 && mounted) {
            final faceCenterX = x + w / 2.0;
            final faceCenterY = y + h / 2.0;
            final alignX = ((faceCenterX / imgW) * 2.0 - 1.0).clamp(-1.0, 1.0);
            final alignY = ((faceCenterY / imgH) * 2.0 - 1.0).clamp(-1.0, 1.0);
            setState(() {
              _personFaceAlignment = Alignment(alignX, alignY);
            });
          }
        }
      }
    } catch (e) {
      debugPrint("RecommendsViewerScreen: _loadPersonFaceAlignment error: $e");
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _isDarkTheme = Theme.of(context).brightness == Brightness.dark;
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _videoController?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    // Restore status bar styling based on current theme brightness
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: _isDarkTheme ? Brightness.light : Brightness.dark,
        statusBarBrightness: _isDarkTheme ? Brightness.dark : Brightness.light,
      ),
    );

    super.dispose();
  }

  void _loadCurrentSlide() {
    _progressTimer?.cancel();
    _videoController?.dispose();
    _videoController = null;
    _isVideoInitialized = false;
    _currentProgress = 0.0;
    _elapsedMs = 0;
    _isPaused = false;

    if (widget.group.items.isEmpty) return;
    final item = widget.group.items[_currentIndex];

    if (item.isVideo && item.displayPath != null) {
      _totalMs = 15000; // default/fallback duration until video loads
      final file = File(item.displayPath!);
      if (file.existsSync()) {
        _videoController = VideoPlayerController.file(file)
          ..initialize()
              .then((_) {
                if (mounted) {
                  setState(() {
                    _isVideoInitialized = true;
                    _totalMs = _videoController!.value.duration.inMilliseconds;
                  });
                  _videoController!.play();
                  _startProgressTimer();
                }
              })
              .catchError((error) {
                debugPrint(
                  "RecommendsViewerScreen: Video initialization failed: $error",
                );
                if (mounted) {
                  _startProgressTimer();
                }
              });
      } else {
        // Fallback if file missing
        _startProgressTimer();
      }
    } else {
      _totalMs = _getSlideDuration(_currentIndex);
      _startProgressTimer();
    }
  }

  int _getSlideDuration(int index) {
    // Rhythmic durations matching a music tempo (in milliseconds)
    final beatPatternMs = [4000, 2500, 3500, 2000, 4500, 3000];
    return beatPatternMs[index % beatPatternMs.length];
  }

  void _startProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      if (_isPaused) return;

      setState(() {
        _elapsedMs += 50;
        _currentProgress = (_elapsedMs / _totalMs).clamp(0.0, 1.0);
      });

      if (_currentProgress >= 1.0) {
        timer.cancel();
        _nextSlide();
      }
    });
  }

  void _nextSlide() {
    if (_currentIndex < widget.group.items.length - 1) {
      setState(() {
        _currentIndex++;
      });
      _loadCurrentSlide();
    } else {
      // Finished all slides, exit viewer
      Navigator.pop(context);
    }
  }

  void _prevSlide() {
    if (_currentIndex > 0) {
      setState(() {
        _currentIndex--;
      });
      _loadCurrentSlide();
    } else {
      // Re-restart current slide
      setState(() {
        _elapsedMs = 0;
        _currentProgress = 0.0;
      });
      _videoController?.seekTo(Duration.zero);
      _videoController?.play();
    }
  }

  void _pause() {
    setState(() => _isPaused = true);
    _videoController?.pause();
  }

  void _resume() {
    setState(() => _isPaused = false);
    _videoController?.play();
  }

  // Save the currently shown generated image/video to device library
  Future<void> _saveToLibrary() async {
    final item = widget.group.items[_currentIndex];
    final path = item.generatedFilePath;
    if (path == null || !File(path).existsSync()) {
      _showToast("File path not available.");
      return;
    }

    _pause();
    _showProgressDialog("Saving memory to Gallery...");

    try {
      final file = File(path);
      final filename = path.split(Platform.isWindows ? '\\' : '/').last;

      if (Platform.isAndroid || Platform.isIOS) {
        Map<dynamic, dynamic>? savedResult;
        if (item.isVideo) {
          savedResult = await const MethodChannel(
            'in.sddev.ghost_gallery/media_manager',
          ).invokeMethod<Map<dynamic, dynamic>>(
            'saveVideoToGallery',
            {
              'filePath': path,
              'title': filename,
              'relativePath': 'Movies/Ghost Gallery',
            },
          );
        } else {
          final bytes = await file.readAsBytes();
          savedResult = await const MethodChannel(
            'in.sddev.ghost_gallery/media_manager',
          ).invokeMethod<Map<dynamic, dynamic>>(
            'saveImageToGallery',
            {
              'bytes': bytes,
              'title': filename,
              'relativePath': 'Pictures/Ghost Gallery',
            },
          );
        }

        if (savedResult == null) {
          throw Exception("Failed to save memory to Gallery.");
        }

        final String savedId = savedResult['id']?.toString() ?? '';
        final String finalPath = savedResult['path']?.toString() ?? path;

        // Insert into our SQLite database so it appears in main gallery immediately!
        final db = DatabaseHelper.instance;
        final now = DateTime.now();

        await db.insertMediaItem({
          'id': savedId,
          'path': finalPath,
          'media_type': item.isVideo ? 'video' : 'image',
          'duration': item.isVideo ? (_totalMs / 1000.0) : 0.0,
          'date_timestamp': now.millisecondsSinceEpoch,
          'date': 'Today',
          'location': '',
          'is_processed': 0,
          'width': 720,
          'height': 1280,
          'size': '${(file.lengthSync() / 1048576).toStringAsFixed(2)} MB',
          'camera_info': 'Saved Memory',
          'album_name': 'Ghost Gallery Curated',
          'album_category': 'Ghost Gallery Curated',
        });
      } else {
        // Fallback for Windows (copy to Pictures/Videos directory)
        final userHome = await getApplicationDocumentsDirectory();
        final copyPath = '${userHome.path}/$filename';
        await file.copy(copyPath);
      }

      if (mounted) Navigator.pop(context); // Dismiss dialog
      _showToast("Saved successfully to Gallery!");
    } catch (e) {
      if (mounted) Navigator.pop(context); // Dismiss dialog
      _showToast("Failed to save memory: $e");
    } finally {
      _resume();
    }
  }

  // Share using share_plus
  void _shareCuratedItem() {
    final item = widget.group.items[_currentIndex];
    final path = item.generatedFilePath ?? item.sourceItemPath;
    if (path == null || !File(path).existsSync()) {
      _showToast("File does not exist on disk.");
      return;
    }
    _pause();
    Share.shareXFiles([
      XFile(path),
    ], text: item.textOverlay ?? widget.group.title).then((_) {
      _resume();
    });
  }

  // Show in Gallery (navigates to original Album or filters in gallery)
  Future<void> _showInGallery() async {
    final item = widget.group.items[_currentIndex];
    if (item.sourceItemId == null || item.sourceItemPath == null) {
      _showToast("Not available for generated items.");
      return;
    }

    _pause();
    final db = DatabaseHelper.instance;
    final allMaps = await db.getAllMediaItemsLite();

    // Map database models to gallery items
    final List<GalleryItem> galleryItems = [];
    for (final map in allMaps) {
      galleryItems.add(GalleryItem.fromMap(map));
    }

    final targetItemIndex = galleryItems.indexWhere(
      (x) => x.id == item.sourceItemId,
    );
    if (targetItemIndex == -1) {
      _showToast("Original image not found in database.");
      _resume();
      return;
    }

    final targetItem = galleryItems[targetItemIndex];
    final albumName = targetItem.albumName.isNotEmpty
        ? targetItem.albumName
        : 'Camera';

    // Find all items in this album
    final albumItems = galleryItems
        .where((x) => x.albumName == targetItem.albumName)
        .toList();

    if (mounted) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AlbumDetailScreen(
            albumName: albumName,
            items: albumItems,
            onItemTapped: (tapItem, [list]) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PhotoViewerPage(
                    item: tapItem,
                    allItems: list ?? albumItems,
                    ghostPersonality: 'Friendly',
                    onDelete: (id) async {
                      // Stub or refresh
                    },
                  ),
                ),
              );
            },
            highlightItemId: targetItem.id,
          ),
        ),
      ).then((_) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        _resume();
      });
    }
  }

  void _onCustomizeAudioPressed() async {
    final imagePaths = <String>[];
    for (final item in widget.group.items) {
      if (item.itemType == RecommendItemType.libraryMedia &&
          item.sourceItemPath != null) {
        final path = item.sourceItemPath!;
        final isImg =
            path.toLowerCase().endsWith('.jpg') ||
            path.toLowerCase().endsWith('.jpeg') ||
            path.toLowerCase().endsWith('.png');
        if (isImg && File(path).existsSync()) {
          imagePaths.add(path);
        }
      }
    }

    RecommendItem? collageItem;
    for (final i in widget.group.items) {
      if (i.itemType == RecommendItemType.collagePhoto) {
        collageItem = i;
        break;
      }
    }
    if (collageItem != null &&
        collageItem.generatedFilePath != null &&
        File(collageItem.generatedFilePath!).existsSync()) {
      imagePaths.add(collageItem.generatedFilePath!);
    }

    if (imagePaths.isEmpty) {
      _showToast("No images found to regenerate slideshow.");
      _resume();
      return;
    }

    _pause();
    if (!mounted) return;

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    final String? selectedAudioPath = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            AudioSelectionScreen(videoDuration: imagePaths.length * 2.5),
      ),
    );

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (selectedAudioPath == null) {
      _resume();
      return;
    }

    _showProgressDialog("Synchronizing with song's Beats...");

    try {
      final newVideoPath = await RecommendsAlgorithm.instance
          .regenerateSlideshow(
            groupId: widget.group.id,
            imagePaths: imagePaths,
            type: widget.group.type,
            customAudioPath: selectedAudioPath,
          );

      _dismissProgressDialog();

      if (newVideoPath != null) {
        _showToast("Custom music applied successfully!");
        _loadCurrentSlide();
      } else {
        _showToast("Failed to generate video with custom music.");
        _resume();
      }
    } catch (e) {
      _dismissProgressDialog();
      _showToast("Error generating video: $e");
      _resume();
    } finally {
      try {
        final f = File(selectedAudioPath);
        if (f.existsSync()) {
          f.deleteSync();
          debugPrint("RecommendsViewerScreen: Cleaned up temporary trimmed audio file at $selectedAudioPath");
        }
      } catch (e) {
        debugPrint("RecommendsViewerScreen: Error cleaning up trimmed audio file: $e");
      }
    }
  }

  void _showToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Route? _progressDialogRoute;
  void _showProgressDialog(String msg) {
    _dismissProgressDialog();
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(
        child: Card(
          color: Colors.grey[900],
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: Colors.white),
                const SizedBox(height: 16),
                Text(
                  msg,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    _progressDialogRoute = route;
    Navigator.of(context).push(route);
  }

  void _dismissProgressDialog() {
    if (_progressDialogRoute != null) {
      if (_progressDialogRoute!.isActive && mounted) {
        Navigator.of(context).removeRoute(_progressDialogRoute!);
      }
      _progressDialogRoute = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.group.items.isEmpty) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text(
            "No items inside this memory group.",
            style: TextStyle(color: Colors.white),
          ),
        ),
      );
    }

    final item = widget.group.items[_currentIndex];
    final isVideo = item.isVideo;
    final isStaticCard =
        item.itemType == RecommendItemType.textPhoto ||
        item.itemType == RecommendItemType.collagePhoto;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapDown: (_) => _pause(),
        onTapUp: (_) => _resume(),
        onLongPress: _pause,
        onLongPressUp: _resume,
        onPanUpdate: (details) {
          // Swipe down to dismiss screen
          if (details.delta.dy > 12) {
            Navigator.pop(context);
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── Main Slide content ───────────────────────────────────────────
            Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 600),
                switchInCurve: Curves.easeInOut,
                switchOutCurve: Curves.easeInOut,
                transitionBuilder: (Widget child, Animation<double> animation) {
                  return FadeTransition(opacity: animation, child: child);
                },
                child: Stack(
                  key: ValueKey<int>(_currentIndex),
                  fit: StackFit.expand,
                  children: [
                    _buildAmbientBlurBackground(item),
                    Center(
                      child: isVideo
                          ? (_isVideoInitialized && _videoController != null
                                ? AspectRatio(
                                    aspectRatio:
                                        _videoController!.value.aspectRatio,
                                    child: VideoPlayer(_videoController!),
                                  )
                                : const Center(
                                    child: CircularProgressIndicator(
                                      color: Colors.white,
                                    ),
                                  ))
                          : (item.displayPath != null
                                ? KenBurnsWrapper(
                                    duration: Duration(milliseconds: _totalMs),
                                    index: _currentIndex,
                                    isPaused: _isPaused,
                                    isFaceZoomInOut: widget.group.type == RecommendType.highlight &&
                                        (_currentIndex == 0 || (_profileItemPath != null && item.displayPath == _profileItemPath)),
                                    faceAlignment: _personFaceAlignment,
                                    child: Image.file(
                                      File(item.displayPath!),
                                      fit: BoxFit.contain,
                                      width: double.infinity,
                                      height: double.infinity,
                                      errorBuilder:
                                          (context, error, stackTrace) {
                                            return const Center(
                                              child: Icon(
                                                Icons.broken_image,
                                                size: 64,
                                                color: Colors.grey,
                                              ),
                                            );
                                          },
                                    ),
                                  )
                                : const Center(
                                    child: Icon(
                                      Icons.broken_image,
                                      size: 64,
                                      color: Colors.grey,
                                    ),
                                  )),
                    ),
                  ],
                ),
              ),
            ),

            // Tap navigation hot zones (left 30% prev, right 70% next)
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: GestureDetector(
                    onTap: _prevSlide,
                    behavior: HitTestBehavior.translucent,
                    child: const SizedBox.expand(),
                  ),
                ),
                Expanded(
                  flex: 7,
                  child: GestureDetector(
                    onTap: _nextSlide,
                    behavior: HitTestBehavior.translucent,
                    child: const SizedBox.expand(),
                  ),
                ),
              ],
            ),

            // ── Top Bar Gradient Overlay ──────────────────────────────────
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 140,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.65),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // ── Top Bar: Segment Progress Indicators & Details ───────────────
            Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              left: 16,
              right: 16,
              child: Column(
                children: [
                  // Progress bars row
                  Row(
                    children: List.generate(widget.group.items.length, (idx) {
                      double widthFactor = 0.0;
                      if (idx < _currentIndex) {
                        widthFactor = 1.0;
                      } else if (idx == _currentIndex) {
                        widthFactor = _currentProgress;
                      }

                      return Expanded(
                        child: Container(
                          height: 2,
                          margin: const EdgeInsets.symmetric(horizontal: 1.5),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(1),
                          ),
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: widthFactor,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(1),
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 16),
                  // Group Header info
                  Row(
                    children: [
                      if (widget.group.type == RecommendType.birthdaySpecial ||
                          widget.group.type == RecommendType.highlight)
                        GestureDetector(
                          onTap: () async {
                            _pause();
                            SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
                            final personId = getPersonIdFromGroupId(widget.group.id);
                            if (personId != null) {
                              final person = await DatabaseHelper.instance.getPersonById(personId);
                              if (person != null && context.mounted) {
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => PersonPhotosScreen(person: person),
                                  ),
                                );
                              }
                            }
                            SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
                            _resume();
                          },
                          child: Container(
                            width: context.isWatch ? 28 : 40,
                            height: context.isWatch ? 28 : 40,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.75),
                                width: context.isWatch ? 1.5 : 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.4),
                                  blurRadius: 8,
                                ),
                              ],
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: PersonAvatar(
                              groupId: widget.group.id,
                              size: context.isWatch ? 28 : 40,
                              fallback: Container(
                                color: widget.group.type ==
                                        RecommendType.birthdaySpecial
                                    ? const Color(0xFFEC4899)
                                    : const Color(0xFF14B8A6),
                                child: Icon(
                                  widget.group.type ==
                                          RecommendType.birthdaySpecial
                                      ? Icons.cake_rounded
                                      : Icons.person_rounded,
                                  color: Colors.white,
                                  size: context.isWatch ? 16 : 22,
                                ),
                              ),
                            ),
                          ),
                        )
                      else
                        Icon(
                          widget.group.type == RecommendType.bestTrip
                              ? Icons.flight_takeoff
                              : Icons.auto_awesome_outlined,
                          color: Colors.white70,
                          size: context.isWatch ? 16 : 20,
                        ),
                      SizedBox(width: context.isWatch ? 4 : 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.group.title,
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: context.isWatch ? 12 : 16,
                                shadows: const [
                                  Shadow(color: Colors.black, blurRadius: 4),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              "${widget.group.subtitle}  •  ${_formatDate(widget.group.generatedAt)}",
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: context.isWatch ? 9 : 11,
                                shadows: const [
                                  Shadow(color: Colors.black, blurRadius: 4),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.close, color: Colors.white, size: context.isWatch ? 18 : 24),
                        padding: EdgeInsets.zero,
                        visualDensity: context.isWatch ? VisualDensity.compact : VisualDensity.standard,
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // ── Play/Pause Interactive Central Fade Overlay ─────────────────
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _isPaused ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 150),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.4),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.pause_rounded,
                        color: Colors.white,
                        size: 40,
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // ── Bottom Action Controls: Glassmorphic Dock ────────────────────
            Positioned(
              bottom: MediaQuery.of(context).padding.bottom + (context.isWatch ? 8 : 16),
              left: context.isWatch ? 8 : 20,
              right: context.isWatch ? 8 : 20,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 500),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(30),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          vertical: context.isWatch ? 6 : 10,
                          horizontal: context.isWatch ? 4 : 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(30),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.12),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            if (item.generatedFilePath != null)
                              _buildDockButton(
                                icon: Icons.save_alt_rounded,
                                label: "Save",
                                onTap: _saveToLibrary,
                              ),
                            if (item.itemType == RecommendItemType.generatedVideo)
                              _buildDockButton(
                                icon: Icons.music_note_rounded,
                                label: "Music",
                                onTap: _onCustomizeAudioPressed,
                              ),
                            _buildDockButton(
                              icon: Icons.share_rounded,
                              label: "Share",
                              onTap: _shareCuratedItem,
                            ),
                            if (item.sourceItemId != null)
                              _buildDockButton(
                                icon: Icons.photo_library_rounded,
                                label: "Album",
                                onTap: _showInGallery,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAmbientBlurBackground(RecommendItem currentItem) {
    final bgPath = (currentItem.displayPath != null && !currentItem.isVideo)
        ? currentItem.displayPath
        : widget.group.items
              .firstWhere(
                (x) => !x.isVideo && x.displayPath != null,
                orElse: () => currentItem,
              )
              .displayPath;

    if (bgPath == null ||
        bgPath.toLowerCase().endsWith('.mp4') ||
        bgPath.toLowerCase().endsWith('.mov') ||
        bgPath.toLowerCase().endsWith('.mkv')) {
      return Container(color: Colors.black);
    }

    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
      child: Image.file(
        File(bgPath),
        fit: BoxFit.cover,
        color: Colors.black.withValues(alpha: 0.55),
        colorBlendMode: BlendMode.darken,
        errorBuilder: (_, _, _) => Container(color: Colors.black),
      ),
    );
  }

  Widget _buildDockButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final isWatch = context.isWatch;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: EdgeInsets.all(isWatch ? 6 : 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: Colors.white, size: isWatch ? 16 : 20),
            ),
            if (!isWatch) ...[
              const SizedBox(height: 4),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final months = [
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
    return "${months[dt.month - 1]} ${dt.day}, ${dt.year}";
  }
}
