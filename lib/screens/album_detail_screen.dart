import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/gallery_item.dart';
import '../services/database_helper.dart';
import '../services/favorites_persistence.dart';
import '../services/trash_persistence.dart';
import '../services/media_permission_service.dart';
import '../services/device_media_scanner.dart';
import 'tabs/fast_media_preview.dart';
import 'tabs/albums_tab.dart';
import '../widgets/grid_scale_overlay.dart';
import '../widgets/album_slideshow_background.dart';
import '../services/burst_helper.dart';
import 'collage_creator_screen.dart';
import 'photo_viewer_screen.dart';
import 'package:ghost_gallery/widgets/add_to_album_dialog.dart';
import '../services/ui_preference_provider.dart';
import '../widgets/photo_grid.dart';
import '../services/responsive_helper.dart';

// ─────────────────────────────────────────────────────────────────────────────
// AlbumDetailScreen — full-screen album viewer
// ─────────────────────────────────────────────────────────────────────────────
class AlbumDetailScreen extends StatefulWidget {
  final String albumName;
  final List<GalleryItem> items;
  final bool isCustom;
  final bool isRecentlyDeleted;

  /// Set to true for location-cluster albums opened from the Memory Map.
  /// Prevents _refreshAlbum from replacing cluster items with all-device media.
  final bool isLocationAlbum;
  final Function(GalleryItem, [List<GalleryItem>?]) onItemTapped;

  /// Called when items are permanently added/removed so parent can rebuild.
  final Future<void> Function()? onAlbumChanged;
  final String? highlightItemId;

  const AlbumDetailScreen({
    super.key,
    required this.albumName,
    required this.items,
    required this.onItemTapped,
    this.isCustom = false,
    this.isRecentlyDeleted = false,
    this.isLocationAlbum = false,
    this.onAlbumChanged,
    this.highlightItemId,
  });

  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen> {
  List<GalleryItem> _items = [];
  bool _selectionMode = false;
  final Set<String> _selected = {};
  late String _albumName;
  String? _highlightItemId;

  int _crossAxisCount = 3;
  double _scaleStartColumns = 3.0;
  final double _visualScale = 1.0;
  final double _baseScale = 1.0;
  int _pointerCount = 0;
  OverlayEntry? _activeOverlayEntry;
  ValueNotifier<double>? _scaleNotifier;

  bool _columnHudVisible = false;
  Timer? _hudHideTimer;
  int _anchorItemIndex = 0;
  bool _pendingAnchorScroll = false;

  final Map<String, BuildContext> _itemContexts = {};
  bool _isDraggingToSelect = false;
  String? _dragStartId;
  bool _dragSelectInitialState = true;
  Offset? _dragStartPosition;
  bool _dragDirectionDecided = false;
  final ScrollController _scrollController = ScrollController();

  String _getDynamicDateLabel(GalleryItem item) {
    final ts = item.modifiedTimestamp ?? item.dateTimestamp;
    if (ts == 0) return item.date;
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final itemDay = DateTime(dt.year, dt.month, dt.day);

    if (itemDay == today) return 'Today';
    if (itemDay == yesterday) return 'Yesterday';

    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
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
    final weekdayStr = weekdays[dt.weekday - 1];
    final monthStr = months[dt.month - 1];

    if (dt.year == now.year) {
      return '$weekdayStr, ${dt.day} $monthStr';
    }
    return '$weekdayStr, ${dt.day} $monthStr, ${dt.year}';
  }

  void _scrollToHighlightItem() {
    if (_highlightItemId == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        final collapsedItems = BurstHelper.collapseBursts(_items);
        collapsedItems.sort((a, b) {
          final tsA = a.modifiedTimestamp ?? a.dateTimestamp;
          final tsB = b.modifiedTimestamp ?? b.dateTimestamp;
          return tsB.compareTo(tsA);
        });

        int targetItemIdx = collapsedItems.indexWhere(
          (x) => x.id == _highlightItemId,
        );
        if (targetItemIdx == -1) return;

        final targetItem = collapsedItems[targetItemIdx];

        final Map<String, List<GalleryItem>> groupedItems = {};
        for (final item in collapsedItems) {
          final dateLabel = _getDynamicDateLabel(item);
          groupedItems.putIfAbsent(dateLabel, () => []).add(item);
        }
        final sortedDates = groupedItems.keys.toList();

        final targetDateLabel = _getDynamicDateLabel(targetItem);
        final targetDateIdx = sortedDates.indexOf(targetDateLabel);
        if (targetDateIdx == -1) return;

        final screenWidth = MediaQuery.of(context).size.width;
        final double itemSize =
            (screenWidth - 24 - (_crossAxisCount - 1) * 6) / _crossAxisCount;

        double offset = 8.0; // top padding of ListView

        for (int i = 0; i < targetDateIdx; i++) {
          final dateStr = sortedDates[i];
          final listForDate = groupedItems[dateStr]!;
          final rows = (listForDate.length / _crossAxisCount).ceil();
          final gridHeight = rows * itemSize + (rows - 1) * 6;
          final groupHeight = 30.0 + gridHeight + 20.0;
          offset += groupHeight;
        }

        final targetList = groupedItems[targetDateLabel]!;
        final idxInGroup = targetList.indexWhere(
          (x) => x.id == _highlightItemId,
        );
        if (idxInGroup != -1) {
          final targetRow = (idxInGroup / _crossAxisCount).floor();
          offset += 30.0; // after the header
          offset += targetRow * (itemSize + 6);
        }

        if (_scrollController.hasClients) {
          final maxScroll = _scrollController.position.maxScrollExtent;
          final targetScroll = offset.clamp(0.0, maxScroll);
          _scrollController.animateTo(
            targetScroll,
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeInOut,
          );

          // Clear highlight after 2 seconds
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) {
              setState(() {
                _highlightItemId = null;
              });
            }
          });
        }
      } catch (e) {
        debugPrint("Error scrolling to highlight item: $e");
      }
    });
  }

  Future<void> _refreshAlbum() async {
    try {
      final trashIds = await TrashPersistence.loadTrashIds();
      final favs = await FavoritesPersistence.loadFavorites();

      List<GalleryItem> sourceItems = [];

      if (widget.isLocationAlbum) {
        // Location-cluster albums: re-fetch only the original cluster items from DB
        // by their IDs to get up-to-date data, without querying by album name
        // (which would fall back to "All Photos" and return every item on the device).
        final db = DatabaseHelper.instance;
        final originalIds = widget.items.map((x) => x.id).toSet();
        final itemsMap = await db.getAllMediaItems();
        for (final map in itemsMap) {
          final item = GalleryItem.fromMap(map);
          if (originalIds.contains(item.id)) {
            sourceItems.add(item);
          }
        }
      } else if (widget.isCustom) {
        // Load custom album items from JSON/DB cache
        final db = DatabaseHelper.instance;
        final itemsMap = await db.getAllMediaItems();
        final dir = await getApplicationDocumentsDirectory();
        final file = File('${dir.path}/custom_albums.json');
        List<String> customItemIds = [];
        if (await file.exists()) {
          final decoded =
              json.decode(await file.readAsString()) as Map<String, dynamic>;
          customItemIds = List<String>.from(decoded[_albumName] ?? []);
        }
        for (final map in itemsMap) {
          final item = GalleryItem.fromMap(map);
          if (customItemIds.contains(item.id)) {
            sourceItems.add(item);
          }
        }
      } else if (widget.albumName == 'Favorites') {
        // Load favorites from DB
        final db = DatabaseHelper.instance;
        final itemsMap = await db.getAllMediaItems();
        for (final map in itemsMap) {
          final item = GalleryItem.fromMap(map);
          if (favs.contains(item.id)) {
            sourceItems.add(item);
          }
        }
      } else if (widget.albumName == 'Recently Deleted') {
        // Load recently deleted from DB cache
        final db = DatabaseHelper.instance;
        final itemsMap = await db.getAllMediaItems();

        final dir = await getApplicationDocumentsDirectory();
        final file = File('${dir.path}/recently_deleted.json');
        Map<String, dynamic> deletedJsonData = {};
        if (await file.exists()) {
          try {
            deletedJsonData =
                json.decode(await file.readAsString()) as Map<String, dynamic>;
          } catch (e) {
            debugPrint('Error parsing recently_deleted.json: $e');
          }
        }

        for (final map in itemsMap) {
          final item = GalleryItem.fromMap(map);
          if (trashIds.contains(item.id)) {
            final jsonEntry = deletedJsonData[item.id];
            DateTime? deletedAt;
            if (jsonEntry != null && jsonEntry['deletedAt'] != null) {
              deletedAt = DateTime.tryParse(jsonEntry['deletedAt']);
            }
            sourceItems.add(item.copyWith(deletedAt: deletedAt));
          }
        }
      } else {
        // Load directly from PhotoManager for native performance and up-to-date state
        try {
          sourceItems =
              await DeviceMediaScanner.loadAlbumMediaDirectlyFromDevice(
                widget.albumName,
              );
        } catch (e) {
          debugPrint('Error loading native album from device: $e');
        }
        // Safety Fallback: If PhotoManager returns fewer items than we originally had
        // in widget.items (likely due to query/naming mismatches or platform restrictions),
        // we preserve the scanned list from widget.items.
        if (sourceItems.length < widget.items.length &&
            widget.items.isNotEmpty) {
          sourceItems = List.from(widget.items);
        }
      }

      final List<GalleryItem> freshItems = [];
      for (final item in sourceItems) {
        if (widget.albumName != 'Recently Deleted' &&
            trashIds.contains(item.id)) {
          continue;
        }

        bool matches = false;
        if (widget.isCustom) {
          matches = true;
        } else if (widget.albumName == 'All photos') {
          matches = true;
        } else if (widget.albumName == 'Videos') {
          matches = item.mediaType == 'video';
        } else if (widget.albumName == 'Favorites') {
          matches = true;
        } else if (widget.albumName == 'Recently Deleted') {
          matches = true;
        } else {
          matches = true;
        }

        if (matches || widget.items.any((x) => x.id == item.id)) {
          freshItems.add(item);
        }
      }

      if (mounted) {
        freshItems.sort((a, b) {
          final tsA = a.modifiedTimestamp ?? a.dateTimestamp;
          final tsB = b.modifiedTimestamp ?? b.dateTimestamp;
          return tsB.compareTo(tsA);
        });
        setState(() {
          _items = freshItems;
        });
        if (_highlightItemId != null) {
          _scrollToHighlightItem();
        }
      }
      widget.onAlbumChanged?.call();
    } catch (e) {
      debugPrint('refresh album error: $e');
    }
  }

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

  String? _getItemIdAtPosition(Offset globalPos) {
    for (final entry in _itemContexts.entries) {
      final ctx = entry.value;
      if (!ctx.mounted) continue;
      final renderBox = ctx.findRenderObject() as RenderBox?;
      if (renderBox == null || !renderBox.hasSize) continue;
      final localPos = renderBox.globalToLocal(globalPos);
      if (localPos.dx >= 0 &&
          localPos.dx <= renderBox.size.width &&
          localPos.dy >= 0 &&
          localPos.dy <= renderBox.size.height) {
        return entry.key;
      }
    }
    return null;
  }

  void _checkAutoScroll(Offset globalPos) {
    // Disabled to prevent scrolling screen when sliding to select
  }

  void _updateDragSelection(String currentId) {
    if (_dragStartId == null) return;
    final collapsedItems = BurstHelper.collapseBursts(_items);
    final startIdx = collapsedItems.indexWhere((x) => x.id == _dragStartId);
    final endIdx = collapsedItems.indexWhere((x) => x.id == currentId);
    if (startIdx == -1 || endIdx == -1) return;

    final low = min(startIdx, endIdx);
    final high = max(startIdx, endIdx);

    bool changed = false;
    setState(() {
      for (int i = low; i <= high; i++) {
        final id = collapsedItems[i].id;
        if (_dragSelectInitialState) {
          if (!_selected.contains(id)) {
            _selected.add(id);
            changed = true;
          }
        } else {
          if (_selected.contains(id)) {
            _selected.remove(id);
            changed = true;
          }
        }
      }
      if (_selected.isEmpty) _selectionMode = false;
    });

    if (changed) {
      HapticFeedback.lightImpact();
    }
  }

  bool _isCollapsed = false;

  void _scrollListener() {
    if (_scrollController.hasClients) {
      final double offset = _scrollController.offset;
      // Banner height is 320, toolbar is kToolbarHeight
      final double collapseHeight = 320.0 - kToolbarHeight;
      if (offset >= collapseHeight && !_isCollapsed) {
        setState(() {
          _isCollapsed = true;
        });
      } else if (offset < collapseHeight && _isCollapsed) {
        setState(() {
          _isCollapsed = false;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _albumName = widget.albumName;
    _items = List.from(widget.items);
    _items.sort((a, b) {
      final tsA = a.modifiedTimestamp ?? a.dateTimestamp;
      final tsB = b.modifiedTimestamp ?? b.dateTimestamp;
      return tsB.compareTo(tsA);
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _highlightItemId = widget.highlightItemId;
    _scrollController.addListener(_scrollListener);
    if (_highlightItemId != null) {
      _scrollToHighlightItem();
    }
    _crossAxisCount = UIPreferenceProvider.instance.gridColumns;
    _scaleStartColumns = _crossAxisCount.toDouble();
    UIPreferenceProvider.instance.addListener(_handleUIPreferencesChange);
    DeviceMediaScanner.instance.addListener(_refreshAlbum);
  }

  void _handleUIPreferencesChange() {
    if (mounted) {
      setState(() {
        _crossAxisCount = UIPreferenceProvider.instance.gridColumns;
      });
    }
  }

  @override
  void dispose() {
    DeviceMediaScanner.instance.removeListener(_refreshAlbum);
    UIPreferenceProvider.instance.removeListener(_handleUIPreferencesChange);
    _scrollController.removeListener(_scrollListener);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AlbumDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.items != oldWidget.items) {
      setState(() {
        _items = List.from(widget.items);
        _items.sort((a, b) {
          final tsA = a.modifiedTimestamp ?? a.dateTimestamp;
          final tsB = b.modifiedTimestamp ?? b.dateTimestamp;
          return tsB.compareTo(tsA);
        });
      });
    }
  }

  void _toggleSelect(String id) {
    HapticFeedback.lightImpact();
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
      if (_selected.isEmpty) _selectionMode = false;
    });
  }

  void _enterSelection() => setState(() {
    _selectionMode = true;
    _selected.clear();
  });

  void _cancelSelection() => setState(() {
    _selectionMode = false;
    _selected.clear();
  });

  // Soft-delete selected items → move to recently_deleted.json
  Future<void> _softDeleteSelected() async {
    if (_selected.isEmpty) return;

    if (widget.isCustom) {
      final result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text('Delete from Album?'),
          content: Text(
            'Would you like to remove ${_selected.length} item(s) from this album, '
            'or move them to Recently Deleted (Trash)?\n\nTrash files will be permanently deleted after 30 days.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'remove'),
              child: const Text(
                'Remove from Album',
                style: TextStyle(
                  color: Colors.blue,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'trash'),
              child: const Text(
                'Move to Trash',
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      );

      if (result == null || result == 'cancel') return;

      if (result == 'remove') {
        await _removeSelectedFromCustomAlbum();
        return;
      }
    } else {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text('Move to Trash?'),
          content: Text(
            'Move ${_selected.length} item(s) to Recently Deleted? '
            'You can restore them from the Recently Deleted album later.\n\nTrash files will be permanently deleted after 30 days.',
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
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }

    final toTrash = _items.where((x) => _selected.contains(x.id)).toList();
    final toTrashIds = toTrash.map((x) => x.id).toList();

    try {
      await MediaPermissionService.softDeleteWithPermission(context, toTrash);
    } catch (e) {
      debugPrint('soft-delete error: $e');
    }

    setState(() {
      _items.removeWhere((x) => _selected.contains(x.id));
      _selectionMode = false;
      _selected.clear();
    });
    widget.onAlbumChanged?.call();
    if (mounted) {
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
                      final hasNative = toTrash.any(
                        (i) =>
                            !i.id.startsWith('win_') &&
                            !i.id.startsWith('imported_') &&
                            !i.id.startsWith('captured_'),
                      );
                      if (hasNative && Platform.isAndroid && context.mounted) {
                        final granted =
                            await MediaPermissionService.ensureManageMediaPermission(
                              context,
                            );
                        if (!granted) return;
                      }

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
                      await _refreshAlbum();
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

  Future<void> _removeSelectedFromCustomAlbum() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/custom_albums.json');
      if (await file.exists()) {
        final Map<String, dynamic> customAlbums = json.decode(
          await file.readAsString(),
        );
        final existingList = List<String>.from(customAlbums[_albumName] ?? []);
        existingList.removeWhere((id) => _selected.contains(id));
        customAlbums[_albumName] = existingList;
        await file.writeAsString(json.encode(customAlbums));
      }

      setState(() {
        _items.removeWhere((x) => _selected.contains(x.id));
        _selectionMode = false;
        _selected.clear();
      });
      widget.onAlbumChanged?.call();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Removed selected items from this album.'),
          ),
        );
      }
    } catch (e) {
      debugPrint("Error removing items from custom album: $e");
    }
  }

  // Restore all items in recently_deleted.json
  Future<void> _restoreSelected() async {
    if (_selected.isEmpty) return;
    try {
      final selectedItems = _items
          .where((x) => _selected.contains(x.id))
          .toList();
      final hasNative = selectedItems.any(
        (i) =>
            !i.id.startsWith('win_') &&
            !i.id.startsWith('imported_') &&
            !i.id.startsWith('captured_'),
      );
      if (hasNative && Platform.isAndroid) {
        final granted =
            await MediaPermissionService.ensureManageMediaPermission(context);
        if (!granted) return;
      }

      await MediaPermissionService.showBatchProgressDialog(
        context: context,
        title: "Restoring Media Files",
        totalCount: _selected.length,
        action: (onProgress) => TrashPersistence.restore(
          _selected.toList(),
          context: context,
          onProgress: onProgress,
        ),
      );
    } catch (e) {
      debugPrint('restore error: $e');
    }
    setState(() {
      _items.removeWhere((x) => _selected.contains(x.id));
      _selectionMode = false;
      _selected.clear();
    });
    widget.onAlbumChanged?.call();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Items restored successfully')),
      );
    }
  }

  // Permanently delete selected items from DB and recently_deleted.json
  Future<void> _deletePermanentlySelected() async {
    if (_selected.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete permanently?'),
        content: Text(
          'This will permanently delete ${_selected.length} item(s) from this device. '
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete Permanently',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      final toDelete = _items.where((x) => _selected.contains(x.id)).toList();
      final hasNative = toDelete.any(
        (i) =>
            !i.id.startsWith('win_') &&
            !i.id.startsWith('imported_') &&
            !i.id.startsWith('captured_'),
      );
      if (hasNative && Platform.isAndroid) {
        final granted =
            await MediaPermissionService.ensureManageMediaPermission(context);
        if (!granted) return;
      }

      final result = await MediaPermissionService.showBatchProgressDialog(
        context: context,
        title: "Deleting Media Files",
        totalCount: toDelete.length,
        action: (onProgress) => TrashPersistence.permanentlyDeleteItems(
          toDelete,
          context: context,
          onProgress: onProgress,
        ),
      );

      setState(() {
        _items.removeWhere((x) => _selected.contains(x.id));
        _selectionMode = false;
        _selected.clear();
      });
      widget.onAlbumChanged?.call();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(result.toMessage())));
      }
    } catch (e) {
      debugPrint('permanent delete error: $e');
    }

    setState(() {
      _items.removeWhere((x) => _selected.contains(x.id));
      _selectionMode = false;
      _selected.clear();
    });
    widget.onAlbumChanged?.call();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Items permanently deleted')),
      );
    }
  }

  // Empty all items from recently_deleted.json and DB
  Future<void> _emptyTrash() async {
    if (_items.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Empty Trash?'),
        content: Text(
          'All ${_items.length} item(s) in the trash will be permanently deleted from this device. '
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Empty Trash',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      final hasNative = _items.any(
        (i) =>
            !i.id.startsWith('win_') &&
            !i.id.startsWith('imported_') &&
            !i.id.startsWith('captured_'),
      );
      if (hasNative && Platform.isAndroid) {
        final granted =
            await MediaPermissionService.ensureManageMediaPermission(context);
        if (!granted) return;
      }

      final result = await MediaPermissionService.showBatchProgressDialog(
        context: context,
        title: "Emptying Trash",
        totalCount: _items.length,
        action: (onProgress) => TrashPersistence.permanentlyDeleteItems(
          _items,
          context: context,
          onProgress: onProgress,
        ),
      );

      setState(() {
        _items.clear();
        _selectionMode = false;
        _selected.clear();
      });
      widget.onAlbumChanged?.call();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(result.toMessage())));
      }
    } catch (e) {
      debugPrint('empty trash error: $e');
    }

    setState(() {
      _items.clear();
      _selectionMode = false;
      _selected.clear();
    });
    widget.onAlbumChanged?.call();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Trash emptied successfully')),
      );
    }
  }

  Future<void> _renameAlbum() async {
    final ctrl = TextEditingController(text: _albumName);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Rename Album',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Enter new album name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final t = ctrl.text.trim();
              if (t.isNotEmpty) Navigator.pop(ctx, t);
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == _albumName) return;

    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/custom_albums.json');
      Map<String, dynamic> customAlbums = {};
      if (await file.exists()) {
        customAlbums = json.decode(await file.readAsString());
      }
      if (customAlbums.containsKey(newName)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('An album with that name already exists!'),
          ),
        );
        return;
      }
      final list = customAlbums.remove(_albumName);
      if (list != null) {
        customAlbums[newName] = list;
        await file.writeAsString(json.encode(customAlbums));
        setState(() {
          _albumName = newName;
        });
        await _refreshAlbum();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Album renamed successfully!')),
        );
      }
    } catch (e) {
      debugPrint("Error renaming custom album: $e");
    }
  }

  Future<void> _addPhotosToAlbum() async {
    try {
      final db = DatabaseHelper.instance;
      final itemsMap = await db.getAllMediaItems();
      final trashIds = await TrashPersistence.loadTrashIds();
      final List<GalleryItem> allItems = [];
      for (final map in itemsMap) {
        final item = GalleryItem.fromMap(map);
        if (!trashIds.contains(item.id)) {
          allItems.add(item);
        }
      }

      if (!mounted) return;
      final selectedIds = await Navigator.push<List<String>>(
        context,
        MaterialPageRoute(
          builder: (_) => MediaSelectorScreen(
            allItems: allItems,
            title: 'Add to $_albumName',
          ),
        ),
      );

      if (selectedIds == null || selectedIds.isEmpty) return;

      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/custom_albums.json');
      Map<String, dynamic> customAlbums = {};
      if (await file.exists()) {
        customAlbums = json.decode(await file.readAsString());
      }

      final existingList = List<String>.from(customAlbums[_albumName] ?? []);
      final Set<String> updatedSet = {...existingList, ...selectedIds};
      customAlbums[_albumName] = updatedSet.toList();
      await file.writeAsString(json.encode(customAlbums));

      // Refresh local items
      await _refreshAlbum();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Added ${selectedIds.length} photo(s) to album!'),
        ),
      );
    } catch (e) {
      debugPrint("Error adding photos to custom album: $e");
    }
  }

  void _shareAlbum() {
    final localFiles = _items
        .map((x) => File(x.imageUrl))
        .where((f) => f.existsSync())
        .map((f) => XFile(f.path))
        .toList();

    if (localFiles.isNotEmpty) {
      Share.shareXFiles(localFiles);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No local files available in this album to share.'),
        ),
      );
    }
  }

  String _getDaysLeftText(DateTime? deletedAt) {
    if (deletedAt == null) return '30 days left';
    final difference = DateTime.now().difference(deletedAt).inDays;
    final daysLeft = 30 - difference;
    final clampedDays = daysLeft.clamp(1, 30);
    return '$clampedDays ${clampedDays == 1 ? 'day' : 'days'} left';
  }

  Widget _buildTrashInfoBanner() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isDark
            ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            color: theme.colorScheme.primary,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Items will be permanently deleted after 30 days from the device.',
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }


  void _showHud() {
    _hudHideTimer?.cancel();
    if (!_columnHudVisible) setState(() => _columnHudVisible = true);
    _hudHideTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _columnHudVisible = false);
    });
  }

  void _hideHudAfterDelay() {
    _hudHideTimer?.cancel();
    _hudHideTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _columnHudVisible = false);
    });
  }

  void _captureAnchor(List<GalleryItem> imageItems) {
    try {
      final sc = _scrollController;
      if (!sc.hasClients) return;
      final viewportMidY = sc.offset + sc.position.viewportDimension / 2;
      double bestDist = double.infinity;
      String? bestId;
      for (final entry in _itemContexts.entries) {
        final ctx = entry.value;
        if (!ctx.mounted) continue;
        final rb = ctx.findRenderObject() as RenderBox?;
        if (rb == null || !rb.hasSize) continue;
        final globalTop = rb.localToGlobal(Offset.zero).dy + sc.offset;
        final midY = globalTop + rb.size.height / 2;
        final dist = (midY - viewportMidY).abs();
        if (dist < bestDist) {
          bestDist = dist;
          bestId = entry.key;
        }
      }
      if (bestId != null) {
        final idx = imageItems.indexWhere((x) => x.id == bestId);
        if (idx != -1) _anchorItemIndex = idx;
      }
    } catch (_) {}
  }

  void _restoreAnchor(List<GalleryItem> imageItems, int columns) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pendingAnchorScroll = false;
      try {
        final sc = _scrollController;
        if (!sc.hasClients) return;
        if (_anchorItemIndex >= imageItems.length) return;
        final anchorId = imageItems[_anchorItemIndex].id;
        final ctx = _itemContexts[anchorId];
        if (ctx == null || !ctx.mounted) return;
        final rb = ctx.findRenderObject() as RenderBox?;
        if (rb == null || !rb.hasSize) return;
        final globalTop = rb.localToGlobal(Offset.zero).dy;
        final currentOffset = sc.offset;
        final desiredOffset = currentOffset +
            globalTop -
            sc.position.viewportDimension / 2 +
            rb.size.height / 2;
        sc.jumpTo(desiredOffset.clamp(0.0, sc.position.maxScrollExtent));
      } catch (_) {}
    });
  }

  List<_FlatItem> _buildFlatList(
    double screenWidth,
    List<String> sortedDates,
    Map<String, List<GalleryItem>> groupedItems,
  ) {
    final List<_FlatItem> flat = [];
    final double maxWidth = screenWidth - 24; // 12 padding on each side
    const double spacing = 3.0;

    for (final dateStr in sortedDates) {
      final items = groupedItems[dateStr] ?? [];
      if (items.isEmpty) continue;

      flat.add(_HeaderItem(dateStr));

      final columns = ResponsiveHelper.responsiveGridColumns(
        context,
        baseColumns: _crossAxisCount,
        min: 1,
        max: 10,
      );

      if (columns == 1) {
        flat.add(_RowItem(
          dateStr,
          [items.first],
          1,
          0,
          customAspectRatio: 4 / 3,
        ));

        for (int i = 1; i < items.length; i += 2) {
          final end = (i + 2 < items.length) ? i + 2 : items.length;
          flat.add(_RowItem(
            dateStr,
            items.sublist(i, end),
            2,
            (i - 1) ~/ 2 + 1,
            customAspectRatio: 1.0,
          ));
        }
      } else if (columns == 3) {
        final double targetHeight = maxWidth / 3;
        List<GalleryItem> currentRow = [];
        double currentAspectRatioSum = 0.0;
        int rowIndex = 0;

        for (final item in items) {
          double ratio = item.displayAspectRatio;
          if (ratio <= 0) ratio = 1.0;
          ratio = ratio.clamp(0.5, 2.0);

          currentRow.add(item);
          currentAspectRatioSum += ratio;

          double estimatedWidth = targetHeight * currentAspectRatioSum + spacing * (currentRow.length - 1);
          if (estimatedWidth >= maxWidth) {
            double usableWidth = maxWidth - spacing * (currentRow.length - 1);
            double actualHeight = usableWidth / currentAspectRatioSum;
            actualHeight = actualHeight.clamp(targetHeight * 0.6, targetHeight * 1.5);

            flat.add(_JustifiedRowItem(
              dateStr,
              currentRow,
              actualHeight,
              rowIndex++,
            ));

            currentRow = [];
            currentAspectRatioSum = 0.0;
          }
        }

        if (currentRow.isNotEmpty) {
          flat.add(_JustifiedRowItem(
            dateStr,
            currentRow,
            targetHeight,
            rowIndex,
            isLastRow: true,
          ));
        }
      } else {
        for (int i = 0; i < items.length; i += columns) {
          final end = (i + columns < items.length) ? i + columns : items.length;
          flat.add(_RowItem(
            dateStr,
            items.sublist(i, end),
            columns,
            i ~/ columns,
          ));
        }
      }
    }
    return flat;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF121212) : Colors.white;
    final titleColor = isDark ? Colors.white : Colors.black87;

    // Pre-collapse and sort items once per build
    final collapsedItems = BurstHelper.collapseBursts(_items);
    collapsedItems.sort((a, b) {
      final tsA = a.modifiedTimestamp ?? a.dateTimestamp;
      final tsB = b.modifiedTimestamp ?? b.dateTimestamp;
      return tsB.compareTo(tsA);
    });

    // Group items by date label
    final Map<String, List<GalleryItem>> groupedItems = {};
    for (final item in collapsedItems) {
      final dateLabel = _getDynamicDateLabel(item);
      groupedItems.putIfAbsent(dateLabel, () => []).add(item);
    }
    final sortedDates = groupedItems.keys.toList();

    // Precompute burst count map to avoid O(N^2) searches
    final burstMap = <String, int>{};
    for (final item in _items) {
      final key = BurstHelper.getBurstGroupKey(item);
      if (key != null) burstMap[key] = (burstMap[key] ?? 0) + 1;
    }

    final double screenWidth = MediaQuery.of(context).size.width;
    final List<_FlatItem> flatItems = _buildFlatList(screenWidth, sortedDates, groupedItems);

    if (widget.isRecentlyDeleted) {
      return PopScope(
        canPop: !_selectionMode,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          if (_selectionMode) {
            setState(() {
              _selectionMode = false;
              _selected.clear();
            });
          }
        },
        child: Scaffold(
          backgroundColor: bg,
          appBar: AppBar(
            backgroundColor: bg,
            foregroundColor: titleColor,
            elevation: 0,
            title: _selectionMode
                ? Text(
                    '${_selected.length} selected',
                    style: TextStyle(
                      color: titleColor,
                      fontWeight: FontWeight.bold,
                    ),
                  )
                : Text(
                    _albumName,
                    style: TextStyle(
                      color: titleColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 20,
                    ),
                  ),
            leading: _selectionMode
                ? IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: _cancelSelection,
                  )
                : null,
            actions: _selectionMode
                ? [
                    IconButton(
                      icon: Icon(
                        _selected.length == _items.length
                            ? Icons.deselect_outlined
                            : Icons.select_all,
                      ),
                      tooltip: _selected.length == _items.length
                          ? 'Deselect All'
                          : 'Select All',
                      onPressed: () {
                        setState(() {
                          if (_selected.length == _items.length) {
                            _selected.clear();
                            _selectionMode = false;
                          } else {
                            _selected.addAll(_items.map((x) => x.id));
                          }
                        });
                      },
                    ),
                  ]
                : [
                    if (widget.isRecentlyDeleted && _items.isNotEmpty)
                      TextButton(
                        onPressed: _emptyTrash,
                        child: const Text(
                          'Empty Trash',
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    IconButton(
                      icon: const Icon(Icons.check_box_outline_blank),
                      tooltip: 'Select',
                      onPressed: _enterSelection,
                    ),
                  ],
          ),
          body: Stack(
            children: [
              Column(
                children: [
                  _buildTrashInfoBanner(),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: _refreshAlbum,
                      child: _items.isEmpty
                          ? SingleChildScrollView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              child: Container(
                                height: MediaQuery.of(context).size.height - 220,
                                alignment: Alignment.center,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.delete_outline,
                                      size: 64,
                                      color: isDark
                                          ? Colors.white24
                                          : Colors.black26,
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      'No recently deleted items',
                                      style: TextStyle(
                                        color: isDark
                                            ? Colors.white54
                                            : Colors.black54,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : Stack(
                              children: [
                                Listener(
                                  onPointerDown: (event) {
                                    setState(() => _pointerCount++);
                                    if (_selectionMode && _pointerCount == 1) {
                                      final id = _getItemIdAtPosition(event.position);
                                      if (id != null) {
                                        _dragStartId = id;
                                        _dragStartPosition = event.position;
                                        _dragDirectionDecided = false;
                                        _isDraggingToSelect = false;
                                        _dragSelectInitialState = !_selected.contains(id);
                                      }
                                    }
                                  },
                                  onPointerMove: (event) {
                                    if (_dragStartId != null && _pointerCount == 1) {
                                      if (!_dragDirectionDecided && _dragStartPosition != null) {
                                        final dx = event.position.dx - _dragStartPosition!.dx;
                                        final dy = event.position.dy - _dragStartPosition!.dy;
                                        if (dx.abs() > 10 || dy.abs() > 10) {
                                          _dragDirectionDecided = true;
                                          if (dx.abs() > dy.abs()) {
                                            setState(() {
                                              _isDraggingToSelect = true;
                                            });
                                          } else {
                                            _isDraggingToSelect = false;
                                          }
                                        }
                                      }

                                      if (_isDraggingToSelect) {
                                        _checkAutoScroll(event.position);
                                        final id = _getItemIdAtPosition(event.position);
                                        if (id != null) {
                                          _updateDragSelection(id);
                                        }
                                      }
                                    }
                                  },
                                  onPointerUp: (event) {
                                    setState(() => _pointerCount = (_pointerCount - 1).clamp(0, 99));
                                    _isDraggingToSelect = false;
                                    _dragStartId = null;
                                    _dragStartPosition = null;
                                    _dragDirectionDecided = false;
                                  },
                                  onPointerCancel: (event) {
                                    setState(() => _pointerCount = (_pointerCount - 1).clamp(0, 99));
                                    _isDraggingToSelect = false;
                                    _dragStartId = null;
                                    _dragStartPosition = null;
                                    _dragDirectionDecided = false;
                                  },
                                  child: GestureDetector(
                                    onScaleStart: (d) {
                                      if (_pointerCount >= 2 || d.pointerCount >= 2) {
                                        _scaleStartColumns = _crossAxisCount.toDouble();
                                        _captureAnchor(collapsedItems);
                                        final activeItemId = _getItemIdAtPosition(d.focalPoint);
                                        if (activeItemId != null) {
                                          try {
                                            final activeItem = _items.firstWhere((x) => x.id == activeItemId);
                                            final ctx = _itemContexts[activeItemId];
                                            if (ctx != null && ctx.mounted) {
                                              final renderBox = ctx.findRenderObject() as RenderBox?;
                                              if (renderBox != null && renderBox.hasSize) {
                                                final startingSize = renderBox.size;
                                                final startingPosition = renderBox.localToGlobal(Offset.zero);
                                                _scaleNotifier = ValueNotifier<double>(1.0);
                                                _activeOverlayEntry = OverlayEntry(
                                                  builder: (context) => GridScaleOverlay(
                                                    item: activeItem,
                                                    startingPosition: startingPosition,
                                                    startingSize: startingSize,
                                                    focalPoint: d.focalPoint,
                                                    scaleNotifier: _scaleNotifier!,
                                                  ),
                                                );
                                                Overlay.of(context).insert(_activeOverlayEntry!);
                                              }
                                            }
                                          } catch (e) {
                                            debugPrint('Scale start error: $e');
                                          }
                                        }
                                        _showHud();
                                      }
                                    },
                                    onScaleUpdate: (d) {
                                      if (_pointerCount < 2 && d.pointerCount < 2) return;
                                      _scaleNotifier?.value = d.scale.clamp(0.5, 2.5);

                                      int target = _scaleStartColumns.toInt();
                                      if (d.scale > 1.0) {
                                        final double steps = (d.scale - 1.0) / 0.18;
                                        target = (_scaleStartColumns - steps.floor()).clamp(1, 6).toInt();
                                      } else if (d.scale < 1.0) {
                                        final double steps = (1.0 - d.scale) / 0.15;
                                        target = (_scaleStartColumns + steps.floor()).clamp(1, 6).toInt();
                                      }

                                      if (target != _crossAxisCount) {
                                        _captureAnchor(collapsedItems);
                                        UIPreferenceProvider.instance.setGridColumns(target);
                                        _pendingAnchorScroll = true;
                                        _showHud();
                                      }
                                    },
                                    onScaleEnd: (_) {
                                      _activeOverlayEntry?.remove();
                                      _activeOverlayEntry = null;
                                      _scaleNotifier?.dispose();
                                      _scaleNotifier = null;
                                      _hideHudAfterDelay();
                                      if (_pendingAnchorScroll) {
                                        _restoreAnchor(collapsedItems, _crossAxisCount);
                                      }
                                    },
                                    child: CustomScrollView(
                                      controller: _scrollController,
                                      physics: (_pointerCount >= 2 || _isDraggingToSelect)
                                          ? const NeverScrollableScrollPhysics()
                                          : const BouncingScrollPhysics(
                                              parent: AlwaysScrollableScrollPhysics(),
                                            ),
                                      slivers: [
                                        SliverList.builder(
                                          itemCount: flatItems.length,
                                          itemBuilder: (context, index) {
                                            final flatItem = flatItems[index];
                                            if (flatItem is _HeaderItem) {
                                              return Padding(
                                                padding: const EdgeInsets.only(
                                                  top: 14,
                                                  left: 12,
                                                  right: 12,
                                                  bottom: 8,
                                                ),
                                                child: Text(
                                                  flatItem.date,
                                                  style: TextStyle(
                                                    fontSize: 16,
                                                    fontWeight: FontWeight.bold,
                                                    color: isDark ? Colors.white : Colors.black87,
                                                    letterSpacing: -0.3,
                                                  ),
                                                ),
                                              );
                                            } else if (flatItem is _RowItem) {
                                              final rowItems = flatItem.items;
                                              final columns = flatItem.columns;

                                              final double aspectRatio = flatItem.customAspectRatio ?? (
                                                  columns <= 1
                                                      ? 4 / 3
                                                      : columns == 2
                                                          ? 0.90
                                                          : columns == 3
                                                              ? 1.0
                                                              : columns == 4
                                                                  ? 1.15
                                                                  : columns == 5
                                                                      ? 1.25
                                                                      : 1.0
                                              );

                                              final bool isLastRowOfSection = (index + 1 >= flatItems.length) ||
                                                  (flatItems[index + 1] is _HeaderItem);
                                              final double sectionBottomSpacing = isLastRowOfSection ? 16.0 : 3.0;

                                              return Padding(
                                                padding: EdgeInsets.only(
                                                  left: 12,
                                                  right: 12,
                                                  bottom: sectionBottomSpacing,
                                                ),
                                                child: Row(
                                                  children: List.generate(columns, (colIndex) {
                                                    if (colIndex >= rowItems.length) {
                                                      return const Expanded(child: SizedBox.shrink());
                                                    }
                                                    final item = rowItems[colIndex];

                                                    int burstCount = burstMap[BurstHelper.getBurstGroupKey(item) ?? ''] ?? 1;

                                                    return Expanded(
                                                      child: Padding(
                                                        padding: EdgeInsets.only(
                                                          right: colIndex == columns - 1 ? 0 : 3,
                                                        ),
                                                        child: AspectRatio(
                                                          aspectRatio: aspectRatio,
                                                          child: PhotoGridTile(
                                                            key: ValueKey(item.id),
                                                            item: item,
                                                            isSelected: _selected.contains(item.id),
                                                            isSelectionMode: _selectionMode,
                                                            isBurstRepresentative: burstCount > 1,
                                                            burstCount: burstCount,
                                                            borderRadius: columns >= 5 ? 6.0 : columns == 4 ? 8.0 : 10.0,
                                                            onTap: () async {
                                                              if (_selectionMode) {
                                                                _toggleSelect(item.id);
                                                              } else {
                                                                await widget.onItemTapped(item, _items);
                                                                _refreshAlbum();
                                                              }
                                                            },
                                                            onLongPress: () {
                                                              if (!_selectionMode) {
                                                                HapticFeedback.lightImpact();
                                                                setState(() {
                                                                  _selectionMode = true;
                                                                  _selected.add(item.id);
                                                                });
                                                              }
                                                            },
                                                            onContextReady: (ctx) => _itemContexts[item.id] = ctx,
                                                            topLeftBadge: Container(
                                                              padding: const EdgeInsets.symmetric(
                                                                horizontal: 6,
                                                                vertical: 3,
                                                              ),
                                                              decoration: BoxDecoration(
                                                                color: Colors.black.withValues(alpha: 0.65),
                                                                borderRadius: BorderRadius.circular(6),
                                                                border: Border.all(
                                                                  color: Colors.white24,
                                                                  width: 0.5,
                                                                ),
                                                              ),
                                                              child: Text(
                                                                _getDaysLeftText(item.deletedAt),
                                                                style: const TextStyle(
                                                                  color: Colors.white,
                                                                  fontSize: 9,
                                                                  fontWeight: FontWeight.w600,
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    );
                                                  }),
                                                ),
                                              );
                                            } else if (flatItem is _JustifiedRowItem) {
                                              final rowItems = flatItem.items;
                                              final height = flatItem.height;
                                              final isLastRow = flatItem.isLastRow;

                                              const double spacing = 3.0;

                                              final List<double> ratios = rowItems.map((item) {
                                                double ratio = item.displayAspectRatio;
                                                if (ratio <= 0) ratio = 1.0;
                                                return ratio.clamp(0.5, 2.0);
                                              }).toList();

                                              final double aspectSum = ratios.fold(0.0, (sum, r) => sum + r);
                                              final double maxWidth = screenWidth - 24;

                                              List<double> widths = [];
                                              if (isLastRow) {
                                                for (final r in ratios) {
                                                  widths.add(height * r);
                                                }
                                                double totalWidth = widths.fold(0.0, (sum, w) => sum + w) + spacing * (rowItems.length - 1);
                                                if (totalWidth > maxWidth) {
                                                  double scale = (maxWidth - spacing * (rowItems.length - 1)) / (totalWidth - spacing * (rowItems.length - 1));
                                                  widths = widths.map((w) => w * scale).toList();
                                                }
                                              } else {
                                                double usableWidth = maxWidth - spacing * (rowItems.length - 1);
                                                for (final r in ratios) {
                                                  widths.add(usableWidth * (r / aspectSum));
                                                }
                                              }

                                              final bool isLastRowOfSection = (index + 1 >= flatItems.length) ||
                                                  (flatItems[index + 1] is _HeaderItem);
                                              final double sectionBottomSpacing = isLastRowOfSection ? 16.0 : 3.0;

                                              return Padding(
                                                padding: EdgeInsets.only(
                                                  left: 12,
                                                  right: 12,
                                                  bottom: sectionBottomSpacing,
                                                ),
                                                child: SizedBox(
                                                  height: height,
                                                  child: Row(
                                                    mainAxisAlignment: MainAxisAlignment.start,
                                                    children: [
                                                      for (int i = 0; i < rowItems.length; i++) ...[
                                                        if (i > 0) const SizedBox(width: spacing),
                                                        SizedBox(
                                                          width: widths[i],
                                                          height: height,
                                                          child: Builder(
                                                            builder: (itemCtx) {
                                                              final item = rowItems[i];
                                                              int burstCount = burstMap[BurstHelper.getBurstGroupKey(item) ?? ''] ?? 1;

                                                              return PhotoGridTile(
                                                                key: ValueKey(item.id),
                                                                item: item,
                                                                isSelected: _selected.contains(item.id),
                                                                isSelectionMode: _selectionMode,
                                                                isBurstRepresentative: burstCount > 1,
                                                                burstCount: burstCount,
                                                                borderRadius: 4.0,
                                                                onTap: () async {
                                                                  if (_selectionMode) {
                                                                    _toggleSelect(item.id);
                                                                  } else {
                                                                    await widget.onItemTapped(item, _items);
                                                                    _refreshAlbum();
                                                                  }
                                                                },
                                                                onLongPress: () {
                                                                  if (!_selectionMode) {
                                                                    HapticFeedback.lightImpact();
                                                                    setState(() {
                                                                      _selectionMode = true;
                                                                      _selected.add(item.id);
                                                                    });
                                                                  }
                                                                },
                                                                onContextReady: (ctx) => _itemContexts[item.id] = ctx,
                                                                topLeftBadge: Container(
                                                                  padding: const EdgeInsets.symmetric(
                                                                    horizontal: 6,
                                                                    vertical: 3,
                                                                  ),
                                                                  decoration: BoxDecoration(
                                                                    color: Colors.black.withValues(alpha: 0.65),
                                                                    borderRadius: BorderRadius.circular(6),
                                                                    border: Border.all(
                                                                      color: Colors.white24,
                                                                      width: 0.5,
                                                                    ),
                                                                  ),
                                                                  child: Text(
                                                                    _getDaysLeftText(item.deletedAt),
                                                                    style: const TextStyle(
                                                                      color: Colors.white,
                                                                      fontSize: 9,
                                                                      fontWeight: FontWeight.w600,
                                                                    ),
                                                                  ),
                                                                ),
                                                              );
                                                            },
                                                          ),
                                                        ),
                                                      ],
                                                    ],
                                                  ),
                                                ),
                                              );
                                            }
                                            return const SizedBox.shrink();
                                          },
                                        ),
                                        SliverToBoxAdapter(
                                          child: SizedBox(
                                            height: 16 + MediaQuery.of(context).padding.bottom,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                AnimatedOpacity(
                                  duration: const Duration(milliseconds: 200),
                                  opacity: _columnHudVisible ? 1.0 : 0.0,
                                  child: IgnorePointer(
                                    child: Align(
                                      alignment: const Alignment(0.0, -0.88),
                                      child: _ColumnHud(columns: _crossAxisCount),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                ],
              ),
              if (_selectionMode && _selected.isNotEmpty)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16 + MediaQuery.of(context).padding.bottom,
                  child: _buildFloatingSelectionBar(),
                ),
            ],
          ),
        ),
      );
    }

    final appBarColor = _isCollapsed ? bg : Colors.transparent;
    final appBarIconColor = (_isCollapsed && !_selectionMode)
        ? (isDark ? Colors.white : Colors.black87)
        : Colors.white;

    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_selectionMode) {
          setState(() {
            _selectionMode = false;
            _selected.clear();
          });
        }
      },
      child: Scaffold(
        backgroundColor: bg,
        body: Stack(
          children: [
            RefreshIndicator(
              onRefresh: _refreshAlbum,
              child: Listener(
                onPointerDown: (event) {
                  setState(() => _pointerCount++);
                  if (_selectionMode && _pointerCount == 1) {
                    final id = _getItemIdAtPosition(event.position);
                    if (id != null) {
                      _dragStartId = id;
                      _dragStartPosition = event.position;
                      _dragDirectionDecided = false;
                      _isDraggingToSelect = false;
                      _dragSelectInitialState = !_selected.contains(id);
                    }
                  }
                },
                onPointerMove: (event) {
                  if (_dragStartId != null && _pointerCount == 1) {
                    if (!_dragDirectionDecided && _dragStartPosition != null) {
                      final dx = event.position.dx - _dragStartPosition!.dx;
                      final dy = event.position.dy - _dragStartPosition!.dy;
                      if (dx.abs() > 10 || dy.abs() > 10) {
                        _dragDirectionDecided = true;
                        if (dx.abs() > dy.abs()) {
                          setState(() {
                            _isDraggingToSelect = true;
                          });
                        } else {
                          _isDraggingToSelect = false;
                        }
                      }
                    }

                    if (_isDraggingToSelect) {
                      _checkAutoScroll(event.position);
                      final id = _getItemIdAtPosition(event.position);
                      if (id != null) {
                        _updateDragSelection(id);
                      }
                    }
                  }
                },
                onPointerUp: (event) {
                  setState(() => _pointerCount = (_pointerCount - 1).clamp(0, 99));
                  _isDraggingToSelect = false;
                  _dragStartId = null;
                  _dragStartPosition = null;
                  _dragDirectionDecided = false;
                },
                onPointerCancel: (event) {
                  setState(() => _pointerCount = (_pointerCount - 1).clamp(0, 99));
                  _isDraggingToSelect = false;
                  _dragStartId = null;
                  _dragStartPosition = null;
                  _dragDirectionDecided = false;
                },
                child: GestureDetector(
                  onScaleStart: (d) {
                    if (_pointerCount >= 2 || d.pointerCount >= 2) {
                      _scaleStartColumns = _crossAxisCount.toDouble();
                      _captureAnchor(collapsedItems);
                      final activeItemId = _getItemIdAtPosition(d.focalPoint);
                      if (activeItemId != null) {
                        try {
                          final activeItem = _items.firstWhere((x) => x.id == activeItemId);
                          final ctx = _itemContexts[activeItemId];
                          if (ctx != null && ctx.mounted) {
                            final renderBox = ctx.findRenderObject() as RenderBox?;
                            if (renderBox != null && renderBox.hasSize) {
                              final startingSize = renderBox.size;
                              final startingPosition = renderBox.localToGlobal(Offset.zero);
                              _scaleNotifier = ValueNotifier<double>(1.0);
                              _activeOverlayEntry = OverlayEntry(
                                builder: (context) => GridScaleOverlay(
                                  item: activeItem,
                                  startingPosition: startingPosition,
                                  startingSize: startingSize,
                                  focalPoint: d.focalPoint,
                                  scaleNotifier: _scaleNotifier!,
                                ),
                              );
                              Overlay.of(context).insert(_activeOverlayEntry!);
                            }
                          }
                        } catch (e) {
                          debugPrint('Scale start error: $e');
                        }
                      }
                      _showHud();
                    }
                  },
                  onScaleUpdate: (d) {
                    if (_pointerCount < 2 && d.pointerCount < 2) return;
                    _scaleNotifier?.value = d.scale.clamp(0.5, 2.5);

                    int target = _scaleStartColumns.toInt();
                    if (d.scale > 1.0) {
                      final double steps = (d.scale - 1.0) / 0.18;
                      target = (_scaleStartColumns - steps.floor()).clamp(1, 6).toInt();
                    } else if (d.scale < 1.0) {
                      final double steps = (1.0 - d.scale) / 0.15;
                      target = (_scaleStartColumns + steps.floor()).clamp(1, 6).toInt();
                    }

                    if (target != _crossAxisCount) {
                      _captureAnchor(collapsedItems);
                      UIPreferenceProvider.instance.setGridColumns(target);
                      _pendingAnchorScroll = true;
                      _showHud();
                    }
                  },
                  onScaleEnd: (_) {
                    _activeOverlayEntry?.remove();
                    _activeOverlayEntry = null;
                    _scaleNotifier?.dispose();
                    _scaleNotifier = null;
                    _hideHudAfterDelay();
                    if (_pendingAnchorScroll) {
                      _restoreAnchor(collapsedItems, _crossAxisCount);
                    }
                  },
                  child: CustomScrollView(
                    controller: _scrollController,
                    physics: (_pointerCount >= 2 || _isDraggingToSelect)
                        ? const NeverScrollableScrollPhysics()
                        : const BouncingScrollPhysics(
                            parent: AlwaysScrollableScrollPhysics(),
                          ),
                    slivers: [
                      SliverAppBar(
                        expandedHeight: 320.0,
                        pinned: true,
                        backgroundColor: appBarColor,
                        elevation: 0,
                        leading: _selectionMode
                            ? IconButton(
                                icon: const Icon(
                                  Icons.close,
                                  color: Colors.white,
                                ),
                                onPressed: _cancelSelection,
                              )
                            : IconButton(
                                icon: Icon(
                                  Icons.arrow_back,
                                  color: appBarIconColor,
                                ),
                                onPressed: () => Navigator.pop(context),
                              ),
                        actions: _selectionMode
                            ? [
                                IconButton(
                                  icon: Icon(
                                    _selected.length == _items.length
                                        ? Icons.deselect_outlined
                                        : Icons.select_all,
                                    color: Colors.white,
                                  ),
                                  tooltip: _selected.length == _items.length
                                      ? 'Deselect All'
                                      : 'Select All',
                                  onPressed: () {
                                    setState(() {
                                      if (_selected.length == _items.length) {
                                        _selected.clear();
                                        _selectionMode = false;
                                      } else {
                                        _selected.addAll(_items.map((x) => x.id));
                                      }
                                    });
                                  },
                                ),
                              ]
                            : [
                                if (widget.isCustom)
                                  Theme(
                                    data: Theme.of(context).copyWith(
                                      cardColor: isDark
                                          ? const Color(0xFF1E1E24)
                                          : Colors.white,
                                    ),
                                    child: PopupMenuButton<String>(
                                      icon: Icon(
                                        Icons.more_vert,
                                        color: appBarIconColor,
                                      ),
                                      onSelected: (v) {
                                        if (v == 'rename') {
                                          _renameAlbum();
                                        } else if (v == 'add') {
                                          _addPhotosToAlbum();
                                        } else if (v == 'share') {
                                          _shareAlbum();
                                        }
                                      },
                                      itemBuilder: (_) => const [
                                        PopupMenuItem(
                                          value: 'rename',
                                          child: Text('Rename'),
                                        ),
                                        PopupMenuItem(
                                          value: 'add',
                                          child: Text('Add photos'),
                                        ),
                                        PopupMenuItem(
                                          value: 'share',
                                          child: Text('Share album'),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                        flexibleSpace: FlexibleSpaceBar(
                          stretchModes: const [StretchMode.zoomBackground],
                          background: Stack(
                            fit: StackFit.expand,
                            children: [
                              AlbumSlideshowBackground(items: _items),
                              Container(color: Colors.black.withValues(alpha: 0.2)),
                              Container(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      Colors.black.withValues(alpha: 0.0),
                                      Colors.black.withValues(alpha: 0.75),
                                    ],
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                  ),
                                ),
                              ),
                              Positioned(
                                left: 16,
                                bottom: 16,
                                right: 16,
                                child: AnimatedOpacity(
                                  opacity: _isCollapsed || _selectionMode ? 0.0 : 1.0,
                                  duration: const Duration(milliseconds: 200),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        _albumName,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 32,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: -0.5,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${_items.length} items',
                                        style: TextStyle(
                                          color: Colors.white.withValues(alpha: 0.75),
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        title: AnimatedOpacity(
                          opacity: _isCollapsed || _selectionMode ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 200),
                          child: Text(
                            _selectionMode ? '${_selected.length} selected' : _albumName,
                            style: TextStyle(
                              color: _selectionMode ? Colors.white : titleColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      if (_items.isEmpty)
                        SliverPadding(
                          padding: const EdgeInsets.only(top: 32),
                          sliver: SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.photo_library_outlined,
                                    size: 64,
                                    color: isDark ? Colors.white24 : Colors.black26,
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    'No items in this album',
                                    style: TextStyle(
                                      color: isDark ? Colors.white54 : Colors.black54,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        )
                      else ...[
                        SliverList.builder(
                          itemCount: flatItems.length,
                          itemBuilder: (context, index) {
                            final flatItem = flatItems[index];
                            if (flatItem is _HeaderItem) {
                              return Padding(
                                padding: const EdgeInsets.only(
                                  top: 14,
                                  left: 12,
                                  right: 12,
                                  bottom: 8,
                                ),
                                child: Text(
                                  flatItem.date,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: isDark ? Colors.white : Colors.black87,
                                    letterSpacing: -0.3,
                                  ),
                                ),
                              );
                            } else if (flatItem is _RowItem) {
                              final rowItems = flatItem.items;
                              final columns = flatItem.columns;

                              final double aspectRatio = flatItem.customAspectRatio ?? (
                                  columns <= 1
                                      ? 4 / 3
                                      : columns == 2
                                          ? 0.90
                                          : columns == 3
                                              ? 1.0
                                              : columns == 4
                                                  ? 1.15
                                                  : columns == 5
                                                      ? 1.25
                                                      : 1.0
                              );

                              final bool isLastRowOfSection = (index + 1 >= flatItems.length) ||
                                  (flatItems[index + 1] is _HeaderItem);
                              final double sectionBottomSpacing = isLastRowOfSection ? 16.0 : 3.0;

                              return Padding(
                                padding: EdgeInsets.only(
                                  left: 12,
                                  right: 12,
                                  bottom: sectionBottomSpacing,
                                ),
                                child: Row(
                                  children: List.generate(columns, (colIndex) {
                                    if (colIndex >= rowItems.length) {
                                      return const Expanded(child: SizedBox.shrink());
                                    }
                                    final item = rowItems[colIndex];

                                    int burstCount = burstMap[BurstHelper.getBurstGroupKey(item) ?? ''] ?? 1;

                                    return Expanded(
                                      child: Padding(
                                        padding: EdgeInsets.only(
                                          right: colIndex == columns - 1 ? 0 : 3,
                                        ),
                                        child: AspectRatio(
                                          aspectRatio: aspectRatio,
                                          child: PhotoGridTile(
                                            key: ValueKey(item.id),
                                            item: item,
                                            isSelected: _selected.contains(item.id),
                                            isSelectionMode: _selectionMode,
                                            isBurstRepresentative: burstCount > 1,
                                            burstCount: burstCount,
                                            borderRadius: columns >= 5 ? 6.0 : columns == 4 ? 8.0 : 10.0,
                                            onTap: () async {
                                              if (_selectionMode) {
                                                _toggleSelect(item.id);
                                              } else {
                                                await widget.onItemTapped(item, _items);
                                                _refreshAlbum();
                                              }
                                            },
                                            onLongPress: () {
                                              if (!_selectionMode) {
                                                HapticFeedback.lightImpact();
                                                setState(() {
                                                  _selectionMode = true;
                                                  _selected.add(item.id);
                                                });
                                              }
                                            },
                                            onContextReady: (ctx) => _itemContexts[item.id] = ctx,
                                            highlightItemId: _highlightItemId,
                                          ),
                                        ),
                                      ),
                                    );
                                  }),
                                ),
                              );
                            } else if (flatItem is _JustifiedRowItem) {
                              final rowItems = flatItem.items;
                              final height = flatItem.height;
                              final isLastRow = flatItem.isLastRow;

                              const double spacing = 3.0;

                              final List<double> ratios = rowItems.map((item) {
                                double ratio = item.displayAspectRatio;
                                if (ratio <= 0) ratio = 1.0;
                                return ratio.clamp(0.5, 2.0);
                              }).toList();

                              final double aspectSum = ratios.fold(0.0, (sum, r) => sum + r);
                              final double maxWidth = screenWidth - 24;

                              List<double> widths = [];
                              if (isLastRow) {
                                for (final r in ratios) {
                                  widths.add(height * r);
                                }
                                double totalWidth = widths.fold(0.0, (sum, w) => sum + w) + spacing * (rowItems.length - 1);
                                if (totalWidth > maxWidth) {
                                  double scale = (maxWidth - spacing * (rowItems.length - 1)) / (totalWidth - spacing * (rowItems.length - 1));
                                  widths = widths.map((w) => w * scale).toList();
                                }
                              } else {
                                double usableWidth = maxWidth - spacing * (rowItems.length - 1);
                                for (final r in ratios) {
                                  widths.add(usableWidth * (r / aspectSum));
                                }
                              }

                              final bool isLastRowOfSection = (index + 1 >= flatItems.length) ||
                                  (flatItems[index + 1] is _HeaderItem);
                              final double sectionBottomSpacing = isLastRowOfSection ? 16.0 : 3.0;

                              return Padding(
                                padding: EdgeInsets.only(
                                  left: 12,
                                  right: 12,
                                  bottom: sectionBottomSpacing,
                                ),
                                child: SizedBox(
                                  height: height,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.start,
                                    children: [
                                      for (int i = 0; i < rowItems.length; i++) ...[
                                        if (i > 0) const SizedBox(width: spacing),
                                        SizedBox(
                                          width: widths[i],
                                          height: height,
                                          child: Builder(
                                            builder: (itemCtx) {
                                              final item = rowItems[i];
                                              int burstCount = burstMap[BurstHelper.getBurstGroupKey(item) ?? ''] ?? 1;

                                              return PhotoGridTile(
                                                key: ValueKey(item.id),
                                                item: item,
                                                isSelected: _selected.contains(item.id),
                                                isSelectionMode: _selectionMode,
                                                isBurstRepresentative: burstCount > 1,
                                                burstCount: burstCount,
                                                borderRadius: 4.0,
                                                onTap: () async {
                                                  if (_selectionMode) {
                                                    _toggleSelect(item.id);
                                                  } else {
                                                    await widget.onItemTapped(item, _items);
                                                    _refreshAlbum();
                                                  }
                                                },
                                                onLongPress: () {
                                                  if (!_selectionMode) {
                                                    HapticFeedback.lightImpact();
                                                    setState(() {
                                                      _selectionMode = true;
                                                      _selected.add(item.id);
                                                    });
                                                  }
                                                },
                                                onContextReady: (ctx) => _itemContexts[item.id] = ctx,
                                                highlightItemId: _highlightItemId,
                                              );
                                            },
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              );
                            }
                            return const SizedBox.shrink();
                          },
                        ),
                        SliverToBoxAdapter(
                          child: SizedBox(
                            height: 16 + MediaQuery.of(context).padding.bottom,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _columnHudVisible ? 1.0 : 0.0,
              child: IgnorePointer(
                child: Align(
                  alignment: const Alignment(0.0, -0.88),
                  child: _ColumnHud(columns: _crossAxisCount),
                ),
              ),
            ),
            if (_selectionMode && _selected.isNotEmpty)
              Positioned(
                left: 16,
                right: 16,
                bottom: 16 + MediaQuery.of(context).padding.bottom,
                child: _buildFloatingSelectionBar(),
              ),
          ],
        ),
      ),
    );
  }

  void _secureSelectedItems() async {
    final List<GalleryItem> selectedItems = [];
    for (final id in _selected) {
      try {
        final item = _items.firstWhere((x) => x.id == id);
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
            _items.removeWhere((item) => _selected.contains(item.id));
            _selectionMode = false;
            _selected.clear();
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Media moved to Secure Vault.')),
          );
          _refreshAlbum();
          widget.onAlbumChanged?.call();
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
            if (widget.isRecentlyDeleted) ...[
              _buildSelectionActionItem(
                icon: Icons.restore,
                label: "Restore",
                onTap: _restoreSelected,
              ),
              _buildSelectionActionItem(
                icon: Icons.delete_forever,
                label: "Delete",
                onTap: _deletePermanentlySelected,
                color: Colors.redAccent,
              ),
            ] else ...[
              _buildSelectionActionItem(
                icon: widget.isCustom
                    ? Icons.playlist_remove
                    : Icons.delete_outline,
                label: widget.isCustom ? "Remove" : "Delete",
                onTap: widget.isCustom
                    ? _removeSelectedFromCustomAlbum
                    : _softDeleteSelected,
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
            ],
            if (!widget.isRecentlyDeleted) ...[
              _buildSelectionActionItem(
                icon: Icons.dashboard_customize_outlined,
                label: "Collage",
                onTap: _createCollageFromSelected,
              ),
            ],
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
    final selectedItems = _items
        .where((x) => _selected.contains(x.id))
        .toList();
    final localFiles = selectedItems
        .map((x) => File(x.imageUrl))
        .where((f) => f.existsSync())
        .map((f) => XFile(f.path))
        .toList();
    if (localFiles.isNotEmpty) {
      Share.shareXFiles(localFiles);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No local files available to share.')),
      );
    }
  }

  Future<void> _addSelectedItemsToAlbum() async {
    AddToAlbumDialog.show(
      context,
      _selected.toList(),
      onComplete: () {
        if (mounted) {
          setState(() {
            _selectionMode = false;
            _selected.clear();
          });
          _refreshAlbum();
          widget.onAlbumChanged?.call();
        }
      },
    );
  }

  void _createCollageFromSelected() async {
    final List<GalleryItem> items = [];
    for (final id in _selected) {
      try {
        final item = _items.firstWhere((x) => x.id == id);
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
        _selectionMode = false;
        _selected.clear();
      });
      await _refreshAlbum();
      widget.onAlbumChanged?.call();
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RecentlyDeletedScreen — shows soft-deleted items loaded from JSON
// ─────────────────────────────────────────────────────────────────────────────
class RecentlyDeletedScreen extends StatefulWidget {
  const RecentlyDeletedScreen({super.key});

  @override
  State<RecentlyDeletedScreen> createState() => _RecentlyDeletedScreenState();
}

class _RecentlyDeletedScreenState extends State<RecentlyDeletedScreen> {
  List<GalleryItem> _deletedItems = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/recently_deleted.json');
      if (await file.exists()) {
        final retentionDays = await TrashPersistence.getTrashRetentionDays();
        final cutoff = DateTime.now().subtract(Duration(days: retentionDays));
        final Map<String, dynamic> data = json.decode(
          await file.readAsString(),
        );
        final items = <GalleryItem>[];
        data.forEach((id, val) {
          final deletedAt = DateTime.tryParse(val['deletedAt'] ?? '');
          if (deletedAt != null && deletedAt.isAfter(cutoff)) {
            items.add(
              GalleryItem(
                id: id,
                imageUrl: val['path'] ?? '',
                date: val['date'] ?? '',
                dateTimestamp: 0,
                location: '',
                category: '',
                description: '',
                ghostComment: '',
                resolution: '',
                size: '',
                mediaType: val['mediaType'] ?? 'image',
                deletedAt: deletedAt,
              ),
            );
          }
        });
        setState(() => _deletedItems = items);
      }
    } catch (e) {
      debugPrint('load recently deleted error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return AlbumDetailScreen(
      albumName: 'Recently Deleted',
      items: _deletedItems,
      isRecentlyDeleted: true,
      onItemTapped: (item, [customList]) async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => PhotoViewerPage(
              item: item,
              allItems: customList ?? _deletedItems,
              ghostPersonality: 'Friendly',
              onDelete: (id) async {
                await _load();
              },
              isRecentlyDeleted: true,
            ),
          ),
        );
        _load();
      },
      onAlbumChanged: _load,
    );
  }
}

// Flat list models for AlbumDetailScreen
abstract class _FlatItem {}

class _HeaderItem extends _FlatItem {
  final String date;
  _HeaderItem(this.date);
}

class _RowItem extends _FlatItem {
  final String date;
  final List<GalleryItem> items;
  final int columns;
  final int rowIndex;
  final double? customAspectRatio;
  _RowItem(this.date, this.items, this.columns, this.rowIndex, {this.customAspectRatio});
}

class _JustifiedRowItem extends _FlatItem {
  final String date;
  final List<GalleryItem> items;
  final double height;
  final int rowIndex;
  final bool isLastRow;
  _JustifiedRowItem(this.date, this.items, this.height, this.rowIndex, {this.isLastRow = false});
}

class _ColumnHud extends StatelessWidget {
  final int columns;
  const _ColumnHud({required this.columns});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.black.withValues(alpha: 0.75)
            : Colors.white.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(
          color: isDark ? Colors.white12 : Colors.black12,
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(columns, (i) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white70 : Colors.black54,
                    shape: BoxShape.circle,
                  ),
                ),
              );
            }),
          ),
          const SizedBox(width: 10),
          Text(
            '$columns',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: isDark ? Colors.white : Colors.black87,
              letterSpacing: -0.3,
            ),
          ),
        ],
      ),
    );
  }
}
