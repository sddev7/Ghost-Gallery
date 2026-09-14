// ═══════════════════════════════════════════════════════════════════════════
// recommend_models.dart
//
// Data models for the Recommends tab:
//  - RecommendType: the 6 memory types
//  - RecommendItemType: what kind of item each group slot is
//  - RecommendItem: a single slot in a group
//  - RecommendGroup: a full memory group shown as a card in the tab
// ═══════════════════════════════════════════════════════════════════════════

enum RecommendType {
  birthdaySpecial,   // On birthday of a person
  onThisDay,         // Same date, prior years
  bestMoment,        // Top photo day in last 30 days
  highlight,         // Highlight on {person}
  bestTrip,          // Best trip photos of {year}
  recapPreviousYear, // Only in January
}

enum RecommendItemType {
  libraryMedia,    // Real photo from user library
  generatedVideo,  // Slideshow video made by algorithm
  collagePhoto,    // Collage grid image made by algorithm
  textPhoto,       // Library photo + text overlay
}

class RecommendItem {
  final String id;
  final RecommendItemType itemType;

  /// Populated for [RecommendItemType.libraryMedia] and [RecommendItemType.textPhoto]
  final String? sourceItemId;
  final String? sourceItemPath; // file path for display
  final String? originAlbumName;

  /// Populated for generated files (video / collage / textPhoto overlay)
  final String? generatedFilePath;
  final String? textOverlay; // text for textPhoto type

  const RecommendItem({
    required this.id,
    required this.itemType,
    this.sourceItemId,
    this.sourceItemPath,
    this.originAlbumName,
    this.generatedFilePath,
    this.textOverlay,
  });

  bool get isGenerated =>
      itemType == RecommendItemType.generatedVideo ||
      itemType == RecommendItemType.collagePhoto ||
      itemType == RecommendItemType.textPhoto;

  String? get displayPath => generatedFilePath ?? sourceItemPath;

  bool get isVideo =>
      itemType == RecommendItemType.generatedVideo ||
      (sourceItemPath != null && (
         sourceItemPath!.toLowerCase().endsWith('.mp4') ||
         sourceItemPath!.toLowerCase().endsWith('.mov') ||
         sourceItemPath!.toLowerCase().endsWith('.avi') ||
         sourceItemPath!.toLowerCase().endsWith('.mkv') ||
         sourceItemPath!.toLowerCase().endsWith('.wmv') ||
         sourceItemPath!.toLowerCase().endsWith('.3gp') ||
         sourceItemPath!.toLowerCase().endsWith('.webm')
      ));

  Map<String, dynamic> toMap() => {
        'id': id,
        'itemType': itemType.name,
        'sourceItemId': sourceItemId,
        'sourceItemPath': sourceItemPath,
        'originAlbumName': originAlbumName,
        'generatedFilePath': generatedFilePath,
        'textOverlay': textOverlay,
      };

  factory RecommendItem.fromMap(Map<String, dynamic> m) => RecommendItem(
        id: m['id'] as String,
        itemType: RecommendItemType.values.firstWhere(
          (e) => e.name == m['itemType'],
          orElse: () => RecommendItemType.libraryMedia,
        ),
        sourceItemId: m['sourceItemId'] as String?,
        sourceItemPath: m['sourceItemPath'] as String?,
        originAlbumName: m['originAlbumName'] as String?,
        generatedFilePath: m['generatedFilePath'] as String?,
        textOverlay: m['textOverlay'] as String?,
      );
}

class RecommendGroup {
  final String id;
  final RecommendType type;
  final String title;
  final String subtitle;
  final DateTime generatedAt;
  final DateTime expiresAt;
  final List<RecommendItem> items;

  /// Cover image path — first item's displayPath used for the grid card
  String? get coverPath => items.isNotEmpty ? items.first.displayPath : null;

  const RecommendGroup({
    required this.id,
    required this.type,
    required this.title,
    required this.subtitle,
    required this.generatedAt,
    required this.expiresAt,
    required this.items,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  String get typeEmoji {
    switch (type) {
      case RecommendType.birthdaySpecial:
        return '🎂';
      case RecommendType.onThisDay:
        return '📅';
      case RecommendType.bestMoment:
        return '✨';
      case RecommendType.highlight:
        return '👤';
      case RecommendType.bestTrip:
        return '✈️';
      case RecommendType.recapPreviousYear:
        return '🎉';
    }
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'type': type.name,
        'title': title,
        'subtitle': subtitle,
        'generatedAt': generatedAt.toIso8601String(),
        'expiresAt': expiresAt.toIso8601String(),
        'items': items.map((i) => i.toMap()).toList(),
      };

  factory RecommendGroup.fromMap(Map<String, dynamic> m) => RecommendGroup(
        id: m['id'] as String,
        type: RecommendType.values.firstWhere(
          (e) => e.name == m['type'],
          orElse: () => RecommendType.onThisDay,
        ),
        title: m['title'] as String,
        subtitle: m['subtitle'] as String,
        generatedAt: DateTime.parse(m['generatedAt'] as String),
        expiresAt: DateTime.parse(m['expiresAt'] as String),
        items: (m['items'] as List<dynamic>)
            .map((i) => RecommendItem.fromMap(i as Map<String, dynamic>))
            .toList(),
      );
}
