import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghost_gallery/models/vault_models.dart';
import 'package:ghost_gallery/services/ui_preference_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/gallery_item.dart';
import '../services/database_helper.dart';
import '../services/optional_features.dart';
import '../services/ml_processing_service.dart';
import '../services/favorites_persistence.dart';
import '../services/trash_persistence.dart';
import '../services/media_permission_service.dart';
import '../services/burst_helper.dart';
import 'package:ghost_gallery/widgets/add_to_album_dialog.dart';
import '../services/responsive_helper.dart';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'photo_editor_screen.dart';
import 'package:async_wallpaper/async_wallpaper.dart';
import 'video_editor_screen.dart';
import 'map_view_screen.dart';
import 'tabs/fast_media_preview.dart';
import '../widgets/cached_media_thumbnail.dart';
import 'people_management_screen.dart';
import 'person_photos_screen.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/vault_service.dart';
import 'vault/vault_setup_screen.dart';
import 'vault/vault_unlock_screen.dart';
import '../services/collection_source.dart';
import '../services/device_media_scanner.dart';
import '../widgets/cached_tile_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Design tokens — Dynamic Theme support
// ─────────────────────────────────────────────────────────────────────────────
class _P {
  final BuildContext context;
  _P(this.context);

  Color get accent => Theme.of(context).colorScheme.primary;
  Color get accentLight => Theme.of(context).colorScheme.primaryContainer;
  Color get surface => Theme.of(context).colorScheme.surface;
  Color get surfaceGrey =>
      Theme.of(context).colorScheme.surfaceContainerHighest;
  Color get card => Theme.of(context).colorScheme.surfaceContainer;
  Color get onSurface => Theme.of(context).colorScheme.onSurface;
  Color get muted => Theme.of(context).colorScheme.onSurfaceVariant;
  Color get border => Theme.of(context).dividerColor;
  Color get danger => Theme.of(context).colorScheme.error;
  Color get canvasBg => Theme.of(context).scaffoldBackgroundColor;
}

class PhotoViewerPage extends StatefulWidget {
  final GalleryItem item;
  final List<GalleryItem> allItems;
  final String ghostPersonality;
  final Future<void> Function(String) onDelete;
  final bool isRecentlyDeleted;

  final bool isVault;

  const PhotoViewerPage({
    super.key,
    required this.item,
    required this.allItems,
    required this.ghostPersonality,
    required this.onDelete,
    this.isRecentlyDeleted = false,
    this.isVault = false,
  });

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage>
    with TickerProviderStateMixin {
  _P get p => _P(context);

  late int _currentIndex;
  late PageController _pageController;

  // Chrome / overlay
  bool _showChrome = true;
  bool _showResolutionPanel = false;
  bool _showDetailsOverlay = false;
  bool _isDarkTheme = false;

  // Inline caption editing
  bool _isEditingCaption = false;
  late TextEditingController _captionController;
  late FocusNode _captionFocusNode;
  late FlutterTts _tts;

  // Resolution & quality
  double _resolutionProgress = 1.0;
  double _qualityProgress = 0.9;

  // Video
  VideoPlayerController? _videoController;
  bool _isVideoInitialized = false;
  double _playbackSpeed = 1.0;
  double _currentPositionInSeconds = 0.0;
  double _totalDurationInSeconds = 0.0;
  bool _isVideoPlaying = false;
  double _videoVolume = 1.0;
  bool _isSettingSystemVolume = false;
  double? _pendingSystemVolume;
  double _videoBrightness = 1.0;
  bool _showVolumeIndicator = false;
  bool _showBrightnessIndicator = false;
  bool _showSkipIndicator = false;
  bool _isSkipForward = true;
  DateTime? _lastTapTime;
  Timer? _volumeIndicatorTimer;
  Timer? _brightnessIndicatorTimer;
  Timer? _skipIndicatorTimer;
  // Orientation & long-press 2× speed
  bool _isVideoLandscape = false;
  bool _isLongPressSpeedActive = false;
  bool _showVideoGestureGuide = false;

  // Flip state with undo/redo
  bool _isFlipped = false;
  final List<bool> _undoStack = [];
  final List<bool> _redoStack = [];

  // Relational data
  List<Map<String, dynamic>> _ocrTexts = [];
  List<Map<String, dynamic>> _objects = [];
  List<Map<String, dynamic>> _faces = [];
  List<Map<String, dynamic>> _people = [];
  List<Map<String, dynamic>> _allDbFaces = [];

  // Zoom / pan state (per current image)
  double _scale = 1.0;
  final double _previousScale = 1.0;
  Offset _offset = Offset.zero;
  bool get _isZoomed => _scale > 1.02;

  // Double-tap animation state variables
  double _startScale = 1.0;
  double _targetScale = 1.0;
  Offset _startOffset = Offset.zero;
  Offset _targetOffset = Offset.zero;

  late TransformationController _transformationController;
  late AnimationController _zoomAnimController;

  // Animation controllers
  late AnimationController _chromeController;
  late Animation<double> _chromeFade;
  late AnimationController _detailsController;
  late Animation<Offset> _detailsSlide;

  Set<String> _favoriteIds = {};
  late List<GalleryItem> _localItems;

  bool _isBurstSelectionMode = false;
  final Set<String> _selectedBurstItemIds = {};

  // Slideshow
  bool _isSlideshowActive = false;
  Timer? _slideshowTimer;
  final Set<String> _loadedImageIds = {};

  Timer? _preloadTimer;
  final Map<String, Uint8List> _trashedBytesCache = {};

  // ── Interactive Tour ─────────────────────────────────────────────────────────
  bool _isTourActive = false;
  int _tourStep = 0;
  // GlobalKeys for tour spotlight targets
  final GlobalKey _tourShareKey = GlobalKey();
  final GlobalKey _tourEditKey = GlobalKey();
  final GlobalKey _tourDeleteKey = GlobalKey();
  final GlobalKey _tourInfoKey = GlobalKey();
  final GlobalKey _tourFavoriteKey = GlobalKey();
  final GlobalKey _tourSlideshowKey = GlobalKey();
  final GlobalKey _tourMoreKey = GlobalKey();
  // Video-specific tour targets
  final GlobalKey _tourVideoOrientKey = GlobalKey();
  final GlobalKey _tourVideoSpeedKey = GlobalKey();

  @override
  void initState() {
    super.initState();

    _localItems = BurstHelper.collapseBursts(widget.allItems);
    _loadFavorites();

    _currentIndex = _localItems.indexWhere((x) => x.id == widget.item.id);
    if (_currentIndex == -1) {
      final key = BurstHelper.getBurstGroupKey(widget.item);
      if (key != null) {
        _currentIndex = _localItems.indexWhere(
          (x) => BurstHelper.getBurstGroupKey(x) == key,
        );
      }
    }
    if (_currentIndex == -1) _currentIndex = 0;
    _pageController = PageController(initialPage: _currentIndex);

    _transformationController = TransformationController();

    _captionController = TextEditingController();
    _captionFocusNode = FocusNode();
    _tts = FlutterTts();

    _chromeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      value: 1.0,
    );
    _chromeFade = CurvedAnimation(
      parent: _chromeController,
      curve: Curves.easeOut,
    );

    _detailsController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _detailsSlide = Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _detailsController,
            curve: Curves.easeOutCubic,
          ),
        );

    _zoomAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _zoomAnimController.addListener(() {
      final t = _zoomAnimController.value;
      final currentScale = _startScale + (_targetScale - _startScale) * t;
      final currentOffset = Offset.lerp(_startOffset, _targetOffset, t)!;

      _transformationController.value = Matrix4.identity()
        ..translate(currentOffset.dx, currentOffset.dy)
        ..scale(currentScale);

      final isZoomed = currentScale > 1.02;
      if (isZoomed != _isZoomed) {
        setState(() {
          _scale = currentScale;
        });
      }
    });

    _prioritizeAndLoadActiveItem();

    final activeItem = _localItems[_currentIndex];
    if (activeItem.mediaType == 'video') {
      _initVideoPlayer(activeItem.imageUrl);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateSystemUi();
      _preloadNextAndPrevious();
      if (!widget.isVault && !widget.isRecentlyDeleted) {
        _checkAndShowTour();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _isDarkTheme = Theme.of(context).brightness == Brightness.dark;
  }

  @override
  void dispose() {
    _preloadTimer?.cancel();
    _slideshowTimer?.cancel();
    _volumeIndicatorTimer?.cancel();
    _brightnessIndicatorTimer?.cancel();
    _skipIndicatorTimer?.cancel();
    WakelockPlus.toggle(enable: false);
    // Restore portrait orientation on exit
    SystemChrome.setPreferredOrientations([]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: _isDarkTheme
            ? Brightness.light
            : Brightness.dark,
        statusBarBrightness: _isDarkTheme ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: _isDarkTheme
            ? Brightness.light
            : Brightness.dark,
      ),
    );
    _videoController?.removeListener(_onVideoUpdate);
    _videoController?.dispose();
    _pageController.dispose();
    _chromeController.dispose();
    _detailsController.dispose();
    _zoomAnimController.dispose();
    _transformationController.dispose();
    _captionController.dispose();
    _captionFocusNode.dispose();
    _tts.stop();
    super.dispose();
  }

  // ─── Favorites ──────────────────────────────────────────────────────────────
  Future<void> _loadFavorites() async {
    final favs = await FavoritesPersistence.loadFavorites();
    if (mounted) {
      setState(() {
        _favoriteIds = favs;
      });
    }
  }

  void _toggleFavorite() {
    final activeItem = _localItems[_currentIndex];
    setState(() {
      if (_favoriteIds.contains(activeItem.id)) {
        _favoriteIds.remove(activeItem.id);
      } else {
        _favoriteIds.add(activeItem.id);
      }
    });
    FavoritesPersistence.saveFavorites(_favoriteIds);
    HapticFeedback.lightImpact();
  }

  // ─── Slideshow ──────────────────────────────────────────────────────────────
  Future<void> _updateWakelock() async {
    final bool shouldEnable =
        _isSlideshowActive ||
        (_videoController != null && _videoController!.value.isPlaying);
    try {
      await WakelockPlus.toggle(enable: shouldEnable);
      debugPrint('Wakelock: toggled to $shouldEnable');
    } catch (e) {
      debugPrint('Wakelock error: $e');
    }
  }

  void _onOriginalImageLoaded(String itemId) {
    if (!mounted) return;
    _loadedImageIds.add(itemId);
    if (!_isSlideshowActive) return;
    final activeItem = _localItems[_currentIndex];
    if (activeItem.id == itemId && activeItem.mediaType != 'video') {
      _startSlideshowTimerForCurrentImage();
    }
  }

  void _startSlideshowTimerForCurrentImage() {
    _slideshowTimer?.cancel();
    _slideshowTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || !_isSlideshowActive) return;
      _goNext();
    });
  }

  void _toggleSlideshow() {
    setState(() {
      _isSlideshowActive = !_isSlideshowActive;
      if (_isSlideshowActive) {
        _startSlideshow();
        _showSnack("Slideshow started");
      } else {
        _stopSlideshow();
        _showSnack("Slideshow stopped");
      }
    });
    _updateWakelock();
  }

  void _startSlideshow() {
    _slideshowTimer?.cancel();
    if (_localItems.isEmpty) return;

    final activeItem = _localItems[_currentIndex];
    if (activeItem.mediaType == 'video') {
      _videoController?.setLooping(false);
      // Wait for video completion instead of starting a timer
      return;
    }

    if (_loadedImageIds.contains(activeItem.id)) {
      _startSlideshowTimerForCurrentImage();
    } else {
      // Fallback timer of 8 seconds so the slideshow doesn't get stuck on loading errors
      _slideshowTimer = Timer(const Duration(seconds: 8), () {
        if (!mounted || !_isSlideshowActive) return;
        _goNext();
      });
    }
  }

  void _stopSlideshow() {
    _slideshowTimer?.cancel();
    _slideshowTimer = null;
    setState(() {
      _isSlideshowActive = false;
    });
    _videoController?.setLooping(true);
    _updateWakelock();
  }

  // ─── Data ───────────────────────────────────────────────────────────────────
  Future<void> _loadRelationalData() async {
    final activeItem = _localItems[_currentIndex];
    final db = DatabaseHelper.instance;
    final results = await Future.wait([
      db.getOcrTextsForMedia(activeItem.id),
      db.getObjectsForMedia(activeItem.id),
      db.getFacesForMedia(activeItem.id),
      db.getAllPeople(),
      db.getAllFaces(),
    ]);
    if (!mounted) return;
    setState(() {
      _ocrTexts = results[0];
      _objects = results[1];
      _faces = results[2];
      _people = results[3];
      _allDbFaces = results[4];
    });
  }

  Future<void> _prioritizeAndLoadActiveItem() async {
    final activeItem = _localItems[_currentIndex];

    // Fetch and print database row of current item
    final dbItem = await DatabaseHelper.instance.getMediaItemById(activeItem.id);
    debugPrint("DATABASE ROW FOR ACTIVE ITEM: $dbItem");

    // 1. Immediately load whatever relational data we currently have
    await _loadRelationalData();

    // 2. Perform priority processing asynchronously
    _runPriorityProcessing(activeItem);
  }

  Future<void> _runPriorityProcessing(GalleryItem item) async {
    final db = DatabaseHelper.instance;
    final dbItem = await db.getMediaItemById(item.id);
    if (dbItem == null) return;

    final bool needsTier2 = (dbItem['metadata_ready'] as int? ?? 0) == 0;
    final bool needsTier3 = (dbItem['is_processed'] as int? ?? 0) != 1;

    if (needsTier2 || needsTier3) {
      debugPrint(
        'PhotoViewerPage: Prioritizing Tier 2/3 for active item: ${item.id}',
      );
      await MLProcessingService.instance.prioritizeItem(
        item.id,
        item.imageUrl,
        item.mediaType,
        item.duration,
      );

      if (!mounted) return;
      final currentItem = _localItems[_currentIndex];
      if (currentItem.id == item.id) {
        // Reload completed details from DB
        await _loadRelationalData();
        final updatedDbItem = await db.getMediaItemById(item.id);
        if (updatedDbItem != null && mounted) {
          setState(() {
            _localItems[_currentIndex] = GalleryItem.fromMap(updatedDbItem);
          });
        }
      }
    }
  }

  // ─── Page navigation ────────────────────────────────────────────────────────
  void _onPageChanged(int index) {
    // Skip burst sequence logic
    final prevIndex = _currentIndex;
    if (prevIndex >= 0 && prevIndex < _localItems.length) {
      final prevItem = _localItems[prevIndex];
      final prevBurstKey = BurstHelper.getBurstGroupKey(prevItem);

      if (prevBurstKey != null && index >= 0 && index < _localItems.length) {
        final newItem = _localItems[index];
        final newBurstKey = BurstHelper.getBurstGroupKey(newItem);

        if (newBurstKey == prevBurstKey) {
          if (index > prevIndex) {
            int targetIndex = index;
            while (targetIndex < _localItems.length) {
              final targetItem = _localItems[targetIndex];
              if (BurstHelper.getBurstGroupKey(targetItem) != prevBurstKey) {
                break;
              }
              targetIndex++;
            }
            if (targetIndex < _localItems.length) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_pageController.hasClients) {
                  _pageController.jumpToPage(targetIndex);
                }
              });
              return;
            }
          } else if (index < prevIndex) {
            int targetIndex = index;
            while (targetIndex >= 0) {
              final targetItem = _localItems[targetIndex];
              if (BurstHelper.getBurstGroupKey(targetItem) != prevBurstKey) {
                break;
              }
              targetIndex--;
            }
            if (targetIndex >= 0) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_pageController.hasClients) {
                  _pageController.jumpToPage(targetIndex);
                }
              });
              return;
            }
          }
        }
      }
    }

    _videoController?.removeListener(_onVideoUpdate);
    _videoController?.dispose();
    _videoController = null;
    _isVideoInitialized = false;
    _playbackSpeed = 1.0;
    _updateWakelock();

    if (_showDetailsOverlay) {
      _detailsController.reverse();
    }

    setState(() {
      _currentIndex = index;
      // _showChrome intentionally NOT reset — preserve user's chrome state across swipes
      _isFlipped = false;
      _undoStack.clear();
      _redoStack.clear();
      _showResolutionPanel = false;
      _showDetailsOverlay = false;
      // Reset zoom
      _transformationController.value = Matrix4.identity();
      _scale = 1.0;
      _offset = Offset.zero;
    });

    _prioritizeAndLoadActiveItem();

    final activeItem = _localItems[_currentIndex];
    if (activeItem.mediaType == 'video') {
      _initVideoPlayer(activeItem.imageUrl);
    }
    _updateSystemUi();

    if (_isSlideshowActive) {
      _startSlideshow();
    }

    _preloadTimer?.cancel();
    _preloadTimer = Timer(const Duration(milliseconds: 350), () {
      _preloadNextAndPrevious();
    });
  }

  void _cleanTrashedBytesCache() {
    final allowedKeys = <String>{};
    if (_currentIndex >= 0 && _currentIndex < _localItems.length) {
      allowedKeys.add(_localItems[_currentIndex].id);
      if (_currentIndex - 1 >= 0) {
        allowedKeys.add(_localItems[_currentIndex - 1].id);
      }
      if (_currentIndex + 1 < _localItems.length) {
        allowedKeys.add(_localItems[_currentIndex + 1].id);
      }
    }
    _trashedBytesCache.removeWhere((key, _) => !allowedKeys.contains(key));
  }

  void _preloadNextAndPrevious() {
    if (!mounted) return;
    _cleanTrashedBytesCache();

    // 1. Preload NEXT item
    if (_currentIndex + 1 < _localItems.length) {
      final nextItem = _localItems[_currentIndex + 1];
      if (nextItem.mediaType != 'video') {
        if (nextItem.imageUrl.contains('.trashed') ||
            widget.isRecentlyDeleted) {
          if (!_trashedBytesCache.containsKey(nextItem.id)) {
            TrashPersistence.getMediaBytes(
              mediaId: nextItem.id,
              filePath: nextItem.imageUrl,
            ).then((bytes) {
              if (bytes != null && mounted) {
                setState(() {
                  _trashedBytesCache[nextItem.id] = bytes;
                });
              }
            });
          }
        } else {
          try {
            if (widget.isVault && !File(nextItem.imageUrl).existsSync()) {
              // Skip precaching if the vault item is not decrypted yet.
            } else {
              final provider = nextItem.imageUrl.startsWith('http')
                  ? NetworkImage(nextItem.imageUrl)
                  : FileImage(File(nextItem.imageUrl)) as ImageProvider;
              precacheImage(provider, context);
            }
          } catch (e) {
            debugPrint("Preloading next image failed: $e");
          }
        }
      }
    }

    // 2. Preload PREVIOUS item
    if (_currentIndex - 1 >= 0) {
      final prevItem = _localItems[_currentIndex - 1];
      if (prevItem.mediaType != 'video') {
        if (prevItem.imageUrl.contains('.trashed') ||
            widget.isRecentlyDeleted) {
          if (!_trashedBytesCache.containsKey(prevItem.id)) {
            TrashPersistence.getMediaBytes(
              mediaId: prevItem.id,
              filePath: prevItem.imageUrl,
            ).then((bytes) {
              if (bytes != null && mounted) {
                setState(() {
                  _trashedBytesCache[prevItem.id] = bytes;
                });
              }
            });
          }
        } else {
          try {
            if (widget.isVault && !File(prevItem.imageUrl).existsSync()) {
              // Skip precaching if the vault item is not decrypted yet.
            } else {
              final provider = prevItem.imageUrl.startsWith('http')
                  ? NetworkImage(prevItem.imageUrl)
                  : FileImage(File(prevItem.imageUrl)) as ImageProvider;
              precacheImage(provider, context);
            }
          } catch (e) {
            debugPrint("Preloading previous image failed: $e");
          }
        }
      }
    }
  }

  // ─── Navigate prev/next ──────────────────────────────────────────────────────
  void _goNext() {
    if (_currentIndex < _localItems.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    } else {
      if (_isSlideshowActive && _pageController.hasClients) {
        _pageController.animateToPage(
          0,
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOut,
        );
      }
    }
  }

  void _goPrev() {
    if (_currentIndex > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  // ─── System UI Update ────────────────────────────────────────────────────────
  void _updateSystemUi() {
    if (_showChrome) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      final isDark = Theme.of(context).brightness == Brightness.dark;
      SystemChrome.setSystemUIOverlayStyle(
        SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
          statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: isDark
              ? Brightness.light
              : Brightness.dark,
        ),
      );
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  // ─── Video ──────────────────────────────────────────────────────────────────
  Future<void> _initVideoPlayer(String path) async {
    _initSystemVolume();
    final activeItem = _localItems[_currentIndex];
    final activeItemId = activeItem.id;

    VideoPlayerController? controller;

    if (Platform.isAndroid &&
        (path.contains('.trashed') || widget.isRecentlyDeleted)) {
      final contentUriStr = await TrashPersistence.getMediaContentUri(
        mediaId: activeItem.id,
        filePath: path,
      );
      if (!mounted || _localItems[_currentIndex].id != activeItemId) {
        return;
      }
      if (contentUriStr != null) {
        controller = VideoPlayerController.contentUri(Uri.parse(contentUriStr));
      }
    }

    controller ??= path.startsWith('http')
        ? VideoPlayerController.networkUrl(Uri.parse(path))
        : VideoPlayerController.file(File(path));

    if (!mounted || _localItems[_currentIndex].id != activeItemId) {
      controller.dispose();
      return;
    }

    _videoController = controller;

    _videoController!
        .initialize()
        .then((_) {
          if (!mounted || _localItems[_currentIndex].id != activeItemId) {
            controller!.dispose();
            return;
          }
          setState(() {
            _isVideoInitialized = true;
            _totalDurationInSeconds =
                _videoController!.value.duration.inMilliseconds / 1000.0;
            _showChrome = false;
          });
          _updateSystemUi();
          _videoController!
            ..addListener(_onVideoUpdate)
            ..play()
            ..setLooping(!_isSlideshowActive);
          _updateWakelock();
          _checkAndShowVideoGestureGuide();
        })
        .catchError((e) => debugPrint('Video init failed: $e'));
  }

  Future<void> _checkAndShowVideoGestureGuide() async {
    final prefs = await SharedPreferences.getInstance();
    // Use v2 key — old key was for the skip guide; new one is for zoom guide
    final done = prefs.getBool('video_gesture_guide_done_v2') ?? false;
    if (done || !mounted) return;

    setState(() {
      _showVideoGestureGuide = true;
    });
    await prefs.setBool('video_gesture_guide_done_v2', true);
  }

  Widget _buildVideoGestureGuideOverlay() {
    if (!_showVideoGestureGuide) return const SizedBox.shrink();

    return Positioned.fill(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _showVideoGestureGuide = false;
          });
        },
        child: Container(
          color: Colors.black.withValues(alpha: 0.85),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.touch_app_rounded, color: p.accent, size: 48),
              const SizedBox(height: 16),
              const Text(
                'Video Gesture Controls',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Master these intuitive gestures for quick control',
                style: TextStyle(color: Colors.white70, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),

              _buildGuideItem(
                icon: Icons.brightness_6_rounded,
                title: 'Brightness Control',
                description: 'Swipe Up/Down on the LEFT half of the screen.',
              ),
              const SizedBox(height: 20),
              _buildGuideItem(
                icon: Icons.volume_up_rounded,
                title: 'Volume Control',
                description: 'Swipe Up/Down on the RIGHT half of the screen.',
              ),
              const SizedBox(height: 20),
              _buildGuideItem(
                icon: Icons.zoom_in_rounded,
                title: 'Double Tap to Zoom',
                description:
                    'Double tap anywhere to zoom in. Double tap again to zoom back out.',
              ),
              const SizedBox(height: 20),
              _buildGuideItem(
                icon: Icons.speed_rounded,
                title: '2× Playback Speed',
                description:
                    'Long-press on the RIGHT half of the screen for instant 2× speed (restores on release).',
              ),

              const SizedBox(height: 40),

              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: p.accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 36,
                    vertical: 12,
                  ),
                  elevation: 0,
                ),
                onPressed: () {
                  setState(() {
                    _showVideoGestureGuide = false;
                  });
                },
                child: const Text(
                  'Got it',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGuideItem({
    required IconData icon,
    required String title,
    required String description,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: p.accent.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: p.accent.withValues(alpha: 0.3)),
          ),
          child: Icon(icon, color: p.accent, size: 22),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _onVideoUpdate() {
    if (_videoController == null || !mounted) return;
    final newPos = _videoController!.value.position.inMilliseconds / 1000.0;
    final newPlaying = _videoController!.value.isPlaying;

    final isFinished =
        _videoController!.value.position >= _videoController!.value.duration;
    if (isFinished &&
        _isSlideshowActive &&
        _videoController!.value.duration > Duration.zero) {
      _videoController!.pause();
      _goNext();
      return;
    }

    // Only rebuild when something actually changed to avoid excessive repaints
    if ((newPos - _currentPositionInSeconds).abs() > 0.05 ||
        newPlaying != _isVideoPlaying) {
      setState(() {
        _currentPositionInSeconds = newPos;
        _isVideoPlaying = newPlaying;
      });
      _updateWakelock();
    }
  }

  void _cyclePlaybackSpeed() {
    final speeds = [0.5, 1.0, 1.5, 2.0];
    final idx = speeds.indexOf(_playbackSpeed);
    final next = speeds[(idx + 1) % speeds.length];
    setState(() => _playbackSpeed = next);
    _videoController?.setPlaybackSpeed(next);
  }

  void _toggleVideoOrientation() {
    setState(() => _isVideoLandscape = !_isVideoLandscape);
    if (_isVideoLandscape) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
    HapticFeedback.lightImpact();
  }

  void _handleTapDown(TapDownDetails details, Size size) {
    final now = DateTime.now();
    if (_lastTapTime != null &&
        now.difference(_lastTapTime!) < const Duration(milliseconds: 300)) {
      // Double-tap → zoom in/out (same behaviour as the photo viewer)
      _onDoubleTapAt(details.localPosition, size);
      _lastTapTime = null;
    } else {
      _lastTapTime = now;
      Future.delayed(const Duration(milliseconds: 300), () {
        if (_lastTapTime == now) {
          _toggleChrome();
        }
      });
    }
  }

  void _skipVideo(bool forward) {
    if (_videoController == null || !_isVideoInitialized) return;

    final current = _videoController!.value.position;
    final skipDuration = const Duration(seconds: 10);
    final target = forward ? current + skipDuration : current - skipDuration;
    final maxDuration = _videoController!.value.duration;

    _videoController!.seekTo(
      forward
          ? (target > maxDuration ? maxDuration : target)
          : (target < Duration.zero ? Duration.zero : target),
    );

    setState(() {
      _showSkipIndicator = true;
      _isSkipForward = forward;
    });

    _skipIndicatorTimer?.cancel();
    _skipIndicatorTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) {
        setState(() {
          _showSkipIndicator = false;
        });
      }
    });

    HapticFeedback.lightImpact();
  }

  Future<void> _updateSystemVolume(double value) async {
    _videoController?.setVolume(value);
    if (!Platform.isAndroid) return;

    if (_isSettingSystemVolume) {
      _pendingSystemVolume = value;
      return;
    }

    _isSettingSystemVolume = true;
    try {
      const channel = MethodChannel('in.sddev.ghost_gallery/wallpaper');
      await channel.invokeMethod('setSystemVolume', {'volume': value});
    } catch (e) {
      debugPrint('Error setting system volume: $e');
    } finally {
      _isSettingSystemVolume = false;
      if (_pendingSystemVolume != null) {
        final nextVol = _pendingSystemVolume!;
        _pendingSystemVolume = null;
        _updateSystemVolume(nextVol);
      }
    }
  }

  Future<void> _initSystemVolume() async {
    if (Platform.isAndroid) {
      try {
        const channel = MethodChannel('in.sddev.ghost_gallery/wallpaper');
        final vol = await channel.invokeMethod<double>('getSystemVolume');
        if (vol != null && mounted) {
          setState(() {
            _videoVolume = vol;
          });
        }
      } catch (_) {}
    }
  }

  void _adjustVolume(double deltaY, double screenHeight) {
    if (_videoController == null) return;

    final change = -deltaY / screenHeight;
    setState(() {
      _videoVolume = (_videoVolume + change).clamp(0.0, 1.0);
      _showVolumeIndicator = true;
      _showBrightnessIndicator = false;
    });

    _updateSystemVolume(_videoVolume);

    _volumeIndicatorTimer?.cancel();
    _volumeIndicatorTimer = Timer(const Duration(milliseconds: 1000), () {
      if (mounted) {
        setState(() {
          _showVolumeIndicator = false;
        });
      }
    });
  }

  void _adjustBrightness(double deltaY, double screenHeight) {
    final change = -deltaY / screenHeight;
    setState(() {
      _videoBrightness = (_videoBrightness + change).clamp(0.0, 1.0);
      _showBrightnessIndicator = true;
      _showVolumeIndicator = false;
    });

    _brightnessIndicatorTimer?.cancel();
    _brightnessIndicatorTimer = Timer(const Duration(milliseconds: 1000), () {
      if (mounted) {
        setState(() {
          _showBrightnessIndicator = false;
        });
      }
    });
  }

  Widget _buildGestureHUDs() {
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_showVolumeIndicator)
              Positioned(
                top: 80,
                child: _buildHUDContainer(
                  icon: _videoVolume == 0
                      ? Icons.volume_off_rounded
                      : _videoVolume < 0.4
                      ? Icons.volume_down_rounded
                      : Icons.volume_up_rounded,
                  label: 'Volume',
                  percent: _videoVolume,
                ),
              ),
            if (_showBrightnessIndicator)
              Positioned(
                top: 80,
                child: _buildHUDContainer(
                  icon: _videoBrightness < 0.3
                      ? Icons.brightness_low_rounded
                      : _videoBrightness < 0.7
                      ? Icons.brightness_medium_rounded
                      : Icons.brightness_high_rounded,
                  label: 'Brightness',
                  percent: _videoBrightness,
                ),
              ),
            if (_showSkipIndicator)
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _isSkipForward
                            ? Icons.fast_forward_rounded
                            : Icons.fast_rewind_rounded,
                        color: Colors.white,
                        size: 40,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _isSkipForward ? '+10s' : '-10s',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHUDContainer({
    required IconData icon,
    required String label,
    required double percent,
  }) {
    return Container(
      width: 220,
      height: 50,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(25),
        border: Border.all(color: Colors.white10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: percent,
                    backgroundColor: Colors.white12,
                    valueColor: AlwaysStoppedAnimation<Color>(p.accent),
                    minHeight: 4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${(percent * 100).toInt()}%',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Chrome toggle ───────────────────────────────────────────────────────────
  void _toggleChrome() {
    setState(() {
      _showChrome = !_showChrome;
      if (_showChrome) {
        _chromeController.forward();
      } else {
        _chromeController.reverse();
        _showResolutionPanel = false;
        if (_showDetailsOverlay) {
          _showDetailsOverlay = false;
          _detailsController.reverse();
        }
      }
    });
    _updateSystemUi();
  }

  // ─── Zoom: double-tap ────────────────────────────────────────────────────────
  void _onDoubleTapAt(Offset localPos, Size size) {
    if (_zoomAnimController.isAnimating) return;

    _startScale = _transformationController.value.getMaxScaleOnAxis();
    _startOffset = Offset(
      _transformationController.value.entry(0, 3),
      _transformationController.value.entry(1, 3),
    );

    if (_isZoomed) {
      // Zoom out to 1×
      _targetScale = 1.0;
      _targetOffset = Offset.zero;
    } else {
      // Zoom in to 2.5× centered on tap point
      _targetScale = 2.5;
      final double tx = size.width / 2 - localPos.dx * _targetScale;
      final double ty = size.height / 2 - localPos.dy * _targetScale;
      _targetOffset = _clampOffset(Offset(tx, ty), size, _targetScale);
    }

    _zoomAnimController.forward(from: 0.0);
  }

  // ─── Zoom: clamp offset ──────────────────────────────────────────────────────
  Offset _clampOffset(Offset offset, Size size, double scale) {
    final maxX = (size.width * (scale - 1)) / 2;
    final maxY = (size.height * (scale - 1)) / 2;
    return Offset(offset.dx.clamp(-maxX, maxX), offset.dy.clamp(-maxY, maxY));
  }

  // ─── Flip / Undo / Redo ─────────────────────────────────────────────────────
  Future<void> _toggleFlip() async {
    final activeItem = _localItems[_currentIndex];
    final newFlip = !activeItem.isFlipped;

    final db = DatabaseHelper.instance;
    final dbClient = await db.database;
    await dbClient.update(
      'media_items',
      {'is_flipped': newFlip ? 1 : 0},
      where: 'id = ?',
      whereArgs: [activeItem.id],
    );

    setState(() {
      _localItems[_currentIndex] = activeItem.copyWith(isFlipped: newFlip);
    });
    HapticFeedback.lightImpact();
  }

  // ─── Resolution helpers ──────────────────────────────────────────────────────
  String _getResolutionString() {
    final activeItem = _localItems[_currentIndex];
    int bW = 3060, bH = 4080;
    final parts = activeItem.resolution.split(RegExp(r'[x×]'));
    if (parts.length == 2) {
      bW = int.tryParse(parts[0].trim()) ?? bW;
      bH = int.tryParse(parts[1].trim()) ?? bH;
    }
    return '${(bW * _resolutionProgress).toInt()} × ${(bH * _resolutionProgress).toInt()}';
  }

  String _getFileSizeDisplay() {
    final activeItem = _localItems[_currentIndex];
    double base =
        double.tryParse(activeItem.size.replaceAll(RegExp(r'[a-zA-Z ]'), '')) ??
        3.53;
    if (activeItem.size.toLowerCase().contains('kb')) base /= 1024;
    double factor = (_resolutionProgress * _qualityProgress).clamp(0.1, 1.0);
    return '~${(base * factor).toStringAsFixed(2)} MB';
  }

  // ─── Save ────────────────────────────────────────────────────────────────────
  Future<void> _handleSaveOption(String option) async {
    setState(() => _showResolutionPanel = false);
    final activeItem = _localItems[_currentIndex];

    if (activeItem.mediaType == 'video') {
      _showSnack('Resolution changes are for images only.');
      return;
    }

    _showProgressDialog('Saving…');

    try {
      final bytes = activeItem.imageUrl.startsWith('http')
          ? await _fetchRemoteBytes(activeItem.imageUrl)
          : await File(activeItem.imageUrl).readAsBytes();

      final bitmap = img.decodeImage(bytes);
      if (bitmap == null) throw Exception('Could not decode image');

      final tW = (bitmap.width * _resolutionProgress).toInt();
      final tH = (bitmap.height * _resolutionProgress).toInt();
      final resized = img.copyResize(bitmap, width: tW, height: tH);
      final encoded = img.encodeJpg(
        resized,
        quality: (_qualityProgress * 100).toInt(),
      );

      final db = DatabaseHelper.instance;
      final isOverwrite = option == 'overwrite';

      if (isOverwrite && !activeItem.imageUrl.startsWith('http')) {
        await File(activeItem.imageUrl).writeAsBytes(encoded);
        final size = '${(encoded.length / 1048576).toStringAsFixed(2)} MB';
        final res = '$tW × $tH';
        activeItem.resolution = res;
        activeItem.size = size;
        await db.updateMediaItemResolutionAndSize(activeItem.id, res, size);
      } else {
        String path;
        if (activeItem.imageUrl.startsWith('http')) {
          final dir = await getApplicationDocumentsDirectory();
          path =
              '${dir.path}/copy_${DateTime.now().millisecondsSinceEpoch}.jpg';
        } else {
          try {
            final originalFile = File(activeItem.imageUrl);
            final parentDir = originalFile.parent.path;
            final fileName = originalFile.path
                .split(Platform.isWindows ? '\\' : '/')
                .last;
            final nameParts = fileName.split('.');
            final ext = nameParts.length > 1 ? nameParts.last : 'jpg';
            final baseName = nameParts.first;
            final separator = Platform.isWindows ? '\\' : '/';
            final candidatePath =
                '$parentDir$separator${baseName}_copy_${DateTime.now().millisecondsSinceEpoch}.$ext';

            // Try creating a test file to verify write permission
            final testFile = File(
              '$parentDir$separator.write_test_${DateTime.now().millisecondsSinceEpoch}',
            );
            await testFile.writeAsString('test');
            await testFile.delete();

            path = candidatePath;
          } catch (_) {
            // Permission denied or write failed, fall back to safe app sandbox
            final dir = await getApplicationDocumentsDirectory();
            path =
                '${dir.path}/copy_${DateTime.now().millisecondsSinceEpoch}.jpg';
          }
        }
        await File(path).writeAsBytes(encoded);
        await db.insertMediaItem({
          'id': 'imported_${DateTime.now().millisecondsSinceEpoch}',
          'path': path,
          'media_type': 'image',
          'duration': 0.0,
          'date_timestamp': DateTime.now().millisecondsSinceEpoch,
          'date': 'Today',
          'location': activeItem.location.isNotEmpty ? activeItem.location : '',
          'is_processed': 0,
          'width': tW,
          'height': tH,
          'size': '${(encoded.length / 1048576).toStringAsFixed(2)} MB',
          'camera_info': 'Edited',
        });

        // Sync viewer items with SQLite so new copy displays instantly!
        await _syncViewerItemsWithDB(path);
      }

      if (mounted) Navigator.pop(context); // Dismiss saving progress dialog
      _showSnack(isOverwrite ? 'Saved (overwritten).' : 'Saved as copy.');
      setState(() {});
    } catch (e) {
      if (mounted) Navigator.pop(context); // Dismiss saving progress dialog
      _showSnack('Save failed: $e');
    }
  }

  Future<void> _syncViewerItemsWithDB(String path) async {
    final db = DatabaseHelper.instance;
    final allMaps = await db.getAllMediaItems();
    final newMap = allMaps.firstWhere(
      (m) => m['path'] == path,
      orElse: () => <String, dynamic>{},
    );
    if (newMap.isEmpty) return;

    final newItem = GalleryItem.fromMap(newMap);

    setState(() {
      final existingIndex = _localItems.indexWhere(
        (x) => x.id == newItem.id || x.imageUrl == path,
      );
      if (existingIndex != -1) {
        _localItems[existingIndex] = newItem;
      } else {
        _localItems.insert(_currentIndex + 1, newItem);
        _currentIndex = _currentIndex + 1;
        _pageController.jumpToPage(_currentIndex);
      }
    });
  }

  Future<Uint8List> _fetchRemoteBytes(String url) async {
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close();
    final chunks = <int>[];
    await for (final chunk in res) {
      chunks.addAll(chunk);
    }
    return Uint8List.fromList(chunks);
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────────
  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        backgroundColor: p.onSurface,
      ),
    );
  }

  Route? _progressDialogRoute;

  void _showProgressDialog(String msg) {
    _dismissProgressDialog();

    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(
        child: Container(
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 16)],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: p.accent),
              const SizedBox(height: 16),
              Text(
                msg,
                style: TextStyle(
                  color: p.onSurface,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ],
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

  String _getPersonName(String? id) {
    if (id == null) return 'Unknown';
    final m = _people.where((p) => p['id'] == id);
    return m.isEmpty ? 'Face Cluster' : m.first['name'] as String;
  }

  String _getPersonRelation(String? id) {
    if (id == null) return 'Unknown';
    final m = _people.where((p) => p['id'] == id);
    return m.isEmpty ? 'Face Cluster' : m.first['relation'] as String;
  }

  String? _getPersonCoverImage(String? id) {
    if (id == null) return null;
    final m = _people.where((p) => p['id'] == id);
    return m.isEmpty ? null : m.first['cover_image'] as String?;
  }

  String _formatDuration(double s) {
    if (s.isNaN || s.isInfinite) return '0:00';
    final m = (s / 60).floor();
    final sec = (s % 60).floor();
    return '$m:${sec.toString().padLeft(2, '0')}';
  }

  // ─── Sub-actions ─────────────────────────────────────────────────────────────
  Future<void> _openEditor(String tool) async {
    final item = _localItems[_currentIndex];
    if (item.mediaType == 'video') {
      _videoController?.pause();

      String videoPath = item.imageUrl;

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VideoEditorPage(
            videoUrl: videoPath,
            onSave: (path) async {
              await _saveEditedMedia(
                originalItem: item,
                editedFilePath: path,
                isVideo: true,
              );
            },
          ),
        ),
      );

      if (mounted && _localItems[_currentIndex].id == item.id) {
        _videoController?.play();
      }
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CustomPhotoEditorPage(
          imageUrl: item.imageUrl,
          initialTool: tool,
          onSave: (path) async {
            await _saveEditedMedia(
              originalItem: item,
              editedFilePath: path,
              isVideo: false,
            );
          },
        ),
      ),
    );
  }

  Future<void> _saveEditedMedia({
    required GalleryItem originalItem,
    required String editedFilePath,
    required bool isVideo,
  }) async {
    const option = 'copy';
    bool saveSuccess = false;
    String? finalNewId;

    _showProgressDialog("Saving edited media copy…");
    try {
      final editedFile = File(editedFilePath);
      if (!await editedFile.exists()) {
        throw Exception("Edited file not found on disk");
      }
      final bytes = await editedFile.readAsBytes();
      final filename = editedFilePath
          .split(Platform.isWindows ? '\\' : '/')
          .last;

      final db = DatabaseHelper.instance;

      if (option == 'original') {
        // --- Save as Original ---
        String newPath = editedFilePath;
        String newId = originalItem.id;

        if (Platform.isAndroid) {
          Map<dynamic, dynamic>? savedResult;
          if (isVideo) {
            savedResult =
                await const MethodChannel(
                  'in.sddev.ghost_gallery/media_manager',
                ).invokeMethod<Map<dynamic, dynamic>>('saveVideoToGallery', {
                  'filePath': editedFilePath,
                  'title': filename,
                  'relativePath': 'Movies/Ghost Gallery Edit',
                });
          } else {
            savedResult =
                await const MethodChannel(
                  'in.sddev.ghost_gallery/media_manager',
                ).invokeMethod<Map<dynamic, dynamic>>('saveImageToGallery', {
                  'bytes': bytes,
                  'title': filename,
                  'relativePath': 'Pictures/Ghost Gallery Edit',
                });
          }

          try {
            await const MethodChannel(
              'in.sddev.ghost_gallery/media_manager',
            ).invokeMethod('deleteMedia', {
              'filePaths': [originalItem.imageUrl],
              'mediaIds': [originalItem.id],
            });
          } catch (_) {}

          if (savedResult != null) {
            newPath = savedResult['path']?.toString() ?? editedFilePath;
            newId = savedResult['id']?.toString() ?? originalItem.id;
          }
        } else {
          final origFile = File(originalItem.imageUrl);
          await origFile.writeAsBytes(bytes);
          newPath = originalItem.imageUrl;
        }

        int width = originalItem.width;
        int height = originalItem.height;
        if (!isVideo) {
          final decoded = img.decodeImage(bytes);
          if (decoded != null) {
            width = decoded.width;
            height = decoded.height;
          }
        }
        final sizeStr = '${(bytes.length / 1048576).toStringAsFixed(2)} MB';

        final dbClient = await db.database;
        if (newId != originalItem.id) {
          await db.deleteMediaItem(originalItem.id);
          await db.insertMediaItem({
            'id': newId,
            'path': newPath,
            'media_type': originalItem.mediaType,
            'duration': originalItem.duration ?? 0.0,
            'date_timestamp': DateTime.now().millisecondsSinceEpoch,
            'date': 'Today',
            'location': originalItem.location,
            'is_processed': 0,
            'width': width,
            'height': height,
            'size': sizeStr,
            'camera_info': 'Edited Original',
          });
        } else {
          await dbClient.update(
            'media_items',
            {
              'path': newPath,
              'width': width,
              'height': height,
              'size': sizeStr,
            },
            where: 'id = ?',
            whereArgs: [originalItem.id],
          );
        }

        await _syncViewerItemsWithDB(newPath);
        _showSnack("Successfully overwrote original media!");
      } else {
        // --- Save as Copy ---
        String newPath = editedFilePath;
        String newId = 'imported_${DateTime.now().millisecondsSinceEpoch}';

        if (Platform.isAndroid) {
          Map<dynamic, dynamic>? savedResult;
          if (isVideo) {
            savedResult =
                await const MethodChannel(
                  'in.sddev.ghost_gallery/media_manager',
                ).invokeMethod<Map<dynamic, dynamic>>('saveVideoToGallery', {
                  'filePath': editedFilePath,
                  'title': filename,
                  'relativePath': 'Movies/Ghost Gallery Edit',
                });
          } else {
            savedResult =
                await const MethodChannel(
                  'in.sddev.ghost_gallery/media_manager',
                ).invokeMethod<Map<dynamic, dynamic>>('saveImageToGallery', {
                  'bytes': bytes,
                  'title': filename,
                  'relativePath': 'Pictures/Ghost Gallery Edit',
                });
          }

          if (savedResult != null) {
            newPath = savedResult['path']?.toString() ?? editedFilePath;
            newId =
                savedResult['id']?.toString() ??
                'imported_${DateTime.now().millisecondsSinceEpoch}';
          }
        } else {
          final origFile = File(originalItem.imageUrl);
          final parent = origFile.parent.path;
          final separator = Platform.isWindows ? '\\' : '/';
          final editDir = Directory('$parent${separator}Ghost Gallery Edit');
          if (!await editDir.exists()) {
            await editDir.create(recursive: true);
          }
          newPath = '${editDir.path}$separator$filename';
          await File(newPath).writeAsBytes(bytes);
        }

        int width = originalItem.width;
        int height = originalItem.height;
        if (!isVideo) {
          final decoded = img.decodeImage(bytes);
          if (decoded != null) {
            width = decoded.width;
            height = decoded.height;
          }
        }
        final sizeStr = '${(bytes.length / 1048576).toStringAsFixed(2)} MB';

        await db.insertMediaItem({
          'id': newId,
          'path': newPath,
          'media_type': originalItem.mediaType,
          'duration': originalItem.duration ?? 0.0,
          'date_timestamp': DateTime.now().millisecondsSinceEpoch,
          'date': 'Today',
          'location': originalItem.location,
          'is_processed': 0,
          'width': width,
          'height': height,
          'size': sizeStr,
          'camera_info': 'Edited Copy',
          'album_name': 'Ghost Gallery Edit',
          'album_category': 'Ghost Gallery Edit',
        });

        await _syncViewerItemsWithDB(newPath);
        _showSnack("Saved copy in 'Ghost Gallery Edit' album!");
        saveSuccess = true;
        finalNewId = newId;
      }
      _loadRelationalData();
    } catch (e) {
      debugPrint("Error saving edited media: $e");
      _showSnack("Failed to save media: $e");
    } finally {
      if (mounted) Navigator.pop(context); // Dismiss progress dialog
      try {
        final f = File(editedFilePath);
        if (f.existsSync()) {
          f.deleteSync();
          debugPrint("PhotoViewerPage: Cleaned up temporary edited file: $editedFilePath");
        }
      } catch (e) {
        debugPrint("PhotoViewerPage: Error cleaning up temporary edited file: $e");
      }
    }

    if (saveSuccess && finalNewId != null && option == 'copy') {
      final db = DatabaseHelper.instance;
      final allMaps = await db.getAllMediaItems();
      final ghostEditItems = allMaps
          .where(
            (map) =>
                (map['album_name'] as String? ?? '') == 'Ghost Gallery Edit',
          )
          .map((map) => GalleryItem.fromMap(map))
          .toList();

      ghostEditItems.sort((a, b) => b.dateTimestamp.compareTo(a.dateTimestamp));

      int newIdx = ghostEditItems.indexWhere((x) => x.id == finalNewId);
      if (newIdx == -1 && ghostEditItems.isNotEmpty) {
        newIdx = 0;
      }

      if (mounted && ghostEditItems.isNotEmpty) {
        final targetIdx = newIdx != -1 ? newIdx : 0;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => PhotoViewerPage(
              item: ghostEditItems[targetIdx],
              allItems: ghostEditItems,
              ghostPersonality: widget.ghostPersonality,
              onDelete: widget.onDelete,
            ),
          ),
        );
      }
    }
  }

  void _shareMedia() {
    final item = _localItems[_currentIndex];
    final file = File(item.imageUrl);
    if (file.existsSync()) {
      Share.shareXFiles([XFile(item.imageUrl)]);
    } else {
      _showSnack('Cannot share remote media directly.');
    }
  }

  Future<void> _deleteCurrentItem() async {
    final activeItem = _localItems[_currentIndex];
    final messenger = ScaffoldMessenger.of(context);

    try {
      if (widget.isVault) {
        try {
          await widget.onDelete(activeItem.id);
        } catch (e) {
          debugPrint("Error notifying parent of vault deletion: $e");
        }

        setState(() {
          _localItems.removeAt(_currentIndex);
          _videoController?.removeListener(_onVideoUpdate);
          _videoController?.dispose();
          _videoController = null;
          _isVideoInitialized = false;

          if (_localItems.isEmpty) {
            Navigator.pop(context);
          } else {
            if (_currentIndex >= _localItems.length) {
              _currentIndex = _localItems.length - 1;
            }
            _pageController.jumpToPage(_currentIndex);
            final newActiveItem = _localItems[_currentIndex];
            if (newActiveItem.mediaType == 'video') {
              _initVideoPlayer(newActiveItem.imageUrl);
            }
          }
        });
        _showSnack("Item deleted permanently from Vault.");
        return;
      }

      final isLocal =
          activeItem.id.startsWith('win_') ||
          activeItem.id.startsWith('imported_') ||
          activeItem.id.startsWith('captured_');
      if (!isLocal && Platform.isAndroid) {
        final granted =
            await MediaPermissionService.ensureManageMediaPermission(context);
        if (!granted) return;
      }

      await MediaPermissionService.showBatchProgressDialog(
        context: context,
        title: "Moving Media to Trash",
        totalCount: 1,
        action: (onProgress) => TrashPersistence.softDeleteAll(
          [activeItem],
          context: context,
          onProgress: onProgress,
        ),
      );

      try {
        await widget.onDelete(activeItem.id);
      } catch (e) {
        debugPrint("Error notifying parent of deletion: $e");
      }

      final deletedItem = activeItem;
      final deletedIndex = _currentIndex;
      final messenger = ScaffoldMessenger.of(context);
      final parentOnDelete = widget.onDelete;

      bool isEmpty = false;
      setState(() {
        _localItems.removeAt(_currentIndex);

        _videoController?.removeListener(_onVideoUpdate);
        _videoController?.dispose();
        _videoController = null;
        _isVideoInitialized = false;

        if (_localItems.isEmpty) {
          isEmpty = true;
          Navigator.pop(context);
        } else {
          if (_currentIndex >= _localItems.length) {
            _currentIndex = _localItems.length - 1;
          }

          _pageController.jumpToPage(_currentIndex);

          final newActiveItem = _localItems[_currentIndex];
          if (newActiveItem.mediaType == 'video') {
            _initVideoPlayer(newActiveItem.imageUrl);
          }
        }
      });

      if (isEmpty) {
        messenger.clearSnackBars();
        messenger.showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 5),
            backgroundColor: Colors.transparent,
            elevation: 0,
            content: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white10),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const Icon(Icons.delete_outline, color: Colors.white70),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Moved to Recently Deleted.',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      messenger.hideCurrentSnackBar();
                      try {
                        final isLocal =
                            deletedItem.id.startsWith('win_') ||
                            deletedItem.id.startsWith('imported_') ||
                            deletedItem.id.startsWith('captured_');
                        if (!isLocal && Platform.isAndroid && context.mounted) {
                          final granted =
                              await MediaPermissionService.ensureManageMediaPermission(
                                context,
                              );
                          if (!granted) return;
                        }

                        if (context.mounted) {
                          await MediaPermissionService.showBatchProgressDialog(
                            context: context,
                            title: "Restoring Media File",
                            totalCount: 1,
                            action: (onProgress) => TrashPersistence.restore(
                              [deletedItem.id],
                              context: context,
                              onProgress: onProgress,
                            ),
                          );
                        }
                        try {
                          await parentOnDelete('');
                        } catch (e) {
                          debugPrint("Error notifying parent of restore: $e");
                        }
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text("Item restored successfully."),
                          ),
                        );
                      } catch (e) {
                        debugPrint("Undo restore error: $e");
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text("Failed to restore item."),
                          ),
                        );
                      }
                    },
                    child: Text(
                      'UNDO',
                      style: TextStyle(
                        color: p.accent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        return;
      }

      _loadRelationalData();

      if (mounted) {
        messenger.clearSnackBars();
        messenger.showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 5),
            backgroundColor: Colors.transparent,
            elevation: 0,
            content: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white10),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const Icon(Icons.delete_outline, color: Colors.white70),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Moved to Recently Deleted.',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                      }

                      try {
                        final isLocal =
                            deletedItem.id.startsWith('win_') ||
                            deletedItem.id.startsWith('imported_') ||
                            deletedItem.id.startsWith('captured_');
                        if (!isLocal && Platform.isAndroid && context.mounted) {
                          final granted =
                              await MediaPermissionService.ensureManageMediaPermission(
                                context,
                              );
                          if (!granted) return;
                        }

                        if (context.mounted) {
                          await MediaPermissionService.showBatchProgressDialog(
                            context: context,
                            title: "Restoring Media File",
                            totalCount: 1,
                            action: (onProgress) => TrashPersistence.restore(
                              [deletedItem.id],
                              context: context,
                              onProgress: onProgress,
                            ),
                          );
                        }

                        try {
                          await widget.onDelete('');
                        } catch (e) {
                          debugPrint("Error notifying parent of restore: $e");
                        }

                        setState(() {
                          _localItems.insert(deletedIndex, deletedItem);
                          _currentIndex = deletedIndex;

                          _pageController.jumpToPage(_currentIndex);
                          _videoController?.removeListener(_onVideoUpdate);
                          _videoController?.dispose();
                          _videoController = null;
                          _isVideoInitialized = false;
                          if (deletedItem.mediaType == 'video') {
                            _initVideoPlayer(deletedItem.imageUrl);
                          }
                        });

                        _loadRelationalData();
                        _showSnack("Item restored successfully.");
                      } catch (e) {
                        debugPrint("Undo restore error in viewer: $e");
                        _showSnack("Failed to restore item.");
                      }
                    },
                    child: Text(
                      'UNDO',
                      style: TextStyle(
                        color: p.accent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint("Error soft deleting item in viewer: $e");
      _showSnack("Failed to delete item.");
    }
  }

  Future<void> _restoreVaultItem() async {
    final activeItem = _localItems[_currentIndex];
    final messenger = ScaffoldMessenger.of(context);
    _showProgressDialog("Restoring item out of Vault…");
    try {
      final vaultItems = await VaultService.instance.getAllVaultItems();
      final vaultItem = vaultItems.firstWhere(
        (x) => x.id == activeItem.id,
        orElse: () => throw Exception('Item not found in Vault database'),
      );

      final restoredPath = await VaultService.instance.removeFromVault(
        item: vaultItem,
        restore: true,
      );
      final isFallback = restoredPath.contains("Ghost Vault Restore");

      try {
        await widget.onDelete(activeItem.id);
      } catch (e) {
        debugPrint("Error notifying parent of restore: $e");
      }

      if (Platform.isAndroid) {
        await DeviceMediaScanner.instance.scanAndSyncDeviceMedia(force: true);
      }
      await CollectionSource.instance.refresh();

      if (mounted) Navigator.pop(context); // Close the progress dialog

      bool isEmpty = false;
      setState(() {
        _localItems.removeAt(_currentIndex);

        _videoController?.removeListener(_onVideoUpdate);
        _videoController?.dispose();
        _videoController = null;
        _isVideoInitialized = false;

        if (_localItems.isEmpty) {
          isEmpty = true;
          Navigator.pop(context); // Close the viewer screen
        } else {
          if (_currentIndex >= _localItems.length) {
            _currentIndex = _localItems.length - 1;
          }

          _pageController.jumpToPage(_currentIndex);

          final newActiveItem = _localItems[_currentIndex];
          if (newActiveItem.mediaType == 'video') {
            _initVideoPlayer(newActiveItem.imageUrl);
          }
        }
      });

      final successMsg = isFallback
          ? "Item restored to 'Ghost Vault Restore' folder."
          : "Item successfully restored out of Vault.";

      if (isEmpty) {
        messenger.clearSnackBars();
        messenger.showSnackBar(SnackBar(content: Text(successMsg)));
        return;
      }

      _loadRelationalData();
      _showSnack(successMsg);
    } catch (e) {
      if (mounted) Navigator.pop(context); // Dismiss progress dialog
      debugPrint("Restore vault item error: $e");
      _showSnack("Failed to restore vault item: $e");
    }
  }

  void _confirmDelete() {
    if (widget.isVault) {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: p.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: p.danger),
              const SizedBox(width: 8),
              Text(
                'Permanently Delete?',
                style: TextStyle(color: p.danger, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: Text(
            'Are you sure you want to permanently delete this item?\n\n'
            '⚠️ WARNING: This item will be permanently removed from both the Secure Vault and your device storage. This action cannot be undone.',
            style: TextStyle(color: p.muted, height: 1.45),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel', style: TextStyle(color: p.muted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: p.danger,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () {
                Navigator.pop(context);
                _deleteCurrentItem();
              },
              child: const Text(
                'Delete Permanently',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: p.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Move to Trash?',
          style: TextStyle(color: p.onSurface, fontWeight: FontWeight.bold),
        ),
        content: Text(
          'Move this item to the Trash? You can restore it from the Recently Deleted album later.\n\nTrash files will be permanently deleted after 30 days.',
          style: TextStyle(color: p.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: p.muted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: p.danger,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () {
              Navigator.pop(context);
              _deleteCurrentItem();
            },
            child: const Text(
              'Move to Trash',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  // ─── AVES-STYLE MODERN FUNCTIONAL ACTIONS ──────────────────────────────────
  Future<void> _renameActiveItem(String newName) async {
    if (newName.trim().isEmpty) return;

    final activeItem = _localItems[_currentIndex];
    final file = File(activeItem.imageUrl);
    if (!await file.exists()) {
      _showSnack("Local file does not exist on disk.");
      return;
    }

    if (Platform.isAndroid) {
      final granted = await MediaPermissionService.ensureManageMediaPermission(
        context,
      );
      if (!granted) {
        _showSnack("Permission denied.");
        return;
      }
    }

    _showProgressDialog("Renaming…");

    try {
      final ext = file.path.split('.').last;
      String newPath = file.path;
      String newId = activeItem.id;

      if (Platform.isAndroid) {
        final newFilename = "$newName.$ext";
        final renamedPath = await TrashPersistence.renameViaNative(
          null,
          file.path,
          newFilename,
          mediaId: activeItem.id,
        );
        if (renamedPath != null) {
          newPath = renamedPath;
        } else {
          throw Exception("Failed to rename media file on Android.");
        }
      } else {
        final dir = file.parent.path;
        final separator = Platform.isWindows ? '\\' : '/';
        newPath = '$dir$separator$newName.$ext';
        await file.rename(newPath);
      }

      // Update SQLite database
      final db = DatabaseHelper.instance;
      if (newId != activeItem.id) {
        await db.deleteMediaItem(activeItem.id);
        await db.insertMediaItem({
          'id': newId,
          'path': newPath,
          'media_type': activeItem.mediaType,
          'duration': activeItem.duration ?? 0.0,
          'date_timestamp': activeItem.dateTimestamp,
          'date': activeItem.date,
          'location': activeItem.location,
          'is_processed': activeItem.isProcessed,
          'width': activeItem.width,
          'height': activeItem.height,
          'size': activeItem.size,
          'camera_info': activeItem.cameraInfo,
          'album_name': activeItem.albumCategory.isNotEmpty
              ? activeItem.albumCategory
              : 'Camera',
          'album_category': activeItem.albumCategory.isNotEmpty
              ? activeItem.albumCategory
              : 'Camera',
        });
      } else {
        final dbClient = await db.database;
        await dbClient.update(
          'media_items',
          {'path': newPath},
          where: 'id = ?',
          whereArgs: [activeItem.id],
        );
      }

      // Evict from ImageCache
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      // Update state
      if (mounted) {
        setState(() {
          _localItems[_currentIndex] = activeItem.copyWith(imageUrl: newPath);
        });
        _showSnack("Renamed successfully!");
      }
    } catch (e) {
      debugPrint("Error renaming file: $e");
      if (mounted) {
        _showSnack("Failed to rename: $e");
      }
    } finally {
      _dismissProgressDialog();
    }
  }

  Future<void> _rotateImageActiveItem() async {
    final activeItem = _localItems[_currentIndex];
    if (activeItem.mediaType == 'video') {
      _showSnack('Rotation is supported for images only.');
      return;
    }

    final newRotation = (activeItem.rotationDegrees + 90) % 360;

    try {
      final db = DatabaseHelper.instance;
      final dbClient = await db.database;
      await dbClient.update(
        'media_items',
        {'rotation_degrees': newRotation},
        where: 'id = ?',
        whereArgs: [activeItem.id],
      );

      setState(() {
        _localItems[_currentIndex] = activeItem.copyWith(
          rotationDegrees: newRotation,
        );
      });

      HapticFeedback.lightImpact();
      _showSnack("Successfully rotated image!");
    } catch (e) {
      debugPrint("Error rotating image: $e");
      _showSnack("Failed to rotate: $e");
    }
  }

  Future<void> _copyMoveMediaToAlbum(String newAlbumName, bool isMove) async {
    if (newAlbumName.trim().isEmpty) return;

    final activeItem = _localItems[_currentIndex];
    final file = File(activeItem.imageUrl);
    if (!await file.exists()) {
      _showSnack("Local file does not exist.");
      return;
    }

    _showProgressDialog(isMove ? "Moving media…" : "Copying media…");

    try {
      final separator = Platform.isWindows ? '\\' : '/';
      final grandParent = file.parent.parent.path;
      final targetFolder = '$grandParent$separator$newAlbumName';

      // Create target directory if it doesn't exist
      await Directory(targetFolder).create(recursive: true);

      final fileName = file.path.split(separator).last;

      // Prevent collisions: prepend timestamp if file already exists
      String targetPath = '$targetFolder$separator$fileName';
      if (await File(targetPath).exists()) {
        final ext = fileName.split('.').last;
        final nameWithoutExt = fileName.substring(
          0,
          fileName.length - ext.length - 1,
        );
        targetPath =
            '$targetFolder$separator${nameWithoutExt}_${DateTime.now().millisecondsSinceEpoch}.$ext';
      }

      final db = DatabaseHelper.instance;
      final dbClient = await db.database;

      if (isMove) {
        // Move file on-disk
        await file.rename(targetPath);

        // Update database row
        await dbClient.update(
          'media_items',
          {
            'path': targetPath,
            'album_name': newAlbumName,
            'album_category': newAlbumName,
          },
          where: 'id = ?',
          whereArgs: [activeItem.id],
        );

        // Evict from ImageCache
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();

        // Update local item
        setState(() {
          _localItems[_currentIndex] = activeItem.copyWith(
            imageUrl: targetPath,
            albumCategory: newAlbumName,
          );
        });

        _showSnack("Moved successfully to album '$newAlbumName'!");
      } else {
        // Copy file on-disk
        await file.copy(targetPath);

        // Insert new database row for copy
        final newId = 'imported_${DateTime.now().millisecondsSinceEpoch}';

        final origMap = await db.getMediaItemById(activeItem.id);
        final Map<String, dynamic> newMap = Map<String, dynamic>.from(
          origMap ?? {},
        );
        newMap['id'] = newId;
        newMap['path'] = targetPath;
        newMap['album_name'] = newAlbumName;
        newMap['album_category'] = newAlbumName;
        newMap['date_timestamp'] = DateTime.now().millisecondsSinceEpoch;
        newMap['date'] = 'Today';

        await db.insertMediaItem(newMap);

        // Refresh viewer list from SQLite to display copied image
        await _syncViewerItemsWithDB(targetPath);

        _showSnack("Copied successfully to album '$newAlbumName'!");
      }
    } catch (e) {
      debugPrint("Error copy/moving file: $e");
      _showSnack("Operation failed: $e");
    } finally {
      if (mounted) Navigator.pop(context); // Dismiss progress dialog
    }
  }

  Future<void> _showOnMemoriesMap() async {
    final activeItem = _localItems[_currentIndex];
    if (!activeItem.hasGps) {
      _showSnack("This media item has no GPS metadata coordinates.");
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MapViewScreen(highlightItem: activeItem),
      ),
    );
  }

  void _copyGpsCoordinates() {
    final activeItem = _localItems[_currentIndex];
    if (!activeItem.hasGps) {
      _showSnack("This media item has no GPS metadata coordinates.");
      return;
    }

    Clipboard.setData(
      ClipboardData(text: "${activeItem.latitude}, ${activeItem.longitude}"),
    );
    _showSnack("GPS coordinates copied to clipboard!");
  }

  /// [sheetContext] is the BuildContext of the bottom-sheet that contains this
  /// tile. We pop that sheet explicitly before pushing the editor so we use the
  /// correct navigator scope — not the viewer's outer context.
  Future<void> _setAsWallpaper({required BuildContext sheetContext}) async {
    final activeItem = _localItems[_currentIndex];
    if (activeItem.mediaType == 'video') {
      _showSnack("Cannot set a video as wallpaper.");
      return;
    }

    // Dismiss the 'More options' sheet using its own navigator entry.
    // Using rootNavigator:false ensures we only pop the modal sheet route,
    // never the PhotoViewerScreen itself.
    try {
      Navigator.of(sheetContext, rootNavigator: false).pop();
    } catch (_) {
      // Sheet already dismissed — safe to ignore.
    }

    // Small delay so the sheet's pop animation completes before we push the
    // editor — prevents route-stack conflicts.
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    // Use a Completer so the saved path is captured synchronously by onSave
    // and then read AFTER Navigator.push returns (editor fully dismounted).
    final completer = Completer<String>();

    // Navigate to CustomPhotoEditorPage for wallpaper cropping & rotation.
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CustomPhotoEditorPage(
          imageUrl: activeItem.imageUrl,
          forWallpaper: true,
          onSave: (editedPath) {
            if (!completer.isCompleted) {
              completer.complete(editedPath);
            }
          },
        ),
      ),
    );

    // Editor route fully popped — now safe to show the target-selection sheet.
    if (!mounted) return;
    if (completer.isCompleted) {
      final savedPath = await completer.future;
      _showWallpaperScreenSelectionDialog(savedPath);
    }
  }

  void _showWallpaperScreenSelectionDialog(String imagePath) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final cardColor = Theme.of(ctx).cardColor;
        final onSurface = Theme.of(ctx).colorScheme.onSurface;
        final border = Theme.of(ctx).dividerColor;

        return Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 16, spreadRadius: 1),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 5,
                    decoration: BoxDecoration(
                      color: border,
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  "Apply Wallpaper 👻",
                  style: TextStyle(
                    color: onSurface,
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  "Choose where you want to apply this wallpaper",
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),

                // Wallpaper Cropped Preview
                Center(
                  child: Container(
                    height: 140,
                    width: 95,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: border, width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.15),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10.5),
                      child: Image.file(File(imagePath), fit: BoxFit.cover),
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // Platform dependent options
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.primaryContainer,
                    foregroundColor: Theme.of(ctx).colorScheme.primary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _applyWallpaper(imagePath, 'home');
                  },
                  icon: const Icon(Icons.home_outlined),
                  label: const Text(
                    "Home Screen",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(
                      ctx,
                    ).colorScheme.secondaryContainer,
                    foregroundColor: Theme.of(ctx).colorScheme.secondary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _applyWallpaper(imagePath, 'lock');
                  },
                  icon: const Icon(Icons.lock_outline),
                  label: const Text(
                    "Lock Screen",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.primary,
                    foregroundColor: Theme.of(ctx).colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _applyWallpaper(imagePath, 'both');
                  },
                  icon: const Icon(Icons.phonelink_setup_rounded),
                  label: const Text(
                    "Home & Lock Screen",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    // Delete temp file on cancel
                    try {
                      File(imagePath).delete();
                    } catch (_) {}
                  },
                  child: const Text(
                    "Cancel",
                    style: TextStyle(
                      color: Colors.grey,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _applyWallpaper(String path, String screen) async {
    // Show progress dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );

    try {
      if (Platform.isAndroid) {
        WallpaperTarget target;
        switch (screen) {
          case 'home':
            target = WallpaperTarget.home;
            break;
          case 'lock':
            target = WallpaperTarget.lock;
            break;
          default:
            target = WallpaperTarget.both;
        }

        final result = await AsyncWallpaper.setWallpaper(
          WallpaperRequest(
            target: target,
            sourceType: WallpaperSourceType.file,
            source: path,
          ),
        );

        if (result.isSuccess) {
          _showSnack("Wallpaper applied successfully!");
        } else {
          _showSnack("Failed to apply wallpaper: ${result.error?.message}");
        }
      } else if (Platform.isWindows) {
        final absolutePath = File(path).absolute.path;
        final psCommand =
            'Add-Type -TypeDefinition \'using System; using System.Runtime.InteropServices; public class Wallpaper { [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni); }\'; [Wallpaper]::SystemParametersInfo(20, 0, "$absolutePath", 3)';
        final result = await Process.run('powershell', ['-Command', psCommand]);
        if (result.exitCode == 0) {
          _showSnack("Wallpaper applied successfully!");
        } else {
          _showSnack("Failed to apply wallpaper: ${result.stderr}");
        }
      } else {
        _showSnack("Set as Wallpaper is not supported on this platform.");
      }
    } catch (e) {
      debugPrint("Set wallpaper error: $e");
      _showSnack("Error applying wallpaper: $e");
    } finally {
      if (mounted) {
        Navigator.pop(context); // Dismiss the progress indicator
      }

      // Clean up temp wallpaper file
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint("Error deleting temp wallpaper file: $e");
      }
    }
  }

  void _printActiveItem() {
    final activeItem = _localItems[_currentIndex];
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.print_rounded, color: p.accent),
            const SizedBox(width: 10),
            Text(
              "Print Setup",
              style: TextStyle(color: p.onSurface, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Document: ${activeItem.imageUrl.split(Platform.isWindows ? '\\' : '/').last}",
              style: TextStyle(
                color: p.muted,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 16),
            _buildPrintRow("Paper Size", "A4 (Standard)"),
            _buildPrintRow(
              "Orientation",
              activeItem.width > activeItem.height ? "Landscape" : "Portrait",
            ),
            _buildPrintRow("Color Mode", "Full Color (High Quality)"),
            _buildPrintRow("Resolution", "300 DPI"),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text("Cancel", style: TextStyle(color: p.muted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: p.accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              _showProgressDialog("Preparing PDF document…");
              try {
                final file = File(activeItem.imageUrl);
                if (!await file.exists()) {
                  if (mounted) Navigator.pop(context); // Dismiss progress
                  _showSnack("Local file does not exist on disk.");
                  return;
                }

                final bytes = await file.readAsBytes();
                final doc = pw.Document();
                final image = pw.MemoryImage(bytes);

                doc.addPage(
                  pw.Page(
                    pageFormat: PdfPageFormat.a4,
                    build: (pw.Context context) {
                      return pw.Center(
                        child: pw.Image(image, fit: pw.BoxFit.contain),
                      );
                    },
                  ),
                );

                if (mounted) Navigator.pop(context); // Dismiss progress
                await Printing.layoutPdf(
                  onLayout: (PdfPageFormat format) async => doc.save(),
                  name: activeItem.imageUrl
                      .split(Platform.isWindows ? '\\' : '/')
                      .last,
                );
              } catch (e) {
                if (mounted) Navigator.pop(context); // Dismiss progress
                debugPrint("Error generating print: $e");
                _showSnack("Failed to start print job: $e");
              }
            },
            child: const Text(
              "Print",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrintRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: p.muted, fontSize: 13)),
          Text(
            value,
            style: TextStyle(
              color: p.onSurface,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ─── BUILD ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final activeItem = _localItems[_currentIndex];
    debugPrint("CAMERA: ${activeItem.cameraInfo}");

    final isVideo = activeItem.mediaType == 'video';

    final visibleFaces = _faces.where((f) {
      final pid = f['person_id'] as String?;
      return pid != null && pid.isNotEmpty;
    }).toList();

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Theme.of(context).brightness == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: PopScope(
        canPop: !_showDetailsOverlay,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          if (_showDetailsOverlay) {
            setState(() {
              _showDetailsOverlay = false;
              _detailsController.reverse();
            });
          }
        },
        child: Scaffold(
          backgroundColor: p.canvasBg,
          body: Stack(
            children: [
              // ── CANVAS (Full screen behind elements) ──────────────────────
              Positioned.fill(child: _buildImageCanvas(activeItem, isVideo)),
              if (isVideo)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      color: Colors.black.withValues(
                        alpha: (1.0 - _videoBrightness).clamp(0.0, 0.85),
                      ),
                    ),
                  ),
                ),

              // ── TOP BAR (Correct notch separation overlay) ────────────────
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AnimatedOpacity(
                  opacity: _showChrome ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_showChrome,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.4),
                            Colors.transparent,
                          ],
                        ),
                      ),
                      child: SafeArea(
                        bottom: false,
                        child: _buildTopBar(activeItem),
                      ),
                    ),
                  ),
                ),
              ),

              // ── BOTTOM CONTAINER (Merged Media controls + Toolbar) ────────
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: AnimatedOpacity(
                  opacity: _showChrome ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_showChrome,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.45),
                            Colors.transparent,
                          ],
                        ),
                      ),
                      child: SafeArea(
                        top: false,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (isVideo && _isVideoInitialized)
                              _buildVideoControls(),
                            _buildBurstStrip(activeItem),
                            _buildBottomToolbar(activeItem, isVideo),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              _buildGestureHUDs(),

              // ── DETAILS OVERLAY ───────────────────────────────────────────
              if (_showDetailsOverlay)
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _showDetailsOverlay = false);
                      _detailsController.reverse();
                    },
                    child: Container(
                      color: Colors.black45,
                      alignment: Alignment.bottomCenter,
                      child: SlideTransition(
                        position: _detailsSlide,
                        child: GestureDetector(
                          onTap: () {},
                          child: _buildDetailsSheet(
                            activeItem,
                            isVideo,
                            visibleFaces,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

              // ── TOUR OVERLAY ──────────────────────────────────────────────
              if (_isTourActive) _buildTourOverlay(),
              // ── VIDEO GESTURE GUIDE OVERLAY ────────────────────────────────
              if (_showVideoGestureGuide) _buildVideoGestureGuideOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Image canvas with zoom/pan/swipe ────────────────────────────────────────
  Widget _buildImageCanvas(GalleryItem activeItem, bool isVideo) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);

        return GestureDetector(
          // Single tap: toggle chrome/controls
          onTap: _toggleChrome,

          // Double-tap: zoom in/out
          onDoubleTapDown: (d) => _onDoubleTapAt(d.localPosition, size),
          onDoubleTap: () {},

          onVerticalDragEnd: (_isZoomed || widget.isRecentlyDeleted)
              ? null
              : (details) {
                  if (details.primaryVelocity != null &&
                      details.primaryVelocity! < -200) {
                    setState(() {
                      _showDetailsOverlay = true;
                      _detailsController.forward();
                    });
                  }
                  if (details.primaryVelocity != null &&
                      details.primaryVelocity! > 200) {
                    if (_showDetailsOverlay) {
                      setState(() {
                        _showDetailsOverlay = false;
                        _detailsController.reverse();
                      });
                    }
                  }
                },

          // Zoomable and swipable content
          child: _buildZoomablePageView(size),
        );
      },
    );
  }

  // Zoomable single-media page view (supports images and videos)
  Widget _buildZoomablePageView(Size size) {
    return NotificationListener<ScrollNotification>(
      onNotification: (_) => _isZoomed,
      child: PageView.builder(
        controller: _pageController,
        itemCount: _localItems.length,
        physics: _isZoomed
            ? const NeverScrollableScrollPhysics()
            : const ClampingScrollPhysics(),
        onPageChanged: _onPageChanged,
        itemBuilder: (_, index) {
          final itm = _localItems[index];
          final isCurrent = index == _currentIndex;
          final isItmVideo = itm.mediaType == 'video';

          Widget mediaWidget = (isItmVideo && isCurrent)
              ? _buildVideoCanvasContent(itm)
              : _buildImageView(itm);

          if (widget.isVault) {
            mediaWidget = VaultMediaLoader(
              item: itm,
              onDecryptSuccess: () {
                if (isItmVideo && isCurrent) {
                  _initVideoPlayer(itm.imageUrl);
                }
              },
              builder: (context, decryptedPath) {
                return (isItmVideo && isCurrent)
                    ? _buildVideoCanvasContent(itm)
                    : _buildImageView(itm);
              },
            );
          }

          // Apply flip only — Image.file already auto-corrects EXIF rotation on
          // Android, so applying rotationDegrees again would double-rotate the image.
          if (itm.isFlipped) {
            mediaWidget = Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()..scale(-1.0, 1.0),
              child: mediaWidget,
            );
          }

          return InteractiveViewer(
            transformationController: isCurrent
                ? _transformationController
                : null,
            minScale: 1.0,
            maxScale: 5.0,
            panEnabled: isCurrent && _isZoomed,
            scaleEnabled: isCurrent,
            onInteractionUpdate: isCurrent
                ? (details) {
                    final Matrix4 matrix = _transformationController.value;
                    final double scale = matrix.getMaxScaleOnAxis();
                    final isZoomed = scale > 1.02;
                    if (isZoomed != _isZoomed) {
                      setState(() {
                        _scale = scale;
                      });
                    }
                  }
                : null,
            onInteractionEnd: isCurrent
                ? (details) {
                    final Matrix4 matrix = _transformationController.value;
                    final double scale = matrix.getMaxScaleOnAxis();
                    if (scale <= 1.02) {
                      _transformationController.value = Matrix4.identity();
                      if (_isZoomed) {
                        setState(() {
                          _scale = 1.0;
                        });
                      }
                    }
                  }
                : null,
            child: mediaWidget,
          );
        },
      ),
    );
  }

  Widget _buildVideoCanvasContent(GalleryItem item) {
    if (!_isVideoInitialized || _videoController == null) {
      return Center(child: CircularProgressIndicator(color: p.accent));
    }

    double videoWidth = _videoController!.value.size.width;
    double videoHeight = _videoController!.value.size.height;

    // Fallback to database resolution if video_player size is uninitialized
    if (videoWidth <= 0 || videoHeight <= 0) {
      try {
        final parts = item.resolution.split('x');
        if (parts.length == 2) {
          videoWidth = double.tryParse(parts[0]) ?? 1600.0;
          videoHeight = double.tryParse(parts[1]) ?? 900.0;
        }
      } catch (_) {}
    }

    // Ultimate fallback if still invalid
    if (videoWidth <= 0 || videoHeight <= 0) {
      videoWidth = 1600.0;
      videoHeight = 900.0;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => _handleTapDown(details, size),
          onVerticalDragUpdate: _isZoomed
              ? null
              : (details) {
                  final x = details.localPosition.dx;
                  if (x < size.width / 2) {
                    _adjustBrightness(details.delta.dy, size.height);
                  } else {
                    _adjustVolume(details.delta.dy, size.height);
                  }
                },
          onLongPressStart: (details) {
            // Right side long-press → 2× playback speed
            if (details.localPosition.dx > size.width / 2) {
              setState(() => _isLongPressSpeedActive = true);
              _videoController?.setPlaybackSpeed(2.0);
              HapticFeedback.mediumImpact();
            }
          },
          onLongPressEnd: (_) {
            if (_isLongPressSpeedActive) {
              setState(() => _isLongPressSpeedActive = false);
              _videoController?.setPlaybackSpeed(_playbackSpeed);
              HapticFeedback.lightImpact();
            }
          },
          child: SizedBox.expand(
            child: Center(
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: videoWidth,
                  height: videoHeight,
                  child: VideoPlayer(_videoController!),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildImageView(GalleryItem item) {
    if (item.mediaType == 'video') {
      return CachedMediaThumbnail(
        assetId: item.id,
        filePath: item.imageUrl,
        isVideo: true,
        fit: BoxFit.contain,
      );
    }
    if (item.imageUrl.contains('.trashed') || widget.isRecentlyDeleted) {
      return FullResolutionTrashedImage(
        item: item,
        onLoaded: () => _onOriginalImageLoaded(item.id),
        bytesCache: _trashedBytesCache,
      );
    }
    if (item.imageUrl.startsWith('http')) {
      return Image.network(
        item.imageUrl,
        fit: BoxFit.contain,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _onOriginalImageLoaded(item.id);
            });
            return child;
          }
          return FastMediaPreview(item: item, fit: BoxFit.contain);
        },
        errorBuilder: (_, _, _) => _buildFallback(item),
      );
    }
    return Image.file(
      File(item.imageUrl),
      fit: BoxFit.contain,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || frame != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _onOriginalImageLoaded(item.id);
          });
          return child;
        }
        return FastMediaPreview(item: item, fit: BoxFit.contain);
      },
      errorBuilder: (_, _, _) => _buildFallback(item),
    );
  }

  Widget _buildFallback(GalleryItem item) {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined, color: p.muted, size: 56),
          const SizedBox(height: 12),
          Text(item.category, style: TextStyle(color: p.muted, fontSize: 13)),
        ],
      ),
    );
  }

  // ─── Video Controls ──────────────────────────────────────────────────────────
  Widget _buildVideoControls() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: p.accent,
              inactiveTrackColor: Colors.white24,
              thumbColor: p.accent,
              overlayColor: p.accent.withValues(alpha: 0.2),
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
            ),
            child: Slider(
              value: _currentPositionInSeconds.clamp(
                0.0,
                _totalDurationInSeconds.clamp(1.0, double.infinity),
              ),
              min: 0.0,
              max: _totalDurationInSeconds > 0 ? _totalDurationInSeconds : 1.0,
              onChanged: (v) {
                setState(() => _currentPositionInSeconds = v);
                _videoController?.seekTo(
                  Duration(milliseconds: (v * 1000).toInt()),
                );
              },
            ),
          ),
          Row(
            children: [
              GestureDetector(
                onTap: () {
                  if (_isVideoPlaying) {
                    _videoController?.pause();
                  } else {
                    _videoController?.play();
                    setState(() => _showChrome = false);
                  }
                },
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: p.accent,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _isVideoPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${_formatDuration(_currentPositionInSeconds)} / ${_formatDuration(_totalDurationInSeconds)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              GestureDetector(
                key: _tourVideoSpeedKey,
                onTap: _cyclePlaybackSpeed,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: _isLongPressSpeedActive
                        ? p.accent.withValues(alpha: 0.3)
                        : Colors.white12,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _isLongPressSpeedActive
                          ? p.accent
                          : Colors.white24,
                    ),
                  ),
                  child: Text(
                    _isLongPressSpeedActive
                        ? '2×'
                        : '${_playbackSpeed.toStringAsFixed(1)}×',
                    style: TextStyle(
                      color: _isLongPressSpeedActive ? p.accent : Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Orientation toggle
              GestureDetector(
                key: _tourVideoOrientKey,
                onTap: _toggleVideoOrientation,
                child: Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: _isVideoLandscape
                        ? p.accent.withValues(alpha: 0.2)
                        : Colors.white12,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _isVideoLandscape ? p.accent : Colors.white24,
                    ),
                  ),
                  child: Icon(
                    _isVideoLandscape
                        ? Icons.screen_lock_portrait_rounded
                        : Icons.screen_lock_landscape_rounded,
                    color: _isVideoLandscape ? p.accent : Colors.white,
                    size: 16,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () {
                  setState(() {
                    _showVideoGestureGuide = true;
                  });
                },
                child: Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: const Icon(
                    Icons.help_outline_rounded,
                    color: Colors.white,
                    size: 16,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── Top Bar ─────────────────────────────────────────────────────────────────
  Widget _buildTopBar(GalleryItem activeItem) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              Icons.arrow_back_ios_new_rounded,
              color: p.onSurface,
              size: 20,
            ),
            onPressed: () => Navigator.pop(context),
          ),
          const SizedBox(width: 8),
          Text(
            '${_currentIndex + 1}/${_localItems.length}',
            style: TextStyle(
              color: p.onSurface,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          if (!widget.isVault)
            IconButton(
              key: _tourFavoriteKey,
              icon: Icon(
                _favoriteIds.contains(activeItem.id)
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                color: _favoriteIds.contains(activeItem.id)
                    ? Colors.red
                    : p.onSurface,
                size: 24,
              ),
              onPressed: () {
                if (_isTourActive && _tourStep == 4) _advanceTour();
                _toggleFavorite();
              },
              tooltip: 'Like',
            ),
          IconButton(
            key: _tourSlideshowKey,
            icon: Icon(
              _isSlideshowActive
                  ? Icons.pause_presentation_rounded
                  : Icons.slideshow_rounded,
              color: _isSlideshowActive ? p.accent : p.onSurface,
              size: 24,
            ),
            onPressed: () {
              if (_isTourActive && _tourStep == 5) _advanceTour();
              _toggleSlideshow();
            },
            tooltip: 'Slideshow',
          ),
          if (!widget.isRecentlyDeleted)
            PopupMenuButton<String>(
              key: _tourMoreKey,
              icon: Icon(Icons.more_vert_rounded, color: p.onSurface, size: 24),
              color: p.card,
              surfaceTintColor: Colors.transparent,
              elevation: 8,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: p.border.withValues(alpha: 0.12)),
              ),
              onOpened: () {
                if (_isTourActive && _tourStep == 6) _advanceTour();
              },
              onSelected: (value) {
                final activeItem = _localItems[_currentIndex];
                switch (value) {
                  case 'rotate':
                    _rotateImageActiveItem();
                    break;
                  case 'flip':
                    _toggleFlip();
                    break;
                  case 'vault':
                    _secureActiveItem(activeItem);
                    break;
                  case 'copy':
                    AddToAlbumDialog.show(context, [activeItem.id]);
                    break;
                  case 'move':
                    _showCopyMoveAlbumDialog(true);
                    break;
                  case 'rename':
                    _showRenameDialog();
                    break;
                  case 'map':
                    _showOnMemoriesMap();
                    break;
                  case 'coords':
                    _copyGpsCoordinates();
                    break;
                  case 'print':
                    _printActiveItem();
                    break;
                  case 'export':
                    _showExportQualityDialog();
                    break;
                  case 'delete':
                    _confirmDelete();
                    break;
                  case 'guide':
                    _startTour();
                    break;
                }
              },
              itemBuilder: (BuildContext context) {
                final activeItem = _localItems[_currentIndex];
                final isVideo = activeItem.mediaType == 'video';

                return [
                  // if (!isVideo)
                  //   PopupMenuItem<String>(
                  //     value: 'rotate',
                  //     child: Row(
                  //       children: [
                  //         Icon(Icons.rotate_right_rounded, color: p.onSurface, size: 20),
                  //         const SizedBox(width: 12),
                  //         const Text('Rotate CW'),
                  //       ],
                  //     ),
                  //   ),
                  PopupMenuItem<String>(
                    value: 'flip',
                    child: Row(
                      children: [
                        Icon(Icons.flip_rounded, color: p.onSurface, size: 20),
                        const SizedBox(width: 12),
                        Text(activeItem.isFlipped ? 'Unflip' : 'Flip H'),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'vault',
                    child: Row(
                      children: [
                        Icon(Icons.lock_outline, color: p.onSurface, size: 20),
                        const SizedBox(width: 12),
                        const Text('Secure in Vault'),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'copy',
                    child: Row(
                      children: [
                        Icon(
                          Icons.add_to_photos_rounded,
                          color: p.onSurface,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        const Text('Add to album'),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'move',
                    child: Row(
                      children: [
                        Icon(
                          Icons.drive_file_move_rounded,
                          color: p.onSurface,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        const Text('Move to Album'),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'rename',
                    child: Row(
                      children: [
                        Icon(
                          Icons.drive_file_rename_outline_rounded,
                          color: p.onSurface,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        const Text('Rename'),
                      ],
                    ),
                  ),
                  if (activeItem.hasGps) ...[
                    PopupMenuItem<String>(
                      value: 'map',
                      child: Row(
                        children: [
                          Icon(
                            Icons.map_outlined,
                            color: p.onSurface,
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          const Text('Show on Map'),
                        ],
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'coords',
                      child: Row(
                        children: [
                          Icon(
                            Icons.content_copy_rounded,
                            color: p.onSurface,
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          const Text('Copy GPS Coords'),
                        ],
                      ),
                    ),
                  ],
                  if (!isVideo)
                    PopupMenuItem<String>(
                      value: 'print',
                      child: Row(
                        children: [
                          Icon(
                            Icons.print_rounded,
                            color: p.onSurface,
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          const Text('Print PDF'),
                        ],
                      ),
                    ),
                  PopupMenuItem<String>(
                    value: 'export',
                    child: Row(
                      children: [
                        Icon(Icons.tune_rounded, color: p.onSurface, size: 20),
                        const SizedBox(width: 12),
                        const Text('Custom Export'),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(
                          Icons.delete_outline_rounded,
                          color: p.danger,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Text('Delete', style: TextStyle(color: p.danger)),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem<String>(
                    value: 'guide',
                    child: Row(
                      children: [
                        Icon(Icons.explore_outlined, color: p.accent, size: 20),
                        const SizedBox(width: 12),
                        Text('View Guide', style: TextStyle(color: p.accent)),
                      ],
                    ),
                  ),
                ];
              },
            ),
        ],
      ),
    );
  }

  // ─── Bottom Action Helper ───────────────────────────────────────────────────
  Widget _buildBottomAction({
    Key? key,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final isWatch = context.isWatch;
    return Expanded(
      key: key,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: isWatch ? 18 : 24, color: p.onSurface),
            if (!isWatch) ...[
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: p.onSurface,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBurstStrip(GalleryItem activeItem) {
    final burstSequence = BurstHelper.getBurstSequence(
      activeItem,
      widget.allItems,
    );
    if (burstSequence.length <= 1) return const SizedBox.shrink();

    return Container(
      height: 72,
      margin: const EdgeInsets.only(bottom: 8),
      alignment: Alignment.center,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        cacheExtent: 150.0,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: burstSequence.length,
        itemBuilder: (context, idx) {
          final frame = burstSequence[idx];
          final isSelected = frame.id == activeItem.id;
          final isBurstSelected = _selectedBurstItemIds.contains(frame.id);

          return GestureDetector(
            onTap: () {
              if (_isBurstSelectionMode) {
                HapticFeedback.lightImpact();
                setState(() {
                  if (isBurstSelected) {
                    _selectedBurstItemIds.remove(frame.id);
                  } else {
                    _selectedBurstItemIds.add(frame.id);
                  }
                });
              } else {
                if (isSelected) return;
                HapticFeedback.lightImpact();
                setState(() {
                  _localItems[_currentIndex] = frame;
                  _videoController?.removeListener(_onVideoUpdate);
                  _videoController?.dispose();
                  _videoController = null;
                  _isVideoInitialized = false;
                  _playbackSpeed = 1.0;

                  if (frame.mediaType == 'video') {
                    _initVideoPlayer(frame.imageUrl);
                  }
                });
                _loadRelationalData();
              }
            },
            onLongPress: () {
              HapticFeedback.heavyImpact();
              setState(() {
                _isBurstSelectionMode = true;
                _selectedBurstItemIds.add(frame.id);
              });
              _showBurstActionMenu(frame);
            },
            child: Stack(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 56,
                  height: 56,
                  margin: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isSelected ? p.accent : Colors.white24,
                      width: isSelected ? 3.0 : 1.0,
                    ),
                    boxShadow: isSelected
                        ? [
                            BoxShadow(
                              color: p.accent.withValues(alpha: 0.4),
                              blurRadius: 8,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: FastMediaPreview(item: frame, fit: BoxFit.cover),
                  ),
                ),
                if (_isBurstSelectionMode)
                  Positioned(
                    top: 10,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: isBurstSelected ? p.accent : Colors.black54,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1),
                      ),
                      child: Icon(
                        isBurstSelected ? Icons.check : Icons.add,
                        size: 10,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showBurstActionMenu(GalleryItem frame) {
    showModalBottomSheet(
      context: context,
      backgroundColor: p.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final selectedCount = _selectedBurstItemIds.length;
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      "Burst Sequence Options",
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: p.onSurface,
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: Icon(Icons.star_rounded, color: p.accent),
                    title: const Text("Keep this only"),
                    subtitle: const Text(
                      "Delete all other photos in this burst sequence",
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      _keepBurstItemOnly(frame);
                    },
                  ),
                  ListTile(
                    leading: Icon(Icons.delete_sweep_rounded, color: p.danger),
                    title: Text("Delete selected ($selectedCount)"),
                    subtitle: const Text(
                      "Delete all currently marked burst photos",
                    ),
                    enabled: selectedCount > 0,
                    onTap: () {
                      Navigator.pop(context);
                      _deleteSelectedBurstItems();
                    },
                  ),
                  ListTile(
                    leading: Icon(Icons.select_all_rounded, color: p.onSurface),
                    title: const Text("Select all"),
                    onTap: () {
                      final burstSequence = BurstHelper.getBurstSequence(
                        frame,
                        widget.allItems,
                      );
                      setState(() {
                        _selectedBurstItemIds.addAll(
                          burstSequence.map((x) => x.id),
                        );
                      });
                      setSheetState(() {});
                    },
                  ),
                  ListTile(
                    leading: Icon(Icons.close_rounded, color: p.muted),
                    title: const Text("Cancel / Exit Selection Mode"),
                    onTap: () {
                      Navigator.pop(context);
                      setState(() {
                        _isBurstSelectionMode = false;
                        _selectedBurstItemIds.clear();
                      });
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _keepBurstItemOnly(GalleryItem keepItem) async {
    final burstSequence = BurstHelper.getBurstSequence(
      keepItem,
      widget.allItems,
    );
    final itemsToDelete = burstSequence
        .where((x) => x.id != keepItem.id)
        .toList();

    _showProgressDialog("Cleaning burst sequence…");
    try {
      await MediaPermissionService.softDeleteWithPermission(
        context,
        itemsToDelete,
      );

      setState(() {
        _localItems.removeWhere((x) => itemsToDelete.any((d) => d.id == x.id));
        _currentIndex = _localItems.indexWhere((x) => x.id == keepItem.id);
        if (_currentIndex == -1) _currentIndex = 0;

        _isBurstSelectionMode = false;
        _selectedBurstItemIds.clear();
      });

      widget.onDelete('');
      _showSnack("Kept only this image. Other burst frames moved to trash.");
    } catch (e) {
      debugPrint("Error keeping burst item only: $e");
      _showSnack("Failed to delete other burst items.");
    } finally {
      Navigator.pop(context);
    }
  }

  void _deleteSelectedBurstItems() async {
    final activeItem = _localItems[_currentIndex];
    final burstSequence = BurstHelper.getBurstSequence(
      activeItem,
      widget.allItems,
    );
    final itemsToDelete = burstSequence
        .where((x) => _selectedBurstItemIds.contains(x.id))
        .toList();

    _showProgressDialog("Deleting selected burst photos…");
    try {
      await MediaPermissionService.softDeleteWithPermission(
        context,
        itemsToDelete,
      );

      setState(() {
        _localItems.removeWhere((x) => _selectedBurstItemIds.contains(x.id));

        _isBurstSelectionMode = false;
        _selectedBurstItemIds.clear();

        if (_currentIndex >= _localItems.length) {
          _currentIndex = _localItems.length - 1;
        }
        if (_currentIndex < 0) _currentIndex = 0;
      });

      widget.onDelete('');
      _showSnack("Selected burst frames moved to trash.");
    } catch (e) {
      debugPrint("Error deleting selected burst items: $e");
      _showSnack("Failed to delete selected burst items.");
    } finally {
      Navigator.pop(context);
    }
  }

  Future<void> _restoreCurrentItem() async {
    final activeItem = _localItems[_currentIndex];
    final messenger = ScaffoldMessenger.of(context);
    try {
      final isLocal =
          activeItem.id.startsWith('win_') ||
          activeItem.id.startsWith('imported_') ||
          activeItem.id.startsWith('captured_');
      if (!isLocal && Platform.isAndroid) {
        final granted =
            await MediaPermissionService.ensureManageMediaPermission(context);
        if (!granted) return;
      }

      await MediaPermissionService.showBatchProgressDialog(
        context: context,
        title: "Restoring Media File",
        totalCount: 1,
        action: (onProgress) => TrashPersistence.restore(
          [activeItem.id],
          context: context,
          onProgress: onProgress,
        ),
      );

      try {
        await widget.onDelete(activeItem.id);
      } catch (e) {
        debugPrint("Error notifying parent of restore: $e");
      }

      bool isEmpty = false;
      setState(() {
        _localItems.removeAt(_currentIndex);

        _videoController?.removeListener(_onVideoUpdate);
        _videoController?.dispose();
        _videoController = null;
        _isVideoInitialized = false;

        if (_localItems.isEmpty) {
          isEmpty = true;
          Navigator.pop(context);
        } else {
          if (_currentIndex >= _localItems.length) {
            _currentIndex = _localItems.length - 1;
          }

          _pageController.jumpToPage(_currentIndex);

          final newActiveItem = _localItems[_currentIndex];
          if (newActiveItem.mediaType == 'video') {
            _initVideoPlayer(newActiveItem.imageUrl);
          }
        }
      });

      if (isEmpty) {
        messenger.clearSnackBars();
        messenger.showSnackBar(
          const SnackBar(content: Text("Item restored successfully.")),
        );
        return;
      }

      _loadRelationalData();
      _showSnack("Item restored successfully.");
    } catch (e) {
      debugPrint("Restore error in viewer: $e");
      _showSnack("Failed to restore item.");
    }
  }

  void _confirmPermanentDelete() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: p.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Delete Permanently?',
          style: TextStyle(color: p.onSurface, fontWeight: FontWeight.bold),
        ),
        content: Text(
          'This item will be permanently deleted from this device. This action cannot be undone.',
          style: TextStyle(color: p.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: p.muted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: p.danger,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () {
              Navigator.pop(context);
              _deleteCurrentItemPermanently();
            },
            child: const Text(
              'Delete',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteCurrentItemPermanently() async {
    final activeItem = _localItems[_currentIndex];
    final messenger = ScaffoldMessenger.of(context);
    try {
      final isLocal =
          activeItem.id.startsWith('win_') ||
          activeItem.id.startsWith('imported_') ||
          activeItem.id.startsWith('captured_');
      if (!isLocal && Platform.isAndroid) {
        final granted =
            await MediaPermissionService.ensureManageMediaPermission(context);
        if (!granted) return;
      }

      await MediaPermissionService.showBatchProgressDialog(
        context: context,
        title: "Permanently Deleting Media",
        totalCount: 1,
        action: (onProgress) => TrashPersistence.permanentlyDeleteItems(
          [activeItem],
          context: context,
          onProgress: onProgress,
        ),
      );

      try {
        await widget.onDelete(activeItem.id);
      } catch (e) {
        debugPrint("Error notifying parent of permanent delete: $e");
      }

      bool isEmpty = false;
      setState(() {
        _localItems.removeAt(_currentIndex);

        _videoController?.removeListener(_onVideoUpdate);
        _videoController?.dispose();
        _videoController = null;
        _isVideoInitialized = false;

        if (_localItems.isEmpty) {
          isEmpty = true;
          Navigator.pop(context);
        } else {
          if (_currentIndex >= _localItems.length) {
            _currentIndex = _localItems.length - 1;
          }

          _pageController.jumpToPage(_currentIndex);

          final newActiveItem = _localItems[_currentIndex];
          if (newActiveItem.mediaType == 'video') {
            _initVideoPlayer(newActiveItem.imageUrl);
          }
        }
      });

      if (isEmpty) {
        messenger.clearSnackBars();
        messenger.showSnackBar(
          const SnackBar(content: Text("Item deleted permanently.")),
        );
        return;
      }

      _loadRelationalData();
      _showSnack("Item deleted permanently.");
    } catch (e) {
      debugPrint("Permanent delete error in viewer: $e");
      _showSnack("Failed to delete item permanently.");
    }
  }

  // ─── Bottom toolbar ──────────────────────────────────────────────────────────
  Widget _buildBottomToolbar(GalleryItem activeItem, bool isVideo) {
    if (widget.isVault) {
      return SizedBox(
        height: 72,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildBottomAction(
              icon: Icons.restore_from_trash_rounded,
              label: 'Restore',
              onTap: _restoreVaultItem,
            ),
            _buildBottomAction(
              icon: Icons.ios_share,
              label: 'Share',
              onTap: _shareMedia,
            ),
            _buildBottomAction(
              icon: Icons.delete_outline_rounded,
              label: 'Delete',
              onTap: _confirmDelete,
            ),
          ],
        ),
      );
    }

    if (widget.isRecentlyDeleted) {
      return SizedBox(
        height: 72,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildBottomAction(
              icon: Icons.restore_from_trash_rounded,
              label: 'Restore',
              onTap: _restoreCurrentItem,
            ),
            _buildBottomAction(
              icon: Icons.delete_forever_rounded,
              label: 'Delete Permanently',
              onTap: _confirmPermanentDelete,
            ),
          ],
        ),
      );
    }

    if (_isBurstSelectionMode) {
      final activeItem = _localItems[_currentIndex];
      return SizedBox(
        height: 72,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildBottomAction(
              icon: Icons.close_rounded,
              label: 'Cancel',
              onTap: () {
                setState(() {
                  _isBurstSelectionMode = false;
                  _selectedBurstItemIds.clear();
                });
              },
            ),
            _buildBottomAction(
              icon: Icons.star_rounded,
              label: 'Keep This Only',
              onTap: () => _keepBurstItemOnly(activeItem),
            ),
            _buildBottomAction(
              icon: Icons.delete_sweep_rounded,
              label: 'Delete Selected (${_selectedBurstItemIds.length})',
              onTap: _deleteSelectedBurstItems,
            ),
          ],
        ),
      );
    }

    final isWatch = context.isWatch;
    return SizedBox(
      height: isWatch ? 50 : 72,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildBottomAction(
                key: _tourShareKey,
                icon: Icons.ios_share,
                label: 'Share',
                onTap: () {
                  if (_isTourActive && _tourStep == 0) _advanceTour();
                  _shareMedia();
                },
              ),
              _buildBottomAction(
                key: _tourEditKey,
                icon: Icons.edit_outlined,
                label: 'Edit',
                onTap: () {
                  if (_isTourActive && _tourStep == 1) _advanceTour();
                  _openEditor('framing');
                },
              ),
              _buildBottomAction(
                icon: Icons.lock_outline,
                label: 'Secure',
                onTap: () => _secureActiveItem(activeItem),
              ),
              _buildBottomAction(
                key: _tourDeleteKey,
                icon: Icons.delete_outline_rounded,
                label: 'Delete',
                onTap: () {
                  if (_isTourActive && _tourStep == 2)
                    _advanceTour();
                  else
                    _confirmDelete();
                },
              ),
              _buildBottomAction(
                key: _tourInfoKey,
                icon: Icons.info_outline_rounded,
                label: 'Info',
                onTap: () {
                  if (_isTourActive && _tourStep == 3) _advanceTour();
                  setState(() => _showDetailsOverlay = !_showDetailsOverlay);
                  if (_showDetailsOverlay) {
                    _detailsController.forward();
                  } else {
                    _detailsController.reverse();
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── More Options Sheet ──────────────────────────────────────────────────────
  Widget _buildSheetActionButton({
    required IconData icon,
    required String label,
    required bool enabled,
    bool active = false,
    required VoidCallback onTap,
  }) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.4,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: active ? p.accentLight : p.surfaceGrey,
                shape: BoxShape.circle,
                border: Border.all(
                  color: active ? p.accent : Colors.transparent,
                ),
              ),
              child: Icon(
                icon,
                color: active ? p.accent : p.onSurface,
                size: 22,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: active ? p.accent : p.muted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showExportQualityDialog() {
    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setStateDialog) {
          final hasChanges =
              _resolutionProgress != 1.0 || _qualityProgress != 0.9;
          return AlertDialog(
            backgroundColor: p.card,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: Text(
              "Custom Export Quality",
              style: TextStyle(
                color: p.onSurface,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Resolution Scale',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: p.muted,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: p.accentLight,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _getResolutionString(),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: p.accent,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                _FlatSlider(
                  value: _resolutionProgress,
                  min: 0.2,
                  max: 1.0,
                  divisions: 4,
                  onChanged: (v) {
                    setState(() {
                      _resolutionProgress = v;
                    });
                    setStateDialog(() {});
                  },
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Text(
                      'Compression Quality',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: p.muted,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _getFileSizeDisplay(),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: p.muted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                _FlatSlider(
                  value: _qualityProgress,
                  min: 0.1,
                  max: 1.0,
                  onChanged: (v) {
                    setState(() {
                      _qualityProgress = v;
                    });
                    setStateDialog(() {});
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx),
                child: Text("Cancel", style: TextStyle(color: p.muted)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: hasChanges ? p.accent : p.border,
                  foregroundColor: hasChanges ? Colors.white : p.muted,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  elevation: 0,
                ),
                onPressed: hasChanges
                    ? () {
                        Navigator.pop(dialogCtx);
                        _showSaveOptionsDialog();
                      }
                    : null,
                child: const Text(
                  'Save Custom Quality',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showRenameDialog() {
    final activeItem = _localItems[_currentIndex];
    final oldName = activeItem.imageUrl
        .split(Platform.isWindows ? '\\' : '/')
        .last
        .split('.')
        .first;
    final ctrl = TextEditingController(text: oldName);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          "Rename File",
          style: TextStyle(color: p.onSurface, fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: ctrl,
          style: TextStyle(color: p.onSurface),
          decoration: InputDecoration(
            hintText: "Enter new name",
            hintStyle: TextStyle(color: p.muted),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: p.border),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: p.accent),
            ),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text("Cancel", style: TextStyle(color: p.muted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: p.accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () {
              final newName = ctrl.text.trim();
              Navigator.pop(ctx);
              _renameActiveItem(newName);
            },
            child: const Text(
              "Rename",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  // AddToAlbumDialog is now used for virtual albums.

  void _showCopyMoveAlbumDialog(bool isMove) async {
    // Load existing album names from the database
    final db = DatabaseHelper.instance;
    final allItems = await db.getAllMediaItems();
    final albumNames =
        allItems
            .map((m) => (m['album_name'] as String? ?? '').trim())
            .where((n) => n.isNotEmpty)
            .toSet()
            .toList()
          ..sort();

    if (!mounted) return;

    String? selectedAlbum = albumNames.isNotEmpty ? albumNames.first : null;
    bool isCreatingNew = albumNames.isEmpty;
    final newAlbumCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) => AlertDialog(
          backgroundColor: p.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            isMove ? 'Move to Album' : 'Copy to Album',
            style: TextStyle(color: p.onSurface, fontWeight: FontWeight.bold),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isCreatingNew && albumNames.isNotEmpty) ...[
                  DropdownButtonFormField<String>(
                    initialValue: selectedAlbum,
                    dropdownColor: p.card,
                    style: TextStyle(color: p.onSurface),
                    decoration: InputDecoration(
                      labelText: 'Select Album',
                      labelStyle: TextStyle(color: p.muted, fontSize: 13),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: p.border),
                      ),
                      focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: p.accent),
                      ),
                    ),
                    items: albumNames
                        .map(
                          (a) => DropdownMenuItem(
                            value: a,
                            child: Text(
                              a,
                              style: TextStyle(color: p.onSurface),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setDs(() => selectedAlbum = v),
                  ),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    icon: Icon(
                      Icons.add_circle_outline,
                      color: p.accent,
                      size: 18,
                    ),
                    label: Text(
                      'Create New Album',
                      style: TextStyle(color: p.accent, fontSize: 13),
                    ),
                    onPressed: () => setDs(() {
                      isCreatingNew = true;
                      selectedAlbum = null;
                    }),
                  ),
                ] else ...[
                  if (albumNames.isNotEmpty)
                    TextButton.icon(
                      icon: Icon(Icons.arrow_back, color: p.muted, size: 18),
                      label: Text(
                        'Back to existing albums',
                        style: TextStyle(color: p.muted, fontSize: 13),
                      ),
                      onPressed: () => setDs(() {
                        isCreatingNew = false;
                        selectedAlbum = albumNames.first;
                      }),
                    ),
                  const SizedBox(height: 4),
                  TextField(
                    controller: newAlbumCtrl,
                    autofocus: true,
                    style: TextStyle(color: p.onSurface),
                    decoration: InputDecoration(
                      hintText: 'New album name',
                      hintStyle: TextStyle(color: p.muted),
                      labelText: 'Album Name',
                      labelStyle: TextStyle(color: p.muted, fontSize: 13),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: p.border),
                      ),
                      focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: p.accent),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: p.muted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: p.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () {
                final albumName = isCreatingNew
                    ? newAlbumCtrl.text.trim()
                    : (selectedAlbum ?? '');
                if (albumName.isEmpty) return;
                Navigator.pop(ctx);
                _copyMoveMediaToAlbum(albumName, isMove);
              },
              child: Text(
                isMove ? 'Move' : 'Copy',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickActionStar({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback? onTap,
  }) {
    final isEnabled = onTap != null;
    return Opacity(
      opacity: isEnabled ? 1.0 : 0.4,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 80,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: color.withValues(alpha: 0.2),
                    width: 1.5,
                  ),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  color: p.onSurface.withValues(alpha: 0.8),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        title,
        style: TextStyle(
          color: p.accent,
          fontSize: 10.5,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildFlatListTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: p.border.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: p.border.withValues(alpha: 0.1), width: 1),
        ),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: iconColor, size: 20),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: p.onSurface,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: p.muted, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showSaveOptionsDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: p.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Save Quality Changes',
          style: TextStyle(color: p.onSurface, fontWeight: FontWeight.bold),
        ),
        content: Text(
          'Would you like to overwrite the original image or save as a new copy?',
          style: TextStyle(color: p.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: p.muted)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _handleSaveOption('copy');
            },
            child: Text(
              'Save Copy',
              style: TextStyle(color: p.accent, fontWeight: FontWeight.bold),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: p.accent,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () {
              Navigator.pop(context);
              _handleSaveOption('overwrite');
            },
            child: const Text(
              'Overwrite',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLensButton(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: p.border.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: p.onSurface),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: p.onSurface,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLocationMapCard(GalleryItem item) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final latLng = LatLng(item.latitude, item.longitude);
    final mapStyleId = UIPreferenceProvider.instance.mapStyleId;
    String urlTemplate = isDark
        ? "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png"
        : "https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png";
    List<String> subdomains = const ['a', 'b', 'c', 'd'];

    if (mapStyleId == 'voyager') {
      urlTemplate =
          "https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png";
      subdomains = const ['a', 'b', 'c', 'd'];
    } else if (mapStyleId == 'dark') {
      urlTemplate =
          "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png";
      subdomains = const ['a', 'b', 'c', 'd'];
    } else if (mapStyleId == 'positron') {
      urlTemplate =
          "https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png";
      subdomains = const ['a', 'b', 'c', 'd'];
    } else if (mapStyleId == 'satellite') {
      urlTemplate =
          "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}";
      subdomains = const [];
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                item.shortAddress,
                style: TextStyle(
                  color: p.onSurface,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: _showOnMemoriesMap,
              child: Row(
                children: [
                  Text(
                    'Open in Maps',
                    style: TextStyle(
                      color: p.accent,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, size: 16, color: p.accent),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: _showOnMemoriesMap,
          child: Container(
            width: double.infinity,
            height: 160,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: p.border.withValues(alpha: 0.5)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: FlutterMap(
                options: MapOptions(
                  initialCenter: latLng,
                  initialZoom: 13.0,
                  minZoom: 2.0,
                  maxZoom: 18.0,
                ),
                children: [
                  TileLayer(
                    urlTemplate: urlTemplate,
                    subdomains: const ['a', 'b', 'c', 'd'],
                    userAgentPackageName: 'in.sddev.ghost_gallery',
                    tileProvider: CachedTileProvider(),
                  ),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: latLng,
                        width: 50,
                        height: 50,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Positioned(
                              bottom: 0,
                              child: Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: p.accent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.all(2.5),
                              decoration: BoxDecoration(
                                color: p.accent,
                                shape: BoxShape.circle,
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black26,
                                    blurRadius: 4,
                                    spreadRadius: 1,
                                    offset: Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(20),
                                child: SizedBox(
                                  width: 34,
                                  height: 34,
                                  child: item.imageUrl.startsWith('http')
                                      ? Image.network(
                                          item.imageUrl,
                                          fit: BoxFit.cover,
                                        )
                                      : Image.file(
                                          File(item.imageUrl),
                                          fit: BoxFit.cover,
                                        ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDetailsCard(GalleryItem item, bool isVideo) {
    final fileName = item.imageUrl.split('/').last;
    debugPrint("CAMERA: ${item.cameraInfo}");

    String mpStr = '';
    if (!isVideo) {
      if (item.resolution.contains('x') || item.resolution.contains('×')) {
        final parts = item.resolution.split(RegExp(r'[x×]'));
        if (parts.length == 2) {
          final w = int.tryParse(parts[0].trim());
          final h = int.tryParse(parts[1].trim());
          if (w != null && h != null) {
            final mp = (w * h) / 1000000.0;
            mpStr = '${mp.toStringAsFixed(1)} MP';
          }
        }
      }
    }

    final exifParts = <String>[];
    if (item.apertureDisplay != null) exifParts.add(item.apertureDisplay!);
    if (item.exposureTime != null) exifParts.add(item.exposureTime!);
    if (item.focalLengthDisplay != null) {
      exifParts.add(item.focalLengthDisplay!);
    }
    if (item.isoDisplay != null) exifParts.add(item.isoDisplay!);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: Card(
            color: p.card,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: p.border.withValues(alpha: 0.15)),
            ),
            child: ExpansionTile(
              initiallyExpanded: false,
              iconColor: p.accent,
              collapsedIconColor: p.muted,
              leading: Icon(Icons.camera_alt_outlined, color: p.accent),
              title: Text(
                item.cameraInfo,
                style: TextStyle(
                  color: p.onSurface,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              subtitle: Text(
                'File resolution & parameters',
                style: TextStyle(color: p.muted, fontSize: 11),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              childrenPadding: const EdgeInsets.symmetric(
                horizontal: 4,
                vertical: 8,
              ),
              children: [
                if (exifParts.isNotEmpty) ...[
                  Divider(height: 1, color: p.border.withValues(alpha: 0.15)),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.tune_rounded, color: p.muted, size: 18),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            exifParts.join('  ·  '),
                            style: TextStyle(
                              color: p.onSurface,
                              fontWeight: FontWeight.w500,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                Divider(height: 1, color: p.border.withValues(alpha: 0.15)),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fileName,
                        style: TextStyle(
                          color: p.onSurface,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (mpStr.isNotEmpty) _buildDetailBadge(mpStr),
                          _buildDetailBadge(item.resolution),
                          if (item.isHdr) _buildDetailBadge('Ultra HDR'),
                          if (item.mimeType != null)
                            _buildDetailBadge(
                              item.mimeType!.toUpperCase().split('/').last,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: p.border.withValues(alpha: 0.15)),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'On device  ·  ${item.size}',
                        style: TextStyle(
                          color: p.onSurface,
                          fontWeight: FontWeight.bold,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.imageUrl,
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 11.5,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDetailBadge(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: p.border.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border.withValues(alpha: 0.2)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: p.onSurface,
          fontSize: 11.5,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  // ─── Details Sheet ───────────────────────────────────────────────────────────
  Widget _buildDetailsSheet(
    GalleryItem item,
    bool isVideo,
    List<Map<String, dynamic>> faces,
  ) {
    // Filter the face list to only show recognized persons with at least 10 linked images
    final eligibleFaces = faces.where((f) {
      final pid = f['person_id'] as String?;
      if (pid == null || pid.isEmpty) return false;
      final faceCount = _allDbFaces
          .where((dbf) => dbf['person_id'] == pid)
          .length;
      return faceCount >= 10;
    }).toList();

    String exactDateTime = item.date;
    if (item.dateTimestamp != 0) {
      final dt = DateTime.fromMillisecondsSinceEpoch(item.dateTimestamp);
      final weekDays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
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
      final wday = weekDays[dt.weekday - 1];
      final monthName = months[dt.month - 1];
      final int hour12 = dt.hour == 0
          ? 12
          : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
      final String amPm = dt.hour >= 12 ? 'pm' : 'am';
      final String minStr = dt.minute.toString().padLeft(2, '0');
      final String timeStr = '$hour12:$minStr $amPm';
      exactDateTime = '$wday, ${dt.day} $monthName, ${dt.year} • $timeStr';
    }

    return Container(
      constraints: const BoxConstraints(maxHeight: 520),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: p.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          exactDateTime,
                          style: TextStyle(
                            color: p.onSurface,
                            fontWeight: FontWeight.bold,
                            fontSize: 15.5,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.close_rounded,
                          color: p.muted,
                          size: 20,
                        ),
                        onPressed: () {
                          setState(() => _showDetailsOverlay = false);
                          _detailsController.reverse();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  _isEditingCaption
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextField(
                              controller: _captionController,
                              focusNode: _captionFocusNode,
                              maxLines: null,
                              autofocus: true,
                              style: TextStyle(
                                color: p.onSurface,
                                fontSize: 16,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Add a caption...',
                                hintStyle: TextStyle(
                                  color: p.muted.withValues(alpha: 0.5),
                                ),
                                enabledBorder: UnderlineInputBorder(
                                  borderSide: BorderSide(
                                    color: p.border.withValues(alpha: 0.5),
                                  ),
                                ),
                                focusedBorder: UnderlineInputBorder(
                                  borderSide: BorderSide(color: p.accent),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton(
                                  onPressed: () {
                                    setState(() {
                                      _isEditingCaption = false;
                                    });
                                  },
                                  child: Text(
                                    'Cancel',
                                    style: TextStyle(color: p.muted),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: p.accent,
                                    foregroundColor: Colors.white,
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                  ),
                                  onPressed: () async {
                                    final newDesc = _captionController.text
                                        .trim();
                                    final defaultVal = item.mediaType == 'video'
                                        ? 'Local video capture'
                                        : 'Device photo image';
                                    final savedDesc = newDesc.isNotEmpty
                                        ? newDesc
                                        : defaultVal;
                                    try {
                                      await DatabaseHelper.instance
                                          .updateMediaRichMetadata(item.id, {
                                            'description': savedDesc,
                                          });

                                      // Trigger embedding generation immediately in the background
                                      if (OptionalFeatures
                                              .scheduleEmbeddingBackgroundTask !=
                                          null) {
                                        unawaited(
                                          OptionalFeatures
                                              .scheduleEmbeddingBackgroundTask!(
                                            item.id,
                                          ),
                                        );
                                      } else {
                                        unawaited(
                                          MLProcessingService.instance
                                              .generateAndStoreMediaEmbedding(
                                                item.id,
                                              ),
                                        );
                                      }

                                      setState(() {
                                        final updatedItem = item.copyWith(
                                          description: savedDesc,
                                        );
                                        _localItems[_currentIndex] =
                                            updatedItem;
                                        _isEditingCaption = false;
                                      });
                                    } catch (e) {
                                      debugPrint(
                                        'Failed to save caption inline: $e',
                                      );
                                    }
                                  },
                                  child: const Text(
                                    'Save',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        )
                      : GestureDetector(
                          onTap: () {
                            setState(() {
                              _isEditingCaption = true;
                              _captionController.text =
                                  item.description == 'Local video capture' ||
                                      item.description == 'Device photo image'
                                  ? ''
                                  : item.description;
                            });
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8.0),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    item.description.isEmpty ||
                                            item.description ==
                                                'Local video capture' ||
                                            item.description ==
                                                'Device photo image'
                                        ? 'Add a caption...'
                                        : item.description,
                                    style: TextStyle(
                                      color:
                                          item.description.isEmpty ||
                                              item.description ==
                                                  'Local video capture' ||
                                              item.description ==
                                                  'Device photo image'
                                          ? p.muted.withValues(alpha: 0.6)
                                          : p.onSurface,
                                      fontSize: 16,
                                      fontStyle:
                                          item.description.isEmpty ||
                                              item.description ==
                                                  'Local video capture' ||
                                              item.description ==
                                                  'Device photo image'
                                          ? FontStyle.italic
                                          : FontStyle.normal,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                Icon(
                                  Icons.edit_outlined,
                                  size: 16,
                                  color: p.muted.withValues(alpha: 0.6),
                                ),
                              ],
                            ),
                          ),
                        ),

                  // Google Lens Search Section

                  // Geotagged Map section
                  if (item.hasGps) _buildLocationMapCard(item),

                  // Sleek Aves-style details card
                  _buildDetailsCard(item, isVideo),

                  // Upgraded: XMP Rating Stars
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        'Rating: ',
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Row(
                        children: List.generate(
                          5,
                          (index) => GestureDetector(
                            onTap: () async {
                              final int newRating = index + 1;
                              final int finalRating = item.rating == newRating
                                  ? 0
                                  : newRating;
                              try {
                                await DatabaseHelper.instance
                                    .updateMediaRichMetadata(item.id, {
                                      'rating': finalRating,
                                    });
                                setState(() {
                                  _localItems[_currentIndex] = item.copyWith(
                                    rating: finalRating,
                                  );
                                });
                              } catch (e) {
                                debugPrint('Failed to save rating: $e');
                              }
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2.0,
                              ),
                              child: Icon(
                                index < item.rating
                                    ? Icons.star_rounded
                                    : Icons.star_border_rounded,
                                color: Colors.amber,
                                size: 28,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),

                  // Upgraded: XMP Subject Tags chips
                  if (item.tags.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    _SectionLabel('XMP Subject Tags'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: item.tags
                          .map(
                            (t) => Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: p.surfaceGrey,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: p.border),
                              ),
                              child: Text(
                                t,
                                style: TextStyle(
                                  color: p.onSurface,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ],

                  Divider(height: 24, color: p.border),
                  if (_ocrTexts.isNotEmpty) ...[
                    _SectionLabel('Extracted Text'),
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: p.surfaceGrey,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _ocrTexts.first['text'] as String,
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Divider(height: 1, color: p.border.withValues(alpha: 0.5)),
                    Container(
                      color: p.border.withValues(alpha: 0.03),
                      padding: const EdgeInsets.symmetric(
                        vertical: 8,
                        horizontal: 12,
                      ),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _buildLensButton(
                              Icons.copy_rounded,
                              'Copy text',
                              () {
                                if (_ocrTexts.isNotEmpty) {
                                  Clipboard.setData(
                                    ClipboardData(
                                      text: _ocrTexts.first['text'] as String,
                                    ),
                                  );
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: const Text(
                                        'Text copied to clipboard!',
                                      ),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: const Text(
                                        'No text detected to copy!',
                                      ),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                }
                              },
                            ),
                            const SizedBox(width: 12),
                            _buildLensButton(
                              Icons.search_rounded,
                              'Search',
                              () async {
                                if (_ocrTexts.isNotEmpty) {
                                  final text =
                                      _ocrTexts.first['text'] as String;
                                  final url = Uri.parse(
                                    'https://www.google.com/search?q=${Uri.encodeComponent(text)}',
                                  );
                                  try {
                                    await launchUrl(
                                      url,
                                      mode: LaunchMode.externalApplication,
                                    );
                                  } catch (e) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Could not launch search URL',
                                        ),
                                        behavior: SnackBarBehavior.floating,
                                      ),
                                    );
                                  }
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('No text found to search!'),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                }
                              },
                            ),
                            const SizedBox(width: 12),
                            _buildLensButton(
                              Icons.volume_up_rounded,
                              'Listen',
                              () async {
                                if (_ocrTexts.isNotEmpty) {
                                  final text =
                                      _ocrTexts.first['text'] as String;
                                  await _tts.speak(text);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Speaking text...'),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('No text to listen!'),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                }
                              },
                            ),
                            const SizedBox(width: 12),
                            _buildLensButton(Icons.share_rounded, 'Share', () {
                              if (_ocrTexts.isNotEmpty) {
                                final text = _ocrTexts.first['text'] as String;
                                Share.share(text);
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('No text to share!'),
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                );
                              }
                            }),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (_objects.isNotEmpty) ...[
                    _SectionLabel('Object Tags'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _objects
                          .map(
                            (o) => Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: p.surfaceGrey,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: p.border),
                              ),
                              child: Text(
                                o['label'] as String,
                                style: TextStyle(
                                  color: p.onSurface,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (eligibleFaces.isNotEmpty) ...[
                    _SectionLabel('Recognised Faces'),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 60,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: eligibleFaces.length,
                        itemBuilder: (_, i) {
                          final f = eligibleFaces[i];
                          final pid = f['person_id'] as String?;
                          final name = _getPersonName(pid);
                          final relation = _getPersonRelation(pid);
                          final cover = _getPersonCoverImage(pid);
                          final isUnnamed =
                              name == 'Unknown' || name.startsWith('Face');

                          final person = _people.firstWhere(
                            (p) => p['id'] == pid,
                            orElse: () => <String, dynamic>{},
                          );

                          final String bboxStr =
                              f['bounding_box']?.toString() ?? '';
                          final parts = bboxStr.split(',');
                          final bx = parts.isNotEmpty
                              ? (int.tryParse(parts[0]) ?? 0)
                              : 0;
                          final by = parts.length > 1
                              ? (int.tryParse(parts[1]) ?? 0)
                              : 0;
                          final bw = parts.length > 2
                              ? (int.tryParse(parts[2]) ?? 0)
                              : 0;
                          final bh = parts.length > 3
                              ? (int.tryParse(parts[3]) ?? 0)
                              : 0;

                          return GestureDetector(
                            onTap: () async {
                              if (person.isNotEmpty) {
                                final result = await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        PersonPhotosScreen(person: person),
                                  ),
                                );
                                if (result == true) {
                                  _loadRelationalData();
                                }
                              }
                            },
                            child: Padding(
                              padding: const EdgeInsets.only(right: 16),
                              child: Row(
                                children: [
                                  Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: p.accentLight,
                                      border: Border.all(
                                        color: p.accent.withValues(alpha: 0.2),
                                        width: 1.5,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.08,
                                          ),
                                          blurRadius: 4,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child:
                                        cover != null &&
                                            cover.isNotEmpty &&
                                            File(cover).existsSync()
                                        ? (person.isNotEmpty &&
                                                  person['cover_w'] != null &&
                                                  (person['cover_w'] as int? ??
                                                          0) >
                                                      0
                                              ? FacePreview(
                                                  imagePath: cover,
                                                  x:
                                                      person['cover_x']
                                                          as int? ??
                                                      0,
                                                  y:
                                                      person['cover_y']
                                                          as int? ??
                                                      0,
                                                  w:
                                                      person['cover_w']
                                                          as int? ??
                                                      0,
                                                  h:
                                                      person['cover_h']
                                                          as int? ??
                                                      0,
                                                )
                                              : Image.file(
                                                  File(cover),
                                                  fit: BoxFit.cover,
                                                ))
                                        : (bboxStr.isNotEmpty &&
                                                  bw > 0 &&
                                                  File(
                                                    item.imageUrl,
                                                  ).existsSync()
                                              ? FacePreview(
                                                  imagePath: item.imageUrl,
                                                  x: bx,
                                                  y: by,
                                                  w: bw,
                                                  h: bh,
                                                )
                                              : Icon(
                                                  Icons.person_rounded,
                                                  color: p.accent,
                                                  size: 22,
                                                )),
                                  ),
                                  const SizedBox(width: 10),
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      if (isUnnamed && pid != null)
                                        SizedBox(
                                          width: 100,
                                          height: 22,
                                          child: TextField(
                                            style: TextStyle(
                                              color: p.onSurface,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                            ),
                                            decoration: InputDecoration(
                                              hintText: 'Add name',
                                              hintStyle: TextStyle(
                                                color: p.muted,
                                                fontSize: 12,
                                              ),
                                              border: InputBorder.none,
                                              contentPadding: EdgeInsets.zero,
                                            ),
                                            onSubmitted: (v) async {
                                              if (v.trim().isNotEmpty) {
                                                await DatabaseHelper.instance
                                                    .updatePersonName(
                                                      pid,
                                                      v.trim(),
                                                    );
                                                OptionalFeatures
                                                    .updateEmbeddingsForPerson
                                                    ?.call(
                                                      pid,
                                                    ); // Asynchronous (non-blocking)
                                                _loadRelationalData();
                                              }
                                            },
                                          ),
                                        )
                                      else
                                        Text(
                                          name,
                                          style: TextStyle(
                                            color: p.onSurface,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      Text(
                                        relation,
                                        style: TextStyle(
                                          color: p.muted,
                                          fontSize: 10,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                  SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _secureActiveItem(GalleryItem activeItem) async {
    if (Platform.isAndroid) {
      final granted = await MediaPermissionService.ensureManageMediaPermission(
        context,
      );
      if (!granted) return;
    }

    final configured = await VaultService.instance.isVaultConfigured();
    if (!mounted) return;
    if (!configured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please set up Secure Vault from the Albums tab first.',
          ),
        ),
      );
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const VaultSetupScreen()),
      );
      return;
    }

    // Lock the vault first to force authentication challenge
    VaultService.instance.lockVault();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VaultUnlockScreen(
          onUnlockSuccess: () {
            Navigator.pop(context); // Pop unlock screen
            _showVaultAlbumSelectionDialog(activeItem);
          },
        ),
      ),
    );
  }

  Future<void> _showVaultAlbumSelectionDialog(GalleryItem activeItem) async {
    final albums = await VaultService.instance.getVaultAlbums();
    if (!mounted) return;

    String? selectedAlbumId = 'general';

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final dialogTheme = Theme.of(context);
          return AlertDialog(
            backgroundColor: dialogTheme.dialogBackgroundColor,
            title: Text(
              'Secure to Vault',
              style: TextStyle(
                color: dialogTheme.colorScheme.onSurface,
                fontWeight: FontWeight.bold,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Select a Vault album to encrypt and hide this file.',
                  style: TextStyle(
                    color: dialogTheme.colorScheme.onSurface.withValues(
                      alpha: 0.7,
                    ),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: selectedAlbumId,
                  dropdownColor: dialogTheme.cardColor,
                  style: TextStyle(color: dialogTheme.colorScheme.onSurface),
                  decoration: InputDecoration(
                    labelText: 'Vault Album',
                    labelStyle: TextStyle(
                      color: dialogTheme.colorScheme.primary,
                    ),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: dialogTheme.dividerColor),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(
                        color: dialogTheme.colorScheme.primary,
                      ),
                    ),
                  ),
                  items: albums
                      .map(
                        (a) => DropdownMenuItem(
                          value: a.id,
                          child: Text(
                            a.name,
                            style: TextStyle(
                              color: dialogTheme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (val) {
                    setDialogState(() {
                      selectedAlbumId = val;
                    });
                  },
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  icon: Icon(
                    Icons.add_circle_outline,
                    color: dialogTheme.colorScheme.secondary,
                  ),
                  label: Text(
                    'Create New Album',
                    style: TextStyle(color: dialogTheme.colorScheme.secondary),
                  ),
                  onPressed: () async {
                    final nameController = TextEditingController();
                    final newAlbum = await showDialog<VaultAlbum>(
                      context: context,
                      builder: (context) {
                        final innerTheme = Theme.of(context);
                        return AlertDialog(
                          backgroundColor: innerTheme.dialogBackgroundColor,
                          title: Text(
                            'New Vault Album',
                            style: TextStyle(
                              color: innerTheme.colorScheme.onSurface,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          content: TextField(
                            controller: nameController,
                            style: TextStyle(
                              color: innerTheme.colorScheme.onSurface,
                            ),
                            decoration: InputDecoration(
                              labelText: 'Album Name',
                              labelStyle: TextStyle(
                                color: innerTheme.colorScheme.primary,
                              ),
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: Text(
                                'Cancel',
                                style: TextStyle(
                                  color: innerTheme.colorScheme.onSurface
                                      .withValues(alpha: 0.6),
                                ),
                              ),
                            ),
                            ElevatedButton(
                              onPressed: () async {
                                if (nameController.text.isNotEmpty) {
                                  final album = await VaultService.instance
                                      .createVaultAlbum(nameController.text);
                                  Navigator.pop(context, album);
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: innerTheme.colorScheme.primary,
                                foregroundColor:
                                    innerTheme.colorScheme.onPrimary,
                              ),
                              child: const Text('Create'),
                            ),
                          ],
                        );
                      },
                    );
                    if (newAlbum != null) {
                      final updatedAlbums = await VaultService.instance
                          .getVaultAlbums();
                      setDialogState(() {
                        albums.clear();
                        albums.addAll(updatedAlbums);
                        selectedAlbumId = newAlbum.id;
                      });
                    }
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  'Cancel',
                  style: TextStyle(
                    color: dialogTheme.colorScheme.onSurface.withValues(
                      alpha: 0.6,
                    ),
                  ),
                ),
              ),
              ElevatedButton(
                onPressed: () async {
                  Navigator.pop(context); // Close selection dialog
                  _encryptAndSecureItem(activeItem, selectedAlbumId!);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: dialogTheme.colorScheme.primary,
                  foregroundColor: dialogTheme.colorScheme.onPrimary,
                ),
                child: const Text('Secure'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _encryptAndSecureItem(
    GalleryItem activeItem,
    String albumId,
  ) async {
    // Show loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(color: Colors.purpleAccent),
      ),
    );

    try {
      await VaultService.instance.addMediaToVault(
        filePath: activeItem.imageUrl,
        albumId: albumId,
        originalMediaId: activeItem.id,
        mimeType: activeItem.mimeType,
        mediaType: activeItem.mediaType,
        width: activeItem.width,
        height: activeItem.height,
        dateTaken: activeItem.dateTimestamp,
      );

      // Close loading dialog
      if (mounted) Navigator.pop(context);

      // Notify parent screen that item was removed
      await widget.onDelete(activeItem.id);

      setState(() {
        _localItems.removeAt(_currentIndex);
        _videoController?.removeListener(_onVideoUpdate);
        _videoController?.dispose();
        _videoController = null;
        _isVideoInitialized = false;

        if (_localItems.isEmpty) {
          Navigator.pop(context);
        } else {
          if (_currentIndex >= _localItems.length) {
            _currentIndex = _localItems.length - 1;
          }
          _pageController.jumpToPage(_currentIndex);
          final newActiveItem = _localItems[_currentIndex];
          if (newActiveItem.mediaType == 'video') {
            _initVideoPlayer(newActiveItem.imageUrl);
          }
        }
      });

      _showSnack("Item successfully encrypted and secured in Vault.");
    } catch (e) {
      if (mounted) Navigator.pop(context); // Close loading dialog
      _showSnack("Encryption failed: $e");
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // INTERACTIVE TOUR
  // ═══════════════════════════════════════════════════════════════════════════

  static const String _tourPrefKey = 'viewer_tour_done';

  // Step definitions: (globalKey, icon, title, description)
  List<_TourStepDef> get _tourSteps {
    final isVideo =
        _localItems.isNotEmpty &&
        _localItems[_currentIndex].mediaType == 'video';
    return [
      _TourStepDef(
        _tourShareKey,
        Icons.ios_share,
        'Share',
        'Share this media with friends or apps.',
      ),
      _TourStepDef(
        _tourEditKey,
        Icons.edit_outlined,
        'Edit',
        'Open the editor to crop, filter and enhance.',
      ),
      _TourStepDef(
        _tourDeleteKey,
        Icons.delete_outline_rounded,
        'Delete',
        'Move to Recently Deleted. Recoverable within 30 days.',
      ),
      _TourStepDef(
        _tourInfoKey,
        Icons.info_outline_rounded,
        'Info',
        'View EXIF, GPS, faces and full media details.',
      ),
      _TourStepDef(
        _tourFavoriteKey,
        Icons.favorite_border_rounded,
        'Favorite',
        'Heart this media to access it in Favorites.',
      ),
      _TourStepDef(
        _tourSlideshowKey,
        Icons.slideshow_rounded,
        'Slideshow',
        'Auto-play media as a full-screen slideshow.',
      ),
      _TourStepDef(
        _tourMoreKey,
        Icons.more_vert_rounded,
        'More Options',
        'Add to album, move, rename, rotate, vault, export and more.',
      ),
      // ── Video-only steps ──────────────────────────────────────────────────
      if (isVideo && _isVideoInitialized) ...[
        _TourStepDef(
          _tourVideoSpeedKey,
          Icons.speed_rounded,
          'Playback Speed',
          'Tap to cycle 0.5×, 1×, 1.5×, 2× speed. Or long-press the right side of the video for instant 2× — releases back to normal on lift.',
        ),
        _TourStepDef(
          _tourVideoOrientKey,
          Icons.screen_lock_landscape_rounded,
          'Orientation',
          'Tap to toggle between portrait and landscape mode for a better fullscreen experience.',
        ),
      ],
    ];
  }

  Future<void> _checkAndShowTour() async {
    final prefs = await SharedPreferences.getInstance();
    final done = prefs.getBool(_tourPrefKey) ?? false;
    if (done || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.explore_outlined, color: p.accent, size: 24),
            const SizedBox(width: 10),
            Text(
              'Discover the Viewer',
              style: TextStyle(
                color: p.onSurface,
                fontWeight: FontWeight.bold,
                fontSize: 17,
              ),
            ),
          ],
        ),
        content: Text(
          "Let's walk through the key features of the Media Viewer.\nTap each highlighted item to explore it.",
          style: TextStyle(color: p.muted, fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool(_tourPrefKey, true);
            },
            child: Text('Skip', style: TextStyle(color: p.muted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: p.accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              elevation: 0,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _startTour();
            },
            child: const Text(
              'Start Guide',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  void _startTour() {
    // Force chrome visible during tour
    if (!_showChrome) _toggleChrome();
    setState(() {
      _isTourActive = true;
      _tourStep = 0;
    });
  }

  void _advanceTour() {
    final next = _tourStep + 1;
    if (next >= _tourSteps.length) {
      _endTour();
    } else {
      setState(() => _tourStep = next);
    }
  }

  Future<void> _endTour() async {
    setState(() => _isTourActive = false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_tourPrefKey, true);
    _showSnack('Tour complete! You can re-open it from the menu.');
  }

  Rect? _getWidgetRect(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final offset = box.localToGlobal(Offset.zero);
    return offset & box.size;
  }

  Widget _buildTourOverlay() {
    if (_tourStep >= _tourSteps.length) return const SizedBox.shrink();
    final step = _tourSteps[_tourStep];
    final spotRect = _getWidgetRect(step.key);
    final screenSize = MediaQuery.of(context).size;
    final isBottom = (spotRect?.center.dy ?? 0) > screenSize.height * 0.6;
    final totalSteps = _tourSteps.length;

    return Positioned.fill(
      child: Stack(
        children: [
          // Darkened background with spotlight hole (non-interactive)
          IgnorePointer(
            child: CustomPaint(
              painter: _SpotlightPainter(
                spotRect: spotRect?.inflate(10),
                screenSize: screenSize,
              ),
              size: screenSize,
            ),
          ),

          // Transparent hit-pass-through over spotlight (lets real widget receive taps)
          if (spotRect != null)
            Positioned.fromRect(
              rect: spotRect.inflate(10),
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _advanceTour,
              ),
            ),

          // Tooltip card
          Positioned(
            left: 20,
            right: 20,
            top: isBottom
                ? (spotRect != null ? spotRect.top - 170 : 80)
                : (spotRect != null
                      ? spotRect.bottom + 20
                      : screenSize.height * 0.7),
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: p.card,
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black38,
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                  border: Border.all(
                    color: p.accent.withValues(alpha: 0.3),
                    width: 1.5,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: p.accentLight,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(step.icon, color: p.accent, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                step.title,
                                style: TextStyle(
                                  color: p.onSurface,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                              Text(
                                'Step ${_tourStep + 1} of $totalSteps',
                                style: TextStyle(color: p.muted, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      step.description,
                      style: TextStyle(
                        color: p.muted,
                        fontSize: 13,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton(
                          onPressed: _endTour,
                          child: Text(
                            'Skip Tour',
                            style: TextStyle(color: p.muted, fontSize: 12),
                          ),
                        ),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: p.accent,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                          ),
                          icon: const Icon(Icons.touch_app_rounded, size: 16),
                          label: Text(
                            _tourStep < totalSteps - 1
                                ? 'Tap it or Next →'
                                : 'Finish',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                          onPressed: _advanceTour,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reusable tiny widgets
// ─────────────────────────────────────────────────────────────────────────────

class _FlatSlider extends StatelessWidget {
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  const _FlatSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
  });

  @override
  Widget build(BuildContext context) {
    final p = _P(context);
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: p.accent,
        inactiveTrackColor: p.border,
        thumbColor: p.accent,
        overlayColor: p.accentLight,
        trackHeight: 2,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      ),
      child: Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        onChanged: onChanged,
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final p = _P(context);
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        color: p.muted,
        fontSize: 10.5,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.6,
      ),
    );
  }
}

class FullResolutionTrashedImage extends StatefulWidget {
  final GalleryItem item;
  final VoidCallback? onLoaded;
  final Map<String, Uint8List>? bytesCache;

  const FullResolutionTrashedImage({
    super.key,
    required this.item,
    this.onLoaded,
    this.bytesCache,
  });

  @override
  State<FullResolutionTrashedImage> createState() =>
      _FullResolutionTrashedImageState();
}

class _FullResolutionTrashedImageState
    extends State<FullResolutionTrashedImage> {
  Uint8List? _bytes;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadBytes();
  }

  @override
  void didUpdateWidget(FullResolutionTrashedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.item.id != oldWidget.item.id ||
        widget.item.imageUrl != oldWidget.item.imageUrl) {
      setState(() {
        _isLoading = true;
        _bytes = null;
      });
      _loadBytes();
    }
  }

  Future<void> _loadBytes() async {
    try {
      Uint8List? bytes = widget.bytesCache?[widget.item.id];
      if (bytes == null) {
        bytes = await TrashPersistence.getMediaBytes(
          mediaId: widget.item.id,
          filePath: widget.item.imageUrl,
        );
        if (bytes != null && widget.bytesCache != null) {
          widget.bytesCache![widget.item.id] = bytes;
        }
      }
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _isLoading = false;
      });
      if (bytes != null && widget.onLoaded != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            widget.onLoaded!();
          }
        });
      }
    } catch (e) {
      debugPrint('Error loading full-resolution trashed bytes: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _bytes == null) {
      return CachedMediaThumbnail(
        assetId: widget.item.id,
        filePath: widget.item.imageUrl,
        isVideo: false,
        fit: BoxFit.contain,
        onLoaded: () {
          if (widget.onLoaded != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) widget.onLoaded!();
            });
          }
        },
      );
    }
    return Image.memory(_bytes!, fit: BoxFit.contain);
  }
}

class VaultMediaLoader extends StatefulWidget {
  final GalleryItem item;
  final VoidCallback? onDecryptSuccess;
  final Widget Function(BuildContext, String) builder;

  const VaultMediaLoader({
    super.key,
    required this.item,
    this.onDecryptSuccess,
    required this.builder,
  });

  @override
  State<VaultMediaLoader> createState() => _VaultMediaLoaderState();
}

class _VaultMediaLoaderState extends State<VaultMediaLoader> {
  String? _error;
  bool _exists = false;

  @override
  void initState() {
    super.initState();
    _checkAndDecrypt();
  }

  @override
  void didUpdateWidget(VaultMediaLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.item.imageUrl != widget.item.imageUrl) {
      _checkAndDecrypt();
    }
  }

  Future<void> _checkAndDecrypt() async {
    final file = File(widget.item.imageUrl);
    if (await file.exists()) {
      if (mounted) {
        setState(() {
          _exists = true;
          _error = null;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _exists = false;
        _error = null;
      });
    }

    try {
      final vaultItems = await VaultService.instance.getAllVaultItems();
      final vaultItem = vaultItems.firstWhere(
        (x) => x.id == widget.item.id,
        orElse: () => throw Exception('Item not found in Vault database'),
      );

      final bytes = await VaultService.instance.getDecryptedBytes(vaultItem);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);

      if (mounted) {
        setState(() {
          _exists = true;
        });
        if (widget.onDecryptSuccess != null) {
          widget.onDecryptSuccess!();
        }
      }
    } catch (e) {
      debugPrint('VaultMediaLoader: Error decrypting ${widget.item.id}: $e');
      if (mounted) {
        setState(() {
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_exists) {
      return widget.builder(context, widget.item.imageUrl);
    }
    if (_error != null) {
      return Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
            const SizedBox(height: 12),
            Text(
              'Failed to decrypt media:\n$_error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return Container(
      color: Colors.black87,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
          SizedBox(height: 16),
          Text(
            'Decrypting media securely...',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tour helpers
// ─────────────────────────────────────────────────────────────────────────────

class _TourStepDef {
  final GlobalKey key;
  final IconData icon;
  final String title;
  final String description;
  const _TourStepDef(this.key, this.icon, this.title, this.description);
}

class _SpotlightPainter extends CustomPainter {
  final Rect? spotRect;
  final Size screenSize;

  const _SpotlightPainter({required this.spotRect, required this.screenSize});

  @override
  void paint(Canvas canvas, Size size) {
    final darkPaint = Paint()..color = Colors.black.withValues(alpha: 0.78);

    if (spotRect == null) {
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), darkPaint);
      return;
    }

    final rRect = RRect.fromRectAndRadius(spotRect!, const Radius.circular(14));

    // Punch-out spotlight via evenOdd fill — use ui.Path to avoid flutter_map conflict
    final path = ui.Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(rRect)
      ..fillType = ui.PathFillType.evenOdd;

    canvas.drawPath(path, darkPaint);

    // Glowing border around spotlight
    canvas.drawRRect(
      rRect,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) => old.spotRect != spotRect;
}
