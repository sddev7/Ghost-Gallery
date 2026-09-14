import 'package:flutter/material.dart';
import '../models/gallery_item.dart';
import '../services/burst_helper.dart';
import '../screens/tabs/fast_media_preview.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Reusable photo grid – used by PhotosTab, album detail screen, search tab, tags, and people.
// ─────────────────────────────────────────────────────────────────────────────
class PhotoGrid extends StatelessWidget {
  final List<GalleryItem> items;
  final List<GalleryItem> allItems;
  final int columns;
  final bool isSelectionMode;
  final List<String> selectedItemIds;
  final Function(GalleryItem) onItemTapped;
  final void Function(GalleryItem)? onItemLongPressed;
  final Map<String, BuildContext> itemContexts;
  final String? highlightItemId;
  /// Pre-computed burst counts keyed by getBurstGroupKey(). When provided,
  /// avoids the O(n²) per-tile getBurstCount() scan.
  final Map<String, int>? burstCountMap;

  const PhotoGrid({
    super.key,
    required this.items,
    required this.allItems,
    required this.columns,
    required this.isSelectionMode,
    required this.selectedItemIds,
    required this.onItemTapped,
    this.onItemLongPressed,
    required this.itemContexts,
    this.highlightItemId,
    this.burstCountMap,
  });

  @override
  Widget build(BuildContext context) {
    // ── 1-column hero layout ─────────────────────────────────────────────
    if (columns == 1) {
      return _buildHeroLayout(context);
    }

    // ── 3-column justified layout ────────────────────────────────────────
    if (columns == 3) {
      return _buildJustifiedLayout(context);
    }

    // ── Standard multi-column grid ───────────────────────────────────────
    final double aspectRatio = columns <= 1
        ? 4 / 3
        : columns == 2
            ? 0.90
            : columns == 3
                ? 1.0
                : columns == 4
                    ? 1.15
                    : columns == 5
                        ? 1.25
                        : 1.0; // 6+ columns on tablet and TV

    // FadeTransition only — ScaleTransition causes simultaneous scale animations
    // across all date groups when columns change, spiking GPU work.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: child,
      ),
      child: GridView.builder(
        key: ValueKey<int>(columns),
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: 3,
          mainAxisSpacing: 3,
          childAspectRatio: aspectRatio,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          final burstCount = _getBurstCount(item);
          return PhotoGridTile(
            key: ValueKey(item.id),
            item: item,
            isSelected: selectedItemIds.contains(item.id),
            isSelectionMode: isSelectionMode,
            isBurstRepresentative: burstCount > 1,
            burstCount: burstCount,
            borderRadius: columns >= 5 ? 6.0 : columns == 4 ? 8.0 : 10.0,
            onTap: () => onItemTapped(item),
            onLongPress: () => onItemLongPressed?.call(item),
            onContextReady: (ctx) => itemContexts[item.id] = ctx,
            highlightItemId: highlightItemId,
          );
        },
      ),
    );
  }

  /// Returns burst count using the pre-computed map when available,
  /// falling back to the O(n) scan only for screens that don't provide a map.
  int _getBurstCount(GalleryItem item) {
    if (burstCountMap != null) {
      final key = BurstHelper.getBurstGroupKey(item);
      if (key == null) return 1;
      return burstCountMap![key] ?? 1;
    }
    return BurstHelper.getBurstCount(item, allItems);
  }

  /// Returns a [SliverGrid] for use inside [CustomScrollView].
  /// This avoids shrinkWrap:true which forces full layout of all children
  /// even when off-screen, causing scroll jank.
  static Widget buildAsSliver({
    required List<GalleryItem> items,
    required int columns,
    required bool isSelectionMode,
    required List<String> selectedItemIds,
    required Function(GalleryItem) onItemTapped,
    void Function(GalleryItem)? onItemLongPressed,
    required Map<String, BuildContext> itemContexts,
    Map<String, int>? burstCountMap,
    List<GalleryItem> allItems = const [],
    String? highlightItemId,
  }) {
    final double aspectRatio = columns <= 1
        ? 4 / 3
        : columns == 2
            ? 0.90
            : columns == 3
                ? 1.0
                : columns == 4
                    ? 1.15
                    : columns == 5
                        ? 1.25
                        : 1.0;

    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns < 1 ? 1 : columns,
        crossAxisSpacing: 3,
        mainAxisSpacing: 3,
        childAspectRatio: aspectRatio,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final item = items[index];
          int burstCount = 1;
          if (burstCountMap != null) {
            final key = BurstHelper.getBurstGroupKey(item);
            burstCount = key != null ? (burstCountMap[key] ?? 1) : 1;
          } else {
            burstCount = BurstHelper.getBurstCount(item, allItems);
          }
          return PhotoGridTile(
            key: ValueKey(item.id),
            item: item,
            isSelected: selectedItemIds.contains(item.id),
            isSelectionMode: isSelectionMode,
            isBurstRepresentative: burstCount > 1,
            burstCount: burstCount,
            borderRadius: columns >= 5 ? 6.0 : columns == 4 ? 8.0 : 10.0,
            onTap: () => onItemTapped(item),
            onLongPress: () => onItemLongPressed?.call(item),
            onContextReady: (ctx) => itemContexts[item.id] = ctx,
            highlightItemId: highlightItemId,
          );
        },
        childCount: items.length,
        addRepaintBoundaries: true,   // each tile gets its own layer
        addAutomaticKeepAlives: false, // we don't need tile keep-alive
      ),
    );
  }

  /// 3-column dynamic justified layout.
  /// Formats images horizontally into rows of equal height, adjusting widths
  /// proportionally based on aspect ratios, matching premium gallery layouts.
  Widget _buildJustifiedLayout(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        const double spacing = 3.0;
        final double maxWidth = constraints.maxWidth;
        // targetHeight is determined by active columns count
        final double targetHeight = maxWidth / columns;

        final List<List<GalleryItem>> rows = [];
        final List<double> rowHeights = [];

        List<GalleryItem> currentRow = [];
        double currentAspectRatioSum = 0.0;

        for (final item in items) {
          double ratio = item.displayAspectRatio;
          if (ratio <= 0) ratio = 1.0;
          ratio = ratio.clamp(0.5, 2.0);

          currentRow.add(item);
          currentAspectRatioSum += ratio;

          // Estimate the width of row items with spacing
          double estimatedWidth = targetHeight * currentAspectRatioSum + spacing * (currentRow.length - 1);

          if (estimatedWidth >= maxWidth) {
            // Row is full! Justify it
            double usableWidth = maxWidth - spacing * (currentRow.length - 1);
            double actualHeight = usableWidth / currentAspectRatioSum;
            // Clamp actual height to keep rows balanced
            actualHeight = actualHeight.clamp(targetHeight * 0.6, targetHeight * 1.5);

            rows.add(currentRow);
            rowHeights.add(actualHeight);

            currentRow = [];
            currentAspectRatioSum = 0.0;
          }
        }

        // Add leftover items as the last row
        if (currentRow.isNotEmpty) {
          rows.add(currentRow);
          rowHeights.add(targetHeight); // last row is not justified to prevent huge items
        }

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.96, end: 1.0).animate(animation),
              child: child,
            ),
          ),
          child: Column(
            key: ValueKey<int>(columns),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (int r = 0; r < rows.length; r++) ...[
                if (r > 0) const SizedBox(height: spacing),
                _buildJustifiedRow(
                  context,
                  rows[r],
                  rowHeights[r],
                  maxWidth,
                  spacing,
                  isLastRow: r == rows.length - 1,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildJustifiedRow(
    BuildContext context,
    List<GalleryItem> rowItems,
    double height,
    double maxWidth,
    double spacing, {
    required bool isLastRow,
  }) {
    final List<double> ratios = rowItems.map((item) {
      double ratio = item.displayAspectRatio;
      if (ratio <= 0) ratio = 1.0;
      return ratio.clamp(0.5, 2.0);
    }).toList();

    final double aspectSum = ratios.fold(0.0, (sum, r) => sum + r);

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

    return SizedBox(
      height: height,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          for (int i = 0; i < rowItems.length; i++) ...[
            if (i > 0) SizedBox(width: spacing),
            SizedBox(
              width: widths[i],
              height: height,
              child: Builder(
                builder: (itemCtx) {
                  final item = rowItems[i];
                  final burstCount = BurstHelper.getBurstCount(item, allItems);
                  return PhotoGridTile(
                    key: ValueKey(item.id),
                    item: item,
                    isSelected: selectedItemIds.contains(item.id),
                    isSelectionMode: isSelectionMode,
                    isBurstRepresentative: burstCount > 1,
                    burstCount: burstCount,
                    borderRadius: 4.0,
                    onTap: () => onItemTapped(item),
                    onLongPress: () => onItemLongPressed?.call(item),
                    onContextReady: (ctx) => itemContexts[item.id] = ctx,
                    highlightItemId: highlightItemId,
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Full-width hero layout used when columns == 1.
  /// First item → large 4:3 banner; remaining → 2-column mini-grid.
  Widget _buildHeroLayout(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    final heroItem = items.first;
    final rest = items.length > 1 ? items.sublist(1) : <GalleryItem>[];

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(animation),
          child: child,
        ),
      ),
      child: Column(
        key: const ValueKey<int>(1),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Hero banner ──────────────────────────────────────────────────
          AspectRatio(
            aspectRatio: 4 / 3,
            child: PhotoGridTile(
              key: ValueKey('hero_${heroItem.id}'),
              item: heroItem,
              isSelected: selectedItemIds.contains(heroItem.id),
              isSelectionMode: isSelectionMode,
              isBurstRepresentative:
                  BurstHelper.getBurstCount(heroItem, allItems) > 1,
              burstCount: BurstHelper.getBurstCount(heroItem, allItems),
              borderRadius: 14.0,
              onTap: () => onItemTapped(heroItem),
              onLongPress: () => onItemLongPressed?.call(heroItem),
              onContextReady: (ctx) => itemContexts[heroItem.id] = ctx,
              highlightItemId: highlightItemId,
            ),
          ),
          if (rest.isNotEmpty) ...[
            const SizedBox(height: 3),
            // ── 2-column mini-grid for the rest ─────────────────────────
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 3,
                mainAxisSpacing: 3,
                childAspectRatio: 1.0,
              ),
              itemCount: rest.length,
              itemBuilder: (context, i) {
                final item = rest[i];
                final burstCount = BurstHelper.getBurstCount(item, allItems);
                return PhotoGridTile(
                  key: ValueKey(item.id),
                  item: item,
                  isSelected: selectedItemIds.contains(item.id),
                  isSelectionMode: isSelectionMode,
                  isBurstRepresentative: burstCount > 1,
                  burstCount: burstCount,
                  borderRadius: 10.0,
                  onTap: () => onItemTapped(item),
                  onLongPress: () => onItemLongPressed?.call(item),
                  onContextReady: (ctx) => itemContexts[item.id] = ctx,
                  highlightItemId: highlightItemId,
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// A single grid cell with placeholder colour + fade-in image loading.
// ─────────────────────────────────────────────────────────────────────────────
class PhotoGridTile extends StatefulWidget {
  final GalleryItem item;
  final bool isSelected;
  final bool isSelectionMode;
  final bool isBurstRepresentative;
  final int burstCount;
  final double borderRadius;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final void Function(BuildContext ctx) onContextReady;
  final String? highlightItemId;
  final Widget? topLeftBadge;

  const PhotoGridTile({
    super.key,
    required this.item,
    required this.isSelected,
    required this.isSelectionMode,
    required this.isBurstRepresentative,
    required this.burstCount,
    required this.borderRadius,
    required this.onTap,
    required this.onLongPress,
    required this.onContextReady,
    this.highlightItemId,
    this.topLeftBadge,
  });

  @override
  State<PhotoGridTile> createState() => PhotoGridTileState();
}

class PhotoGridTileState extends State<PhotoGridTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeCtrl;
  late final Animation<double> _fadeAnim;
  bool _imageReady = false;

  /// Deterministic pastel placeholder derived from item id hash.
  Color get _placeholderColor {
    final hue = (widget.item.id.hashCode.abs() % 360).toDouble();
    return HSLColor.fromAHSL(1.0, hue, 0.28, 0.22).toColor();
  }

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeIn);
    // Register context after first frame so RenderObject exists.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onContextReady(context);
    });
  }

  @override
  void didUpdateWidget(PhotoGridTile old) {
    super.didUpdateWidget(old);
    // Re-register if the item changed (e.g. list reorder).
    if (old.item.id != widget.item.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onContextReady(context);
      });
    }
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    super.dispose();
  }

  void _onImageReady() {
    if (!_imageReady && mounted) {
      _imageReady = true;
      _fadeCtrl.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    // onContextReady is called from initState/didUpdateWidget, NOT build,
    // so it doesn't run on every scroll-induced rebuild.
    final isVideo = widget.item.mediaType == 'video';
    final br = BorderRadius.circular(widget.borderRadius);

    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: ClipRRect(
        borderRadius: br,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── Phase 1: placeholder colour ─────────────────────────────
            ColoredBox(color: _placeholderColor),

            // ── Phase 2: actual image (fades in) ────────────────────────
            FadeTransition(
              opacity: _fadeAnim,
              child: Hero(
                tag: 'hero_${widget.item.id}',
                child: FastMediaPreview(
                  item: widget.item,
                  fit: BoxFit.cover,
                  onLoaded: _onImageReady,
                ),
              ),
            ),

            // ── Highlight border (for search focus/highlight) ────────────
            if (widget.item.id == widget.highlightItemId)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 4,
                    ),
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.25),
                  ),
                ),
              ),

            // ── Video play icon ──────────────────────────────────────────
            if (isVideo)
              const Center(
                child: Icon(
                  Icons.play_circle_fill,
                  color: Colors.white,
                  size: 36,
                ),
              ),

            // ── Burst badge ──────────────────────────────────────────────
            if (widget.isBurstRepresentative)
              Positioned(
                left: 6,
                bottom: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.white12, width: 0.5),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.collections_rounded,
                        color: Colors.white,
                        size: 11,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '${widget.burstCount}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            if (widget.topLeftBadge != null)
              Positioned(
                left: 6,
                top: 6,
                child: widget.topLeftBadge!,
              ),

            // ── Selection overlay ────────────────────────────────────────
            if (widget.isSelectionMode)
              Positioned.fill(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  color: widget.isSelected
                      ? Colors.blue.withValues(alpha: 0.35)
                      : Colors.transparent,
                ),
              ),
            if (widget.isSelectionMode)
              Positioned(
                top: 5,
                right: 5,
                child: Icon(
                  widget.isSelected
                      ? Icons.check_circle
                      : Icons.circle_outlined,
                  color: widget.isSelected
                      ? Colors.blue
                      : Colors.white.withValues(alpha: 0.8),
                  size: 20,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
