import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:ui' show ImageFilter;
import 'dart:math';
import 'package:flutter/material.dart';
import '../widgets/premium_gate.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../models/gallery_item.dart';
import 'photo_viewer_screen.dart';
import './tabs/fast_media_preview.dart';
import 'collage_creator_screen.dart';
import '../widgets/album_slideshow_background.dart';
import '../services/trash_persistence.dart';
import '../services/media_permission_service.dart';
import '../widgets/grid_scale_overlay.dart';
import '../services/ui_preference_provider.dart';
import 'package:ghost_gallery/widgets/add_to_album_dialog.dart';
import '../widgets/photo_grid.dart';
import '../services/burst_helper.dart';

import '../services/entitlement_service.dart';
import '../services/responsive_helper.dart';

class TagPhotosScreen extends StatefulWidget {
  final String tagName;
  final List<GalleryItem> items;

  const TagPhotosScreen({
    super.key,
    required this.tagName,
    required this.items,
  });

  @override
  State<TagPhotosScreen> createState() => _TagPhotosScreenState();
}

class _TagPhotosScreenState extends State<TagPhotosScreen> {
  bool _isSelectionMode = false;
  final Set<String> _selectedItemIds = {};
  late List<GalleryItem> _screenItems;
  final ScrollController _scrollController = ScrollController();
  bool _isCollapsed = false;

  bool _columnHudVisible = false;
  Timer? _hudHideTimer;
  int _anchorItemIndex = 0;
  bool _pendingAnchorScroll = false;
  int _gridColumns = 3;
  double _scaleStartColumns = 3.0;
  int _pointerCount = 0;
  OverlayEntry? _activeOverlayEntry;
  ValueNotifier<double>? _scaleNotifier;
  final Map<String, BuildContext> _itemContexts = {};
  bool _isDraggingToSelect = false;
  String? _dragStartId;
  bool _dragSelectInitialState = true;
  Offset? _dragStartPosition;
  bool _dragDirectionDecided = false;

  void _scrollListener() {
    if (_scrollController.hasClients) {
      final double offset = _scrollController.offset;
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
    _screenItems = widget.items.toList();
    _sortItems();
    _scrollController.addListener(_scrollListener);
    _gridColumns = UIPreferenceProvider.instance.gridColumns;
    _scaleStartColumns = _gridColumns.toDouble();
    UIPreferenceProvider.instance.addListener(_handleUIPreferencesChange);

  }

  void _handleUIPreferencesChange() {
    if (mounted) {
      setState(() {
        _gridColumns = UIPreferenceProvider.instance.gridColumns;
      });
    }
  }

  @override
  void dispose() {
    UIPreferenceProvider.instance.removeListener(_handleUIPreferencesChange);
    _scrollController.removeListener(_scrollListener);
    _scrollController.dispose();
    super.dispose();
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
    final startIdx = _screenItems.indexWhere((x) => x.id == _dragStartId);
    final endIdx = _screenItems.indexWhere((x) => x.id == currentId);
    if (startIdx == -1 || endIdx == -1) return;

    final low = min(startIdx, endIdx);
    final high = max(startIdx, endIdx);

    bool changed = false;
    setState(() {
      for (int i = low; i <= high; i++) {
        final id = _screenItems[i].id;
        if (_dragSelectInitialState) {
          if (!_selectedItemIds.contains(id)) {
            _selectedItemIds.add(id);
            changed = true;
          }
        } else {
          if (_selectedItemIds.contains(id)) {
            _selectedItemIds.remove(id);
            changed = true;
          }
        }
      }
      if (_selectedItemIds.isEmpty) _isSelectionMode = false;
    });

    if (changed) {
      HapticFeedback.lightImpact();
    }
  }

  void _sortItems() {
    _screenItems.sort((a, b) {
      final tsA = a.modifiedTimestamp ?? a.dateTimestamp;
      final tsB = b.modifiedTimestamp ?? b.dateTimestamp;
      return tsB.compareTo(tsA);
    });
  }

  @override
  void didUpdateWidget(covariant TagPhotosScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.items != oldWidget.items) {
      setState(() {
        _screenItems = widget.items.toList();
        _sortItems();
      });
    }
  }

  void _shareSelectedItems() {
    final List<XFile> filesToShare = [];
    for (final id in _selectedItemIds) {
      try {
        final item = _screenItems.firstWhere((x) => x.id == id);
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
        final item = _screenItems.firstWhere((x) => x.id == id);
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
      _screenItems.removeWhere((item) => _selectedItemIds.contains(item.id));
      _isSelectionMode = false;
      _selectedItemIds.clear();
    });

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
                      setState(() {
                        for (final item in itemsToDelete) {
                          if (!_screenItems.any((x) => x.id == item.id)) {
                            _screenItems.add(item);
                          }
                        }
                      });
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
        }
      },
    );
  }

  void _createCollageFromSelected() async {
    final List<GalleryItem> items = [];
    for (final id in _selectedItemIds) {
      try {
        final item = _screenItems.firstWhere((x) => x.id == id);
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
    }
  }

  void _secureSelectedItems() async {
    final List<GalleryItem> selectedItems = [];
    for (final id in _selectedItemIds) {
      try {
        final item = _screenItems.firstWhere((x) => x.id == id);
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
            _screenItems.removeWhere(
              (item) => _selectedItemIds.contains(item.id),
            );
            _isSelectionMode = false;
            _selectedItemIds.clear();
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Media moved to Secure Vault.')),
          );
        }
      },
    );
  }

  Widget _buildFloatingSelectionBar() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark
        ? const Color(0xFF1E1E24).withValues(alpha: 0.9)
        : Colors.white.withValues(alpha: 0.9);
    final borderColor = isDark ? Colors.white10 : Colors.black12;

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
              color: Colors.black.withValues(alpha: 0.15),
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
    final activeColor =
        color ??
        (Theme.of(context).brightness == Brightness.dark
            ? Colors.white
            : Colors.black87);
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

  @override
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
        baseColumns: _gridColumns,
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
    final textColor = isDark ? Colors.white : Colors.black87;
    final subTextColor = isDark ? Colors.white60 : Colors.black54;
    final appBarColor = _isCollapsed ? bg : Colors.transparent;
    final appBarIconColor = (_isCollapsed && !_isSelectionMode)
        ? (isDark ? Colors.white : Colors.black87)
        : Colors.white;

    String getDynamicDateLabel(GalleryItem item) {
      final ts = item.modifiedTimestamp ?? item.dateTimestamp;
      if (ts == 0) return item.date;
      final dt = DateTime.fromMillisecondsSinceEpoch(ts);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final yesterday = today.subtract(const Duration(days: 1));
      final itemDay = DateTime(dt.year, dt.month, dt.day);

      if (itemDay == today) return 'Today';
      if (itemDay == yesterday) return 'Yesterday';

      const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
      if (dt.year == now.year) {
        return '${months[dt.month - 1]} ${dt.day}';
      }
      return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
    }

    final Map<String, List<GalleryItem>> groupedItems = {};
    for (final item in _screenItems) {
      final label = getDynamicDateLabel(item);
      groupedItems.putIfAbsent(label, () => []).add(item);
    }
    final sortedDates = groupedItems.keys.toList();

    final burstMap = <String, int>{};
    for (final item in _screenItems) {
      final key = BurstHelper.getBurstGroupKey(item);
      if (key != null) {
        burstMap[key] = (burstMap[key] ?? 0) + 1;
      }
    }

    final double screenWidth = MediaQuery.of(context).size.width;
    final List<_FlatItem> flatItems = _buildFlatList(screenWidth, sortedDates, groupedItems);

    return PopScope(
      canPop: !_isSelectionMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_isSelectionMode) {
          setState(() {
            _isSelectionMode = false;
            _selectedItemIds.clear();
          });
        }
      },
      child: Scaffold(
        backgroundColor: bg,
        body: Stack(
          children: [
            RefreshIndicator(
              onRefresh: () async {
                setState(() {});
              },
              child: Listener(
                onPointerDown: (event) {
                  setState(() => _pointerCount++);
                  if (_isSelectionMode && _pointerCount == 1) {
                    final id = _getItemIdAtPosition(event.position);
                    if (id != null) {
                      _dragStartId = id;
                      _dragStartPosition = event.position;
                      _dragDirectionDecided = false;
                      _isDraggingToSelect = false;
                      _dragSelectInitialState = !_selectedItemIds.contains(id);
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
                  setState(
                    () => _pointerCount = (_pointerCount - 1).clamp(0, 99),
                  );
                  _isDraggingToSelect = false;
                  _dragStartId = null;
                  _dragStartPosition = null;
                  _dragDirectionDecided = false;
                },
                onPointerCancel: (event) {
                  setState(
                    () => _pointerCount = (_pointerCount - 1).clamp(0, 99),
                  );
                  _isDraggingToSelect = false;
                  _dragStartId = null;
                  _dragStartPosition = null;
                  _dragDirectionDecided = false;
                },
                child: GestureDetector(
                  onScaleStart: (details) {
                    if (_pointerCount >= 2 || details.pointerCount >= 2) {
                      _scaleStartColumns = _gridColumns.toDouble();
                      _captureAnchor(_screenItems);
                      final activeItemId = _getItemIdAtPosition(details.focalPoint);
                      if (activeItemId != null) {
                        try {
                          final activeItem = _screenItems.firstWhere(
                            (x) => x.id == activeItemId,
                          );
                          final ctx = _itemContexts[activeItemId];
                          if (ctx != null && ctx.mounted) {
                            final renderBox =
                                ctx.findRenderObject() as RenderBox?;
                            if (renderBox != null && renderBox.hasSize) {
                              final startingSize = renderBox.size;
                              final startingPosition = renderBox.localToGlobal(
                                Offset.zero,
                              );
                              _scaleNotifier = ValueNotifier<double>(1.0);
                              _activeOverlayEntry = OverlayEntry(
                                builder: (context) => GridScaleOverlay(
                                  item: activeItem,
                                  startingPosition: startingPosition,
                                  startingSize: startingSize,
                                  focalPoint: details.focalPoint,
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
                  onScaleUpdate: (details) {
                    if (_pointerCount < 2 && details.pointerCount < 2) return;
                    _scaleNotifier?.value = details.scale.clamp(0.5, 2.5);

                    int target = _scaleStartColumns.toInt();
                    if (details.scale > 1.0) {
                      final double steps = (details.scale - 1.0) / 0.18;
                      target = (_scaleStartColumns - steps.floor()).clamp(1, 6).toInt();
                    } else if (details.scale < 1.0) {
                      final double steps = (1.0 - details.scale) / 0.15;
                      target = (_scaleStartColumns + steps.floor()).clamp(1, 6).toInt();
                    }

                    if (target != _gridColumns) {
                      _captureAnchor(_screenItems);
                      UIPreferenceProvider.instance.setGridColumns(target);
                      _pendingAnchorScroll = true;
                      _showHud();
                    }
                  },
                  onScaleEnd: (details) {
                    _activeOverlayEntry?.remove();
                    _activeOverlayEntry = null;
                    _scaleNotifier?.dispose();
                    _scaleNotifier = null;
                    _hideHudAfterDelay();
                    if (_pendingAnchorScroll) {
                      _restoreAnchor(_screenItems, _gridColumns);
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
                        leading: _isSelectionMode
                            ? IconButton(
                                icon: Icon(
                                  Icons.close,
                                  color: Colors.white,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _isSelectionMode = false;
                                    _selectedItemIds.clear();
                                  });
                                },
                              )
                            : IconButton(
                                icon: Icon(
                                  Icons.arrow_back,
                                  color: appBarIconColor,
                                ),
                                onPressed: () => Navigator.pop(context),
                              ),
                        actions: _isSelectionMode
                            ? [
                                IconButton(
                                  icon: Icon(
                                    _selectedItemIds.length == _screenItems.length
                                        ? Icons.deselect_outlined
                                        : Icons.select_all,
                                    color: Colors.white,
                                  ),
                                  tooltip: _selectedItemIds.length == _screenItems.length
                                      ? 'Deselect All'
                                      : 'Select All',
                                  onPressed: () {
                                    setState(() {
                                      if (_selectedItemIds.length == _screenItems.length) {
                                        _selectedItemIds.clear();
                                        _isSelectionMode = false;
                                      } else {
                                        _selectedItemIds.addAll(_screenItems.map((x) => x.id));
                                      }
                                    });
                                  },
                                ),
                              ]
                            : [],
                        flexibleSpace: FlexibleSpaceBar(
                          stretchModes: const [StretchMode.zoomBackground],
                          background: Stack(
                            fit: StackFit.expand,
                            children: [
                              AlbumSlideshowBackground(items: _screenItems),
                              Container(
                                color: Colors.black.withValues(alpha: 0.2),
                              ),
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
                                left: 20,
                                bottom: 20,
                                right: 20,
                                child: AnimatedOpacity(
                                  opacity: _isCollapsed || _isSelectionMode ? 0.0 : 1.0,
                                  duration: const Duration(milliseconds: 200),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        "#${widget.tagName}",
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 32,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: -0.5,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${_screenItems.length} items',
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
                          opacity: _isCollapsed || _isSelectionMode ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 200),
                          child: Text(
                            _isSelectionMode ? '${_selectedItemIds.length} selected' : "#${widget.tagName}",
                            style: TextStyle(
                              color: _isSelectionMode ? Colors.white : textColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      if (_screenItems.isEmpty)
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
                                    'No items in this tag',
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
                                          child: PremiumGate(
                                            borderRadius: BorderRadius.circular(columns >= 5 ? 6.0 : columns == 4 ? 8.0 : 10.0),
                                            child: PhotoGridTile(
                                              key: ValueKey(item.id),
                                              item: item,
                                              isSelected: _selectedItemIds.contains(item.id),
                                              isSelectionMode: _isSelectionMode,
                                              isBurstRepresentative: burstCount > 1,
                                              burstCount: burstCount,
                                              borderRadius: columns >= 5 ? 6.0 : columns == 4 ? 8.0 : 10.0,
                                              onTap: () async {
                                                if (_isSelectionMode) {
                                                  HapticFeedback.lightImpact();
                                                  setState(() {
                                                    if (_selectedItemIds.contains(item.id)) {
                                                      _selectedItemIds.remove(item.id);
                                                      if (_selectedItemIds.isEmpty) {
                                                        _isSelectionMode = false;
                                                      }
                                                    } else {
                                                      _selectedItemIds.add(item.id);
                                                    }
                                                  });
                                                } else {
                                                  await Navigator.push(
                                                    context,
                                                    MaterialPageRoute(
                                                      builder: (context) => PhotoViewerPage(
                                                        item: item,
                                                        allItems: _screenItems,
                                                        ghostPersonality: "Sassy",
                                                        onDelete: (id) async {
                                                          if (id.isEmpty) {
                                                            setState(() {});
                                                            return;
                                                          }
                                                          setState(() {
                                                            _screenItems.removeWhere(
                                                              (x) => x.id == id,
                                                            );
                                                          });
                                                        },
                                                      ),
                                                    ),
                                                  );
                                                }
                                              },
                                              onLongPress: () {
                                                if (!_isSelectionMode) {
                                                  HapticFeedback.lightImpact();
                                                  setState(() {
                                                    _isSelectionMode = true;
                                                    _selectedItemIds.add(item.id);
                                                  });
                                                }
                                              },
                                              onContextReady: (ctx) => _itemContexts[item.id] = ctx,
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
                                                isSelected: _selectedItemIds.contains(item.id),
                                                isSelectionMode: _isSelectionMode,
                                                isBurstRepresentative: burstCount > 1,
                                                burstCount: burstCount,
                                                borderRadius: 4.0,
                                                onTap: () async {
                                                  if (_isSelectionMode) {
                                                    HapticFeedback.lightImpact();
                                                    setState(() {
                                                      if (_selectedItemIds.contains(item.id)) {
                                                        _selectedItemIds.remove(item.id);
                                                        if (_selectedItemIds.isEmpty) {
                                                          _isSelectionMode = false;
                                                        }
                                                      } else {
                                                        _selectedItemIds.add(item.id);
                                                      }
                                                    });
                                                  } else {
                                                    await Navigator.push(
                                                      context,
                                                      MaterialPageRoute(
                                                        builder: (context) => PhotoViewerPage(
                                                          item: item,
                                                          allItems: _screenItems,
                                                          ghostPersonality: "Sassy",
                                                          onDelete: (id) async {
                                                            if (id.isEmpty) {
                                                              setState(() {});
                                                              return;
                                                            }
                                                            setState(() {
                                                              _screenItems.removeWhere(
                                                                (x) => x.id == id,
                                                              );
                                                            });
                                                          },
                                                        ),
                                                      ),
                                                    );
                                                  }
                                                },
                                                onLongPress: () {
                                                  if (!_isSelectionMode) {
                                                    HapticFeedback.lightImpact();
                                                    setState(() {
                                                      _isSelectionMode = true;
                                                      _selectedItemIds.add(item.id);
                                                    });
                                                  }
                                                },
                                                onContextReady: (ctx) => _itemContexts[item.id] = ctx,
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
                  child: _ColumnHud(columns: _gridColumns),
                ),
              ),
            ),
            if (_isSelectionMode && _selectedItemIds.isNotEmpty)
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
}

// Flat list models for TagPhotosScreen
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
