import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/gallery_item.dart';

import '../../widgets/grid_scale_overlay.dart';
import '../../services/burst_helper.dart';
import './custom_scrollbar.dart';
import '../../services/ui_preference_provider.dart';
import '../../widgets/photo_grid.dart';

class PhotosTab extends StatefulWidget {
  final List<GalleryItem> allItems;
  final bool isSelectionMode;
  final List<String> selectedItemIds;
  final ScrollController scrollController;
  final Function(GalleryItem) onItemTapped;
  final Future<void> Function() onRefresh;
  final int Function(String) getColumnsForGroup;
  final void Function(List<String>)? onSelectionChanged;
  final void Function(GalleryItem)? onItemLongPressed;
  final VoidCallback? onImportPressed;

  const PhotosTab({
    super.key,
    required this.allItems,
    required this.isSelectionMode,
    required this.selectedItemIds,
    required this.scrollController,
    required this.onItemTapped,
    required this.onRefresh,
    required this.getColumnsForGroup,
    this.onSelectionChanged,
    this.onItemLongPressed,
    this.onImportPressed,
  });

  @override
  State<PhotosTab> createState() => _PhotosTabState();
}

class _PhotosTabState extends State<PhotosTab>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  // ── Pinch-zoom state ───────────────────────────────────────────────────
  OverlayEntry? _activeOverlayEntry;
  ValueNotifier<double>? _scaleNotifier;
  double _scaleStartColumns = 3.0;

  // Number of active touch pointers – ValueNotifier so pointer up/down
  // only rebuilds the CustomScrollView physics, not the entire widget tree.
  final ValueNotifier<int> _pointerCountNotifier = ValueNotifier<int>(0);

  // ── Column HUD state ────────────────────────────────────────────────────
  bool _columnHudVisible = false;
  Timer? _hudHideTimer;

  // ── Scroll-anchor state ─────────────────────────────────────────────────
  int _anchorItemIndex = 0;
  bool _pendingAnchorScroll = false;



  // ── Drag Selection state ────────────────────────────────────────────────
  final Map<String, BuildContext> _itemContexts = {};
  bool _isDraggingToSelect = false;
  String? _dragStartId;
  bool _dragSelectInitialState = true;
  Offset? _dragStartPosition;
  bool _dragDirectionDecided = false;

  // Caching computed media items to avoid O(n) rebuilding overhead
  List<GalleryItem> _cachedImageItems = [];
  Map<String, List<GalleryItem>> _cachedGroupedItems = {};
  List<String> _cachedSortedDates = [];
  /// Pre-computed burst counts: burstGroupKey → count. Eliminates O(n²)
  /// getBurstCount() calls inside itemBuilder.
  Map<String, int> _cachedBurstCountMap = {};



  @override
  void initState() {
    super.initState();

    _updateCachedItems();
    UIPreferenceProvider.instance.addListener(_handleUIPreferencesChange);
  }

  void _handleUIPreferencesChange() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(PhotosTab old) {
    super.didUpdateWidget(old);
    // Skip expensive recomputation when the list reference hasn't changed.
    if (!identical(old.allItems, widget.allItems)) {
      _updateCachedItems();
    }
  }

  void _updateCachedItems() {
    final rawCameraItems = widget.allItems.where((x) {
      if (x.mediaType != 'image' && x.mediaType != 'video') return false;
      return _isFromCameraFolder(x);
    }).toList();

    // Pre-compute burst count map from raw (pre-collapse) items.
    // This avoids O(n²) getBurstCount() calls inside itemBuilder.
    final burstMap = <String, int>{};
    for (final item in rawCameraItems) {
      final key = BurstHelper.getBurstGroupKey(item);
      if (key != null) burstMap[key] = (burstMap[key] ?? 0) + 1;
    }
    _cachedBurstCountMap = burstMap;

    final collapsed = BurstHelper.collapseBursts(rawCameraItems);
    collapsed.sort((a, b) {
      final tsA = a.modifiedTimestamp ?? a.dateTimestamp;
      final tsB = b.modifiedTimestamp ?? b.dateTimestamp;
      return tsB.compareTo(tsA);
    });
    _cachedImageItems = collapsed;

    final Map<String, List<GalleryItem>> grouped = {};
    for (final item in _cachedImageItems) {
      final dateLabel = _getDynamicDateLabel(item);
      grouped.putIfAbsent(dateLabel, () => []).add(item);
    }
    _cachedGroupedItems = grouped;
    _cachedSortedDates = grouped.keys.toList();
  }

  @override
  void dispose() {
    UIPreferenceProvider.instance.removeListener(_handleUIPreferencesChange);

    _hudHideTimer?.cancel();
    _pointerCountNotifier.dispose();
    super.dispose();
  }

  // ── Column HUD helpers ──────────────────────────────────────────────────

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

  // ── Scroll-anchor helpers ───────────────────────────────────────────────

  /// Capture which flat item index is currently closest to the viewport
  /// centre so we can restore it after a column change.
  void _captureAnchor(List<GalleryItem> imageItems) {
    try {
      final sc = widget.scrollController;
      if (!sc.hasClients) return;
      final viewportMidY = sc.offset + sc.position.viewportDimension / 2;
      // Walk contexts to find the item whose cell straddles viewportMidY
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

  /// After a column change, scroll so the previously-anchored item is
  /// visible near the viewport centre again.
  void _restoreAnchor(List<GalleryItem> imageItems, int columns) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pendingAnchorScroll = false;
      try {
        final sc = widget.scrollController;
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

  void _updateDragSelection(String currentId, List<GalleryItem> imageItems) {
    if (_dragStartId == null) return;
    final startIdx = imageItems.indexWhere((x) => x.id == _dragStartId);
    final endIdx = imageItems.indexWhere((x) => x.id == currentId);
    if (startIdx == -1 || endIdx == -1) return;

    final low = startIdx < endIdx ? startIdx : endIdx;
    final high = startIdx < endIdx ? endIdx : startIdx;

    final currentSelection = List<String>.from(widget.selectedItemIds);
    bool changed = false;

    for (int i = low; i <= high; i++) {
      final id = imageItems[i].id;
      if (_dragSelectInitialState) {
        if (!currentSelection.contains(id)) {
          currentSelection.add(id);
          changed = true;
        }
      } else {
        if (currentSelection.contains(id)) {
          currentSelection.remove(id);
          changed = true;
        }
      }
    }
    if (changed) {
      HapticFeedback.lightImpact();
      widget.onSelectionChanged?.call(currentSelection);
    }
  }

  // Helper to check if an item is from Camera folder based on file path
  bool _isFromCameraFolder(GalleryItem item) {
    final path = item.imageUrl.toLowerCase();
    if (path.isEmpty) return false;
    
    // Quick string matches for typical Camera path components (covers both / and \)
    if (path.contains('/dcim/') ||
        path.contains('/camera/') ||
        path.contains('/camera roll/') ||
        path.contains('/cameraroll/') ||
        path.contains('/camera-roll/') ||
        path.contains('\\dcim\\') ||
        path.contains('\\camera\\') ||
        path.contains('\\camera roll\\') ||
        path.contains('\\cameraroll\\') ||
        path.contains('\\camera-roll\\') ||
        item.albumCategory.toLowerCase() == 'camera' ||
        item.albumName.toLowerCase() == 'camera' ||
        item.id.toLowerCase().startsWith('imported')) {
      return true;
    }
    return false;
  }

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
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final weekdayStr = weekdays[dt.weekday - 1];
    final monthStr = months[dt.month - 1];

    if (dt.year == now.year) {
      return '$weekdayStr, ${dt.day} $monthStr';
    }
    return '$weekdayStr, ${dt.day} $monthStr, ${dt.year}';
  }

  List<_FlatItem> _buildFlatList(double screenWidth) {
    final List<_FlatItem> flat = [];
    final double maxWidth = screenWidth - 32; // 16 padding on each side
    const double spacing = 3.0;

    for (final dateStr in _cachedSortedDates) {
      final items = _cachedGroupedItems[dateStr] ?? [];
      if (items.isEmpty) continue;

      flat.add(_HeaderItem(dateStr, items.first.location));

      final columns = widget.getColumnsForGroup(dateStr);

      if (columns == 1) {
        // Hero layout: first is 1-col 4:3 banner, rest are 2-col square items
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
        // Justified layout
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
        // Standard multi-column grid
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
    super.build(context);
    final imageItems = _cachedImageItems;
    final groupedItems = _cachedGroupedItems;
    final sortedDates = _cachedSortedDates;

    final double screenWidth = MediaQuery.of(context).size.width;
    final List<_FlatItem> flatItems = _buildFlatList(screenWidth);

    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Listener(
                  onPointerDown: (event) {
                    _pointerCountNotifier.value++;
                    if (widget.isSelectionMode &&
                        _pointerCountNotifier.value == 1) {
                      final id = _getItemIdAtPosition(event.position);
                      if (id != null) {
                        _dragStartId = id;
                        _dragStartPosition = event.position;
                        _dragDirectionDecided = false;
                        _isDraggingToSelect = false;
                        _dragSelectInitialState =
                            !widget.selectedItemIds.contains(id);
                      }
                    }
                  },
                  onPointerMove: (event) {
                    if (_dragStartId != null &&
                        _pointerCountNotifier.value == 1) {
                      if (!_dragDirectionDecided &&
                          _dragStartPosition != null) {
                        final dx =
                            event.position.dx - _dragStartPosition!.dx;
                        final dy =
                            event.position.dy - _dragStartPosition!.dy;
                        if (dx.abs() > 10 || dy.abs() > 10) {
                          _dragDirectionDecided = true;
                          if (dx.abs() > dy.abs()) {
                            setState(() => _isDraggingToSelect = true);
                          } else {
                            _isDraggingToSelect = false;
                          }
                        }
                      }
                      if (_isDraggingToSelect) {
                        _checkAutoScroll(event.position);
                        final id = _getItemIdAtPosition(event.position);
                        if (id != null) {
                          _updateDragSelection(id, imageItems);
                        }
                      }
                    }
                  },
                  onPointerUp: (_) {
                    _pointerCountNotifier.value =
                        (_pointerCountNotifier.value - 1).clamp(0, 99);
                    _isDraggingToSelect = false;
                    _dragStartId = null;
                    _dragStartPosition = null;
                    _dragDirectionDecided = false;
                  },
                  onPointerCancel: (_) {
                    _pointerCountNotifier.value =
                        (_pointerCountNotifier.value - 1).clamp(0, 99);
                    _isDraggingToSelect = false;
                    _dragStartId = null;
                    _dragStartPosition = null;
                    _dragDirectionDecided = false;
                  },
                  child: GestureDetector(
                    onScaleStart: (d) {
                      if (_pointerCountNotifier.value >= 2 || d.pointerCount >= 2) {
                        _scaleStartColumns = UIPreferenceProvider
                            .instance.gridColumns
                            .toDouble();
                        _captureAnchor(imageItems);
                        final activeItemId =
                            _getItemIdAtPosition(d.focalPoint);
                        if (activeItemId != null) {
                          try {
                            final activeItem = widget.allItems.firstWhere(
                              (x) => x.id == activeItemId,
                            );
                            final ctx = _itemContexts[activeItemId];
                            if (ctx != null && ctx.mounted) {
                              final renderBox =
                                  ctx.findRenderObject() as RenderBox?;
                              if (renderBox != null && renderBox.hasSize) {
                                final startingSize = renderBox.size;
                                final startingPosition =
                                    renderBox.localToGlobal(Offset.zero);
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
                                Overlay.of(context)
                                    .insert(_activeOverlayEntry!);
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
                      if (_pointerCountNotifier.value < 2 && d.pointerCount < 2) return;
                      _scaleNotifier?.value = d.scale.clamp(0.5, 2.5);
                      
                      // Calculate dynamic, responsive target column count based on scaling steps
                      int target = _scaleStartColumns.toInt();
                      if (d.scale > 1.0) {
                        // Pinching out (zooming in, decreasing columns)
                        // Trigger step is roughly 18% change
                        final double steps = (d.scale - 1.0) / 0.18;
                        target = (_scaleStartColumns - steps.floor()).clamp(1, 6).toInt();
                      } else if (d.scale < 1.0) {
                        // Pinching in (zooming out, increasing columns)
                        // Trigger step is roughly 15% change
                        final double steps = (1.0 - d.scale) / 0.15;
                        target = (_scaleStartColumns + steps.floor()).clamp(1, 6).toInt();
                      }

                      if (target !=
                          UIPreferenceProvider.instance.gridColumns) {
                        _captureAnchor(imageItems);
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
                        _restoreAnchor(imageItems,
                            UIPreferenceProvider.instance.gridColumns);
                      }
                    },
                    // SliverGrid only builds tiles in the viewport — no shrinkWrap.
                    // Physics are always scrollable; pinch-zoom is handled by
                    // the ancestor GestureDetector which wins gesture arbitration.
                    child: CustomScrollView(
                      controller: widget.scrollController,
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics(),
                      ),
                      slivers: [
                        if (_cachedSortedDates.isEmpty)
                          SliverFillRemaining(
                            child: Center(
                              child: Text(
                                "Your Camera Roll is empty 👻\nTake some photos!",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: 0.5),
                                ),
                              ),
                            ),
                          )
                        else
                          SliverList.builder(
                            itemCount: flatItems.length,
                            itemBuilder: (context, index) {
                              final flatItem = flatItems[index];
                              if (flatItem is _HeaderItem) {
                                return Padding(
                                  padding: EdgeInsets.only(
                                    top: flatItem.date == _cachedSortedDates.first ? 16 : 8,
                                    left: 16,
                                    right: 16,
                                    bottom: 0,
                                  ),
                                  child: _buildSectionHeader(
                                    flatItem.date,
                                    flatItem.location,
                                  ),
                                );
                              } else if (flatItem is _RowItem) {
                                final rowItems = flatItem.items;
                                final columns = flatItem.columns;
                                
                                final double aspectRatio = flatItem.customAspectRatio ?? (
                                    columns == 1
                                        ? 4 / 3
                                        : columns == 2
                                            ? 0.90
                                            : columns == 3
                                                ? 1.0
                                                : columns == 4
                                                    ? 1.15
                                                    : columns == 5
                                                        ? 1.30
                                                        : 1.45 // 6 columns
                                );

                                // Determine bottom spacing for the row based on its group ending structure
                                final bool isLastRowOfSection = (index + 1 >= flatItems.length) ||
                                    (flatItems[index + 1] is _HeaderItem);
                                final double sectionBottomSpacing = isLastRowOfSection
                                    ? (flatItem.date == _cachedSortedDates.last ? 24.0 : 16.0)
                                    : 3.0;

                                return Padding(
                                  padding: EdgeInsets.only(
                                    left: 16,
                                    right: 16,
                                    bottom: sectionBottomSpacing,
                                  ),
                                  child: Row(
                                    children: List.generate(columns, (colIndex) {
                                      if (colIndex >= rowItems.length) {
                                        return const Expanded(child: SizedBox.shrink());
                                      }
                                      final item = rowItems[colIndex];

                                      int burstCount = 1;
                                      final key = BurstHelper.getBurstGroupKey(item);
                                      if (key != null) {
                                        burstCount = _cachedBurstCountMap[key] ?? 1;
                                      }

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
                                              isSelected: widget.selectedItemIds.contains(item.id),
                                              isSelectionMode: widget.isSelectionMode,
                                              isBurstRepresentative: burstCount > 1,
                                              burstCount: burstCount,
                                              borderRadius: columns >= 5 ? 6.0 : columns == 4 ? 8.0 : 10.0,
                                              onTap: () => widget.onItemTapped(item),
                                              onLongPress: () => widget.onItemLongPressed?.call(item),
                                              onContextReady: (ctx) => _itemContexts[item.id] = ctx,
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

                                // Calculate widths proportionally based on aspect ratios
                                final List<double> ratios = rowItems.map((item) {
                                  double ratio = item.displayAspectRatio;
                                  if (ratio <= 0) ratio = 1.0;
                                  return ratio.clamp(0.5, 2.0);
                                }).toList();

                                final double aspectSum = ratios.fold(0.0, (sum, r) => sum + r);
                                final double maxWidth = screenWidth - 32;

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

                                // Determine bottom spacing for the row based on its group ending structure
                                final bool isLastRowOfSection = (index + 1 >= flatItems.length) ||
                                    (flatItems[index + 1] is _HeaderItem);
                                final double sectionBottomSpacing = isLastRowOfSection
                                    ? (flatItem.date == _cachedSortedDates.last ? 24.0 : 16.0)
                                    : 3.0;

                                return Padding(
                                  padding: EdgeInsets.only(
                                    left: 16,
                                    right: 16,
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
                                                int burstCount = 1;
                                                final key = BurstHelper.getBurstGroupKey(item);
                                                if (key != null) {
                                                  burstCount = _cachedBurstCountMap[key] ?? 1;
                                                }

                                                return PhotoGridTile(
                                                  key: ValueKey(item.id),
                                                  item: item,
                                                  isSelected: widget.selectedItemIds.contains(item.id),
                                                  isSelectionMode: widget.isSelectionMode,
                                                  isBurstRepresentative: burstCount > 1,
                                                  burstCount: burstCount,
                                                  borderRadius: 4.0,
                                                  onTap: () => widget.onItemTapped(item),
                                                  onLongPress: () => widget.onItemLongPressed?.call(item),
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
                        const SliverToBoxAdapter(child: SizedBox(height: 16)),
                      ],
                    ),
                  ),
                ),
                if (imageItems.isNotEmpty)
                  CustomScrollbar(
                    scrollController: widget.scrollController,
                    getColumnsForGroup: widget.getColumnsForGroup,
                    groupedItems: groupedItems,
                    sortedDates: sortedDates,
                  ),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: _columnHudVisible ? 1.0 : 0.0,
                  child: IgnorePointer(
                    child: Align(
                      alignment: const Alignment(0.0, -0.88),
                      child: _ColumnHud(
                        columns: UIPreferenceProvider.instance.gridColumns,
                      ),
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

  Widget _buildSectionHeader(String title, String? subtitle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
          if (subtitle != null && subtitle.isNotEmpty) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                subtitle,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}




// ─────────────────────────────────────────────────────────────────────────────
/// Column count HUD pill — shown during pinch-to-resize.
// ─────────────────────────────────────────────────────────────────────────────
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
          // Dot indicators
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

// ─────────────────────────────────────────────────────────────────────────────
// Flat list data models for single-sliver rendering
// ─────────────────────────────────────────────────────────────────────────────
abstract class _FlatItem {}

class _HeaderItem extends _FlatItem {
  final String date;
  final String? location;
  _HeaderItem(this.date, this.location);
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



