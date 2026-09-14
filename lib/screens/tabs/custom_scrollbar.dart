import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/gallery_item.dart';

/// Custom draggable scrollbar pinned to the right edge of the screen.
/// Shows a floating date bubble that tracks the current scroll position.
class CustomScrollbar extends StatefulWidget {
  final ScrollController scrollController;
  final int Function(String) getColumnsForGroup;
  final Map<String, List<GalleryItem>> groupedItems;
  final List<String> sortedDates;

  const CustomScrollbar({
    super.key,
    required this.scrollController,
    required this.getColumnsForGroup,
    required this.groupedItems,
    required this.sortedDates,
  });

  @override
  State<CustomScrollbar> createState() => _CustomScrollbarState();
}

class _CustomScrollbarState extends State<CustomScrollbar> {
  bool _showScrollDateBubble = false;
  String _currentScrollDateStr = '';
  Timer? _scrollBubbleTimer;

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(CustomScrollbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_onScroll);
      widget.scrollController.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_onScroll);
    _scrollBubbleTimer?.cancel();
    super.dispose();
  }

  void _onScroll() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.sortedDates.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final trackHeight = constraints.maxHeight;

        // 1. Calculate dynamic thumb height based on list scroll length
        double thumbHeight = 60.0;
        if (widget.scrollController.hasClients &&
            widget.scrollController.position.maxScrollExtent > 0) {
          final viewportHeight = widget.scrollController.position.viewportDimension;
          final maxScrollExtent = widget.scrollController.position.maxScrollExtent;
          final totalContentHeight = maxScrollExtent + viewportHeight;
          
          thumbHeight = (viewportHeight / totalContentHeight) * trackHeight;
          // Clamp thumb height to ensure it is always highly touchable
          thumbHeight = thumbHeight.clamp(45.0, 180.0);
        }

        final maxThumbOffset = trackHeight - thumbHeight;

        // 2. Calculate scroll progress and thumb offset
        double scrollProgress = 0.0;
        if (widget.scrollController.hasClients &&
            widget.scrollController.position.maxScrollExtent > 0) {
          scrollProgress = (widget.scrollController.offset /
                  widget.scrollController.position.maxScrollExtent)
              .clamp(0.0, 1.0);
        }
        final thumbOffset = scrollProgress * maxThumbOffset;

        // 3. Centered date bubble top calculation
        const bubbleHeight = 34.0;
        final bubbleTop = thumbOffset + (thumbHeight / 2) - (bubbleHeight / 2);

        void handleDrag(double localY) {
          if (!widget.scrollController.hasClients) return;

          // Drag percentage based on thumb center dragging
          final percentage =
              (localY - (thumbHeight / 2)).clamp(0.0, maxThumbOffset) /
                  maxThumbOffset;
          
          final maxExtent = widget.scrollController.position.maxScrollExtent;
          final targetScroll = percentage * maxExtent;
          
          widget.scrollController.jumpTo(targetScroll);

          // Compute which date section is visible
          final gridWidth = MediaQuery.of(context).size.width - 32;
          double accumulated = 16.0; // Start with ListView padding offset
          String matched = "";
          
          for (final dateStr in widget.sortedDates) {
            final items = widget.groupedItems[dateStr] ?? [];
            final cols = widget.getColumnsForGroup(dateStr);
            final rows = (items.length / cols).ceil();
            
            // Calculate actual layout size matching photos_tab.dart grid exactly
            final itemSize = (gridWidth - (cols - 1) * 8) / cols;
            final gridHeight = rows > 0 ? (rows * itemSize + (rows - 1) * 8) : 0.0;
            
            // header height (32.0) + gridHeight + bottom padding spacing (24.0) = 56.0 + gridHeight
            accumulated += gridHeight + 56.0;

            if (targetScroll <= accumulated) {
              matched = dateStr;
              break;
            }
          }
          
          if (matched.isEmpty && widget.sortedDates.isNotEmpty) {
            matched = widget.sortedDates.last;
          }

          // Format bubble text (e.g. "Jun 2026")
          String bubbleText = matched;
          if (matched != 'Today' && matched != 'Yesterday') {
            try {
              final parts = matched.split(',');
              if (parts.length == 2) {
                final year = parts[1].trim();
                final dayMonth = parts[0].trim().split(' ');
                if (dayMonth.length == 2) {
                  bubbleText = "${dayMonth[0]} $year";
                }
              }
            } catch (_) {}
          }

          _scrollBubbleTimer?.cancel();
          setState(() {
            _currentScrollDateStr = bubbleText;
            _showScrollDateBubble = true;
          });
        }

        void handleDragEnd() {
          _scrollBubbleTimer?.cancel();
          _scrollBubbleTimer = Timer(
            const Duration(milliseconds: 1000),
            () {
              if (mounted) {
                setState(() => _showScrollDateBubble = false);
              }
            },
          );
        }

        return Stack(
          clipBehavior: Clip.none,
          children: [
            // Floating Date Bubble
            if (_currentScrollDateStr.isNotEmpty)
              Positioned(
                right: 48,
                // Keep the bubble from sliding off-screen vertically
                top: bubbleTop.clamp(8.0, trackHeight - bubbleHeight - 8.0),
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _showScrollDateBubble ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 150),
                    child: Container(
                      height: bubbleHeight,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.95),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black26,
                            blurRadius: 6,
                            offset: Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Text(
                        _currentScrollDateStr,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            // Draggable scrollbar track & thumb
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: 40,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragDown: (d) => handleDrag(d.localPosition.dy),
                onVerticalDragUpdate: (d) => handleDrag(d.localPosition.dy),
                onVerticalDragEnd: (_) => handleDragEnd(),
                onTapDown: (d) => handleDrag(d.localPosition.dy),
                onTapUp: (_) => handleDragEnd(),
                child: Stack(
                  children: [
                    // Thin track line
                    Positioned(
                      right: 8,
                      top: 4,
                      bottom: 4,
                      width: 3,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(1.5),
                        ),
                      ),
                    ),
                    // Thumb
                    Positioned(
                      top: thumbOffset,
                      right: 6,
                      child: Container(
                        width: 7,
                        height: thumbHeight,
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(3.5),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
