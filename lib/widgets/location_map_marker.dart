// ═══════════════════════════════════════════════════════════════════════════
// location_map_marker.dart
//
// Aves-style geographic cluster pin widget:
//   • Shows low-res circular thumbnail preview of the item in the cluster
//   • Overlays counts bubble for clustered groups (e.g. "+5", "+42")
//   • Adds premium glowing border to represent real GPS matches
//   • Micro-animations when selected
// ═══════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import '../widgets/cached_media_thumbnail.dart';

class LocationMapMarker extends StatelessWidget {
  final String coverPath;
  final String assetId;
  final int count;
  final VoidCallback onTap;
  final bool isSelected;
  final bool isVideo;

  const LocationMapMarker({
    super.key,
    required this.coverPath,
    required this.assetId,
    required this.count,
    required this.onTap,
    this.isSelected = false,
    this.isVideo = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = isSelected ? 56.0 : 48.0;

    return GestureDetector(
      onTap: onTap,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          // Pin bottom triangle / tail
          Positioned(
            bottom: -5,
            child: CustomPaint(
              size: const Size(12, 8),
              painter: _TrianglePainter(
                color: isSelected ? theme.colorScheme.primary : theme.colorScheme.surface,
                borderColor: theme.colorScheme.outline.withValues(alpha: 0.3),
              ),
            ),
          ),

          // Main thumbnail circle with border
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: isSelected ? theme.colorScheme.primary : theme.colorScheme.surface,
                width: isSelected ? 3.0 : 2.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: (isSelected ? theme.colorScheme.primary : Colors.black)
                      .withValues(alpha: 0.3),
                  blurRadius: isSelected ? 8.0 : 4.0,
                  spreadRadius: isSelected ? 2.0 : 0.0,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: ClipOval(
              child: CachedMediaThumbnail(
                assetId: assetId,
                filePath: coverPath,
                isVideo: isVideo,
              ),
            ),
          ),

          // Clustered count bubble badge
          if (count > 1)
            Positioned(
              top: -6,
              right: -6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: theme.colorScheme.onPrimary,
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                constraints: const BoxConstraints(
                  minWidth: 18,
                  minHeight: 18,
                ),
                child: Center(
                  child: Text(
                    '+$count',
                    style: TextStyle(
                      color: theme.colorScheme.onPrimary,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
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

class _TrianglePainter extends CustomPainter {
  final Color color;
  final Color borderColor;

  _TrianglePainter({required this.color, required this.borderColor});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0)
      ..close();

    canvas.drawPath(path, paint);

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    canvas.drawPath(path, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _TrianglePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.borderColor != borderColor;
}
