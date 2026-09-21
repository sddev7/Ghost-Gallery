import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../services/entitlement_service.dart';
import 'package:flutter/services.dart';
import '../../widgets/premium_gate.dart';
import '../../services/optional_features.dart';
import 'package:path_provider/path_provider.dart';
import '../../models/gallery_item.dart';
import '../../services/database_helper.dart';
import './fast_media_preview.dart';
import './video_preview_widget.dart';
import '../all_tags_screen.dart';
import '../tag_photos_screen.dart';
import '../all_people_screen.dart';
import '../people_management_screen.dart';
import '../all_places_screen.dart';
import '../../services/ml_processing_service.dart';
import 'package:share_plus/share_plus.dart';
import '../collage_creator_screen.dart';
import '../../services/trash_persistence.dart';
import '../../services/media_permission_service.dart';
import '../../widgets/grid_scale_overlay.dart';
import '../../services/ui_preference_provider.dart';
import 'package:ghost_gallery/widgets/add_to_album_dialog.dart';
import '../../widgets/photo_grid.dart';
import '../../services/burst_helper.dart';
import '../../services/unified_search_service.dart';
import '../../services/responsive_helper.dart';

class SearchTab extends StatefulWidget {
  final List<GalleryItem> allItems;
  final List<Map<String, dynamic>> peopleList;
  final Function(GalleryItem, [List<GalleryItem>?]) onItemTapped;

  const SearchTab({
    super.key,
    required this.allItems,
    required this.peopleList,
    required this.onItemTapped,
  });

  @override
  State<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<SearchTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  bool _isSelectionMode = false;
  final Set<String> _selectedItemIds = {};
  bool _isSearching = false;

  // Hint text loop variables
  Timer? _hintTimer;
  int _currentHintIndex = 0;

  // Suggestion overlay variables
  OverlayEntry? _suggestionOverlayEntry;
  final LayerLink _layerLink = LayerLink();

  // Drag Selection state
  final Map<String, BuildContext> _itemContexts = {};
  bool _isDraggingToSelect = false;
  String? _dragStartId;
  bool _dragSelectInitialState = true;
  Offset? _dragStartPosition;
  bool _dragDirectionDecided = false;
  int _pointerCount = 0;

  int _gridColumns = 3;
  double _scaleStartColumns = 3.0;
  OverlayEntry? _activeOverlayEntry;
  ValueNotifier<double>? _scaleNotifier;
  final ScrollController _scrollController = ScrollController();
  bool _columnHudVisible = false;
  Timer? _hudHideTimer;
  int _anchorItemIndex = 0;
  bool _pendingAnchorScroll = false;

  void _handleUIPreferencesChange() {
    if (mounted) {
      setState(() {
        _gridColumns = UIPreferenceProvider.instance.gridColumns;
      });
    }
  }

  String? _getItemIdAtPosition(Offset globalPos) {
    for (final entry in _itemContexts.entries) {
      final ctx = entry.value;
      if (!ctx.mounted) continue;
      final renderBox = ctx.findRenderObject() as RenderBox?;
      if (renderBox == null || !renderBox.hasSize) continue;
      final localPos = renderBox.globalToLocal(globalPos);
      if (localPos.dx >= 0 &&
          localPos.dx <= renderBox.size.width &&
          localPos.dy >= 0 &&
          localPos.dy <= renderBox.size.height) {
        return entry.key;
      }
    }
    return null;
  }

  void _updateDragSelection(String currentId, List<GalleryItem> items) {
    if (_dragStartId == null) return;
    final startIdx = items.indexWhere((x) => x.id == _dragStartId);
    final endIdx = items.indexWhere((x) => x.id == currentId);
    if (startIdx == -1 || endIdx == -1) return;

    final low = startIdx < endIdx ? startIdx : endIdx;
    final high = startIdx < endIdx ? endIdx : startIdx;

    final currentSelection = Set<String>.from(_selectedItemIds);
    bool changed = false;

    for (int i = low; i <= high; i++) {
      final id = items[i].id;
      if (_dragSelectInitialState) {
        if (!currentSelection.contains(id)) {
          currentSelection.add(id);
          changed = true;
        }
      } else {
        if (currentSelection.contains(id)) {
          currentSelection.remove(id);
          changed = true;
        }
      }
    }
    if (changed) {
      HapticFeedback.lightImpact();
      setState(() {
        _selectedItemIds.clear();
        _selectedItemIds.addAll(currentSelection);
        if (_selectedItemIds.isEmpty) {
          _isSelectionMode = false;
        } else {
          _isSelectionMode = true;
        }
      });
    }
  }

  bool get isSelectionMode => _isSelectionMode;
  void clearSelection() {
    setState(() {
      _isSelectionMode = false;
      _selectedItemIds.clear();
    });
  }

  bool get isSearchActive =>
      _searchQuery.isNotEmpty ||
      _filterLocation != null ||
      _filterMediaType != null ||
      _filterRating != null;

  void clearSearchAndFilters() {
    setState(() {
      _searchController.clear();
      _searchQuery = "";
      _queryVector = null;
      _filterLocation = null;
      _filterMediaType = null;
      _filterRating = null;
    });
    _performSearch();
  }

  final FocusNode _searchFocusNode = FocusNode();
  final TextEditingController _searchController = TaggingTextEditingController();
  String _searchQuery = "";
  List<double>? _queryVector;

  List<GalleryItem> _filteredItems = [];
  List<MapEntry<String, List<GalleryItem>>> _sortedPlaces = [];
  Map<String, List<GalleryItem>> _typeGroups = {};

  void _updateSearch(VoidCallback fn) {
    if (mounted) {
      setState(() {
        fn();
      });
      _performSearch();
    }
  }

  void _updateSearchFromDrawer(VoidCallback fn, StateSetter setDrawerState) {
    setDrawerState(() {
      fn();
    });
    _updateSearch(() {});
  }

  Future<void> _updateQueryVector(String val) async {
    final regexBraces = RegExp(r'@{([^}]+)}');
    final regexPlain = RegExp(r'@([a-zA-Z0-9_\-]+)');
    String cleanVal = val.replaceAll(regexBraces, '').replaceAll(regexPlain, '').trim().replaceAll(RegExp(r'\s+'), ' ');

    if (cleanVal.isEmpty) {
      if (mounted) {
        setState(() {
          _queryVector = null;
        });
        _performSearch();
      }
      return;
    }

    final bool isMLRunning =
        MLProcessingService.instance.isProcessingNotifier.value;
    if (isMLRunning) {
      if (mounted) {
        setState(() {
          _queryVector = null;
        });
        _performSearch();
      }
      return;
    }

    final vec = OptionalFeatures.vectorize != null
        ? await OptionalFeatures.vectorize!(cleanVal)
        : MediaVectorizer.vectorize(cleanVal);
    if (mounted) {
      setState(() {
        _queryVector = vec;
      });
      _performSearch();
    }
  }

  // Pre-compiled search indices for ultra-fast, zero-jank in-memory querying
  Map<String, String> _ocrTexts =
      {}; // mediaId -> lowercase consolidated OCR text
  Map<String, Set<String>> _tags = {}; // mediaId -> set of lowercase tags
  Map<String, Set<String>> _mediaPeople =
      {}; // mediaId -> set of recognized personIds
  Map<String, String> _mediaPeopleDetails =
      {}; // mediaId -> lowercase consolidated person details (name, dob, relation)
  List<String> _quickKeywords = [];
  List<String> _recentSearches = [];
  List<MapEntry<String, int>> _allSortedTags = [];

  Future<File> get _recentSearchesFile async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/recent_searches.json');
  }

  Future<void> _loadRecentSearches() async {
    try {
      final file = await _recentSearchesFile;
      if (await file.exists()) {
        final content = await file.readAsString();
        final List<dynamic> jsonList = jsonDecode(content);
        if (mounted) {
          setState(() {
            _recentSearches = jsonList.cast<String>();
          });
        }
      }
    } catch (e) {
      debugPrint("Error loading recent searches: $e");
    }
  }

  Future<void> _saveRecentSearches() async {
    try {
      final file = await _recentSearchesFile;
      final content = jsonEncode(_recentSearches);
      await file.writeAsString(content);
    } catch (e) {
      debugPrint("Error saving recent searches: $e");
    }
  }

  void _addSearchQueryToHistory(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    setState(() {
      _recentSearches.remove(trimmed);
      _recentSearches.insert(0, trimmed);
      if (_recentSearches.length > 10) {
        _recentSearches = _recentSearches.sublist(0, 10);
      }
    });
    _saveRecentSearches();
  }

  void _togglePersonTag(String name) {
    final currentText = _searchController.text.trim();
    final nameTag = '@${name.replaceAll(' ', '_')}';
    
    String newText;
    if (currentText.contains(nameTag)) {
      final escapedTag = RegExp.escape(nameTag);
      final rx = RegExp('$escapedTag\\s*');
      newText = currentText.replaceAll(rx, '').trim();
    } else {
      newText = currentText.isEmpty ? "$nameTag " : "$currentText $nameTag ";
    }
    
    _searchController.text = newText;
    _searchController.selection = TextSelection.fromPosition(
      TextPosition(offset: _searchController.text.length),
    );
    
    _updateSearch(() {
      _searchQuery = newText;
    });
    _updateQueryVector(newText);
  }

  KeyEventResult _handleSearchKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.backspace) {
      final text = _searchController.text;
      final selection = _searchController.selection;
      
      if (selection.isCollapsed && selection.baseOffset > 0) {
        final textBeforeCursor = text.substring(0, selection.baseOffset);
        final tagRegex = RegExp(r'@[a-zA-Z0-9_\-]+$');
        final match = tagRegex.firstMatch(textBeforeCursor);
        
        if (match != null) {
          final tagStart = match.start;
          final tagEnd = selection.baseOffset;
          
          final beforeTag = text.substring(0, tagStart + 1);
          final afterTag = text.substring(tagEnd);
          
          final newText = beforeTag + afterTag;
          final newCursorPos = tagStart + 1;
          
          _searchController.text = newText;
          _searchController.selection = TextSelection.fromPosition(
            TextPosition(offset: newCursorPos),
          );
          
          _updateSearch(() {
            _searchQuery = newText;
          });
          _updateQueryVector(newText);
          
          _onSearchTextChanged(newText);
          
          return KeyEventResult.handled;
        }
      }
    }
    return KeyEventResult.ignored;
  }

  String? _filterLocation;
  String? _filterMediaType;
  int? _filterRating;
  double _filterMaxDuration = 60.0;
  String? _filterDate;

  List<String> get _dynamicHintTexts {
    final List<String> hints = ["Mom's trip to Japan."];
    
    String personPlaceholder = "person_name";
    String secondPersonPlaceholder = "friend_name";
    if (widget.peopleList.isNotEmpty) {
      final p1 = widget.peopleList[0]['name'] as String? ?? '';
      if (p1.isNotEmpty && p1 != 'Unknown Person') {
        personPlaceholder = p1.replaceAll(' ', '_');
      }
      if (widget.peopleList.length > 1) {
        final p2 = widget.peopleList[1]['name'] as String? ?? '';
        if (p2.isNotEmpty && p2 != 'Unknown Person') {
          secondPersonPlaceholder = p2.replaceAll(' ', '_');
        }
      }
    }
    
    hints.add("Trip to Canada with @$personPlaceholder");
    hints.add("Beautiful sunset at the beach");
    hints.add("Delicious food with @$secondPersonPlaceholder");
    return hints;
  }

  void _startHintTimer() {
    _hintTimer = Timer.periodic(const Duration(seconds: 4), (timer) {
      if (mounted) {
        setState(() {
          _currentHintIndex = (_currentHintIndex + 1) % _dynamicHintTexts.length;
        });
      }
    });
  }

  void _onSearchTextChanged(String val) {
    setState(() {}); // updates suffix clear button visibility
    
    final text = _searchController.text;
    final selection = _searchController.selection;
    if (!selection.isValid) {
      _hideSuggestionOverlay();
      return;
    }
    
    final cursorPos = selection.baseOffset;
    if (cursorPos <= 0) {
      _hideSuggestionOverlay();
      return;
    }
    
    final textBeforeCursor = text.substring(0, cursorPos);
    final lastAtIndex = textBeforeCursor.lastIndexOf('@');
    
    if (lastAtIndex != -1) {
      final substring = textBeforeCursor.substring(lastAtIndex);
      if (!substring.contains(' ')) {
        final query = substring.substring(1).toLowerCase();
        _showSuggestionOverlay(query, lastAtIndex);
        return;
      }
    }
    
    _hideSuggestionOverlay();
  }

  void _showSuggestionOverlay(String query, int lastAtIndex) {
    _hideSuggestionOverlay();
    
    final cleanQuery = query.replaceAll('_', ' ').trim().toLowerCase();
    
    final filteredPeople = widget.peopleList.where((p) {
      final name = (p['name'] as String? ?? '').toLowerCase();
      final relation = (p['relation'] as String? ?? '').toLowerCase();
      if (name.isEmpty || name.contains('unknown')) {
        return false;
      }
      return name.contains(cleanQuery) || relation.contains(cleanQuery);
    }).toList();
    
    if (filteredPeople.isEmpty) {
      return;
    }
    
    final overlay = Overlay.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    _suggestionOverlayEntry = OverlayEntry(
      builder: (context) {
        return Positioned(
          width: MediaQuery.of(context).size.width - 32,
          child: CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            offset: const Offset(0, 56),
            child: TapRegion(
              groupId: 'search_suggestions_group',
              child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(16),
              color: isDark ? const Color(0xFF2C2424) : Colors.white,
              shadowColor: Colors.black.withValues(alpha: 0.2),
              child: Container(
                constraints: const BoxConstraints(maxHeight: 250),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isDark ? Colors.white10 : Colors.grey[200]!,
                    width: 1,
                  ),
                ),
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  itemCount: filteredPeople.length,
                  itemBuilder: (context, index) {
                    final p = filteredPeople[index];
                    final name = p['name'] as String? ?? '';
                    final relation = p['relation'] as String? ?? '';
                    final coverPath = p['cover_image'] as String?;
                    
                    return ListTile(
                      leading: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isDark ? Colors.white10 : Colors.grey[200],
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: coverPath != null &&
                               coverPath.isNotEmpty &&
                               File(coverPath).existsSync()
                            ? (p['cover_w'] != null && (p['cover_w'] as int? ?? 0) > 0
                                ? FacePreview(
                                    imagePath: coverPath,
                                    x: p['cover_x'] as int? ?? 0,
                                    y: p['cover_y'] as int? ?? 0,
                                    w: p['cover_w'] as int? ?? 0,
                                    h: p['cover_h'] as int? ?? 0,
                                  )
                                : Image.file(File(coverPath), fit: BoxFit.cover))
                            : Center(
                                child: Text(
                                  name.isNotEmpty ? name[0].toUpperCase() : '👤',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: isDark ? Colors.white : Colors.black87,
                                  ),
                                ),
                              ),
                      ),
                      title: Text(
                        name,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      subtitle: relation.isNotEmpty
                          ? Text(
                              relation,
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark ? Colors.white60 : Colors.black54,
                              ),
                            )
                          : null,
                      onTap: () {
                        final fullText = _searchController.text;
                        final before = fullText.substring(0, lastAtIndex);
                        final after = fullText.substring(_searchController.selection.baseOffset);
                        
                        final tag = '@${name.replaceAll(' ', '_')}';
                        final insertedText = "$before$tag $after";
                        
                        _searchController.text = insertedText;
                        _searchController.selection = TextSelection.fromPosition(
                          TextPosition(offset: before.length + tag.length + 1),
                        );
                        
                        _hideSuggestionOverlay();
                        
                        final newQuery = _searchController.text;
                        setState(() {
                          _searchQuery = newQuery;
                        });
                        _updateQueryVector(newQuery);
                      },
                    );
                  },
                ),
              ),
            ),
            ),
          ),
        );
      },
    );
    
    overlay.insert(_suggestionOverlayEntry!);
  }

  void _hideSuggestionOverlay() {
    _suggestionOverlayEntry?.remove();
    _suggestionOverlayEntry = null;
  }

  @override
  void initState() {
    super.initState();
    _loadSearchMetadata();
    _loadRecentSearches();
    _startHintTimer();
    _gridColumns = UIPreferenceProvider.instance.gridColumns;
    _scaleStartColumns = _gridColumns.toDouble();
    UIPreferenceProvider.instance.addListener(_handleUIPreferencesChange);
  }

  bool _areListsEqual(List<GalleryItem> a, List<GalleryItem> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      final itemA = a[i];
      final itemB = b[i];
      if (itemA.id != itemB.id ||
          itemA.modifiedTimestamp != itemB.modifiedTimestamp ||
          itemA.dateTimestamp != itemB.dateTimestamp ||
          itemA.rating != itemB.rating ||
          itemA.mediaType != itemB.mediaType ||
          itemA.duration != itemB.duration ||
          itemA.location != itemB.location ||
          itemA.description != itemB.description ||
          itemA.xmpSubjects != itemB.xmpSubjects ||
          itemA.imageUrl != itemB.imageUrl ||
          itemA.cameraInfo != itemB.cameraInfo) {
        return false;
      }
    }
    return true;
  }

  bool _arePeopleEqual(List<Map<String, dynamic>> a, List<Map<String, dynamic>> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i]['id'] != b[i]['id'] ||
          a[i]['name'] != b[i]['name'] ||
          a[i]['relation'] != b[i]['relation'] ||
          a[i]['cover_image'] != b[i]['cover_image']) {
        return false;
      }
    }
    return true;
  }

  @override
  void didUpdateWidget(SearchTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final itemsChanged = !_areListsEqual(oldWidget.allItems, widget.allItems);
    final peopleChanged = !_arePeopleEqual(oldWidget.peopleList, widget.peopleList);
    if (itemsChanged || peopleChanged) {
      _loadSearchMetadata();
    }
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    _hideSuggestionOverlay();
    UIPreferenceProvider.instance.removeListener(_handleUIPreferencesChange);
    _searchFocusNode.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadSearchMetadata() async {
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

    final quickKeywords = sortedTags.take(8).map((e) => e.key).toList();

    // Visual fallback default tags if background scanning has not completed yet
    if (quickKeywords.isEmpty) {
      quickKeywords.addAll([
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
    for (final item in widget.allItems) {
      final loc = item.location.trim();
      if (loc.isNotEmpty && loc.toLowerCase() != 'unknown location') {
        final firstPart = loc.split(',').first.trim();
        placeGroups.putIfAbsent(firstPart, () => []).add(item);
      }
    }
    final sortedPlaces = placeGroups.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));

    final Map<String, List<GalleryItem>> typeGroups = {
      'Documents': widget.allItems
          .where((x) => tempOcr[x.id]?.isNotEmpty ?? false)
          .toList(),
      'Food': widget.allItems
          .where((x) => tempTags[x.id]?.contains('food') ?? false)
          .toList(),
      'Plants': widget.allItems
          .where((x) => tempTags[x.id]?.contains('plant') ?? false)
          .toList(),
    };

    if (mounted) {
      setState(() {
        _ocrTexts = tempOcr;
        _tags = tempTags;
        _mediaPeople = tempMediaPeople;
        _mediaPeopleDetails = tempMediaPeopleDetails;
        _quickKeywords = quickKeywords;
        _allSortedTags = sortedTags;
        _sortedPlaces = sortedPlaces;
        _typeGroups = typeGroups;
      });
      _performSearch();
    }
  }

  List<GalleryItem> get _filtered => _filteredItems;

  Future<void> _performSearch() async {
    final queryText = _searchQuery.trim();
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
      final person = widget.peopleList.firstWhere(
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
      final person = widget.peopleList.firstWhere(
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
      if (mounted) {
        setState(() {
          _isSearching = true;
        });
      }
      try {
        final searchResults = await UnifiedSearchService.search(
          queryText,
          mediaTypeFilter: _filterMediaType,
          locationFilter: _filterLocation,
          dateFilter: _filterDate,
          maxResults: 350,
        );

        final List<GalleryItem> results = [];
        for (final res in searchResults) {
          final id = res.item['id'] as String;
          // Find matching item in widget.allItems or parse from map
          final item = widget.allItems.firstWhere(
            (x) => x.id == id,
            orElse: () => GalleryItem.fromMap(res.item),
          );

          if (_filterRating != null && item.rating < _filterRating!) {
            continue;
          }

          if (item.mediaType == 'video') {
            final dur = item.duration ?? 0.0;
            if (dur > (_filterMaxDuration * 60.0)) continue;
          } else if (_filterMediaType == 'video') {
            continue;
          }

          results.add(item);
        }

        if (mounted && _searchQuery.trim() == queryText) {
          setState(() {
            _filteredItems = results;
            _isSearching = false;
          });
        }
      } catch (e) {
        debugPrint("Error performing unified search: $e");
        if (mounted) {
          setState(() {
            _isSearching = false;
          });
        }
      }
    } else {
      // Fallback/standard local sync search when query is empty, or ML is running:
      final Map<String, double> similarities = {};
      List<double>? qVector = _queryVector;
      if (cleanText.isNotEmpty && qVector == null && !isMLRunning) {
        qVector = MediaVectorizer.vectorize(cleanText);
      }

      final results = widget.allItems.where((item) {
        // Query filter
        if (hasQuery) {
          // Enforce conjoint person filter if there are @ mentions
          if (matchedPersonIds.isNotEmpty) {
            final pSet = _mediaPeople[item.id] ?? {};
            final matchedAll = matchedPersonIds.every((pid) => pSet.contains(pid));
            if (!matchedAll) return false;
          }

          if (cleanText.isNotEmpty) {
            final q = cleanText.toLowerCase();
            final path = item.imageUrl.toLowerCase();
            final desc = item.description.toLowerCase();
            final loc = item.location.toLowerCase();

            final ocr = _ocrTexts[item.id] ?? "";
            final tagsSet = _tags[item.id] ?? {};
            final peopleDetails = _mediaPeopleDetails[item.id] ?? "";

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
        if (_filterLocation != null &&
            !item.location.toLowerCase().contains(
              _filterLocation!.toLowerCase(),
            )) {
          return false;
        }

        // Media Type Filter
        if (_filterMediaType != null && item.mediaType != _filterMediaType) {
          return false;
        }

        // Rating Filter
        if (_filterRating != null && item.rating < _filterRating!) {
          return false;
        }

        // Max Video Duration Filter
        if (item.mediaType == 'video') {
          final dur = item.duration ?? 0.0;
          if (dur > (_filterMaxDuration * 60.0)) return false;
        } else if (_filterMediaType == 'video') {
          return false;
        }

        // Date Filter
        if (_filterDate != null &&
            !item.date.toLowerCase().contains(_filterDate!.toLowerCase())) {
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

      if (mounted) {
        setState(() {
          _filteredItems = results;
        });
      }
    }
  }

  void _shareSelectedItems() {
    final List<XFile> filesToShare = [];
    for (final id in _selectedItemIds) {
      try {
        final item = _filteredItems.firstWhere((x) => x.id == id);
        final file = File(item.imageUrl);
        if (file.existsSync()) {
          filesToShare.add(XFile(file.path));
        }
      } catch (_) {}
    }
    if (filesToShare.isNotEmpty) {
      Share.shareXFiles(filesToShare);
      setState(() {
        _isSelectionMode = false;
        _selectedItemIds.clear();
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No local files available to send.')),
      );
    }
  }

  Future<void> _deleteSelectedItems() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Move to Trash?'),
        content: Text(
          'Move ${_selectedItemIds.length} item(s) to Recently Deleted?\n\nTrash files will be permanently deleted after 30 days.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Move to Trash',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final itemsToDelete = <GalleryItem>[];
    for (final id in _selectedItemIds) {
      try {
        final item = _filteredItems.firstWhere((x) => x.id == id);
        itemsToDelete.add(item);
      } catch (_) {}
    }
    final List<String> toTrashIds = itemsToDelete.map((e) => e.id).toList();
    if (itemsToDelete.isNotEmpty) {
      await MediaPermissionService.softDeleteWithPermission(
        context,
        itemsToDelete,
      );
    }

    setState(() {
      _filteredItems.removeWhere((item) => _selectedItemIds.contains(item.id));
      _isSelectionMode = false;
      _selectedItemIds.clear();
    });

    if (mounted && toTrashIds.isNotEmpty) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          backgroundColor: Colors.transparent,
          elevation: 0,
          content: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white10),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                const Icon(Icons.delete_outline, color: Colors.white70),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Moved ${toTrashIds.length} item(s) to Recently Deleted.',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    }
                    try {
                      final hasNative = itemsToDelete.any(
                        (i) =>
                            !i.id.startsWith('win_') &&
                            !i.id.startsWith('imported_') &&
                            !i.id.startsWith('captured_'),
                      );
                      if (hasNative && Platform.isAndroid && context.mounted) {
                        final granted =
                            await MediaPermissionService.ensureManageMediaPermission(
                              context,
                            );
                        if (!granted) return;
                      }

                      await MediaPermissionService.showBatchProgressDialog(
                        context: context,
                        title: "Restoring Media Files",
                        totalCount: toTrashIds.length,
                        action: (onProgress) => TrashPersistence.restore(
                          toTrashIds,
                          context: context,
                          onProgress: onProgress,
                        ),
                      );
                    } catch (e) {
                      debugPrint('Undo restore error: $e');
                    }
                    if (mounted) {
                      setState(() {
                        for (final item in itemsToDelete) {
                          if (!_filteredItems.any((x) => x.id == item.id)) {
                            _filteredItems.add(item);
                          }
                          if (!widget.allItems.any((x) => x.id == item.id)) {
                            widget.allItems.add(item);
                          }
                        }
                      });
                      _performSearch();
                    }
                  },
                  child: const Text(
                    'UNDO',
                    style: TextStyle(
                      color: Colors.blueAccent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
  }

  Future<void> _addSelectedItemsToAlbum() async {
    AddToAlbumDialog.show(
      context,
      _selectedItemIds.toList(),
      onComplete: () {
        if (mounted) {
          setState(() {
            _isSelectionMode = false;
            _selectedItemIds.clear();
          });
        }
      },
    );
  }

  void _createCollageFromSelected() async {
    final List<GalleryItem> items = [];
    for (final id in _selectedItemIds) {
      try {
        final item = _filteredItems.firstWhere((x) => x.id == id);
        items.add(item);
      } catch (_) {}
    }

    if (items.isEmpty) return;

    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CollageCreatorScreen(selectedItems: items),
      ),
    );

    if (created == true) {
      setState(() {
        _isSelectionMode = false;
        _selectedItemIds.clear();
      });
    }
  }

  void _secureSelectedItems() async {
    final List<GalleryItem> selectedItems = [];
    for (final id in _selectedItemIds) {
      try {
        final item = _filteredItems.firstWhere((x) => x.id == id);
        selectedItems.add(item);
      } catch (_) {}
    }
    if (selectedItems.isEmpty) return;

    await MediaPermissionService.secureMediaWithPermission(
      context,
      selectedItems,
      () {
        if (mounted) {
          setState(() {
            _filteredItems.removeWhere(
              (item) => _selectedItemIds.contains(item.id),
            );
            widget.allItems.removeWhere(
              (item) => _selectedItemIds.contains(item.id),
            );
            _isSelectionMode = false;
            _selectedItemIds.clear();
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Media moved to Secure Vault.')),
          );
          _performSearch();
        }
      },
    );
  }

  Widget _buildFloatingSelectionBar() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark
        ? const Color(0xFF1E1E24).withValues(alpha: 0.9)
        : Colors.white.withValues(alpha: 0.9);
    final borderColor = isDark ? Colors.white10 : Colors.black12;

    return Material(
      color: Colors.transparent,
      child: Container(
        height: 70,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: borderColor, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 15,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildSelectionActionItem(
              icon: Icons.share_outlined,
              label: "Send",
              onTap: _shareSelectedItems,
            ),
            _buildSelectionActionItem(
              icon: Icons.delete_outline,
              label: "Delete",
              onTap: _deleteSelectedItems,
              color: Colors.redAccent,
            ),
            _buildSelectionActionItem(
              icon: Icons.lock_outline,
              label: "Secure",
              onTap: _secureSelectedItems,
            ),
            _buildSelectionActionItem(
              icon: Icons.create_new_folder_outlined,
              label: "Add to Album",
              onTap: _addSelectedItemsToAlbum,
            ),
            _buildSelectionActionItem(
              icon: Icons.dashboard_customize_outlined,
              label: "Collage",
              onTap: _createCollageFromSelected,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectionActionItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    final activeColor =
        color ??
        (Theme.of(context).brightness == Brightness.dark
            ? Colors.white
            : Colors.black87);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: activeColor, size: 22),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: activeColor,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showHud() {
    _hudHideTimer?.cancel();
    if (!_columnHudVisible) setState(() => _columnHudVisible = true);
    _hudHideTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _columnHudVisible = false);
    });
  }

  void _hideHudAfterDelay() {
    _hudHideTimer?.cancel();
    _hudHideTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _columnHudVisible = false);
    });
  }

  void _captureAnchor(List<GalleryItem> imageItems) {
    try {
      final sc = _scrollController;
      if (!sc.hasClients) return;
      final viewportMidY = sc.offset + sc.position.viewportDimension / 2;
      double bestDist = double.infinity;
      String? bestId;
      for (final entry in _itemContexts.entries) {
        final ctx = entry.value;
        if (!ctx.mounted) continue;
        final rb = ctx.findRenderObject() as RenderBox?;
        if (rb == null || !rb.hasSize) continue;
        final globalTop = rb.localToGlobal(Offset.zero).dy + sc.offset;
        final midY = globalTop + rb.size.height / 2;
        final dist = (midY - viewportMidY).abs();
        if (dist < bestDist) {
          bestDist = dist;
          bestId = entry.key;
        }
      }
      if (bestId != null) {
        final idx = imageItems.indexWhere((x) => x.id == bestId);
        if (idx != -1) _anchorItemIndex = idx;
      }
    } catch (_) {}
  }

  void _restoreAnchor(List<GalleryItem> imageItems, int columns) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pendingAnchorScroll = false;
      try {
        final sc = _scrollController;
        if (!sc.hasClients) return;
        if (_anchorItemIndex >= imageItems.length) return;
        final anchorId = imageItems[_anchorItemIndex].id;
        final ctx = _itemContexts[anchorId];
        if (ctx == null || !ctx.mounted) return;
        final rb = ctx.findRenderObject() as RenderBox?;
        if (rb == null || !rb.hasSize) return;
        final globalTop = rb.localToGlobal(Offset.zero).dy;
        final currentOffset = sc.offset;
        final desiredOffset = currentOffset +
            globalTop -
            sc.position.viewportDimension / 2 +
            rb.size.height / 2;
        sc.jumpTo(desiredOffset.clamp(0.0, sc.position.maxScrollExtent));
      } catch (_) {}
    });
  }

  List<_FlatSearchItem> _buildFlatList(
    double screenWidth,
    List<GalleryItem> items,
  ) {
    final List<_FlatSearchItem> flat = [];
    if (items.isEmpty) return flat;
    final double maxWidth = screenWidth - 32; // 16 padding on each side
    const double spacing = 3.0;
    final columns = ResponsiveHelper.responsiveGridColumns(
      context,
      baseColumns: _gridColumns,
      min: 1,
      max: 10,
    );

    if (columns == 1) {
      flat.add(_FlatSearchRowItem(
        [items.first],
        1,
        0,
        customAspectRatio: 4 / 3,
      ));

      for (int i = 1; i < items.length; i += 2) {
        final end = (i + 2 < items.length) ? i + 2 : items.length;
        flat.add(_FlatSearchRowItem(
          items.sublist(i, end),
          2,
          (i - 1) ~/ 2 + 1,
          customAspectRatio: 1.0,
        ));
      }
    } else if (columns == 3) {
      final double targetHeight = maxWidth / 3;
      List<GalleryItem> currentRow = [];
      double currentAspectRatioSum = 0.0;
      int rowIndex = 0;

      for (final item in items) {
        double ratio = item.displayAspectRatio;
        if (ratio <= 0) ratio = 1.0;
        ratio = ratio.clamp(0.5, 2.0);

        currentRow.add(item);
        currentAspectRatioSum += ratio;

        double estimatedWidth = targetHeight * currentAspectRatioSum + spacing * (currentRow.length - 1);
        if (estimatedWidth >= maxWidth) {
          double usableWidth = maxWidth - spacing * (currentRow.length - 1);
          double actualHeight = usableWidth / currentAspectRatioSum;
          actualHeight = actualHeight.clamp(targetHeight * 0.6, targetHeight * 1.5);

          flat.add(_FlatSearchJustifiedRowItem(
            currentRow,
            actualHeight,
            rowIndex++,
          ));

          currentRow = [];
          currentAspectRatioSum = 0.0;
        }
      }

      if (currentRow.isNotEmpty) {
        flat.add(_FlatSearchJustifiedRowItem(
          currentRow,
          targetHeight,
          rowIndex,
          isLastRow: true,
        ));
      }
    } else {
      for (int i = 0; i < items.length; i += columns) {
        final end = (i + columns < items.length) ? i + columns : items.length;
        flat.add(_FlatSearchRowItem(
          items.sublist(i, end),
          columns,
          i ~/ columns,
        ));
      }
    }
    return flat;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subTextColor = isDark ? Colors.white60 : Colors.black54;

    final filtered = _filtered;
    final bool isSearchActive =
        _searchQuery.isNotEmpty ||
        _filterLocation != null ||
        _filterMediaType != null;

    final sortedPlaces = _sortedPlaces;
    final Map<String, List<GalleryItem>> typeGroups = Map.from(_typeGroups);
    if (typeGroups['Food'] == null) typeGroups['Food'] = [];
    if (typeGroups['Plants'] == null) typeGroups['Plants'] = [];
    if (typeGroups['Documents'] == null) typeGroups['Documents'] = [];

    // If Food or Plants dynamically evaluated lists are empty, let's provide visual fallback items from categories
    if (typeGroups['Food']!.isEmpty) {
      typeGroups['Food'] = widget.allItems
          .where((x) => x.category.toLowerCase().contains('photo'))
          .take(1)
          .toList();
    }
    if (typeGroups['Plants']!.isEmpty) {
      typeGroups['Plants'] = widget.allItems
          .where((x) => x.category.toLowerCase().contains('photo'))
          .take(2)
          .toList();
    }

    final double screenWidth = MediaQuery.of(context).size.width;
    final List<_FlatSearchItem> flatItems = _buildFlatList(screenWidth, filtered);

    final burstMap = <String, int>{};
    for (final item in widget.allItems) {
      final key = BurstHelper.getBurstGroupKey(item);
      if (key != null) {
        burstMap[key] = (burstMap[key] ?? 0) + 1;
      }
    }

    return Stack(
      children: [
        Positioned.fill(
          child: Listener(
            onPointerDown: (event) {
              setState(() => _pointerCount++);
              if (_isSelectionMode && _pointerCount == 1) {
                final id = _getItemIdAtPosition(event.position);
                if (id != null) {
                  _dragStartId = id;
                  _dragStartPosition = event.position;
                  _dragDirectionDecided = false;
                  _isDraggingToSelect = false;
                  _dragSelectInitialState = !_selectedItemIds.contains(id);
                }
              }
            },
            onPointerMove: (event) {
              if (_dragStartId != null && _pointerCount == 1) {
                if (!_dragDirectionDecided && _dragStartPosition != null) {
                  final dx = event.position.dx - _dragStartPosition!.dx;
                  final dy = event.position.dy - _dragStartPosition!.dy;
                  if (dx.abs() > 10 || dy.abs() > 10) {
                    _dragDirectionDecided = true;
                    if (dx.abs() > dy.abs()) {
                      setState(() {
                        _isDraggingToSelect = true;
                      });
                    } else {
                      _isDraggingToSelect = false;
                    }
                  }
                }

                if (_isDraggingToSelect) {
                  final id = _getItemIdAtPosition(event.position);
                  if (id != null) {
                    _updateDragSelection(id, filtered);
                  }
                }
              }
            },
            onPointerUp: (_) {
              setState(() {
                _pointerCount = (_pointerCount - 1).clamp(0, 99);
              });
              _isDraggingToSelect = false;
              _dragStartId = null;
              _dragStartPosition = null;
              _dragDirectionDecided = false;
            },
            onPointerCancel: (_) {
              setState(() {
                _pointerCount = (_pointerCount - 1).clamp(0, 99);
              });
              _isDraggingToSelect = false;
              _dragStartId = null;
              _dragStartPosition = null;
              _dragDirectionDecided = false;
            },
            child: GestureDetector(
              onScaleStart: (details) {
                if (_pointerCount >= 2) {
                  _scaleStartColumns = _gridColumns.toDouble();
                  _captureAnchor(filtered);
                  final activeItemId = _getItemIdAtPosition(details.focalPoint);
                  if (activeItemId != null) {
                    try {
                      final activeItem = filtered.firstWhere(
                        (x) => x.id == activeItemId,
                      );
                      final ctx = _itemContexts[activeItemId];
                      if (ctx != null && ctx.mounted) {
                        final renderBox =
                            ctx.findRenderObject() as RenderBox?;
                        if (renderBox != null && renderBox.hasSize) {
                          final startingSize = renderBox.size;
                          final startingPosition = renderBox.localToGlobal(
                            Offset.zero,
                          );
                          _scaleNotifier = ValueNotifier<double>(1.0);
                          _activeOverlayEntry = OverlayEntry(
                            builder: (context) => GridScaleOverlay(
                              item: activeItem,
                              startingPosition: startingPosition,
                              startingSize: startingSize,
                              focalPoint: details.focalPoint,
                              scaleNotifier: _scaleNotifier!,
                            ),
                          );
                          Overlay.of(context).insert(_activeOverlayEntry!);
                          _scaleStartColumns = _gridColumns.toDouble();
                        }
                      }
                    } catch (e) {
                      debugPrint('Scale start error: $e');
                    }
                  }
                }
              },
              onScaleUpdate: (details) {
                if (_pointerCount >= 2) {
                  if (_scaleNotifier != null) {
                    _scaleNotifier!.value = details.scale.clamp(0.5, 2.5);
                  }
                  int target = _gridColumns;
                  if (details.scale > 1.35) {
                    target = (_scaleStartColumns - 1).clamp(2.0, 6.0).toInt();
                  } else if (details.scale < 0.68) {
                    target = (_scaleStartColumns + 1).clamp(2.0, 6.0).toInt();
                  }
                  if (target != _gridColumns) {
                    _captureAnchor(filtered);
                    UIPreferenceProvider.instance.setGridColumns(target);
                    _pendingAnchorScroll = true;
                    _showHud();
                  }
                }
              },
              onScaleEnd: (details) {
                _activeOverlayEntry?.remove();
                _activeOverlayEntry = null;
                _scaleNotifier?.dispose();
                _scaleNotifier = null;
                _hideHudAfterDelay();
                if (_pendingAnchorScroll) {
                  _restoreAnchor(filtered, _gridColumns);
                }
              },
              child: CustomScrollView(
                controller: _scrollController,
                physics: (_pointerCount >= 2 || _isDraggingToSelect)
                    ? const NeverScrollableScrollPhysics()
                    : const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(),
                      ),
                slivers: [
                  // 2. Flat Search Bar Input Field
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? Colors.white.withValues(alpha: 0.08)
                                        : Colors.grey[100],
                                    borderRadius: BorderRadius.circular(28),
                                  ),
                                  child: CompositedTransformTarget(
                                    link: _layerLink,
                                    child: TapRegion(
                                      groupId: 'search_suggestions_group',
                                      onTapOutside: (event) {
                                        FocusScope.of(context).unfocus();
                                        _hideSuggestionOverlay();
                                      },
                                      child: Focus(
                                        onKeyEvent: _handleSearchKeyEvent,
                                        child: TextField(
                                          focusNode: _searchFocusNode,
                                          controller: _searchController,
                                          textInputAction: TextInputAction.search,
                                          onChanged: (val) {
                                            _onSearchTextChanged(val);
                                          },
                                          onSubmitted: (val) {
                                            _hideSuggestionOverlay();
                                            setState(() => _searchQuery = val);
                                            _updateQueryVector(val);
                                            _addSearchQueryToHistory(val);
                                          },
                                          style: TextStyle(color: textColor, fontSize: 15),
                                          decoration: InputDecoration(
                                            hintText: _dynamicHintTexts[_currentHintIndex],
                                            hintStyle: TextStyle(
                                              color: subTextColor.withValues(alpha: 0.6),
                                              fontSize: 15,
                                            ),
                                            prefixIcon: IconButton(
                                              icon: Icon(
                                                Icons.search,
                                                color: subTextColor.withValues(alpha: 0.8),
                                              ),
                                              onPressed: () {
                                                _hideSuggestionOverlay();
                                                final val = _searchController.text;
                                                setState(() => _searchQuery = val);
                                                _updateQueryVector(val);
                                                _addSearchQueryToHistory(val);
                                              },
                                            ),
                                            suffixIcon: _searchController.text.isNotEmpty
                                                ? IconButton(
                                                    icon: Icon(
                                                      Icons.clear,
                                                      color: subTextColor,
                                                    ),
                                                    onPressed: () {
                                                      _hideSuggestionOverlay();
                                                      _searchController.clear();
                                                      _updateSearch(() {
                                                        _searchQuery = "";
                                                        _queryVector = null;
                                                      });
                                                    },
                                                  )
                                                : null,
                                            border: InputBorder.none,
                                            contentPadding: const EdgeInsets.symmetric(
                                              vertical: 14,
                                              horizontal: 16,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                icon: Icon(Icons.tune, color: textColor),
                                onPressed: _showAdvancedFilterDrawer,
                              ),
                            ],
                          ),
                        ),
                        // Active Filter Chips
                        (() {
                          final regexBraces = RegExp(r'@{([^}]+)}');
                          final regexPlain = RegExp(r'@([a-zA-Z0-9_\-]+)');
                          final List<String> tagNames = [];
                          for (final match in regexBraces.allMatches(_searchQuery)) {
                            tagNames.add(match.group(1)?.trim() ?? "");
                          }
                          for (final match in regexPlain.allMatches(_searchQuery)) {
                            tagNames.add(match.group(1)?.replaceAll('_', ' ').trim() ?? "");
                          }

                          if (_filterLocation == null &&
                              _filterMediaType == null &&
                              _filterRating == null &&
                              tagNames.isEmpty) {
                            return const SizedBox.shrink();
                          }

                          return Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 4,
                            ),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  Text(
                                    "Active filters: ",
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: subTextColor,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  for (final tagName in tagNames) ...[
                                    _buildCustomFilterChip(
                                      label: tagName,
                                      icon: Icons.face,
                                      onClear: () {
                                        final escapedTagName = RegExp.escape(tagName);
                                        final rxBraces = RegExp('@\\{$escapedTagName\\}');
                                        final rxPlain = RegExp('@${escapedTagName.replaceAll(' ', '_')}');

                                        final currentText = _searchController.text;
                                        String newText = currentText.replaceAll(rxBraces, '').replaceAll(rxPlain, '');
                                        newText = newText.trim().replaceAll(RegExp(r'\s+'), ' ');

                                        _searchController.text = newText;
                                        _searchController.selection = TextSelection.fromPosition(
                                          TextPosition(offset: _searchController.text.length),
                                        );
                                        _updateSearch(() {
                                          _searchQuery = newText;
                                        });
                                        _updateQueryVector(newText);
                                      },
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  if (_filterLocation != null) ...[
                                    _buildCustomFilterChip(
                                      label: _filterLocation!,
                                      icon: Icons.place,
                                      onClear: () =>
                                          _updateSearch(() => _filterLocation = null),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  if (_filterMediaType != null) ...[
                                    _buildCustomFilterChip(
                                      label: _filterMediaType == 'image'
                                          ? 'Photos'
                                          : 'Videos',
                                      icon: _filterMediaType == 'image'
                                          ? Icons.image
                                          : Icons.videocam,
                                      onClear: () => _updateSearch(
                                        () => _filterMediaType = null,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  if (_filterRating != null) ...[
                                    _buildCustomFilterChip(
                                      label: '$_filterRating★ & up',
                                      icon: Icons.star_rounded,
                                      onClear: () =>
                                          _updateSearch(() => _filterRating = null),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  TextButton(
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      minimumSize: Size.zero,
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    onPressed: () {
                                      _searchController.clear();
                                      _updateSearch(() {
                                        _searchQuery = "";
                                        _queryVector = null;
                                        _filterLocation = null;
                                        _filterMediaType = null;
                                        _filterRating = null;
                                        _filterMaxDuration = 60.0;
                                        _filterDate = null;
                                      });
                                    },
                                    child: const Text(
                                      "Clear all",
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.redAccent,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        })(),
                      ],
                    ),
                  ),

                  if (isSearchActive) ...[
                    // 3. Search Results grid display
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                      sliver: SliverToBoxAdapter(
                        child: Row(
                          children: [
                            Text(
                              "Search results",
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: textColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_isSearching)
                      SliverToBoxAdapter(
                        child: Container(
                          padding: const EdgeInsets.all(40),
                          alignment: Alignment.center,
                          child: const CircularProgressIndicator(),
                        ),
                      )
                    else if (filtered.isEmpty)
                      SliverToBoxAdapter(
                        child: Container(
                          padding: const EdgeInsets.all(40),
                          alignment: Alignment.center,
                          child: Text(
                            "No search results found! Try adjustments.",
                            style: TextStyle(color: subTextColor),
                          ),
                        ),
                      )
                    else
                      SliverList.builder(
                        itemCount: flatItems.length,
                        itemBuilder: (context, index) {
                          final flatItem = flatItems[index];
                          if (flatItem is _FlatSearchRowItem) {
                            final rowItems = flatItem.items;
                            final columns = flatItem.columns;

                            final double aspectRatio = flatItem.customAspectRatio ?? (
                                columns <= 1
                                    ? 4 / 3
                                    : columns == 2
                                        ? 0.90
                                        : columns == 3
                                            ? 1.0
                                            : columns == 4
                                                ? 1.15
                                                : columns == 5
                                                    ? 1.25
                                                    : 1.0
                            );

                            return Padding(
                              padding: const EdgeInsets.only(
                                left: 16,
                                right: 16,
                                bottom: 3.0,
                              ),
                              child: Row(
                                children: List.generate(columns, (colIndex) {
                                  if (colIndex >= rowItems.length) {
                                    return const Expanded(child: SizedBox.shrink());
                                  }
                                  final item = rowItems[colIndex];

                                  int burstCount = burstMap[BurstHelper.getBurstGroupKey(item) ?? ''] ?? 1;

                                  return Expanded(
                                    child: Padding(
                                      padding: EdgeInsets.only(
                                        right: colIndex == columns - 1 ? 0 : 3,
                                      ),
                                      child: AspectRatio(
                                        aspectRatio: aspectRatio,
                                        child: PremiumGate(
                                          borderRadius: BorderRadius.circular(columns >= 5 ? 6.0 : columns == 4 ? 8.0 : 10.0),
                                          child: PhotoGridTile(
                                            key: ValueKey(item.id),
                                            item: item,
                                            isSelected: _selectedItemIds.contains(item.id),
                                            isSelectionMode: _isSelectionMode,
                                            isBurstRepresentative: burstCount > 1,
                                            burstCount: burstCount,
                                            borderRadius: columns >= 5 ? 6.0 : columns == 4 ? 8.0 : 10.0,
                                            onTap: () async {
                                              if (_isSelectionMode) {
                                                HapticFeedback.lightImpact();
                                                setState(() {
                                                  if (_selectedItemIds.contains(item.id)) {
                                                    _selectedItemIds.remove(item.id);
                                                    if (_selectedItemIds.isEmpty) {
                                                      _isSelectionMode = false;
                                                    }
                                                  } else {
                                                    _selectedItemIds.add(item.id);
                                                  }
                                                });
                                              } else {
                                                widget.onItemTapped(item, filtered);
                                              }
                                            },
                                            onLongPress: () {
                                              if (!_isSelectionMode) {
                                                HapticFeedback.lightImpact();
                                                setState(() {
                                                  _isSelectionMode = true;
                                                  _selectedItemIds.add(item.id);
                                                });
                                              }
                                            },
                                            onContextReady: (ctx) => _itemContexts[item.id] = ctx,
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                }),
                              ),
                            );
                          } else if (flatItem is _FlatSearchJustifiedRowItem) {
                            final rowItems = flatItem.items;
                            final height = flatItem.height;
                            final isLastRow = flatItem.isLastRow;

                            const double spacing = 3.0;

                            final List<double> ratios = rowItems.map((item) {
                              double ratio = item.displayAspectRatio;
                              if (ratio <= 0) ratio = 1.0;
                              return ratio.clamp(0.5, 2.0);
                            }).toList();

                            final double aspectSum = ratios.fold(0.0, (sum, r) => sum + r);
                            final double maxWidth = screenWidth - 32;

                            List<double> widths = [];
                            if (isLastRow) {
                              for (final r in ratios) {
                                widths.add(height * r);
                              }
                              double totalWidth = widths.fold(0.0, (sum, w) => sum + w) + spacing * (rowItems.length - 1);
                              if (totalWidth > maxWidth) {
                                double scale = (maxWidth - spacing * (rowItems.length - 1)) / (totalWidth - spacing * (rowItems.length - 1));
                                widths = widths.map((w) => w * scale).toList();
                              }
                            } else {
                              double usableWidth = maxWidth - spacing * (rowItems.length - 1);
                              for (final r in ratios) {
                                widths.add(usableWidth * (r / aspectSum));
                              }
                            }

                            return Padding(
                              padding: const EdgeInsets.only(
                                left: 16,
                                right: 16,
                                bottom: 3.0,
                              ),
                              child: SizedBox(
                                height: height,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.start,
                                  children: [
                                    for (int i = 0; i < rowItems.length; i++) ...[
                                      if (i > 0) const SizedBox(width: spacing),
                                      SizedBox(
                                        width: widths[i],
                                        height: height,
                                        child: Builder(
                                          builder: (itemCtx) {
                                            final item = rowItems[i];
                                            int burstCount = burstMap[BurstHelper.getBurstGroupKey(item) ?? ''] ?? 1;

                                            return PremiumGate(
                                              borderRadius: BorderRadius.circular(4.0),
                                              child: PhotoGridTile(
                                                key: ValueKey(item.id),
                                                item: item,
                                                isSelected: _selectedItemIds.contains(item.id),
                                                isSelectionMode: _isSelectionMode,
                                                isBurstRepresentative: burstCount > 1,
                                                burstCount: burstCount,
                                                borderRadius: 4.0,
                                                onTap: () async {
                                                  if (_isSelectionMode) {
                                                    HapticFeedback.lightImpact();
                                                    setState(() {
                                                      if (_selectedItemIds.contains(item.id)) {
                                                        _selectedItemIds.remove(item.id);
                                                        if (_selectedItemIds.isEmpty) {
                                                          _isSelectionMode = false;
                                                        }
                                                      } else {
                                                        _selectedItemIds.add(item.id);
                                                      }
                                                    });
                                                  } else {
                                                    widget.onItemTapped(item, filtered);
                                                  }
                                                },
                                                onLongPress: () {
                                                  if (!_isSelectionMode) {
                                                    HapticFeedback.lightImpact();
                                                    setState(() {
                                                      _isSelectionMode = true;
                                                      _selectedItemIds.add(item.id);
                                                    });
                                                  }
                                                },
                                                onContextReady: (ctx) => _itemContexts[item.id] = ctx,
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                  ] else ...[
                    // 4. Recent searches section
                    if (_recentSearches.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 16, 16, 8),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    "Recent searches",
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: textColor,
                                    ),
                                  ),
                                  IconButton(
                                    icon: Icon(
                                      Icons.delete_outline,
                                      color: subTextColor,
                                      size: 22,
                                    ),
                                    onPressed: () {
                                      setState(() {
                                        _recentSearches.clear();
                                      });
                                      _saveRecentSearches();
                                    },
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(
                              height: 40,
                              child: ListView.builder(
                                scrollDirection: Axis.horizontal,
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                itemCount: _recentSearches.length,
                                itemBuilder: (context, idx) {
                                  final term = _recentSearches[idx];
                                  final chipBg = isDark
                                      ? const Color(0xFF3B2E2D)
                                      : const Color(0xFFFDE8E5);
                                  final chipTextColor = isDark
                                      ? const Color(0xFFFFCDD2)
                                      : const Color(0xFFC62828);

                                  return Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: GestureDetector(
                                      onTap: () {
                                        _searchController.text = term;
                                        _updateSearch(() => _searchQuery = term);
                                        _updateQueryVector(term);
                                        _addSearchQueryToHistory(term);
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 18,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: chipBg,
                                          borderRadius: BorderRadius.circular(20),
                                        ),
                                        child: Center(
                                          child: Text(
                                            term,
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold,
                                              color: chipTextColor,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),

                    // 5. People Section
                    if (widget.peopleList.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 24, 16, 12),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    "People",
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: textColor,
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: () async {
                                      final result = await Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) => AllPeopleScreen(
                                            peopleList: widget.peopleList,
                                          ),
                                        ),
                                      );
                                      if (result == true) {
                                        _loadSearchMetadata();
                                      }
                                    },
                                    child: Text(
                                      "More >",
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                        color: subTextColor,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(
                              height: 110,
                              child: ListView.builder(
                                scrollDirection: Axis.horizontal,
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                itemCount: widget.peopleList.length,
                                itemBuilder: (context, index) {
                                  final p = widget.peopleList[index];
                                  final String name =
                                      p['name'] as String? ?? 'Unknown';
                                  final String? coverPath =
                                      p['cover_image'] as String?;

                                  return Padding(
                                    padding: const EdgeInsets.only(right: 16),
                                    child: GestureDetector(
                                      onTap: () {
                                        _togglePersonTag(name);
                                        _addSearchQueryToHistory(name);
                                      },
                                      child: Column(
                                        children: [
                                          (() {
                                            final nameTag = '@${name.replaceAll(' ', '_')}';
                                            final isSelected = _searchQuery.contains(nameTag);
                                            return Container(
                                              width: 76,
                                              height: 76,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: isDark
                                                    ? Colors.white10
                                                    : Colors.grey[200],
                                                border: isSelected
                                                    ? Border.all(
                                                        color: Colors.blueAccent,
                                                        width: 3.0,
                                                      )
                                                    : null,
                                              ),
                                              clipBehavior: Clip.antiAlias,
                                              child: coverPath != null &&
                                                      coverPath.isNotEmpty &&
                                                      File(coverPath).existsSync()
                                                  ? (p['cover_w'] != null &&
                                                            (p['cover_w'] as int? ??
                                                                    0) >
                                                                0
                                                          ? FacePreview(
                                                              imagePath: coverPath,
                                                              x: p['cover_x'] as int? ?? 0,
                                                              y: p['cover_y'] as int? ?? 0,
                                                              w: p['cover_w'] as int? ?? 0,
                                                              h: p['cover_h'] as int? ?? 0,
                                                            )
                                                          : Image.file(
                                                              File(coverPath),
                                                              fit: BoxFit.cover,
                                                            ))
                                                  : Center(
                                                      child: Text(
                                                        name.isNotEmpty
                                                            ? name[0].toUpperCase()
                                                            : '👤',
                                                        style: TextStyle(
                                                          fontSize: 24,
                                                          color: textColor,
                                                        ),
                                                      ),
                                                    ),
                                            );
                                          })(),
                                          const SizedBox(height: 6),
                                          Text(
                                            name,
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w500,
                                              color: textColor,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),

                    // 6. Places Section
                    if (sortedPlaces.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 20, 16, 12),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    "Places",
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: textColor,
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) => AllPlacesScreen(
                                            sortedPlaces: sortedPlaces,
                                          ),
                                        ),
                                      );
                                    },
                                    child: Text(
                                      "More >",
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                        color: subTextColor,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(
                              height: 155,
                              child: ListView.builder(
                                scrollDirection: Axis.horizontal,
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                itemCount: sortedPlaces.length,
                                itemBuilder: (context, index) {
                                  final entry = sortedPlaces[index];
                                  final placeName = entry.key;
                                  final items = entry.value;
                                  final firstItem = items.first;

                                  return Padding(
                                    padding: const EdgeInsets.only(right: 12),
                                    child: GestureDetector(
                                      onTap: () {
                                        _updateSearch(() {
                                          _filterLocation = placeName;
                                        });
                                      },
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(12),
                                            child: Container(
                                              width: 100,
                                              height: 100,
                                              color: isDark
                                                  ? Colors.white10
                                                  : Colors.grey[200],
                                              child: firstItem.mediaType == 'video'
                                                  ? VideoPreviewWidget(
                                                      videoPath: firstItem.imageUrl,
                                                    )
                                                  : (firstItem.imageUrl.startsWith(
                                                          'http',
                                                        )
                                                        ? Image.network(
                                                            firstItem.imageUrl,
                                                            fit: BoxFit.cover,
                                                          )
                                                        : Image.file(
                                                            File(firstItem.imageUrl),
                                                            cacheWidth: 200,
                                                            fit: BoxFit.cover,
                                                          )),
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          SizedBox(
                                            width: 100,
                                            child: Text(
                                              placeName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                                color: textColor,
                                              ),
                                            ),
                                          ),
                                          Text(
                                            "${items.length}",
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              color: subTextColor,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),

                    // 7. Types Section
                    if (_allSortedTags.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    "Types",
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: textColor,
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) => AllTagsScreen(
                                            allItems: widget.allItems,
                                            sortedTags: _allSortedTags,
                                            ocrTexts: _ocrTexts,
                                            tags: _tags,
                                          ),
                                        ),
                                      );
                                    },
                                    child: Text(
                                      "More >",
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                        color: subTextColor,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(
                              height: 155,
                              child: ListView.builder(
                                scrollDirection: Axis.horizontal,
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                itemCount: _allSortedTags.length.clamp(0, 10),
                                itemBuilder: (context, index) {
                                  final entry = _allSortedTags[index];
                                  final tagName = entry.key;
                                  final count = entry.value;

                                  // Find first item for this tag to use as thumbnail cover
                                  final lowerTag = tagName.toLowerCase();
                                  final items = widget.allItems.where((x) {
                                    final textMatch =
                                        _ocrTexts[x.id]?.contains(lowerTag) ?? false;
                                    final tagMatch =
                                        _tags[x.id]?.contains(lowerTag) ?? false;
                                    return textMatch || tagMatch;
                                  }).toList();

                                  final hasItems = items.isNotEmpty;
                                  final firstItem = hasItems ? items.first : null;

                                  return Padding(
                                    padding: const EdgeInsets.only(right: 12),
                                    child: GestureDetector(
                                      onTap: () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (context) => TagPhotosScreen(
                                              tagName: tagName,
                                              items: items,
                                            ),
                                          ),
                                        );
                                      },
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(12),
                                            child: Container(
                                              width: 100,
                                              height: 100,
                                              color: isDark
                                                  ? Colors.white10
                                                  : Colors.grey[200],
                                              child: firstItem != null
                                                  ? (firstItem.mediaType == 'video'
                                                        ? VideoPreviewWidget(
                                                            videoPath:
                                                                firstItem.imageUrl,
                                                          )
                                                        : (firstItem.imageUrl
                                                                  .startsWith('http')
                                                              ? Image.network(
                                                                  firstItem.imageUrl,
                                                                  fit: BoxFit.cover,
                                                                )
                                                              : Image.file(
                                                                  File(
                                                                    firstItem
                                                                        .imageUrl,
                                                                  ),
                                                                  cacheWidth: 200,
                                                                  fit: BoxFit.cover,
                                                                )))
                                                  : Center(
                                                      child: Icon(
                                                        Icons.tag,
                                                        color: subTextColor,
                                                      ),
                                                    ),
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            tagName,
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: textColor,
                                            ),
                                          ),
                                          Text(
                                            "$count",
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              color: subTextColor,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: (_isSelectionMode && _selectedItemIds.isNotEmpty)
                          ? 100 + MediaQuery.of(context).padding.bottom
                          : 20 + MediaQuery.of(context).padding.bottom,
                    ),
                  ),
                ],
              ),
          ),
        ),
        ),
        AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: _columnHudVisible ? 1.0 : 0.0,
          child: IgnorePointer(
            child: Align(
              alignment: const Alignment(0.0, -0.88),
              child: _SearchColumnHud(columns: _gridColumns),
            ),
          ),
        ),
        if (_isSelectionMode && _selectedItemIds.isNotEmpty)
          Positioned(
            left: 16,
            right: 16,
            bottom: 16 + MediaQuery.of(context).padding.bottom,
            child: _buildFloatingSelectionBar(),
          ),
      ],
    );
  }

  void _showAdvancedFilterDrawer() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setDrawerState) => Container(
          height: MediaQuery.of(context).size.height * 0.75,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1C1B1F) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[400],
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  "Advanced Filter parameters",
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const Divider(height: 24),

                // People filter
                const Text(
                  "Filter by specific Person Face",
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                widget.peopleList.isEmpty
                    ? const Text(
                        "No identified faces in cluster yet.",
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      )
                    : SizedBox(
                        height: 70,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: widget.peopleList.length,
                          itemBuilder: (context, index) {
                            final p = widget.peopleList[index];
                            final id = p['id'] as String;
                            final name = p['name'] as String;
                            final String? coverPath =
                                p['cover_image'] as String?;
                            final nameTag = '@${name.replaceAll(' ', '_')}';
                            final isSelected = _searchQuery.contains(nameTag);
                            return Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: GestureDetector(
                                onTap: () {
                                  _togglePersonTag(name);
                                  setDrawerState(() {});
                                },
                                child: Column(
                                  children: [
                                    Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: isSelected
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.primary
                                            : Colors.grey[300],
                                      ),
                                      clipBehavior: Clip.antiAlias,
                                      child: Stack(
                                        children: [
                                          Positioned.fill(
                                            child:
                                                coverPath != null &&
                                                    coverPath.isNotEmpty &&
                                                    File(coverPath).existsSync()
                                                ? (p['cover_w'] != null &&
                                                          (p['cover_w']
                                                                      as int? ??
                                                                  0) >
                                                              0
                                                      ? FacePreview(
                                                          imagePath: coverPath,
                                                          x:
                                                              p['cover_x']
                                                                  as int? ??
                                                              0,
                                                          y:
                                                              p['cover_y']
                                                                  as int? ??
                                                              0,
                                                          w:
                                                              p['cover_w']
                                                                  as int? ??
                                                              0,
                                                          h:
                                                              p['cover_h']
                                                                  as int? ??
                                                              0,
                                                        )
                                                      : Image.file(
                                                          File(coverPath),
                                                          fit: BoxFit.cover,
                                                        ))
                                                : Center(
                                                    child: Text(
                                                      isSelected ? "✓" : "👤",
                                                      style: TextStyle(
                                                        fontSize: isSelected
                                                            ? 18
                                                            : 14,
                                                        color: isSelected
                                                            ? Colors.white
                                                            : Colors.black87,
                                                      ),
                                                    ),
                                                  ),
                                          ),
                                          if (isSelected &&
                                              coverPath != null &&
                                              coverPath.isNotEmpty &&
                                              File(coverPath).existsSync())
                                            Positioned.fill(
                                              child: Container(
                                                color: Colors.black45,
                                                alignment: Alignment.center,
                                                child: const Icon(
                                                  Icons.check,
                                                  color: Colors.white,
                                                  size: 16,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      name,
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: isSelected
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                const SizedBox(height: 20),

                // Media type
                const Text(
                  "Filter by Media Type",
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _TypeChip(
                      label: "All",
                      type: null,
                      selected: _filterMediaType,
                      onChanged: (t) {
                        _updateSearchFromDrawer(
                          () => _filterMediaType = t,
                          setDrawerState,
                        );
                      },
                    ),
                    const SizedBox(width: 8),
                    _TypeChip(
                      label: "Photos",
                      type: "image",
                      selected: _filterMediaType,
                      onChanged: (t) {
                        _updateSearchFromDrawer(
                          () => _filterMediaType = t,
                          setDrawerState,
                        );
                      },
                    ),
                    const SizedBox(width: 8),
                    _TypeChip(
                      label: "Videos",
                      type: "video",
                      selected: _filterMediaType,
                      onChanged: (t) {
                        _updateSearchFromDrawer(
                          () => _filterMediaType = t,
                          setDrawerState,
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // Location
                const Text(
                  "Filter by Location Area",
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                (() {
                  final Set<String> dynamicLocations = {};
                  for (final item in widget.allItems) {
                    final loc = item.location.trim();
                    if (loc.isNotEmpty &&
                        loc.toLowerCase() != 'unknown location') {
                      final firstPart = loc.split(',').first.trim();
                      if (firstPart.isNotEmpty) {
                        dynamicLocations.add(firstPart);
                      }
                    }
                  }
                  final locationList = dynamicLocations.toList()..sort();
                  if (locationList.isEmpty) {
                    locationList.addAll([
                      "Sonepur",
                      "New Delhi",
                      "Bhubaneswar",
                      "Jauligrant",
                    ]);
                  }

                  return Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: locationList.map((loc) {
                      final isSelected = _filterLocation == loc;
                      return ChoiceChip(
                        label: Text(loc),
                        selected: isSelected,
                        onSelected: (val) {
                          _updateSearchFromDrawer(
                            () => _filterLocation = val ? loc : null,
                            setDrawerState,
                          );
                        },
                      );
                    }).toList(),
                  );
                })(),
                const SizedBox(height: 20),

                // Rating Filter
                const Text(
                  "Filter by Rating",
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Row(
                      children: List.generate(
                        5,
                        (index) => GestureDetector(
                          onTap: () {
                            final int newRating = index + 1;
                            _updateSearchFromDrawer(
                              () => _filterRating = (_filterRating == newRating)
                                  ? null
                                  : newRating,
                              setDrawerState,
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4.0,
                            ),
                            child: Icon(
                              index < (_filterRating ?? 0)
                                  ? Icons.star_rounded
                                  : Icons.star_border_rounded,
                              color: Colors.amber,
                              size: 32,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (_filterRating != null) ...[
                      const SizedBox(width: 12),
                      Text(
                        "$_filterRating★ & up",
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 20),

                // Duration
                const Text(
                  "Max Video Duration (Minutes)",
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                Slider(
                  value: _filterMaxDuration,
                  min: 1.0,
                  max: 60.0,
                  divisions: 6,
                  label: "${_filterMaxDuration.toInt()} mins",
                  onChanged: (val) {
                    _updateSearchFromDrawer(
                      () => _filterMaxDuration = val,
                      setDrawerState,
                    );
                  },
                ),
                const SizedBox(height: 20),

                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () {
                      _updateSearchFromDrawer(() {
                        _filterLocation = null;
                        _filterMediaType = null;
                        _filterRating = null;
                        _filterMaxDuration = 60.0;
                        _filterDate = null;
                      }, setDrawerState);
                    },
                    child: const Text("Reset All Filters"),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCustomFilterChip({
    required String label,
    required IconData icon,
    required VoidCallback onClear,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final chipBg = isDark ? const Color(0xFF3B2E2D) : const Color(0xFFFDE8E5);
    final chipTextColor = isDark
        ? const Color(0xFFFFCDD2)
        : const Color(0xFFC62828);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: chipBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: chipTextColor.withValues(alpha: 0.2), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: chipTextColor),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: chipTextColor,
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: onClear,
            child: Icon(
              Icons.close,
              size: 14,
              color: chipTextColor.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  final String label;
  final String? type;
  final String? selected;
  final void Function(String?) onChanged;

  const _TypeChip({
    required this.label,
    required this.type,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = selected == type;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (val) => onChanged(val ? type : null),
    );
  }
}

class TaggingTextEditingController extends TextEditingController {
  TaggingTextEditingController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final List<TextSpan> children = [];
    final pattern = RegExp(r'(@[a-zA-Z0-9_\-]+)');
    
    text.splitMapJoin(
      pattern,
      onMatch: (Match match) {
        children.add(
          TextSpan(
            text: match[0],
            style: (style ?? const TextStyle()).copyWith(
              color: Colors.blue,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
        return '';
      },
      onNonMatch: (String nonMatch) {
        children.add(
          TextSpan(
            text: nonMatch,
            style: style,
          ),
        );
        return '';
      },
    );

    return TextSpan(style: style, children: children);
  }
}


// Flat list models for SearchTab
abstract class _FlatSearchItem {}

class _FlatSearchRowItem extends _FlatSearchItem {
  final List<GalleryItem> items;
  final int columns;
  final int rowIndex;
  final double? customAspectRatio;
  _FlatSearchRowItem(this.items, this.columns, this.rowIndex, {this.customAspectRatio});
}

class _FlatSearchJustifiedRowItem extends _FlatSearchItem {
  final List<GalleryItem> items;
  final double height;
  final int rowIndex;
  final bool isLastRow;
  _FlatSearchJustifiedRowItem(this.items, this.height, this.rowIndex, {this.isLastRow = false});
}

class _SearchColumnHud extends StatelessWidget {
  final int columns;
  const _SearchColumnHud({required this.columns});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
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
    );
  }
}
