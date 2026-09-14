import 'dart:async';
import 'package:flutter/material.dart';
import '../models/gallery_item.dart';
import 'database_helper.dart';
import 'ml_processing_service.dart';
import 'optional_features.dart';
import 'unified_search_service.dart';

class SearchStateProvider extends ChangeNotifier {
  static final SearchStateProvider instance = SearchStateProvider._internal();
  SearchStateProvider._internal();

  bool isInitialized = false;
  bool isSearching = false;

  // Cached metadata and indices
  Map<String, String> ocrTexts = {};
  Map<String, Set<String>> tags = {};
  Map<String, Set<String>> mediaPeople = {};
  Map<String, String> mediaPeopleDetails = {};
  List<String> quickKeywords = [];
  List<MapEntry<String, int>> allSortedTags = [];
  List<MapEntry<String, List<GalleryItem>>> sortedPlaces = [];
  Map<String, List<GalleryItem>> typeGroups = {};

  // Active search query and filters
  String searchQuery = "";
  List<double>? queryVector;
  String? filterLocation;
  String? filterMediaType;
  int? filterRating;
  double filterMaxDuration = 60.0;
  String? filterDate;

  // Filtered search results
  List<GalleryItem> filteredItems = [];

  Future<void> loadSearchMetadata(List<GalleryItem> allItems, List<Map<String, dynamic>> peopleList, {bool force = false}) async {
    if (isInitialized && !force) return;

    final db = DatabaseHelper.instance;
    final ocrData = await db.getAllOcrTexts();
    final tagData = await db.getAllObjects();
    final faceData = await db.getAllFaces();

    // 1. Build fast pre-lowercased OCR lookup map
    final Map<String, String> tempOcr = {};
    for (final row in ocrData) {
      final mid = row['media_id'] as String;
      final text = row['text'] as String;
      tempOcr[mid] = "${tempOcr[mid] ?? ""} ${text.toLowerCase()}";
    }

    // 2. Build fast pre-lowercased Tag lookup map and count frequency
    final Map<String, Set<String>> tempTags = {};
    final Map<String, int> tagCounts = {};
    for (final row in tagData) {
      final mid = row['media_id'] as String;
      final label = row['label'] as String;
      tempTags.putIfAbsent(mid, () => {}).add(label.toLowerCase());
      tagCounts[label] = (tagCounts[label] ?? 0) + 1;
    }

    // 3. Build recognized person mapping per media item
    final peopleData = await db.getEligiblePeopleForUi();
    final Map<String, Map<String, dynamic>> peopleMap = {
      for (final p in peopleData) p['id'] as String: p,
    };

    final Map<String, Set<String>> tempMediaPeople = {};
    final Map<String, String> tempMediaPeopleDetails = {};
    for (final row in faceData) {
      final mid = row['media_id'] as String;
      final pid = row['person_id'] as String?;
      if (pid != null) {
        tempMediaPeople.putIfAbsent(mid, () => {}).add(pid);
        if (peopleMap.containsKey(pid)) {
          final person = peopleMap[pid]!;
          final name = (person['name'] as String? ?? '').toLowerCase();
          final dob = (person['dob'] as String? ?? '').toLowerCase();
          final relation = (person['relation'] as String? ?? '').toLowerCase();
          final existing = tempMediaPeopleDetails[mid] ?? "";
          tempMediaPeopleDetails[mid] = "$existing $name $dob $relation";
        }
      }
    }

    // Sort tags by frequency to find top occurring keywords
    final sortedTags = tagCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final quickKeywordsList = sortedTags.take(8).map((e) => e.key).toList();
    if (quickKeywordsList.isEmpty) {
      quickKeywordsList.addAll([
        "Ledger",
        "Airport",
        "Baby",
        "Sonepur",
        "Travel",
        "Finance",
      ]);
    }

    // Pre-calculate place groups and type groups once
    final Map<String, List<GalleryItem>> placeGroups = {};
    for (final item in allItems) {
      final loc = item.location.trim();
      if (loc.isNotEmpty && loc.toLowerCase() != 'unknown location') {
        final firstPart = loc.split(',').first.trim();
        placeGroups.putIfAbsent(firstPart, () => []).add(item);
      }
    }
    final sortedPlacesList = placeGroups.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));

    final Map<String, List<GalleryItem>> typeGroupsMap = {
      'Documents': allItems
          .where((x) => tempOcr[x.id]?.isNotEmpty ?? false)
          .toList(),
      'Food': allItems
          .where((x) => tempTags[x.id]?.contains('food') ?? false)
          .toList(),
      'Plants': allItems
          .where((x) => tempTags[x.id]?.contains('plant') ?? false)
          .toList(),
    };

    ocrTexts = tempOcr;
    tags = tempTags;
    mediaPeople = tempMediaPeople;
    mediaPeopleDetails = tempMediaPeopleDetails;
    quickKeywords = quickKeywordsList;
    allSortedTags = sortedTags;
    sortedPlaces = sortedPlacesList;
    typeGroups = typeGroupsMap;
    isInitialized = true;

    notifyListeners();
    performSearch(allItems, peopleList);
  }

  Future<void> updateQueryVector(String val) async {
    final regexBraces = RegExp(r'@{([^}]+)}');
    final regexPlain = RegExp(r'@([a-zA-Z0-9_\-]+)');
    String cleanVal = val.replaceAll(regexBraces, '').replaceAll(regexPlain, '').trim().replaceAll(RegExp(r'\s+'), ' ');

    if (cleanVal.isEmpty) {
      queryVector = null;
      notifyListeners();
      return;
    }

    final bool isMLRunning =
        MLProcessingService.instance.isProcessingNotifier.value;
    if (isMLRunning) {
      queryVector = null;
      notifyListeners();
      return;
    }

    final vec = OptionalFeatures.vectorize != null
        ? await OptionalFeatures.vectorize!(cleanVal)
        : MediaVectorizer.vectorize(cleanVal);
    queryVector = vec;
    notifyListeners();
  }

  Future<void> performSearch(List<GalleryItem> allItems, List<Map<String, dynamic>> peopleList) async {
    final queryText = searchQuery.trim();
    final hasQuery = queryText.isNotEmpty;
    final bool isMLRunning =
        MLProcessingService.instance.isProcessingNotifier.value;

    final regexBraces = RegExp(r'@{([^}]+)}');
    final regexPlain = RegExp(r'@([a-zA-Z0-9_\-]+)');

    String cleanText = queryText;
    final Set<String> matchedPersonIds = {};

    // Find braces matches
    for (final match in regexBraces.allMatches(queryText)) {
      final name = match.group(1)?.trim() ?? "";
      final person = peopleList.firstWhere(
        (p) => (p['name'] as String? ?? "").toLowerCase() == name.toLowerCase(),
        orElse: () => <String, dynamic>{},
      );
      if (person.isNotEmpty) {
        matchedPersonIds.add(person['id'] as String);
      }
    }
    cleanText = cleanText.replaceAll(regexBraces, '');

    // Find plain matches
    for (final match in regexPlain.allMatches(queryText)) {
      final name = match.group(1)?.replaceAll('_', ' ').trim() ?? "";
      final person = peopleList.firstWhere(
        (p) => (p['name'] as String? ?? "").toLowerCase() == name.toLowerCase() ||
               (p['name'] as String? ?? "").replaceAll(' ', '_').toLowerCase() == name.toLowerCase(),
        orElse: () => <String, dynamic>{},
      );
      if (person.isNotEmpty) {
        matchedPersonIds.add(person['id'] as String);
      }
    }
    cleanText = cleanText.replaceAll(regexPlain, '').trim().replaceAll(RegExp(r'\s+'), ' ');

    if (hasQuery) {
      isSearching = true;
      notifyListeners();
      try {
        final searchResults = await UnifiedSearchService.search(
          queryText,
          mediaTypeFilter: filterMediaType,
          locationFilter: filterLocation,
          dateFilter: filterDate,
          maxResults: 350,
        );

        final List<GalleryItem> results = [];
        for (final res in searchResults) {
          final id = res.item['id'] as String;
          final item = allItems.firstWhere(
            (x) => x.id == id,
            orElse: () => GalleryItem.fromMap(res.item),
          );

          if (filterRating != null && item.rating < filterRating!) {
            continue;
          }

          if (item.mediaType == 'video') {
            final dur = item.duration ?? 0.0;
            if (dur > (filterMaxDuration * 60.0)) continue;
          } else if (filterMediaType == 'video') {
            continue;
          }

          results.add(item);
        }

        if (searchQuery.trim() == queryText) {
          filteredItems = results;
          isSearching = false;
          notifyListeners();
        }
      } catch (e) {
        debugPrint("Error performing unified search: $e");
        isSearching = false;
        notifyListeners();
      }
    } else {
      // Fallback/standard local sync search when query is empty, or ML is running:
      final Map<String, double> similarities = {};
      List<double>? qVector = queryVector;
      if (cleanText.isNotEmpty && qVector == null && !isMLRunning) {
        qVector = MediaVectorizer.vectorize(cleanText);
      }

      final results = allItems.where((item) {
        // Query filter
        if (hasQuery) {
          // Enforce conjoint person filter if there are @ mentions
          if (matchedPersonIds.isNotEmpty) {
            final pSet = mediaPeople[item.id] ?? {};
            final matchedAll = matchedPersonIds.every((pid) => pSet.contains(pid));
            if (!matchedAll) return false;
          }

          if (cleanText.isNotEmpty) {
            final q = cleanText.toLowerCase();
            final path = item.imageUrl.toLowerCase();
            final desc = item.description.toLowerCase();
            final loc = item.location.toLowerCase();

            final ocr = ocrTexts[item.id] ?? "";
            final tagsSet = tags[item.id] ?? {};
            final peopleDetails = mediaPeopleDetails[item.id] ?? "";

            final bool hasTextMatch =
                path.contains(q) ||
                desc.contains(q) ||
                loc.contains(q) ||
                ocr.contains(q) ||
                tagsSet.contains(q) ||
                peopleDetails.contains(q);

            if (isMLRunning) {
              if (!hasTextMatch) return false;
              similarities[item.id] = 1.0;
            } else {
              final itemVector = item.mediaEmbedding;
              final double textSim = (itemVector != null && itemVector.isNotEmpty)
                  ? MediaVectorizer.cosineSimilarity(qVector!, itemVector)
                  : 0.0;

              final double threshold = OptionalFeatures.vectorize != null
                  ? 0.60
                  : 0.55;
              if (!hasTextMatch && textSim < threshold) {
                return false;
              }

              similarities[item.id] = textSim;
            }
          } else {
            similarities[item.id] = 1.0;
          }
        }

        // Location Filter
        if (filterLocation != null &&
            !item.location.toLowerCase().contains(
              filterLocation!.toLowerCase(),
            )) {
          return false;
        }

        // Media Type Filter
        if (filterMediaType != null && item.mediaType != filterMediaType) {
          return false;
        }

        // Rating Filter
        if (filterRating != null && item.rating < filterRating!) {
          return false;
        }

        // Max Video Duration Filter
        if (item.mediaType == 'video') {
          final dur = item.duration ?? 0.0;
          if (dur > (filterMaxDuration * 60.0)) return false;
        } else if (filterMediaType == 'video') {
          return false;
        }

        // Date Filter
        if (filterDate != null &&
            !item.date.toLowerCase().contains(filterDate!.toLowerCase())) {
          return false;
        }

        return true;
      }).toList();

      // Sort descending by similarity score if query is active, otherwise by modifiedTimestamp falling back to dateTimestamp
      if (hasQuery && cleanText.isNotEmpty) {
        results.sort((a, b) {
          final simA = similarities[a.id] ?? 0.0;
          final simB = similarities[b.id] ?? 0.0;
          return simB.compareTo(simA);
        });
      } else {
        results.sort((a, b) {
          final tsA = a.modifiedTimestamp ?? a.dateTimestamp;
          final tsB = b.modifiedTimestamp ?? b.dateTimestamp;
          return tsB.compareTo(tsA);
        });
      }

      filteredItems = results;
      notifyListeners();
    }
  }

  void clearSearchAndFilters(List<GalleryItem> allItems, List<Map<String, dynamic>> peopleList) {
    searchQuery = "";
    queryVector = null;
    filterLocation = null;
    filterMediaType = null;
    filterRating = null;
    filterDate = null;
    performSearch(allItems, peopleList);
  }
}
