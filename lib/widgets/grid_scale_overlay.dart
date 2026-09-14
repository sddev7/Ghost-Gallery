import 'package:flutter/material.dart';
import '../models/gallery_item.dart';
import '../screens/tabs/fast_media_preview.dart';
import '../services/ui_preference_provider.dart';

class GridScaleOverlay extends StatefulWidget {
  final GalleryItem item;
  final Offset startingPosition; // global position of the grid item
  final Size startingSize;       // global size of the grid item
  final Offset focalPoint;       // global focal point of pinch
  final ValueNotifier<double> scaleNotifier; // live scale multiplier

  const GridScaleOverlay({
    super.key,
    required this.item,
    required this.startingPosition,
    required this.startingSize,
    required this.focalPoint,
    required this.scaleNotifier,
  });

  @override
  State<GridScaleOverlay> createState() => _GridScaleOverlayState();
}

class _GridScaleOverlayState extends State<GridScaleOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bgFadeController;
  late final Animation<double> _bgFadeAnim;

  @override
  void initState() {
    super.initState();
    _bgFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _bgFadeAnim = CurvedAnimation(
      parent: _bgFadeController,
      curve: Curves.easeOut,
    );
    _bgFadeController.forward();
    UIPreferenceProvider.instance.addListener(_handleUIPreferencesChange);
  }

  void _handleUIPreferencesChange() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    UIPreferenceProvider.instance.removeListener(_handleUIPreferencesChange);
    _bgFadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final columns = UIPreferenceProvider.instance.gridColumns;

    final itemCenter = widget.startingPosition +
        Offset(widget.startingSize.width / 2, widget.startingSize.height / 2);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Radial Gradient Backdrop ──────────────────────────────────────────
          AnimatedBuilder(
            animation: _bgFadeAnim,
            builder: (context, child) {
              final opacity = _bgFadeAnim.value;
              return Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(
                      (itemCenter.dx / screenSize.width) * 2 - 1,
                      (itemCenter.dy / screenSize.height) * 2 - 1,
                    ),
                    radius: 1.2,
                    colors: isDark
                        ? [
                            Colors.black.withValues(alpha: 0.85 * opacity),
                            Colors.black.withValues(alpha: 0.55 * opacity),
                          ]
                        : [
                            Colors.white.withValues(alpha: 0.9 * opacity),
                            Colors.white.withValues(alpha: 0.6 * opacity),
                          ],
                  ),
                ),
              );
            },
          ),
          
          // ── Live Scaling Thumbnail ─────────────────────────────────────────────
          ValueListenableBuilder<double>(
            valueListenable: widget.scaleNotifier,
            builder: (context, scale, child) {
              // Calculate scaled dimensions
              final width = widget.startingSize.width * scale;
              final height = widget.startingSize.height * scale;

              // Center the scaled thumbnail on the itemCenter, but clamp to screen edges
              final double left = (itemCenter.dx - width / 2).clamp(
                12.0,
                screenSize.width - width - 12.0,
              );
              final double top = (itemCenter.dy - height / 2).clamp(
                12.0,
                screenSize.height - height - 12.0,
              );

              return Positioned(
                left: left,
                top: top,
                width: width,
                height: height,
                child: Material(
                  elevation: 8,
                  borderRadius: BorderRadius.circular(14),
                  color: Colors.transparent,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        FastMediaPreview(
                          item: widget.item,
                          fit: BoxFit.cover,
                        ),
                        if (widget.item.mediaType == 'video')
                          const Center(
                            child: Icon(
                              Icons.play_circle_fill,
                              color: Colors.white,
                              size: 48,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),

          // ── Column Count HUD Pill ──────────────────────────────────────────────
          Positioned(
            top: 40 + MediaQuery.paddingOf(context).top,
            left: 0,
            right: 0,
            child: Center(
              child: AnimatedBuilder(
                animation: _bgFadeAnim,
                builder: (context, child) {
                  return Opacity(
                    opacity: _bgFadeAnim.value,
                    child: child,
                  );
                },
                child: Container(
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
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
