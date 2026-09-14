// ═══════════════════════════════════════════════════════════════════════════
// exif_overlay_panel.dart
//
// Aves-style sleek horizontal camera settings indicator.
// Displays key EXIF values as a premium row:
//   "f/1.8  ·  ISO 100  ·  1/250s  ·  26mm"
//
// Seamlessly handles missing fields and defaults with micro icons.
// ═══════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import '../models/gallery_item.dart';

class ExifOverlayPanel extends StatelessWidget {
  final GalleryItem item;
  final Color? color;

  const ExifOverlayPanel({
    super.key,
    required this.item,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textStyle = theme.textTheme.bodyMedium?.copyWith(
      color: color ?? theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.2,
      fontSize: 13,
    );

    final parts = <Widget>[];

    // ── Aperture ────────────────────────────────────────────────────────────
    if (item.apertureDisplay != null) {
      parts.add(_ExifItem(
        icon: Icons.camera_outlined,
        text: item.apertureDisplay!,
        style: textStyle,
      ));
    }

    // ── Exposure Time ───────────────────────────────────────────────────────
    if (item.exposureTime != null) {
      parts.add(_ExifItem(
        icon: Icons.shutter_speed_outlined,
        text: item.exposureTime!,
        style: textStyle,
      ));
    }

    // ── ISO ─────────────────────────────────────────────────────────────────
    if (item.isoDisplay != null) {
      parts.add(_ExifItem(
        icon: Icons.iso_outlined,
        text: item.isoDisplay!,
        style: textStyle,
      ));
    }

    // ── Focal Length ────────────────────────────────────────────────────────
    if (item.focalLengthDisplay != null) {
      parts.add(_ExifItem(
        icon: Icons.filter_hdr_outlined,
        text: item.focalLengthDisplay!,
        style: textStyle,
      ));
    }

    // ── Flash status ────────────────────────────────────────────────────────
    if (item.flashDisplay != null) {
      final fired = (item.flash ?? 0) & 1 != 0;
      parts.add(_ExifItem(
        icon: fired ? Icons.flash_on : Icons.flash_off_outlined,
        text: fired ? 'Flash' : 'No Flash',
        style: textStyle,
      ));
    }

    if (parts.isEmpty) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.info_outline,
            size: 14,
            color: theme.colorScheme.outline.withValues(alpha: 0.6),
          ),
          const SizedBox(width: 6),
          Text(
            'No camera settings available',
            style: textStyle?.copyWith(
              color: theme.colorScheme.outline.withValues(alpha: 0.6),
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      );
    }

    // Join elements with separators
    final List<Widget> children = [];
    for (int i = 0; i < parts.length; i++) {
      children.add(parts[i]);
      if (i < parts.length - 1) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              '·',
              style: textStyle?.copyWith(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
        );
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: children,
        ),
      ),
    );
  }
}

class _ExifItem extends StatelessWidget {
  final IconData icon;
  final String text;
  final TextStyle? style;

  const _ExifItem({
    required this.icon,
    required this.text,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 15,
          color: style?.color?.withValues(alpha: 0.7),
        ),
        const SizedBox(width: 4),
        Text(text, style: style),
      ],
    );
  }
}
