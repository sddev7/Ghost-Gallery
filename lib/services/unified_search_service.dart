import 'package:flutter/foundation.dart';
import 'database_helper.dart';
import 'optional_features.dart';
import 'objectbox_service.dart';
import '../models/media_vector.dart';
import '../objectbox.g.dart';

// ═══════════════════════════════════════════════════════════════════════════
// UnifiedSearchService — Vector Similarity Search
//
// Fuses two pure-Dart signals per photo:
//
//   Signal A — ObjectBox / Fallback Vector Similarity
//     Weight: 0.80
//
//   Signal B — Person identity score (0.0 or 1.0)
//     Weight: 0.20
//
//   finalScore = 0.80×A + 0.20×B
//
// Runs entirely in compute() (a background isolate) so it never
// blocks the UI thread even with thousands of photos.
// ═══════════════════════════════════════════════════════════════════════════

class SearchResult {
  final Map<String, dynamic> item;  // raw DB row
  final double score;               // 0.0–1.0 fused score
  final String debugReason;         // human-readable match explanation

  const SearchResult({
    required this.item,
    required this.score,
    required this.debugReason,
  });
}

class UnifiedSearchService {
  // ── Score weights ─────────────────────────────────────────────────────────
  static const double _wSimpleVector = 0.6;
  static const double _wPerson       = 0.4;

  // Minimum fused score to include a result
  static const double _minScore = 0.1;

  // ── Entry point ───────────────────────────────────────────────────────────

  /// Searches across all media using vector similarity + person identity.
  /// Always runs off the main thread via compute().
  static Future<List<SearchResult>> search(
    String query, {
    String? mediaTypeFilter, // 'image' | 'video' | null = both
    String? locationFilter,
    String? dateFilter,
    int maxResults = 350,
  }) async {
    if (query.trim().isEmpty) return [];

    final db = DatabaseHelper.instance;
    final allFaces = await db.getAllFaces();
    final allPeople = await db.getAllPeople();

    // 1. Parse @{Person Name} and @person_name tags
    final regexBraces = RegExp(r'@{([^}]+)}');
    final regexPlain = RegExp(r'@([a-zA-Z0-9_\-]+)');

    String vectorQuery = query;
    final Set<String> matchedPersonIds = {};

    // Find braces matches (e.g. @{John Doe})
    for (final match in regexBraces.allMatches(query)) {
      final name = match.group(1)?.trim() ?? "";
      final person = allPeople.firstWhere(
        (p) => (p['name'] as String? ?? "").toLowerCase() == name.toLowerCase(),
        orElse: () => <String, dynamic>{},
      );
      if (person.isNotEmpty) {
        matchedPersonIds.add(person['id'] as String);
      }
    }
    vectorQuery = vectorQuery.replaceAll(regexBraces, '');

    // Find plain matches (e.g. @John or @John_Doe)
    for (final match in regexPlain.allMatches(query)) {
      final name = match.group(1)?.replaceAll('_', ' ').trim() ?? "";
      final person = allPeople.firstWhere(
        (p) => (p['name'] as String? ?? "").toLowerCase() == name.toLowerCase() ||
               (p['name'] as String? ?? "").replaceAll(' ', '_').toLowerCase() == name.toLowerCase(),
        orElse: () => <String, dynamic>{},
      );
      if (person.isNotEmpty) {
        matchedPersonIds.add(person['id'] as String);
      }
    }
    vectorQuery = vectorQuery.replaceAll(regexPlain, '');
    vectorQuery = vectorQuery.trim().replaceAll(RegExp(r'\s+'), ' ');

    final String finalVectorQuery = vectorQuery.isEmpty ? "photo" : vectorQuery;

    // Pre-calculate query vector on main thread using the configured vectorizer
    final queryVector = (OptionalFeatures.vectorize != null)
        ? await OptionalFeatures.vectorize!(finalVectorQuery)
        : MediaVectorizer.vectorize(finalVectorQuery);

    // 2. Find all media IDs that contain ALL the mentioned person(s) (conjoint)
    final Set<String> personMediaIds = {};
    if (matchedPersonIds.isNotEmpty) {
      final Map<String, Set<String>> mediaByPerson = {};
      for (final pid in matchedPersonIds) {
        mediaByPerson[pid] = {};
      }
      for (final f in allFaces) {
        final pid = f['person_id'] as String?;
        final mid = f['media_id'] as String?;
        if (pid != null && mid != null && matchedPersonIds.contains(pid)) {
          mediaByPerson[pid]!.add(mid);
        }
      }

      bool first = true;
      for (final pid in matchedPersonIds) {
        final mids = mediaByPerson[pid] ?? {};
        if (first) {
          personMediaIds.addAll(mids);
          first = false;
        } else {
          personMediaIds.retainAll(mids);
        }
      }
    }

    final box = await ObjectBoxService.getBox();
    final Map<String, double> vectorScores = {};
    List<Map<String, dynamic>> candidateItems = [];

    if (box != null) {
      debugPrint('[UnifiedSearchService] Search type: ObjectBox vector search');
      // 3. Query HNSW Index in ObjectBox
      if (personMediaIds.isNotEmpty) {
        // Enforce conjoint constraint: only search within personMediaIds
        final candidateIds = personMediaIds.toList();
        if (candidateIds.isNotEmpty) {
          final qBuilder = box.query(MediaVector_.mediaId.oneOf(candidateIds)).build();
          final vectors = qBuilder.find();
          qBuilder.close();
          for (final mv in vectors) {
            final mvEmbedding = mv.embedding;
            if (mvEmbedding != null && mvEmbedding.length == queryVector.length) {
              final sim = MediaVectorizer.cosineSimilarity(queryVector, mvEmbedding).clamp(0.0, 1.0);
              vectorScores[mv.mediaId] = sim;
            }
          }
        }
        candidateItems = await db.getMediaItemsByIds(candidateIds);
      } else {
        // Normal search
        final queryBuilder = box.query(
          MediaVector_.embedding.nearestNeighborsF32(queryVector, maxResults * 5)
        );
        final queryObj = queryBuilder.build();
        final objectWithScores = queryObj.findWithScores();
        queryObj.close();

        for (final ows in objectWithScores) {
          final similarity = (1.0 - ows.score).clamp(0.0, 1.0);
          vectorScores[ows.object.mediaId] = similarity;
        }

        final candidateIds = vectorScores.keys.toList();
        candidateItems = await db.getMediaItemsByIds(candidateIds);
      }
    } else {
      debugPrint('[UnifiedSearchService] Search type: Simple fallback search (SQLite/Isolate)');
      // Fallback: load all items from SQLite, or just the filtered ones
      if (matchedPersonIds.isNotEmpty) {
        candidateItems = await db.getMediaItemsByIds(personMediaIds.toList());
      } else {
        candidateItems = await db.getAllMediaItems();
      }
    }

    final args = _SearchArgs(
      items:            candidateItems,
      faces:            allFaces,
      people:           allPeople,
      query:            finalVectorQuery,
      queryVector:      queryVector,
      vectorScores:     vectorScores,
      mediaTypeFilter:  mediaTypeFilter,
      locationFilter:   locationFilter,
      dateFilter:       dateFilter,
      maxResults:       maxResults,
      explicitPersonIds: matchedPersonIds.toList(),
    );

    return await compute(_searchIsolate, args);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ISOLATE ENTRY POINT
  // Everything below runs in a background isolate.
  // ═══════════════════════════════════════════════════════════════════════════

  static List<SearchResult> _searchIsolate(_SearchArgs args) {
    // ── Pre-build lookup maps (O(1) per photo later) ──────────────────────

    // media_id → list of person_ids appearing in it
    final Map<String, List<String>> personsByMedia = {};
    for (final f in args.faces) {
      final pid = f['person_id'] as String?;
      if (pid != null) {
        personsByMedia
            .putIfAbsent(f['media_id'] as String, () => [])
            .add(pid);
      }
    }

    // person_id → {name, relation} for name-matching in query
    final Map<String, Map<String, String>> peopleById = {};
    for (final p in args.people) {
      peopleById[p['id'] as String] = {
        'name':     (p['name']     as String? ?? '').toLowerCase(),
        'relation': (p['relation'] as String? ?? '').toLowerCase(),
      };
    }

    // ── Find which person IDs are mentioned in the query (soft fallback) ──
    final q = args.query.toLowerCase().trim();
    final Set<String> mentionedPersonIds = {};
    for (final entry in peopleById.entries) {
      final name     = entry.value['name']!;
      final relation = entry.value['relation']!;
      if (name.isNotEmpty     && q.contains(name))     mentionedPersonIds.add(entry.key);
      if (relation.isNotEmpty && q.contains(relation)) mentionedPersonIds.add(entry.key);
    }

    final Set<String> explicitPersonIdsSet = args.explicitPersonIds.toSet();

    // ── Score every item ──────────────────────────────────────────────────
    final scored = <SearchResult>[];

    for (final item in args.items) {
      // ── Hard filters first ──────────────────────────────────────────────
      if (args.mediaTypeFilter != null &&
          item['media_type'] != args.mediaTypeFilter) {
        continue;
      }

      if (args.locationFilter != null && args.locationFilter!.isNotEmpty) {
        final loc = (item['location'] as String? ?? '').toLowerCase();
        if (!loc.contains(args.locationFilter!.toLowerCase())) continue;
      }

      if (args.dateFilter != null && args.dateFilter!.isNotEmpty) {
        final d = (item['date'] as String? ?? '').toLowerCase();
        if (!d.contains(args.dateFilter!.toLowerCase())) continue;
      }

      final String id = item['id'] as String;

      // ── Signal A: ObjectBox or Fallback Vector Similarity ─────────────────
      double tagScore = 0.0;
      if (args.vectorScores.isNotEmpty) {
        tagScore = args.vectorScores[id] ?? 0.0;
      } else {
        final String? medStr = item['media_embedding'] as String?;
        if (medStr != null && medStr.isNotEmpty && args.queryVector.isNotEmpty) {
          final storedVec = _parseVector(medStr);
          if (storedVec.length == args.queryVector.length) {
            tagScore = MediaVectorizer.cosineSimilarity(args.queryVector, storedVec)
                .clamp(0.0, 1.0);
          }
        }
      }

      // ── Signal B: Person identity score ──────────────────────────────────
      double personScore = 0.0;
      if (explicitPersonIdsSet.isNotEmpty) {
        final photoPeople = personsByMedia[id] ?? [];
        final matchedAll = explicitPersonIdsSet.every((pid) => photoPeople.contains(pid));
        if (!matchedAll) continue; // Conjoint filter: must contain all mentioned people
        personScore = 1.0;
      } else if (mentionedPersonIds.isNotEmpty) {
        final photoPeople = personsByMedia[id] ?? [];
        final matched = photoPeople.any((pid) => mentionedPersonIds.contains(pid));
        personScore = matched ? 1.0 : 0.0;
      }

      // ── Weighted fusion ───────────────────────────────────────────────────
      final fused = (_wSimpleVector * tagScore)
                  + (_wPerson       * personScore);

      if (fused < _minScore) continue;

      scored.add(SearchResult(
        item:        item,
        score:       fused,
        debugReason: _reason(tagScore, personScore),
      ));

      if (scored.length >= args.maxResults * 2) break; // cap before sort
    }

    // ── Sort descending, cap ──────────────────────────────────────────────
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(args.maxResults).toList();
  }

  // ── Pure-Dart helpers (isolate-safe) ──────────────────────────────────────

  static List<double> _parseVector(String s) {
    try {
      return s.split(',').map((v) => double.tryParse(v) ?? 0.0).toList();
    } catch (_) {
      return [];
    }
  }

  static String _reason(double tag, double person) {
    final parts = <String>[];
    if (tag    > 0.30) parts.add('vectorMatch(${(tag    * 100).round()}%)');
    if (person > 0.0)  parts.add('person(${(person * 100).round()}%)');
    return parts.isEmpty ? 'weak match' : parts.join(' + ');
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SEARCH ARGS
// ═══════════════════════════════════════════════════════════════════════════

class _SearchArgs {
  final List<Map<String, dynamic>> items;
  final List<Map<String, dynamic>> faces;
  final List<Map<String, dynamic>> people;
  final String                     query;
  final List<double>               queryVector;
  final Map<String, double>        vectorScores;
  final String?                    mediaTypeFilter;
  final String?                    locationFilter;
  final String?                    dateFilter;
  final int                        maxResults;
  final List<String>               explicitPersonIds;

  const _SearchArgs({
    required this.items,
    required this.faces,
    required this.people,
    required this.query,
    required this.queryVector,
    required this.vectorScores,
    this.mediaTypeFilter,
    this.locationFilter,
    this.dateFilter,
    required this.maxResults,
    required this.explicitPersonIds,
  });
}