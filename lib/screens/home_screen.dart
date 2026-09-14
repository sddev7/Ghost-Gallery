import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghost_gallery/screens/settings_screen.dart';
import 'package:ghost_gallery/services/entitlement_service.dart';
import '../models/gallery_item.dart';
import '../services/database_helper.dart';
import '../services/optional_features.dart';
import '../services/device_media_scanner.dart';
import '../services/ml_processing_service.dart';
import '../services/system_notification_service.dart';
import '../services/collection_source.dart';
import 'photo_viewer_screen.dart';
import 'package:ghost_gallery/widgets/add_to_album_dialog.dart';
import '../widgets/follow_us_dialog.dart';
import '../services/trash_persistence.dart';
import '../services/media_permission_service.dart';
import 'people_management_screen.dart';
import 'map_view_screen.dart';
import 'tabs/photos_tab.dart';
import 'tabs/albums_tab.dart';
import 'tabs/recommended_tab.dart';
import 'tabs/search_tab.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:video_player/video_player.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'collage_creator_screen.dart';
import '../services/widget_service.dart';
import '../services/favorites_persistence.dart';
import 'tabs/fast_media_preview.dart';
import '../services/ui_preference_provider.dart';
import '../widgets/ghost_narrative_dialog.dart';
import '../services/cache_cleanup_service.dart';
import '../services/responsive_helper.dart';

class GalleryHomeScreen extends StatefulWidget {
  final String appTheme; // 'light' | 'darcula' | 'ghost'
  final void Function(String) onThemeChanged;

  const GalleryHomeScreen({
    super.key,
    required this.appTheme,
    required this.onThemeChanged,
  });

  @override
  State<GalleryHomeScreen> createState() => _GalleryHomeScreenState();
}

class _GalleryHomeScreenState extends State<GalleryHomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final PageController _homePageController;
  int _currentTab = 0;
  bool _isSelectionMode = false;
  final List<String> _selectedItemIds = [];
  final int _customGridColumns = 0;

  int _gridColumns = 3;
  double _scaleStartColumns = 3.0;

  String _ghostyPersonality = 'Friendly';

  final bool _isConsoleExpanded = false;

  List<GalleryItem> _allItems = [];
  StreamSubscription<List<SharedMediaFile>>? _intentSub;
  List<GalleryItem> _realtimeCameraItems = [];
  bool _isLoadingRealtimeCamera = false;
  bool _isLoading = true;
  bool _isScanningFolders = false;
  bool _isInitialized = false;
  bool _isCheckingWidgetLaunch = false;
  final ScrollController _scrollController = ScrollController();

  List<Map<String, dynamic>> _peopleList = [];
  final GlobalKey _searchTabKey = GlobalKey();

  late final AnimationController _ghostFloatController;

  void _loadGridColumns() {
    if (mounted) {
      setState(() {
        _gridColumns = UIPreferenceProvider.instance.gridColumns;
        _scaleStartColumns = _gridColumns.toDouble();
      });
    }
    UIPreferenceProvider.instance.addListener(_handleUIPreferencesChange);
  }

  void _handleUIPreferencesChange() {
    if (mounted) {
      setState(() {
        _gridColumns = UIPreferenceProvider.instance.gridColumns;
        _scaleStartColumns = _gridColumns.toDouble();
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _homePageController = PageController(initialPage: _currentTab);
    WidgetsBinding.instance.addObserver(this);
    TrashPersistence.purgeExpired(); // fire-and-forget, non-blocking
    _loadGridColumns();
    _ghostFloatController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _initGallery();

    DeviceMediaScanner.instance.addListener(_refreshFromDB);

    // Refresh the DB at each WorkManager milestone (Tier 1, Tier 2, Tier 3 batch).
    // The background isolate bumps ghost_bg_refresh_seq in SharedPreferences;
    // startUiSync() detects it and increments refreshTriggerNotifier here on the
    // main isolate so _onRefreshTriggered() can call _refreshFromDB() safely.
    MLProcessingService.instance.refreshTriggerNotifier.addListener(
      _onRefreshTriggered,
    );

    // For sharing images/videos when app is running/paused in background
    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen(
      (value) {
        _handleSharedMedia(value);
      },
      onError: (err) {
        debugPrint("getMediaStream error: $err");
      },
    );

    // For sharing images/videos when app is closed
    ReceiveSharingIntent.instance.getInitialMedia().then((value) {
      _handleSharedMedia(value);
      ReceiveSharingIntent.instance.reset();
    });
  }

  /// Called by [MLProcessingService.refreshTriggerNotifier] each time the
  /// background WorkManager task signals a tier milestone (Tier 1 / 2 / 3 batch).
  void _onRefreshTriggered() {
    debugPrint(
      'HomeScreen: WorkManager tier milestone — refreshing DB '
      '(seq=${MLProcessingService.instance.refreshTriggerNotifier.value}).',
    );
    _refreshFromDB();
  }

  @override
  void dispose() {
    _homePageController.dispose();
    _intentSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    _ghostFloatController.dispose();
    DeviceMediaScanner.instance.removeListener(_refreshFromDB);
    MLProcessingService.instance.refreshTriggerNotifier.removeListener(
      _onRefreshTriggered,
    );
    WidgetsBinding.instance.removeObserver(this);
    UIPreferenceProvider.instance.removeListener(_handleUIPreferencesChange);
    DeviceMediaScanner.instance.removeListener(_refreshFromDB);
    MLProcessingService.instance.refreshTriggerNotifier.removeListener(
      _onRefreshTriggered,
    );
    _intentSub?.cancel();
    _ghostFloatController.dispose();
    _homePageController.dispose();
    WidgetsBinding.instance.removeObserver(this);

    super.dispose();
  }

  void _handleSharedMedia(List<SharedMediaFile> mediaFiles) async {
    if (mediaFiles.isEmpty) return;

    // Wait for the app to be fully initialized and not loading
    while (_isLoading || !_isInitialized) {
      await Future.delayed(const Duration(milliseconds: 200));
    }

    if (!mounted) return;

    // Convert SharedMediaFile to GalleryItem asynchronously in parallel
    final List<GalleryItem> sharedItems = await Future.wait(
      mediaFiles.map((file) async {
        final path = file.path;
        final type = file.type;
        final mediaType = type == SharedMediaType.video ? 'video' : 'image';

        // 1. Check if the item is already loaded in _allItems
        GalleryItem? matchedItem;
        for (final item in _allItems) {
          if (item.imageUrl == path || item.imageUrl.toLowerCase() == path.toLowerCase()) {
            matchedItem = item;
            break;
          }
        }

        // 2. If not found in _allItems, check the database directly
        if (matchedItem == null) {
          try {
            final db = DatabaseHelper.instance;
            final sqliteDb = await db.database;
            final dbRows = await sqliteDb.query(
              'media_items',
              where: 'path = ?',
              whereArgs: [path],
            );
            if (dbRows.isNotEmpty) {
              matchedItem = GalleryItem.fromMap(dbRows.first);
            }
          } catch (e) {
            debugPrint("Failed to fetch shared item from DB: $e");
          }
        }

        if (matchedItem != null) {
          return matchedItem;
        }

        // 3. Fallback: Build a temporary GalleryItem
        final id =
            'shared_${path.hashCode}_${DateTime.now().microsecondsSinceEpoch}';

        final fileObj = File(path);
        int sizeInBytes = 0;
        DateTime modifiedTime = DateTime.now();
        try {
          if (await fileObj.exists()) {
            final stat = await fileObj.stat();
            sizeInBytes = stat.size;
            modifiedTime = stat.modified;
          }
        } catch (_) {}

        final dateStr = _formatSharedDate(modifiedTime);
        final sizeStr = _formatSharedBytes(sizeInBytes);

        String dbDescription = "";
        try {
          final db = DatabaseHelper.instance;
          final sqliteDb = await db.database;
          final results = await sqliteDb.query(
            'media_items',
            columns: ['description'],
            where: 'path = ?',
            whereArgs: [path],
          );
          if (results.isNotEmpty) {
            dbDescription = results.first['description'] as String? ?? "";
          }
        } catch (_) {}

        if (dbDescription.isEmpty) {
          try {
            final db = DatabaseHelper.instance;
            final allItems = await db.getAllMediaItemsLite();
            final matching = allItems.firstWhere(
              (item) => item['path'] == path,
              orElse: () => <String, dynamic>{},
            );
            dbDescription = matching['description'] as String? ?? "";
          } catch (_) {}
        }

        int width = 0;
        int height = 0;
        double? durationSec = file.duration != null
            ? file.duration! / 1000.0
            : null;

        if (mediaType == 'image') {
          try {
            final bytes = await fileObj.readAsBytes();
            final codec = await ui.instantiateImageCodec(bytes);
            final frameInfo = await codec.getNextFrame();
            width = frameInfo.image.width;
            height = frameInfo.image.height;
          } catch (e) {
            debugPrint("Failed to decode image dimensions: $e");
          }
        } else if (mediaType == 'video') {
          try {
            final controller = VideoPlayerController.file(fileObj);
            await controller.initialize();
            final size = controller.value.size;
            width = size.width.toInt();
            height = size.height.toInt();
            if (controller.value.duration.inMilliseconds > 0) {
              durationSec = controller.value.duration.inMilliseconds / 1000.0;
            }
            await controller.dispose();
          } catch (e) {
            debugPrint("Failed to decode video dimensions/duration: $e");
          }
        }

        return GalleryItem(
          id: id,
          imageUrl: path,
          date: dateStr,
          dateTimestamp: modifiedTime.millisecondsSinceEpoch,
          location: 'Shared Media',
          description: dbDescription,
          category: mediaType == 'video' ? 'Video' : 'Photo',
          ghostComment: mediaType == 'video'
              ? 'Ooh, a shared video! Lets watch it together! 👻🎥'
              : 'Look at this photo you shared with me! 👻✨',
          resolution: '${width}x$height',
          size: sizeStr,
          mediaType: mediaType,
          duration: durationSec,
          width: width,
          height: height,
          albumName: 'Shared',
          albumCategory: 'Shared',
        );
      }),
    );

    if (sharedItems.isEmpty) return;

    final firstItem = sharedItems.first;
    final bool isFromAllItems = _allItems.any((x) => x.id == firstItem.id);
    final viewerItems = isFromAllItems ? _allItems : sharedItems;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PhotoViewerPage(
          item: firstItem,
          allItems: viewerItems,
          ghostPersonality: _ghostyPersonality,
          onDelete: (id) async {},
        ),
      ),
    );
  }

  String _formatSharedDate(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final itemDay = DateTime(dt.year, dt.month, dt.day);

    if (itemDay == today) return 'Today';
    if (itemDay == yesterday) return 'Yesterday';

    const months = [
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
    if (dt.year == now.year) {
      return '${months[dt.month - 1]} ${dt.day}';
    }
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  String _formatSharedBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    final i = (log(bytes) / log(1024)).floor();
    return '${(bytes / pow(1024, i)).toStringAsFixed(1)} ${suffixes[i]}';
  }

  Future<bool> _showStorageDisclosureDialog() async {
    if (!mounted) return false;
    final bool? result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        final cardColor = isDark ? const Color(0xFF0F0F18) : Colors.white;
        final textColor = isDark ? const Color(0xFFCDCDCD) : Colors.black87;
        const accentColor = Color(0xFFCC0000); // Ghost horror crimson/accent

        return PopScope(
          canPop: false,
          child: Dialog(
            backgroundColor: cardColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.photo_library_outlined,
                        color: accentColor,
                        size: 40,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Center(
                    child: Text(
                      'Access Your Media Library',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Ghost Gallery is a fully offline, local gallery application. To display your photos and videos, organize them into folders, detect faces, and create collages, the app requires access to your device\'s media storage library.',
                    style: TextStyle(
                      fontSize: 14,
                      color: textColor.withValues(alpha: 0.85),
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Icon(
                        Icons.lock_outline,
                        size: 16,
                        color: Colors.green,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Your media is processed entirely offline on-device and is never uploaded.',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: Colors.green[300] ?? Colors.green,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(ctx).pop(false),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(
                              color: textColor.withValues(alpha: 0.3),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: Text(
                            'Exit App',
                            style: TextStyle(
                              color: textColor.withValues(alpha: 0.7),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => Navigator.of(ctx).pop(true),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: accentColor,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            elevation: 4,
                          ),
                          child: const Text(
                            'Allow Access',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    return result ?? false;
  }

  Future<void> _showFirstTimeAiIndexingDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        final cardColor = isDark ? const Color(0xFF0F0F18) : Colors.white;
        final textColor = isDark ? const Color(0xFFCDCDCD) : Colors.black87;
        final titleColor = isDark ? Colors.white : Colors.black;
        final primaryColor = Theme.of(ctx).colorScheme.primary;

        return PopScope(
          canPop: false,
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 8.0, sigmaY: 8.0),
            child: Dialog(
              backgroundColor: cardColor,
              elevation: 24,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
                side: BorderSide(
                  color: isDark ? Colors.white10 : Colors.black12,
                  width: 1,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Glowing Gradient Icon Container
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            primaryColor,
                            primaryColor.withValues(alpha: 0.6),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: primaryColor.withValues(alpha: 0.35),
                            blurRadius: 15,
                            spreadRadius: 2,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.auto_awesome,
                        color: Colors.white,
                        size: 36,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Local AI Indexing',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        color: titleColor,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Setting up your private, offline gallery space.',
                      style: TextStyle(
                        fontSize: 13,
                        color: textColor.withValues(alpha: 0.6),
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    // Feature List
                    _buildDialogFeatureRow(
                      icon: Icons.security_outlined,
                      iconColor: Colors.greenAccent,
                      title: '100% Private & Secure',
                      description: 'All processing is done offline on-device. Your photos never leave your phone.',
                      textColor: textColor,
                    ),
                    const SizedBox(height: 16),
                    _buildDialogFeatureRow(
                      icon: Icons.battery_saver_outlined,
                      iconColor: Colors.amberAccent,
                      title: 'One-Time Initialization',
                      description: 'Scanning and face grouping may temporarily consume more battery and CPU.',
                      textColor: textColor,
                    ),
                    const SizedBox(height: 16),
                    _buildDialogFeatureRow(
                      icon: Icons.check_circle_outline_rounded,
                      iconColor: Colors.blueAccent,
                      title: 'Returns to Normal Mode',
                      description: 'Performance and power consumption will return to standard levels once complete.',
                      textColor: textColor,
                    ),
                    const SizedBox(height: 32),
                    // Action button
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: primaryColor,
                          foregroundColor: Theme.of(ctx).colorScheme.onPrimary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 4,
                          shadowColor: primaryColor.withValues(alpha: 0.4),
                        ),
                        child: const Text(
                          'Understood',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDialogFeatureRow({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String description,
    required Color textColor,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 2),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: iconColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            color: iconColor,
            size: 20,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                description,
                style: TextStyle(
                  fontSize: 12,
                  color: textColor.withValues(alpha: 0.65),
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _startImmediateScanAndUiUpdate() {
    Future.microtask(() async {
      // ── PHASE 1: Show Camera Roll immediately ────────────────────────────
      // A single filtered SQL query (WHERE album_category='Camera') is ~10×
      // faster than loading all items. The Photos tab appears in ~50–150 ms.
      try {
        final db = DatabaseHelper.instance;
        final cameraRows = await db.getCameraMediaItemsLite();
        final trashIds = await TrashPersistence.loadTrashIds();
        final cameraItems = cameraRows
            .where((m) => !trashIds.contains(m['id'] as String? ?? ''))
            .map((m) => GalleryItem.fromMap(m))
            .toList();
        if (mounted) {
          setState(() {
            if (cameraItems.isNotEmpty) {
              _realtimeCameraItems = cameraItems;
            }
            _isLoading = false; // spinner gone
          });
        }
      } catch (e) {
        debugPrint('Phase 1 camera-first load failed: $e');
        if (mounted) setState(() => _isLoading = false);
      }

      // ── PHASE 2: Load full collection in background ──────────────────────
      // Enriches _allItems with all albums + SQLite metadata.
      // Also refreshes _realtimeCameraItems with fully-enriched data.
      try {
        await CollectionSource.instance.init();
        await _refreshFromDBCache();
      } catch (e) {
        debugPrint('Phase 2 full collection load failed: $e');
      }

      // ── PHASE 3: Device media scan ─────────────────────────────────────────
      try {
        final prefs = await SharedPreferences.getInstance();
        final bool isFirstStart =
            !(prefs.getBool('ghost_first_scan_completed') ?? false);
        if (isFirstStart && mounted) {
          setState(() => _isScanningFolders = true);
        }
        await DeviceMediaScanner.instance.scanAndSyncDeviceMedia();
        if (isFirstStart) {
          await prefs.setBool('ghost_first_scan_completed', true);
        }
        await _refreshFromDB();
        // Silently clean up useless leftover files (.rgba, file_picker, share_plus) from cache
        CacheCleanupService.instance.cleanUselessCacheFiles();
      } catch (e) {
        debugPrint('Phase 3 scan/sync failed: $e');
      } finally {
        if (mounted) setState(() => _isScanningFolders = false);
      }
    });
  }

  Future<void> _initGallery() async {
    setState(() => _isLoading = true);

    bool hasPermission = false;
    if (Platform.isAndroid) {
      try {
        hasPermission =
            await const MethodChannel(
              'in.sddev.ghost_gallery/media_manager',
            ).invokeMethod<bool>('checkMediaPermission') ??
            false;
      } catch (e) {
        debugPrint('Error checking native media permission: $e');
      }
    } else {
      hasPermission = true;
    }

    if (!hasPermission) {
      if (mounted) {
        final consented = await showGhostNarrativeDialog(context);
        if (!consented) {
          if (mounted) setState(() => _isLoading = false);
          return;
        }
      }
      if (!mounted) return;

      if (Platform.isAndroid) {
        try {
          hasPermission = await const MethodChannel(
            'in.sddev.ghost_gallery/media_manager',
          ).invokeMethod<bool>('requestMediaPermission') ?? false;
        } catch (e) {
          debugPrint('Error requesting native media permission: $e');
        }
      } else {
        hasPermission = true;
      }

      if (!hasPermission) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }
    }

    // Permission granted! Start scanning and UI update immediately.
    _startImmediateScanAndUiUpdate();

    // 2. Notification permission request sequentially
    final prefs = await SharedPreferences.getInstance();
    final bool notificationAsked =
        prefs.getBool('ghost_notification_asked') ?? false;
    if (!notificationAsked) {
      try {
        await SystemNotificationService.instance.initialize(
          requestPermissions: true,
        );
      } catch (e) {
        debugPrint('Notification initialization/request error: $e');
      }
      await prefs.setBool('ghost_notification_asked', true);
    } else {
      try {
        await SystemNotificationService.instance.initialize(
          requestPermissions: false,
        );
      } catch (e) {
        debugPrint('Notification initialization error: $e');
      }
    }

    // 3. Battery optimization info dialog -> Actual permission
    if (mounted) {
      await _checkAndPromptBatteryOptimization();
    }

    // 4. Final INFO WITH Understood dialog
    final bool hasShownAiNotice =
        prefs.getBool('ghost_has_shown_ai_indexing_notice') ?? false;
    if (!hasShownAiNotice) {
      if (mounted) {
        await _showFirstTimeAiIndexingDialog();
      }
      await prefs.setBool('ghost_has_shown_ai_indexing_notice', true);
    }

    // First-start detection via persistent flag
    final bool isFirstStart =
        !(prefs.getBool('ghost_has_launched_before') ?? false);
    if (isFirstStart) {
      await prefs.setBool('ghost_has_launched_before', true);
    }

    // Clean HTTP ghost items from DB
    final db = DatabaseHelper.instance;
    final itemsMap = await db.getAllMediaItemsLite();
    for (var item in itemsMap) {
      final path = (item['path'] as String? ?? '').toLowerCase();
      if (path.startsWith('http')) {
        await db.deleteMediaItem(item['id'] as String);
      }
    }

    // Force widget update on every app open so the launcher always has fresh PendingIntents
    WidgetService.forceUpdateWidget().catchError((_) {});
    _checkWidgetLaunch();

    DeviceMediaScanner.instance.startListeningToGalleryChanges();
    DeviceMediaScanner.instance.startListeningToWindowsFolderChanges();

    _isInitialized = true;
    if (mounted) {
      FollowUsDialog.checkAndPrompt(context);
    }
  }

  bool _isCameraCapture(String id, String path) {
    final pathLower = path.toLowerCase();
    final idLower = id.toLowerCase();
    if (pathLower.startsWith('http')) return false;
    return pathLower.contains('/dcim/') ||
        pathLower.contains('/camera/') ||
        pathLower.contains('/camera roll/') ||
        pathLower.contains('/cameraroll/') ||
        pathLower.contains('/camera-roll/') ||
        pathLower.contains('\\dcim\\') ||
        pathLower.contains('\\camera\\') ||
        pathLower.contains('\\camera roll\\') ||
        pathLower.contains('\\cameraroll\\') ||
        pathLower.contains('\\camera-roll\\') ||
        idLower.startsWith('imported');
  }

  DateTime _parseDateStringToDateTime(String dateStr, DateTime now) {
    final cleanedStr = dateStr.trim();
    if (cleanedStr.toLowerCase() == 'today') {
      return DateTime(now.year, now.month, now.day, 23, 59, 59);
    }
    if (cleanedStr.toLowerCase() == 'yesterday') {
      return DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(const Duration(seconds: 1));
    }
    final parsedIso = DateTime.tryParse(cleanedStr);
    if (parsedIso != null) return parsedIso;

    try {
      final cleaned = cleanedStr.replaceAll(',', '');
      final parts = cleaned
          .split(RegExp(r'\s+'))
          .where((p) => p.isNotEmpty)
          .toList();
      if (parts.isNotEmpty) {
        final months = [
          'jan',
          'feb',
          'mar',
          'apr',
          'may',
          'jun',
          'jul',
          'aug',
          'sep',
          'oct',
          'nov',
          'dec',
        ];
        int monthIdx = -1;
        int monthPartIndex = -1;
        for (int i = 0; i < parts.length; i++) {
          final mIdx = months.indexOf(parts[i].toLowerCase());
          if (mIdx != -1) {
            monthIdx = mIdx;
            monthPartIndex = i;
            break;
          }
        }
        if (monthIdx != -1) {
          final remainingParts = <String>[];
          for (int i = 0; i < parts.length; i++) {
            if (i != monthPartIndex) remainingParts.add(parts[i]);
          }
          int day = 1;
          int year = now.year;
          if (remainingParts.isNotEmpty) {
            day = int.tryParse(remainingParts[0]) ?? 1;
            if (remainingParts.length >= 2) {
              year = int.tryParse(remainingParts[1]) ?? now.year;
            }
          }
          return DateTime(year, monthIdx + 1, day);
        }
      }
    } catch (_) {}

    return DateTime(1970);
  }

  /// Fast initial load — reads only the SQLite cache.
  /// Clears the loading spinner immediately on app open.
  Future<void> _refreshFromDBCache() async {
    if (mounted) {
      setState(() {
        _allItems = CollectionSource.instance.items;
        _peopleList = CollectionSource.instance.peopleList;
        _isLoading = false; // ← spinner gone immediately
      });
    }
  }

  Future<void> _loadRealtimeCamera() async {
    if (_isLoadingRealtimeCamera) return;
    _isLoadingRealtimeCamera = true;
    try {
      final items = await DeviceMediaScanner.loadAlbumMediaDirectlyFromDevice(
        'Camera',
      );
      final trashIds = await TrashPersistence.loadTrashIds();
      final filteredItems = items
          .where((item) => !trashIds.contains(item.id))
          .toList();
      if (mounted) {
        setState(() {
          _realtimeCameraItems = filteredItems;
        });
      }
    } catch (e) {
      debugPrint('Error loading realtime camera items: $e');
    } finally {
      _isLoadingRealtimeCamera = false;
    }
  }

  /// Silent background/data sync refresh — loads from CollectionSource (single
  /// MediaStore + SQLite call). Extracts camera items directly from the loaded
  /// collection so we never call getMediaList twice.
  Future<void> _refreshFromDB() async {
    await CollectionSource.instance.refresh();
    if (mounted) {
      final allItems = CollectionSource.instance.items;
      final cameraItems = allItems
          .where((x) => _isCameraCapture(x.id, x.imageUrl))
          .toList();
      setState(() {
        _allItems = allItems;
        _peopleList = CollectionSource.instance.peopleList;
        _realtimeCameraItems = cameraItems;
        _isLoading = false;
      });
    }
  }

  void _onTabTapped(int index) {
    setState(() => _currentTab = index);
    _homePageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _navigateToSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsScreen(
          appTheme: widget.appTheme,
          onThemeChanged: widget.onThemeChanged,
          ghostyPersonality: _ghostyPersonality,
          onGhostyChanged: (val) => setState(() => _ghostyPersonality = val),
          onConfigureWidgetPressed: () => _showWidgetPickerForSettings(),
        ),
      ),
    );
    await _refreshFromDB();
  }

  void _toggleSelectMode() {
    setState(() {
      _isSelectionMode = !_isSelectionMode;
      _selectedItemIds.clear();
    });
  }

  Future<void> _onItemTapped(
    GalleryItem item, [
    List<GalleryItem>? customList,
  ]) async {
    if (_isSelectionMode) {
      HapticFeedback.lightImpact();
      setState(() {
        if (_selectedItemIds.contains(item.id)) {
          _selectedItemIds.remove(item.id);
        } else {
          _selectedItemIds.add(item.id);
        }
      });
    } else {
      final viewerItems = customList ?? _allItems;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => PhotoViewerPage(
            item: item,
            allItems: viewerItems,
            ghostPersonality: _ghostyPersonality,
            onDelete: (id) async {
              await _refreshFromDB();
            },
          ),
        ),
      );
      await _refreshFromDB();
    }
  }

  void _importCustomMedia(bool isVideo) async {
    final imported = await DeviceMediaScanner.instance.pickAndImportMedia(
      isVideo,
    );
    if (imported != null) {
      await _refreshFromDB();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Manually added local ${isVideo ? "Video" : "Photo"}!'),
        ),
      );
    }
  }

  void _capturePhotoFromCamera() async {
    final captured = await DeviceMediaScanner.instance.capturePhoto();
    if (captured != null) {
      await _refreshFromDB();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Successfully captured new photo!')),
      );
    }
  }

  int _getColumnsForGroup(String groupName) {
    return ResponsiveHelper.responsiveGridColumns(
      context,
      baseColumns: _gridColumns,
      min: 1,
      max: 10,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isSelectionMode && _currentTab == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;

        if (_isSelectionMode) {
          setState(() {
            _isSelectionMode = false;
            _selectedItemIds.clear();
          });
          return;
        }

        if (_currentTab == 3) {
          final dynamic searchState = _searchTabKey.currentState;
          if (searchState != null) {
            if (searchState.isSelectionMode) {
              searchState.clearSelection();
              return;
            }
            if (searchState.isSearchActive) {
              searchState.clearSearchAndFilters();
              return;
            }
          }
        }

        if (_currentTab != 0) {
          setState(() {
            _currentTab = 0;
          });
          _homePageController.animateToPage(
            0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        }
      },
      child: Scaffold(
        body: Stack(
          children: [
            SafeArea(
              child: Column(
                children: [
                  _buildCustomAppBar(),
                  if (_isScanningFolders) _buildEmbeddedScanningBanner(),
                  Expanded(
                    child: _isLoading
                        ? const Center(child: CircularProgressIndicator())
                        : PageView(
                            controller: _homePageController,
                            // Swipe navigation disabled - use the bottom NavBar to switch tabs
                            physics: const NeverScrollableScrollPhysics(),
                            onPageChanged: (index) {
                              if (_currentTab != index) {
                                setState(() {
                                  _currentTab = index;
                                });
                              }
                            },
                            children: [
                              // Tab 0: Photos
                              PhotosTab(
                                allItems: _realtimeCameraItems.isNotEmpty
                                    ? _realtimeCameraItems
                                    : _allItems,
                                isSelectionMode: _isSelectionMode,
                                selectedItemIds: _selectedItemIds,
                                scrollController: _scrollController,
                                onItemTapped: (item) {
                                  // Map every item in the real-time list to its fully-enriched database representation where possible
                                  final List<GalleryItem> sourceList =
                                      _realtimeCameraItems.isNotEmpty
                                      ? _realtimeCameraItems
                                      : _allItems.where((x) {
                                          if (x.mediaType != 'image' &&
                                              x.mediaType != 'video') {
                                            return false;
                                          }
                                          return _isCameraCapture(
                                                x.id,
                                                x.imageUrl,
                                              ) ||
                                              x.albumCategory.toLowerCase() ==
                                                  'camera' ||
                                              x.albumName
                                                  .toLowerCase()
                                                  .contains('camera');
                                        }).toList();

                                  final List<GalleryItem> viewerItems =
                                      sourceList.map((x) {
                                        return _allItems.firstWhere(
                                          (dbItem) => dbItem.id == x.id,
                                          orElse: () => x,
                                        );
                                      }).toList();

                                  final dbItem = _allItems.firstWhere(
                                    (x) => x.id == item.id,
                                    orElse: () => item,
                                  );

                                  _onItemTapped(dbItem, viewerItems);
                                },
                                onRefresh: () async {
                                  await _refreshFromDB();
                                },
                                getColumnsForGroup: _getColumnsForGroup,
                                onSelectionChanged: (selectedIds) {
                                  setState(() {
                                    _selectedItemIds.clear();
                                    _selectedItemIds.addAll(selectedIds);
                                    if (_selectedItemIds.isEmpty) {
                                      _isSelectionMode = false;
                                    }
                                  });
                                },
                                onItemLongPressed: (item) {
                                  setState(() {
                                    _isSelectionMode = true;
                                    _selectedItemIds.add(item.id);
                                  });
                                },
                                onImportPressed: () =>
                                    _importCustomMedia(false),
                              ),
                              // Tab 1: Albums
                              AlbumsTab(
                                allItems: _allItems,
                                peopleList: _peopleList,
                                onItemTapped: _onItemTapped,
                                onPeoplePressed: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => PeopleManagementScreen(
                                      onDataChanged: _refreshFromDB,
                                    ),
                                  ),
                                ),
                                onMapPressed: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const MapViewScreen(),
                                  ),
                                ),
                                onRefresh: _refreshFromDB,
                                appTheme: widget.appTheme,
                              ),
                              // Tab 2: Recommended
                              RecommendedTab(
                                allItems: _allItems,
                                onItemTapped: _onItemTapped,
                              ),
                              // Tab 3: Search
                              SearchTab(
                                key: _searchTabKey,
                                allItems: _allItems,
                                peopleList: _peopleList,
                                onItemTapped: _onItemTapped,
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
            if (_currentTab == 0 &&
                _isSelectionMode &&
                _selectedItemIds.isNotEmpty)
              Positioned(
                left: 16,
                right: 16,
                bottom: 16 + MediaQuery.of(context).padding.bottom,
                child: _buildFloatingSelectionBar(),
              ),
          ],
        ),
        bottomNavigationBar: context.isTV
            ? Align(
                alignment: Alignment.bottomCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: _buildNavigationBar(),
                ),
              )
            : _buildNavigationBar(),
      ),
    );
  }

  Widget _buildNavigationBar() {
    final isWatch = context.isWatch;
    return NavigationBar(
      height: isWatch ? 50 : (context.isTV ? 72 : null),
      labelBehavior: isWatch
          ? NavigationDestinationLabelBehavior.alwaysHide
          : NavigationDestinationLabelBehavior.alwaysShow,
      selectedIndex: _currentTab,
      onDestinationSelected: _onTabTapped,
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.photo_library_outlined),
          selectedIcon: Icon(Icons.photo_library),
          label: "Photos",
        ),
        NavigationDestination(
          icon: Icon(Icons.folder_open_outlined),
          selectedIcon: Icon(Icons.folder),
          label: "Albums",
        ),
        NavigationDestination(
          icon: Icon(Icons.diamond_outlined),
          selectedIcon: Icon(Icons.diamond),
          label: "Recommends",
        ),
        NavigationDestination(
          icon: Icon(Icons.search_outlined),
          selectedIcon: Icon(Icons.search),
          label: "Search",
        ),
      ],
    );
  }

  Widget _buildEmbeddedScanningBanner() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = isDark ? const Color(0xFF1E1B29) : Colors.purple.shade50;
    final primaryColor = theme.colorScheme.primary;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: primaryColor.withValues(alpha: 0.2),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "Scanning Media Folders... 👻✨",
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: theme.textTheme.titleMedium?.color,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  "Scanning and organizing your library. Photos will appear shortly.",
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.textTheme.bodyMedium?.color?.withValues(
                      alpha: 0.7,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCustomAppBar() {
    final titles = ['Photos', 'Albums', 'Recommends', 'Search'];
    final title = titles[_currentTab];
    final cs = Theme.of(context).colorScheme;
    final isWatch = context.isWatch;
    final titleSize = isWatch ? 19.0 : (context.isTV ? 36.0 : 30.0);

    return Container(
      padding: EdgeInsets.fromLTRB(
        isWatch ? 12 : 20,
        isWatch ? 8 : 16,
        isWatch ? 6 : 8,
        8,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: titleSize,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.8,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _appBarIconBtn(
                customIcon: CustomPaint(
                  size: Size(isWatch ? 18 : 21, isWatch ? 18 : 21),
                  painter: GitHubMarkPainter(color: cs.onSurface),
                ),
                onTap: () => FollowUsDialog.show(context),
                cs: cs,
                tooltip: 'We are open-source / GitHub',
              ),
              _appBarIconBtn(
                icon: Icons.settings_outlined,
                onTap: _navigateToSettings,
                cs: cs,
                tooltip: 'Settings',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _appBarIconBtn({
    IconData? icon,
    Widget? customIcon,
    required VoidCallback onTap,
    required ColorScheme cs,
    Color? iconColor,
    String? tooltip,
  }) {
    final isWatch = context.isWatch;
    final btn = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(50),
        child: Padding(
          padding: EdgeInsets.all(isWatch ? 6 : 10),
          child: customIcon ??
              Icon(
                icon!,
                size: isWatch ? 18 : 24,
                color: iconColor ?? cs.onSurface,
              ),
        ),
      ),
    );
    if (tooltip != null) {
      return Tooltip(message: tooltip, child: btn);
    }
    return btn;
  }

  void _showImportPickerSheet() {
    showModalBottomSheet(
      context: context,
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "Capture or Import Media",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.photo_camera)),
              title: const Text("Capture Photo with Camera"),
              onTap: () {
                Navigator.pop(context);
                _capturePhotoFromCamera();
              },
            ),
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.image)),
              title: const Text("Import Photo from Gallery"),
              onTap: () {
                Navigator.pop(context);
                _importCustomMedia(false);
              },
            ),
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.videocam)),
              title: const Text("Import Video Clip from Gallery"),
              onTap: () {
                Navigator.pop(context);
                _importCustomMedia(true);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _secureSelectedItems() async {
    final List<GalleryItem> selectedItems = [];
    for (final id in _selectedItemIds) {
      try {
        final item = _allItems.firstWhere((x) => x.id == id);
        selectedItems.add(item);
      } catch (_) {}
    }
    if (selectedItems.isEmpty) return;

    await MediaPermissionService.secureMediaWithPermission(
      context,
      selectedItems,
      () {
        if (mounted) {
          setState(() {
            _allItems.removeWhere((item) => _selectedItemIds.contains(item.id));
            _isSelectionMode = false;
            _selectedItemIds.clear();
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Media moved to Secure Vault.')),
          );
          _refreshFromDB();
        }
      },
    );
  }

  Widget _buildFloatingSelectionBar() {
    final theme = Theme.of(context);
    final bgColor = theme.colorScheme.surface.withValues(alpha: 0.95);
    final borderColor = theme.colorScheme.outlineVariant.withValues(alpha: 0.6);

    return Material(
      color: Colors.transparent,
      child: Container(
        height: 70,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: borderColor, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 15,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildSelectionActionItem(
              icon: Icons.share_outlined,
              label: "Send",
              onTap: _shareSelectedItems,
            ),
            _buildSelectionActionItem(
              icon: Icons.delete_outline,
              label: "Delete",
              onTap: _deleteSelectedItems,
              color: Colors.redAccent,
            ),
            _buildSelectionActionItem(
              icon: Icons.lock_outline,
              label: "Secure",
              onTap: _secureSelectedItems,
            ),
            _buildSelectionActionItem(
              icon: Icons.create_new_folder_outlined,
              label: "Add to Album",
              onTap: _addSelectedItemsToAlbum,
            ),
            _buildSelectionActionItem(
              icon: Icons.dashboard_customize_outlined,
              label: "Collage",
              onTap: _createCollageFromSelected,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectionActionItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    final activeColor = color ?? Theme.of(context).colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: activeColor, size: 22),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: activeColor,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _shareSelectedItems() {
    final List<XFile> filesToShare = [];
    for (final id in _selectedItemIds) {
      try {
        final item = _allItems.firstWhere((x) => x.id == id);
        final file = File(item.imageUrl);
        if (file.existsSync()) {
          filesToShare.add(XFile(file.path));
        }
      } catch (_) {}
    }
    if (filesToShare.isNotEmpty) {
      Share.shareXFiles(filesToShare);
      setState(() {
        _isSelectionMode = false;
        _selectedItemIds.clear();
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No local files available to send.')),
      );
    }
  }

  Future<void> _deleteSelectedItems() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Move to Trash?'),
        content: Text(
          'Move ${_selectedItemIds.length} item(s) to Recently Deleted?\n\nTrash files will be permanently deleted after 30 days.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Move to Trash',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final itemsToDelete = <GalleryItem>[];
    for (final id in _selectedItemIds) {
      try {
        final item = _allItems.firstWhere((x) => x.id == id);
        itemsToDelete.add(item);
      } catch (_) {}
    }
    final List<String> toTrashIds = itemsToDelete.map((e) => e.id).toList();
    if (itemsToDelete.isNotEmpty) {
      await MediaPermissionService.softDeleteWithPermission(
        context,
        itemsToDelete,
      );
    }

    setState(() {
      _isSelectionMode = false;
      _selectedItemIds.clear();
    });
    await _refreshFromDB();

    if (mounted && toTrashIds.isNotEmpty) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
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
                Expanded(
                  child: Text(
                    'Moved ${toTrashIds.length} item(s) to Recently Deleted.',
                    style: const TextStyle(
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
                      await MediaPermissionService.showBatchProgressDialog(
                        context: context,
                        title: "Restoring Media Files",
                        totalCount: toTrashIds.length,
                        action: (onProgress) => TrashPersistence.restore(
                          toTrashIds,
                          context: context,
                          onProgress: onProgress,
                        ),
                      );
                    } catch (e) {
                      debugPrint('Undo restore error: $e');
                    }
                    if (mounted) {
                      await _refreshFromDB();
                    }
                  },
                  child: const Text(
                    'UNDO',
                    style: TextStyle(
                      color: Colors.blueAccent,
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
  }

  Future<void> _addSelectedItemsToAlbum() async {
    AddToAlbumDialog.show(
      context,
      _selectedItemIds.toList(),
      onComplete: () {
        if (mounted) {
          setState(() {
            _isSelectionMode = false;
            _selectedItemIds.clear();
          });
          _refreshFromDB();
        }
      },
    );
  }

  void _createCollageFromSelected() async {
    final List<GalleryItem> items = [];
    for (final id in _selectedItemIds) {
      try {
        final item = _allItems.firstWhere((x) => x.id == id);
        items.add(item);
      } catch (_) {}
    }

    if (items.isEmpty) return;

    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CollageCreatorScreen(selectedItems: items),
      ),
    );

    if (created == true) {
      setState(() {
        _isSelectionMode = false;
        _selectedItemIds.clear();
      });
      await _refreshFromDB();
    }
  }

  // ── WidgetsBindingObserver Lifecycle callback ──
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      DatabaseHelper.isAppInForeground = true;
      if (_isInitialized) {
        _checkWidgetLaunch();
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      DatabaseHelper.isAppInForeground = false;
    }
  }

  // ── Home Screen Widget Support ──

  String _getFolderName(String path) {
    if (path.startsWith('http')) return 'Downloads';
    try {
      String name = File(
        path,
      ).parent.path.split(Platform.isWindows ? '\\' : '/').last;
      if (name.isEmpty || name == '0' || name == 'emulated') return 'Other';
      final lowerName = name.toLowerCase();
      if (lowerName == 'cameraroll' ||
          lowerName == 'camera-roll' ||
          lowerName == 'camera' ||
          lowerName == 'dcim') {
        return 'Camera';
      }
      if (lowerName.contains('whatsapp')) return 'WhatsApp';
      if (lowerName.contains('screenshot') ||
          lowerName.contains('screen shot') ||
          lowerName.contains('screen-shot')) {
        return 'Screenshots';
      }
      if (lowerName.contains('download')) return 'Downloads';
      if (lowerName.contains('telegram')) return 'Telegram';
      if (lowerName.contains('instagram')) return 'Instagram';
      if (name.length > 1) {
        return name[0].toUpperCase() + name.substring(1);
      }
      return name;
    } catch (_) {
      return 'Other';
    }
  }

  Future<void> _checkWidgetLaunch() async {
    // Guard against concurrent checks (e.g. postFrameCallback + didChangeAppLifecycleState firing close together)
    if (_isCheckingWidgetLaunch) return;
    _isCheckingWidgetLaunch = true;
    try {
      // On cold start, Android's SharedPreferences disk commit (.apply()) is async.
      // Poll up to 8 times (4 seconds total) to wait for the BroadcastReceiver's
      // WidgetLaunchPrefs write to become visible to this process.
      Map<String, dynamic>? data;
      for (int attempt = 0; attempt < 8; attempt++) {
        data = await WidgetService.getWidgetLaunchData();
        debugPrint(
          "[HomeScreen] Checked widget launch data (attempt ${attempt + 1}): $data",
        );
        if (data != null) break;
        if (attempt < 7) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
      if (data == null) return;

      final isWidgetClick = data['widgetClicked'] == true;
      if (!isWidgetClick) return;

      debugPrint(
        "[HomeScreen] Widget open/click detected! Action: ${data['action']}, ImagePath: ${data['imagePath']}, AlbumName: ${data['albumName']}",
      );

      // Wait for the UI to fully settle before presenting dialogs or navigating.
      await Future.delayed(const Duration(milliseconds: 500));

      // If an initial load or folder scan is in progress, wait for it to complete.
      while (_isLoading || _isScanningFolders) {
        await Future.delayed(const Duration(milliseconds: 200));
      }

      if (!mounted) return;

      final action = data['action'] as String?;
      final imagePath = data['imagePath'] as String?;
      final albumName = data['albumName'] as String?;

      if (action == 'APP_OPEN') {
        // Just opening the app — no extra navigation needed.
        debugPrint(
          '[HomeScreen] APP_OPEN: app brought to foreground by widget tap.',
        );
      } else if (action == 'CONFIGURE') {
        final wId = data['widgetId'] as int?;
        await _showWidgetAlbumSelector(widgetId: wId);
      } else if (action == 'VIEW_IMAGE' && imagePath != null) {
        // Find the GalleryItem corresponding to this path
        GalleryItem? clickedItem;
        for (final item in _allItems) {
          if (item.imageUrl == imagePath) {
            clickedItem = item;
            break;
          }
        }

        if (clickedItem != null) {
          // Construct the list of items for this album
          List<GalleryItem> albumItems = [];
          if (albumName == 'All photos') {
            albumItems = _allItems;
          } else if (albumName == 'Favorites') {
            final favIds = await FavoritesPersistence.loadFavorites();
            albumItems = _allItems.where((x) => favIds.contains(x.id)).toList();
          } else if (albumName != null) {
            // Folder album or custom album — try custom album first
            Map<String, List<String>> customAlbums = {};
            try {
              final dir = await getApplicationDocumentsDirectory();
              final file = File('${dir.path}/custom_albums.json');
              if (await file.exists()) {
                customAlbums = Map<String, List<String>>.from(
                  json.decode(await file.readAsString()),
                );
              }
            } catch (_) {}

            if (customAlbums.containsKey(albumName)) {
              final ids = customAlbums[albumName]!;
              albumItems = _allItems.where((x) => ids.contains(x.id)).toList();
            } else {
              albumItems = _allItems
                  .where((x) => _getFolderName(x.imageUrl) == albumName)
                  .toList();
            }
          }

          if (albumItems.isEmpty) albumItems = [clickedItem];

          if (mounted) {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => PhotoViewerPage(
                  item: clickedItem!,
                  allItems: albumItems,
                  ghostPersonality: _ghostyPersonality,
                  onDelete: (id) async {
                    await _refreshFromDB();
                  },
                ),
              ),
            );
          }
        } else {
          debugPrint(
            '[HomeScreen] Could not find gallery item for path: $imagePath',
          );
        }
      }
    } finally {
      _isCheckingWidgetLaunch = false;
    }
  }

  /// Called from the Settings panel. Fetches active widget IDs and:
  ///   • 0 widgets → shows the album selector anyway (first-time setup / pre-add).
  ///   • 1 widget  → goes straight to the album selector for that widget.
  ///   • 2+ widgets → shows a picker so the user can choose which widget to configure.
  Future<void> _showWidgetPickerForSettings() async {
    if (!mounted) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    List<int> activeIds = [];
    try {
      activeIds = await WidgetService.getActiveWidgetIds();
    } catch (_) {}

    if (!mounted) return;

    if (activeIds.isEmpty || activeIds.length == 1) {
      // No widgets or exactly one — go straight to album selector
      await _showWidgetAlbumSelector(
        widgetId: activeIds.isNotEmpty ? activeIds.first : null,
      );
      return;
    }

    // Multiple widgets — show a picker
    final int? chosenId = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E1E24) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          padding: const EdgeInsets.only(
            top: 8,
            bottom: 32,
            left: 24,
            right: 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: isDark ? Colors.white24 : Colors.black12,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Row(
                children: [
                  const Text('👻', style: TextStyle(fontSize: 24)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Which Widget?',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                        Text(
                          'You have ${activeIds.length} widgets — pick one to configure',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? Colors.white60 : Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              // "Configure All" option
              _buildWidgetPickerTile(
                icon: Icons.dashboard_customize_outlined,
                title: 'Configure All Widgets',
                subtitle: 'Apply the same album to every widget',
                isDark: isDark,
                onTap: () => Navigator.pop(ctx, -1), // -1 = all
              ),
              const SizedBox(height: 8),
              Divider(
                color: isDark ? Colors.white12 : Colors.black12,
                height: 16,
              ),
              ...List.generate(activeIds.length, (i) {
                final id = activeIds[i];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _buildWidgetPickerTile(
                    icon: Icons.widgets_outlined,
                    title: 'Widget ${i + 1}',
                    subtitle: 'ID #$id',
                    isDark: isDark,
                    onTap: () => Navigator.pop(ctx, id),
                  ),
                );
              }),
            ],
          ),
        );
      },
    );

    if (!mounted || chosenId == null) return;

    if (chosenId == -1) {
      // User chose "Configure All"
      await _showWidgetAlbumSelector(widgetId: null);
    } else {
      await _showWidgetAlbumSelector(widgetId: chosenId);
    }
  }

  Widget _buildWidgetPickerTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: isDark ? Colors.white10 : Colors.black12),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.purpleAccent.withValues(
                  alpha: isDark ? 0.15 : 0.08,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: Colors.purpleAccent, size: 22),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white54 : Colors.black45,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: isDark ? Colors.white30 : Colors.black26,
            ),
          ],
        ),
      ),
    );
  }

  /// When [widgetId] is null the selected album is applied to ALL widgets.
  Future<void> _showWidgetAlbumSelector({int? widgetId}) async {
    if (!mounted) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Gather all albums
    final favIds = await FavoritesPersistence.loadFavorites();

    final Map<String, List<GalleryItem>> folderGroups = {};
    for (final item in _allItems) {
      final name = _getFolderName(item.imageUrl);
      folderGroups.putIfAbsent(name, () => []).add(item);
    }

    Map<String, List<String>> customAlbumsRaw = {};
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/custom_albums.json');
      if (await file.exists()) {
        customAlbumsRaw = Map<String, List<String>>.from(
          json.decode(await file.readAsString()),
        );
      }
    } catch (_) {}

    final List<Map<String, dynamic>> albumsToSelect = [];

    albumsToSelect.add({'name': 'All photos', 'items': _allItems});

    final favItems = _allItems.where((x) => favIds.contains(x.id)).toList();
    if (favItems.isNotEmpty) {
      albumsToSelect.add({'name': 'Favorites', 'items': favItems});
    }

    folderGroups.forEach((name, items) {
      if (name.isNotEmpty && items.isNotEmpty) {
        albumsToSelect.add({'name': name, 'items': items});
      }
    });

    customAlbumsRaw.forEach((name, ids) {
      final items = _allItems.where((x) => ids.contains(x.id)).toList();
      if (items.isNotEmpty) {
        albumsToSelect.add({'name': name, 'items': items});
      }
    });

    List<Map<String, dynamic>> validAlbums = albumsToSelect.where((album) {
      final items = album['items'] as List<GalleryItem>;
      return items.any((x) => x.mediaType == 'image');
    }).toList();



    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E1E24) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          padding: const EdgeInsets.only(
            top: 8,
            bottom: 24,
            left: 24,
            right: 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: isDark ? Colors.white24 : Colors.black12,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Row(
                children: [
                  const Text("👻", style: TextStyle(fontSize: 24)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widgetId != null
                              ? "Select Widget Album"
                              : "Select Album for All Widgets",
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                        Text(
                          widgetId != null
                              ? "Configuring Widget #$widgetId"
                              : "This will update all home screen widgets",
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? Colors.white60 : Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.5,
                ),
                child: validAlbums.isEmpty
                    ? Container(
                        padding: const EdgeInsets.symmetric(vertical: 40),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text("👻", style: TextStyle(fontSize: 48)),
                            const SizedBox(height: 16),
                            Text(
                              "No albums found yet!",
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                              ),
                              child: Text(
                                "Ghost couldn't find any photos. Make sure you have photos in your gallery, or wait for the background scan to finish!",
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isDark
                                      ? Colors.white60
                                      : Colors.black54,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: validAlbums.length,
                        itemBuilder: (ctx, idx) {
                          final album = validAlbums[idx];
                          final name = album['name'] as String;

                          final items = album['items'] as List<GalleryItem>;
                          final imageItems = items
                              .where((x) => x.mediaType == 'image')
                              .toList();

                          final GalleryItem? coverItem = imageItems.isNotEmpty
                              ? imageItems.first
                              : null;

                          final int totalPhotos = imageItems.length;

                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: InkWell(
                              onTap: () async {
                                Navigator.pop(context);

                                final finalImageItems = imageItems;

                                await WidgetService.configureWidgetAlbum(
                                  name,
                                  finalImageItems,
                                  widgetId: widgetId,
                                );
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      "Widget set to album '$name' 👻✨",
                                    ),
                                    behavior: SnackBarBehavior.floating,
                                    backgroundColor: Colors.purpleAccent,
                                  ),
                                );
                              },
                              borderRadius: BorderRadius.circular(16),
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: isDark
                                        ? Colors.white10
                                        : Colors.black12,
                                  ),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Row(
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: SizedBox(
                                        width: 50,
                                        height: 50,
                                        child: coverItem != null
                                            ? FastMediaPreview(
                                                item: coverItem,
                                                fit: BoxFit.cover,
                                              )
                                            : Container(
                                                color: Colors.grey,
                                                child: const Icon(Icons.photo),
                                              ),
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            name,
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                              color: isDark
                                                  ? Colors.white
                                                  : Colors.black87,
                                            ),
                                          ),
                                          Text(
                                            "$totalPhotos photos",
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: isDark
                                                  ? Colors.white60
                                                  : Colors.black54,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Icon(
                                      Icons.chevron_right,
                                      color: isDark
                                          ? Colors.white30
                                          : Colors.black26,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Battery Optimization Exemption ─────────────────────────────────────────
  // Shown ONCE per install. If the user already granted it (or denies), we
  // persist the fact and never show it again. Fire-and-forget — does not block
  // any other initialization work.
  Future<void> _checkAndPromptBatteryOptimization() async {
    if (!Platform.isAndroid) return;

    final prefs = await SharedPreferences.getInstance();
    final bool alreadyAsked = prefs.getBool('ghost_battery_opt_asked') ?? false;
    if (alreadyAsked) return;

    // Don't re-prompt if already exempt.
    final bool exempt = await MLProcessingService.isBatteryOptimizationExempt();
    if (exempt) {
      await prefs.setBool('ghost_battery_opt_asked', true);
      return;
    }

    if (!mounted) return;

    // Small delay so the screen settles after the initial media permission dialogs.
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => const _BatteryOptimizationDialog(),
    );

    // Mark as asked regardless of user choice — we only prompt once.
    await prefs.setBool('ghost_battery_opt_asked', true);
  }
}

// ── Battery Optimization Permission Dialog ────────────────────────────────────

class _BatteryOptimizationDialog extends StatefulWidget {
  const _BatteryOptimizationDialog();

  @override
  State<_BatteryOptimizationDialog> createState() =>
      _BatteryOptimizationDialogState();
}

class _BatteryOptimizationDialogState extends State<_BatteryOptimizationDialog>
    with WidgetsBindingObserver {
  bool _waitingForSettings = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When the user comes back from the system dialog, close this dialog.
    if (state == AppLifecycleState.resumed && _waitingForSettings && mounted) {
      _waitingForSettings = false;
      Navigator.of(context).pop();
    }
  }

  Future<void> _allowInBackground() async {
    setState(() => _waitingForSettings = true);
    await MLProcessingService.requestBatteryOptimizationExemption();
    // Dialog auto-closes when app resumes via didChangeAppLifecycleState.
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF1C1C24) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF1A1A2E);
    final subtextColor = isDark ? Colors.white60 : const Color(0xFF6B7280);
    final accentColor = Theme.of(context).colorScheme.primary;

    return Dialog(
      backgroundColor: bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Icon + Title row
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.battery_saver_rounded,
                    color: accentColor,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'Allow Background\nProcessing',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: textColor,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              'Ghost Gallery uses AI to auto-tag, OCR, and organize your photos in the background.',
              style: TextStyle(fontSize: 14, color: textColor, height: 1.5),
            ),
            const SizedBox(height: 10),
            Text(
              'To keep your gallery organized and up to date in the background, we recommend allowing Ghost Gallery to run unrestricted by battery optimization. This allows the local AI to catalog new photos and group faces smoothly when the device is idle.',
              style: TextStyle(fontSize: 13, color: subtextColor, height: 1.55),
            ),
            const SizedBox(height: 8),
            // Info chip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: accentColor.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 15,
                    color: accentColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'You can always change this later in Settings → Apps → Ghost Gallery → Battery.',
                      style: TextStyle(
                        fontSize: 12,
                        color: accentColor,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // Action buttons
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: _waitingForSettings
                        ? null
                        : () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: isDark ? Colors.white12 : Colors.black12,
                        ),
                      ),
                    ),
                    child: Text(
                      'Not now',
                      style: TextStyle(
                        color: subtextColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: _waitingForSettings ? null : _allowInBackground,
                    style: FilledButton.styleFrom(
                      backgroundColor: accentColor,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: _waitingForSettings
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.check_circle_outline, size: 18),
                    label: Text(
                      _waitingForSettings
                          ? 'Opening settings…'
                          : 'Allow in background',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ParsedGalleryItem {
  final GalleryItem item;
  final DateTime parsedDateTime;
  _ParsedGalleryItem(this.item, this.parsedDateTime);
}
