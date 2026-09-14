import 'dart:io';
import '../models/gallery_item.dart';
import '../models/media_flags.dart';

class BurstHelper {
  /// Extracts a unique key representing a burst sequence from a file path.
  /// If the item is not a burst or doesn't match standard burst filename patterns, returns null.
  static String? getBurstGroupKey(GalleryItem item) {
    if (!MediaFlags.isBurst(item.flags)) return null;
    final path = item.imageUrl;
    final filename = path.split('/').last.split('\\').last;

    // Standard Android burst filename pattern: BURST_20260525_120000_1.jpg
    final m1 = RegExp(r'^(BURST_\d{8}_\d{6})', caseSensitive: false).firstMatch(filename);
    if (m1 != null) return m1.group(1)!.toLowerCase();

    // Alternate: IMG_20260525_120000_BURST01.jpg
    final m2 = RegExp(r'^(IMG_\d{8}_\d{6})', caseSensitive: false).firstMatch(filename);
    if (m2 != null && filename.toLowerCase().contains('burst')) return m2.group(1)!.toLowerCase();

    // General pattern: name_BURST_12.jpg
    final m3 = RegExp(r'^(.*?)_?BURST\d*', caseSensitive: false).firstMatch(filename);
    if (m3 != null) return m3.group(1)!.toLowerCase();

    // Sequential series like IMG_0001_b01.jpg, _b002, etc.
    final m4 = RegExp(r'^(.*?)_?b\d{3,}', caseSensitive: false).firstMatch(filename);
    if (m4 != null) return m4.group(1)!.toLowerCase();

    // If it is marked as a burst but naming patterns didn't match,
    // fallback to directory path + creation timestamp divided by 10 seconds to group
    // photos taken in rapid succession.
    final parentDir = File(path).parent.path;
    final timeBucket = item.dateTimestamp ~/ 10000; // 10-second buckets
    return 'fallback_${parentDir.hashCode}_$timeBucket';
  }

  /// Takes a flat list of GalleryItems, identifies burst sequences,
  /// and returns a list containing only the first (representative) item of each sequence.
  static List<GalleryItem> collapseBursts(List<GalleryItem> items) {
    final Map<String, List<GalleryItem>> burstGroups = {};
    for (final item in items) {
      final key = getBurstGroupKey(item);
      if (key != null) {
        burstGroups.putIfAbsent(key, () => []).add(item);
      }
    }

    final List<GalleryItem> collapsedList = [];
    final Set<String> processedKeys = {};

    for (final item in items) {
      final key = getBurstGroupKey(item);
      if (key != null) {
        if (!processedKeys.contains(key)) {
          processedKeys.add(key);
          final group = burstGroups[key]!;
          group.sort((a, b) => a.imageUrl.compareTo(b.imageUrl));
          collapsedList.add(group.first);
        }
      } else {
        collapsedList.add(item);
      }
    }
    return collapsedList;
  }

  /// Gets the count of burst photos in the same sequence.
  static int getBurstCount(GalleryItem representative, List<GalleryItem> allItems) {
    final key = getBurstGroupKey(representative);
    if (key == null) return 1;
    return allItems.where((item) => getBurstGroupKey(item) == key).length;
  }

  /// Retrieves the sorted sequence of burst items for a representative item.
  static List<GalleryItem> getBurstSequence(GalleryItem representative, List<GalleryItem> allItems) {
    final key = getBurstGroupKey(representative);
    if (key == null) return [representative];

    final sequence = allItems.where((item) => getBurstGroupKey(item) == key).toList();
    sequence.sort((a, b) => a.imageUrl.compareTo(b.imageUrl));
    return sequence;
  }
}
