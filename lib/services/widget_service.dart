import 'dart:convert';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/gallery_item.dart';

class WidgetService {
  static const MethodChannel _channel =
      MethodChannel('in.sddev.ghost_gallery/widget_manager');

  /// Fetches widget click/launch data from the native side.
  /// Returns a map containing:
  /// - `widgetClicked`: bool
  /// - `action`: 'VIEW_IMAGE', 'CONFIGURE', or 'APP_OPEN'
  /// - `imagePath`: String?
  /// - `albumName`: String?
  /// - `widgetId`: int?
  static Future<Map<String, dynamic>?> getWidgetLaunchData() async {
    try {
      final Map<dynamic, dynamic>? data =
          await _channel.invokeMethod('getWidgetLaunchData');
      if (data != null) {
        return Map<String, dynamic>.from(data);
      }
    } catch (e) {
      print('Error getting widget launch data: $e');
    }
    return null;
  }

  /// Returns all currently placed widget instance IDs.
  /// Returns an empty list if there are no widgets or on error.
  static Future<List<int>> getActiveWidgetIds() async {
    try {
      final List<dynamic>? ids =
          await _channel.invokeMethod('getActiveWidgetIds');
      return ids?.cast<int>() ?? [];
    } catch (e) {
      print('Error getting active widget IDs: $e');
      return [];
    }
  }

  /// Configures the album for a specific widget (by [widgetId]) or for ALL
  /// widgets when [widgetId] is null.
  ///
  /// Per-widget SharedPreferences keys: `widget_album_name_<id>`, etc.
  /// Legacy global keys are intentionally left untouched so that any
  /// existing widget that has not yet been individually configured still
  /// falls back correctly inside the Kotlin provider.
  static Future<void> configureWidgetAlbum(
    String albumName,
    List<GalleryItem> items, {
    int? widgetId,
  }) async {
    try {
      // 1. Extract local image paths (only images are supported on photo widget)
      final imagePaths = items
          .where((item) => item.mediaType == 'image')
          .map((item) => item.imageUrl)
          .toList();

      if (imagePaths.isEmpty) {
        print(
            'Warning: No images found in album $albumName to display on widget.');
        return;
      }

      // 2. Select a random starting image
      final random = Random();
      final currentImagePath = imagePaths[random.nextInt(imagePaths.length)];

      final prefs = await SharedPreferences.getInstance();

      if (widgetId != null) {
        // 3a. Save per-widget keys for this specific widget instance
        await prefs.setString('widget_album_name_$widgetId', albumName);
        await prefs.setString(
            'widget_album_paths_json_$widgetId', jsonEncode(imagePaths));
        await prefs.setString(
            'widget_current_image_path_$widgetId', currentImagePath);
        await prefs.remove('widget_remaining_paths_json_$widgetId');

        // 4a. Notify native widget to update this specific widget only
        await _channel.invokeMethod('updateWidget', {'widgetId': widgetId});
      } else {
        // 3b. No specific widget — apply to ALL active widget instances
        final activeIds = await getActiveWidgetIds();

        if (activeIds.isEmpty) {
          // Fallback: write to legacy global keys (first-time setup, no widgets yet)
          await prefs.setString('widget_album_name', albumName);
          await prefs.setString(
              'widget_album_paths_json', jsonEncode(imagePaths));
          await prefs.setString(
              'widget_current_image_path', currentImagePath);
          await prefs.remove('widget_remaining_paths_json');
        } else {
          for (final id in activeIds) {
            await prefs.setString('widget_album_name_$id', albumName);
            await prefs.setString(
                'widget_album_paths_json_$id', jsonEncode(imagePaths));
            await prefs.setString(
                'widget_current_image_path_$id', currentImagePath);
            await prefs.remove('widget_remaining_paths_json_$id');
          }
        }

        // 4b. Update all widgets
        await _channel.invokeMethod('updateWidget');
      }
    } catch (e) {
      print('Error configuring widget album: $e');
    }
  }

  /// Refreshes/updates all widgets from their current saved settings.
  static Future<void> forceUpdateWidget() async {
    try {
      await _channel.invokeMethod('updateWidget');
    } catch (e) {
      print('Error updating widget: $e');
    }
  }
}
