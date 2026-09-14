// ═══════════════════════════════════════════════════════════════════════════
// media_type_badge.dart
//
// Aves-style elegant colored chip badges for special media types:
//   ✅ HDR (Orange)
//   ✅ 360° (Blue)
//   ✅ Panorama (Teal)
//   ✅ Burst (Purple)
//   ✅ Motion (Cyan)
//   ✅ Animated (Grey)
// ═══════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import '../models/gallery_item.dart';

class MediaTypeBadge extends StatelessWidget {
  final GalleryItem item;
  final bool compact; // If true, only shows icon, no text label

  const MediaTypeBadge({
    super.key,
    required this.item,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (!item.hasSpecialType) return const SizedBox.shrink();

    final badges = <Widget>[];

    if (item.is360) {
      badges.add(_BadgeChip(
        icon: Icons.threed_rotation,
        label: '360°',
        color: Colors.blue.shade700,
        textColor: Colors.white,
        compact: compact,
      ));
    } else if (item.isPanorama) {
      badges.add(_BadgeChip(
        icon: Icons.panorama_horizontal_outlined,
        label: 'Panorama',
        color: Colors.teal.shade700,
        textColor: Colors.white,
        compact: compact,
      ));
    }

    if (item.isHdr) {
      badges.add(_BadgeChip(
        icon: Icons.hdr_on,
        label: 'HDR',
        color: Colors.orange.shade800,
        textColor: Colors.white,
        compact: compact,
      ));
    }

    if (item.isBurst) {
      badges.add(_BadgeChip(
        icon: Icons.burst_mode_outlined,
        label: 'Burst',
        color: Colors.purple.shade700,
        textColor: Colors.white,
        compact: compact,
      ));
    }

    if (item.isMotionPhoto) {
      badges.add(_BadgeChip(
        icon: Icons.play_circle_outline,
        label: 'Motion',
        color: Colors.cyan.shade800,
        textColor: Colors.white,
        compact: compact,
      ));
    }

    if (item.isAnimated) {
      badges.add(_BadgeChip(
        icon: Icons.gif_box_outlined,
        label: 'GIF',
        color: Colors.grey.shade700,
        textColor: Colors.white,
        compact: compact,
      ));
    }
    if (item.isPortrait) {
      badges.add(_BadgeChip(
        icon: Icons.portrait,
        label: 'Portrait',
        color: Colors.pink.shade400,
        textColor: Colors.white,
        compact: compact,
      ));
    }

    if (badges.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: badges,
    );
  }
}

class _BadgeChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final Color textColor;
  final bool compact;

  const _BadgeChip({
    required this.icon,
    required this.label,
    required this.color,
    required this.textColor,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 12 : 14, color: textColor),
          if (!compact) ...[
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: textColor,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
