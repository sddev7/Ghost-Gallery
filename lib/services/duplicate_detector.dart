import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import '../models/gallery_item.dart';
import 'database_helper.dart';

// ═══════════════════════════════════════════════════════════════════════════
// Models
// ═══════════════════════════════════════════════════════════════════════════

enum DuplicateType {
  exact,  // byte-identical: MD5 hash match
  video,  // same video: size + duration + resolution
}

class DuplicateGroup {
  final DuplicateType type;
  final List<GalleryItem> items; // items[0] = suggested "KEEP" candidate
  final String reason;

  const DuplicateGroup({
    required this.type,
    required this.items,
    required this.reason,
  });

  /// Human-readable date from the oldest item (original copy date).
  String get dateLabel => items.first.date;

  /// Wasted MB = sum of all items EXCEPT the keep candidate (items[0]).
  double get wastedMb {
    double total = 0;
    for (int i = 1; i < items.length; i++) {
      total += _parseMb(items[i].size);
    }
    return total;
  }

  static double _parseMb(String s) {
    try {
      final c = s.toUpperCase().replaceAll(',', '').trim();
      final p = c.split(RegExp(r'\s+'));
      if (p.isEmpty) return 0.0;
      final v = double.tryParse(p[0]) ?? 0.0;
      if (c.contains('GB')) return v * 1024.0;
      if (c.contains('KB')) return v / 1024.0;
      if (c.contains('MB')) return v;
      if (c.contains('B')) return v / (1024.0 * 1024.0);
      return v;
    } catch (_) {
      return 0.0;
    }
  }
}

class DuplicateScanResult {
  final List<DuplicateGroup> groups;
  final int totalCandidates; // files that entered Tier-2 hashing
  final int hashesComputed;  // newly computed (not from cache)
  final int cacheHits;       // loaded from SQLite cache

  const DuplicateScanResult({
    required this.groups,
    required this.totalCandidates,
    required this.hashesComputed,
    required this.cacheHits,
  });

  double get totalWastedMb =>
      groups.fold(0.0, (sum, g) => sum + g.wastedMb);
}

// ═══════════════════════════════════════════════════════════════════════════
// Isolate worker — payload MUST be a plain Map so compute()/SendPort.send()
// can serialize it across the isolate boundary. Custom class instances are
// NOT transferable and will cause compute() to throw on the first batch,
// which is why the scan was stuck and never progressed past batch 1.
// ═══════════════════════════════════════════════════════════════════════════

/// Top-level function so compute() can serialize it.
/// Payload: { 'paths': List<String>, 'cached': Map<String,String> }
/// Returns { filePath → md5 } for every readable path.
Future<Map<String, String>> _computeMd5Batch(Map<String, dynamic> payload) async {
  final paths  = (payload['paths']  as List).cast<String>();
  final cached = (payload['cached'] as Map).cast<String, String>();
  final out    = <String, String>{};
  for (final path in paths) {
    // Use cache when available — saves reading the file again
    final hit = cached[path];
    if (hit != null && hit.isNotEmpty) {
      out[path] = hit;
      continue;
    }
    try {
      final file = File(path);
      if (!file.existsSync()) continue;
      final bytes = await file.readAsBytes();
      out[path] = md5.convert(bytes).toString();
    } catch (_) {
      // Unreadable / locked files are silently skipped
    }
  }
  return out;
}

// ═══════════════════════════════════════════════════════════════════════════
// Duplicate Detector
// ═══════════════════════════════════════════════════════════════════════════

typedef PhaseCallback = void Function(String label, double progress);

class DuplicateDetector {
  /// Full scan pipeline. Heavy MD5 work runs inside compute() isolates.
  ///
  /// [onPhase] receives a human-readable status string + 0.0–1.0 progress.
  /// Results are sorted by date (newest group first).
  static Future<DuplicateScanResult> scan(
    List<GalleryItem> allItems, {
    PhaseCallback? onPhase,
  }) async {
    // ── Load hash cache from SQLite ─────────────────────────────────────────
    onPhase?.call('Loading cached hashes…', 0.02);
    final idHashCache = await DatabaseHelper.instance.getHashCache();
    // Build path-keyed cache for quick lookup inside the isolate
    final pathHashCache = <String, String>{};
    for (final item in allItems) {
      final h = idHashCache[item.id];
      if (h != null) pathHashCache[item.imageUrl] = h;
    }

    // ── Separate images and videos ──────────────────────────────────────────
    final images = allItems.where((i) => i.mediaType == 'image').toList();
    final videos = allItems.where((i) => i.mediaType == 'video').toList();

    // ══════════════════════════════════════════════════════════════════════
    // TIER 1 — Group images by size string
    // ══════════════════════════════════════════════════════════════════════
    onPhase?.call('Grouping by file size…', 0.08);

    final Map<String, List<GalleryItem>> sizeMap = {};
    for (final item in images) {
      final key = item.size.trim();
      if (key.isEmpty || key == '0 B' || key == '0') continue;
      sizeMap.putIfAbsent(key, () => []).add(item);
    }
    // Only groups with >1 file are candidates for Tier 2
    final candidateGroups = sizeMap.values.where((g) => g.length > 1).toList();
    final candidatePaths = candidateGroups
        .expand((g) => g)
        .map((i) => i.imageUrl)
        .toSet()
        .toList();

    // ══════════════════════════════════════════════════════════════════════
    // TIER 2 — MD5 hash (compute isolate, 50-file batches)
    // ══════════════════════════════════════════════════════════════════════
    final pathToId = {for (final i in allItems) i.imageUrl: i.id};
    final Map<String, String> pathToMd5 = {};
    int hashesComputed = 0;
    int cacheHits = 0;
    const batchSize = 50;

    for (int start = 0; start < candidatePaths.length; start += batchSize) {
      final end = (start + batchSize).clamp(0, candidatePaths.length);
      final batch = candidatePaths.sublist(start, end);
      final frac = candidatePaths.isEmpty
          ? 1.0
          : (end / candidatePaths.length).clamp(0.0, 1.0);
      onPhase?.call(
        'Scanning…',
        0.1 + frac * 0.65,
      );

      final result = await compute(
        _computeMd5Batch,
        <String, dynamic>{'paths': batch, 'cached': pathHashCache},
      );
      pathToMd5.addAll(result);

      for (final path in batch) {
        if (pathHashCache.containsKey(path)) {
          cacheHits++;
        } else {
          hashesComputed++;
        }
      }
    }

    // ── Build exact duplicate groups from hash map ───────────────────────────
    onPhase?.call('Identifying duplicates…', 0.80);

    final Map<String, List<GalleryItem>> hashMap = {};
    for (final group in candidateGroups) {
      for (final item in group) {
        final hash = pathToMd5[item.imageUrl];
        if (hash == null || hash.isEmpty) continue;
        hashMap.putIfAbsent(hash, () => []).add(item);
      }
    }

    final List<DuplicateGroup> results = [];
    for (final entry in hashMap.entries) {
      if (entry.value.length < 2) continue;
      // Sort oldest→newest so items[0] = the original
      final sorted = List<GalleryItem>.from(entry.value)
        ..sort((a, b) => a.dateTimestamp.compareTo(b.dateTimestamp));
      results.add(DuplicateGroup(
        type: DuplicateType.exact,
        items: sorted,
        reason: 'Exact copy (identical file content)',
      ));
    }

    // ══════════════════════════════════════════════════════════════════════
    // VIDEO — group by size + duration + resolution
    // ══════════════════════════════════════════════════════════════════════
    final Map<String, List<GalleryItem>> videoMap = {};
    for (final v in videos) {
      final dur = v.duration?.toStringAsFixed(0) ?? '0';
      final key = '${v.size}|$dur|${v.resolution}';
      videoMap.putIfAbsent(key, () => []).add(v);
    }
    for (final group in videoMap.values) {
      if (group.length < 2) continue;
      final sorted = List<GalleryItem>.from(group)
        ..sort((a, b) => a.dateTimestamp.compareTo(b.dateTimestamp));
      results.add(DuplicateGroup(
        type: DuplicateType.video,
        items: sorted,
        reason: 'Same size, duration & resolution',
      ));
    }

    // ── Sort groups newest-first by the KEEP candidate's timestamp ───────────
    results.sort((a, b) =>
        b.items.first.dateTimestamp.compareTo(a.items.first.dateTimestamp));

    // ── Persist new hashes to SQLite cache ──────────────────────────────────
    onPhase?.call('Saving hash cache…', 0.92);
    final newHashes = <String, String>{};
    for (final entry in pathToMd5.entries) {
      final id = pathToId[entry.key];
      if (id != null && !idHashCache.containsKey(id)) {
        newHashes[id] = entry.value;
      }
    }
    if (newHashes.isNotEmpty) {
      await DatabaseHelper.instance.upsertHashCache(newHashes);
    }

    onPhase?.call('Scan complete', 1.0);

    return DuplicateScanResult(
      groups: results,
      totalCandidates: candidatePaths.length,
      hashesComputed: hashesComputed,
      cacheHits: cacheHits,
    );
  }
}
