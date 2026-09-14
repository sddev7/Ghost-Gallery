import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import '../../models/gallery_item.dart';
import '../../services/collection_source.dart';
import '../../services/database_helper.dart';
import '../../services/favorites_persistence.dart';
import '../people_management_screen.dart';
import '../tabs/fast_media_preview.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Design tokens — every colour and spacing decision is sourced from here so
// it follows the host app's ThemeData automatically while the flat surfaces,
// 0-elevation cards and hairline dividers give the picker its own identity.
// ─────────────────────────────────────────────────────────────────────────────

class _T {
  // Category pill constants
  static const double pillH = 34;
  static const double pillRadius = 10;
  static const double gridGap = 3;
  static const double gridRadius = 6;
  static const double thumbSize = 52;
  static const double drawerH = 96;
  static const double albumRailW = 118;
}

// ─────────────────────────────────────────────────────────────────────────────

class CustomMediaPicker extends StatefulWidget {
  const CustomMediaPicker({super.key});

  @override
  State<CustomMediaPicker> createState() => _CustomMediaPickerState();
}

class _CustomMediaPickerState extends State<CustomMediaPicker>
    with SingleTickerProviderStateMixin {
  // Tabs: 0=Albums, 1=People, 2=Tags, 3=Places
  int _activeCategoryIndex = 0;

  // Data states
  List<GalleryItem> _allMediaItems = [];
  Set<String> _favoriteIds = {};
  Map<String, List<String>> _customAlbums = {};
  List<Map<String, dynamic>> _peopleList = [];
  List<Map<String, dynamic>> _tagsList = [];
  List<String> _placesList = [];

  // Cached states
  List<String> _albumCategories = [];
  List<GalleryItem> _filteredItems = [];

  // Drilldown states
  String? _selectedAlbum;
  String? _selectedPersonId;
  String? _selectedPersonName;
  String? _selectedTag;
  List<String> _selectedTagMediaIds = [];
  String? _selectedPlace;

  // Drag selection state
  final Map<String, BuildContext> _itemContexts = {};
  final bool _isDraggingToSelect = false;
  String? _dragStartId;
  final bool _dragSelectInitialState = true;
  Offset? _dragStartPosition;
  final bool _dragDirectionDecided = false;

  // Double-tap drag state
  DateTime? _lastPointerDownTime;
  Offset? _lastPointerDownPosition;
  final bool _isDoubleTapDragging = false;

  // Selection
  final Set<GalleryItem> _selectedItems = {};

  // Peek
  GalleryItem? _peekingItem;
  VideoPlayerController? _peekVideoController;

  bool _isLoading = true;

  // Animate category pill indicator
  late AnimationController _pillAnim;

  @override
  void initState() {
    super.initState();
    _pillAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _loadData();
  }

  @override
  void dispose() {
    _peekVideoController?.dispose();
    _pillAnim.dispose();
    super.dispose();
  }

  // ── Data loading ────────────────────────────────────────────────────────────

  Future<void> _loadCustomAlbums() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/custom_albums.json');
      if (await file.exists()) {
        final decoded =
            json.decode(await file.readAsString()) as Map<String, dynamic>;
        _customAlbums =
            decoded.map((k, v) => MapEntry(k, List<String>.from(v)));
      }
    } catch (e) {
      debugPrint('CustomMediaPicker: load custom albums error: $e');
    }
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    _allMediaItems = CollectionSource.instance.items;
    _favoriteIds = await FavoritesPersistence.loadFavorites();
    await _loadCustomAlbums();

    final rawPeople =
        await DatabaseHelper.instance.getEligiblePeopleForUi();
    final validatedPeople = <Map<String, dynamic>>[];
    for (final person in rawPeople) {
      final coverPath = person['cover_image'] as String?;
      if (coverPath != null && coverPath.isNotEmpty) {
        if (await File(coverPath).exists()) {
          validatedPeople.add(person);
          continue;
        }
      }
      final updated = Map<String, dynamic>.from(person)
        ..['cover_image'] = '';
      validatedPeople.add(updated);
    }
    _peopleList = validatedPeople;

    _tagsList = await DatabaseHelper.instance.getTopTags(limit: 50);
    _placesList = await DatabaseHelper.instance.getDistinctLocalities();

    _updateAlbumCategories();

    final hasCameraCase = _albumCategories.indexWhere((c) => c.toLowerCase() == 'camera');
    if (hasCameraCase != -1) {
      _selectedAlbum = _albumCategories[hasCameraCase];
    } else if (_albumCategories.isNotEmpty) {
      _selectedAlbum = _albumCategories.first;
    }

    _updateFilteredItems();
    setState(() => _isLoading = false);
  }

  void _updateAlbumCategories() {
    final cats = _allMediaItems
        .map((i) => i.albumCategory)
        .toSet()
        .where((c) => c.isNotEmpty)
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final all = <String>[];
    if (_allMediaItems.any((i) => _favoriteIds.contains(i.id))) {
      all.add('Favorites');
    }
    all
      ..addAll(_customAlbums.keys)
      ..addAll(cats);
    _albumCategories = all.toSet().toList();
  }

  void _updateFilteredItems() {
    _itemContexts.clear();
    switch (_activeCategoryIndex) {
      case 0: // Albums
        if (_selectedAlbum == 'Favorites') {
          _filteredItems = _allMediaItems
              .where((i) => _favoriteIds.contains(i.id))
              .toList();
        } else if (_customAlbums.containsKey(_selectedAlbum)) {
          final ids = (_customAlbums[_selectedAlbum] ?? []).toSet();
          _filteredItems =
              _allMediaItems.where((i) => ids.contains(i.id)).toList();
        } else {
          _filteredItems = _allMediaItems
              .where((i) => i.albumCategory == _selectedAlbum)
              .toList();
        }
        break;
      case 1: // People
        _filteredItems = _selectedPersonId == null ? [] : _personItems;
        break;
      case 2: // Tags
        if (_selectedTag == null) {
          _filteredItems = [];
        } else {
          final t = _selectedTag!.toLowerCase();
          _filteredItems = _allMediaItems
              .where((i) => _selectedTagMediaIds.contains(i.id) || i.tags.any((x) => x.toLowerCase() == t))
              .toList();
        }
        break;
      default: // Places
        _filteredItems = _selectedPlace == null
            ? []
            : _allMediaItems
                .where((i) => i.locality == _selectedPlace)
                .toList();
    }
  }

  List<GalleryItem> _personItems = [];
  bool _isLoadingPersonItems = false;

  Future<void> _onPersonSelected(
      String personId, String personName) async {
    setState(() {
      _selectedPersonId = personId;
      _selectedPersonName = personName;
      _isLoadingPersonItems = true;
      _personItems = [];
      _updateFilteredItems();
    });
    try {
      final dbMaps =
          await DatabaseHelper.instance.getMediaItemsForPerson(personId);
      final ids = dbMaps.map((m) => m['id'] as String).toSet();
      final items =
          _allMediaItems.where((i) => ids.contains(i.id)).toList();
      setState(() {
        _personItems = items;
        _isLoadingPersonItems = false;
        _updateFilteredItems();
      });
    } catch (_) {
      setState(() {
        _isLoadingPersonItems = false;
        _updateFilteredItems();
      });
    }
  }

  void _toggleItemSelection(GalleryItem item) {
    setState(() {
      if (_selectedItems.contains(item)) {
        _selectedItems.remove(item);
      } else {
        _selectedItems.add(item);
      }
    });
  }

  Future<void> _startPeek(GalleryItem item) async {
    setState(() => _peekingItem = item);
    if (item.mediaType == 'video') {
      _peekVideoController?.dispose();
      _peekVideoController =
          VideoPlayerController.file(File(item.imageUrl))
            ..initialize().then((_) {
              setState(() {});
              _peekVideoController
                ?..setVolume(0)
                ..setLooping(true)
                ..play();
            });
    }
  }

  void _stopPeek() {
    _peekVideoController
      ?..pause()
      ..dispose();
    _peekVideoController = null;
    setState(() => _peekingItem = null);
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = Theme.of(context).scaffoldBackgroundColor;

    return Stack(
      children: [
        Scaffold(
          backgroundColor: bg,
          // ── AppBar ──────────────────────────────────────────────────────────
          appBar: AppBar(
            backgroundColor: bg,
            elevation: 0,
            scrolledUnderElevation: 0,
            leadingWidth: 48,
            leading: _iconBtn(
              icon: Icons.close_rounded,
              color: cs.onSurface.withValues(alpha: 0.55),
              onTap: () => Navigator.pop(context, <GalleryItem>[]),
            ),
            title: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Text(
                _selectedItems.isEmpty
                    ? 'Select Media'
                    : '${_selectedItems.length} selected',
                key: ValueKey(_selectedItems.length),
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
            ),
            actions: [
              if (_filteredItems.isNotEmpty)
                IconButton(
                  icon: Icon(
                    _filteredItems.every((item) => _selectedItems.contains(item))
                        ? Icons.deselect_rounded
                        : Icons.select_all_rounded,
                    color: cs.onSurface,
                  ),
                  onPressed: () {
                    setState(() {
                      final allSelected = _filteredItems.every((item) => _selectedItems.contains(item));
                      if (allSelected) {
                        for (final item in _filteredItems) {
                          _selectedItems.remove(item);
                        }
                      } else {
                        _selectedItems.addAll(_filteredItems);
                      }
                    });
                  },
                  tooltip: _filteredItems.every((item) => _selectedItems.contains(item)) ? 'Deselect All' : 'Select All',
                ),
              if (_selectedItems.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Center(
                    child: _flatBtn(
                      label: 'Preview',
                      color: cs.secondary,
                      onTap: () => _openSlideablePreview(0),
                    ),
                  ),
                ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(1),
              child: Divider(
                height: 1,
                thickness: 0.5,
                color: cs.onSurface.withValues(alpha: 0.08),
              ),
            ),
          ),
          body: Column(
            children: [
              _buildCategoryPills(),
              Expanded(
                child: _isLoading
                    ? Center(
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: cs.primary,
                        ),
                      )
                    : _buildActiveCategoryContent(),
              ),
              if (_selectedItems.isNotEmpty) _buildSelectionDrawer(),
            ],
          ),
        ),
        if (_peekingItem != null) _buildPeekOverlay(),
      ],
    );
  }

  // ── Category pills ──────────────────────────────────────────────────────────

  Widget _buildCategoryPills() {
    const labels = ['Albums', 'People', 'Tags', 'Places'];
    final cs = Theme.of(context).colorScheme;

    return Container(
      height: 54,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: List.generate(labels.length, (i) {
            final active = i == _activeCategoryIndex;
            return GestureDetector(
              onTap: () {
                if (active) return;
                HapticFeedback.selectionClick();
                setState(() {
                  _activeCategoryIndex = i;
                  if (i == 0) {
                    final hasCameraCase = _albumCategories.indexWhere((c) => c.toLowerCase() == 'camera');
                    if (hasCameraCase != -1) {
                      _selectedAlbum = _albumCategories[hasCameraCase];
                    } else {
                      _selectedAlbum = _albumCategories.firstOrNull;
                    }
                  } else {
                    _selectedAlbum = null;
                  }
                  _selectedPersonId = null;
                  _selectedTag = null;
                  _selectedTagMediaIds = [];
                  _selectedPlace = null;
                  _updateFilteredItems();
                });
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                margin: const EdgeInsets.only(right: 8),
                height: _T.pillH,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: active
                      ? cs.primary
                      : cs.onSurface.withValues(alpha: 0.06),
                  borderRadius:
                      BorderRadius.circular(_T.pillRadius),
                ),
                alignment: Alignment.center,
                child: Text(
                  labels[i],
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: active
                        ? cs.onPrimary
                        : cs.onSurface.withValues(alpha: 0.55),
                    letterSpacing: -0.1,
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  // ── Active content router ───────────────────────────────────────────────────

  Widget _buildActiveCategoryContent() {
    switch (_activeCategoryIndex) {
      case 0:
        return _buildAlbumsContent();
      case 1:
        return _buildPeopleContent();
      case 2:
        return _buildTagsContent();
      case 3:
        return _buildPlacesContent();
      default:
        return const SizedBox.shrink();
    }
  }

  // ── Albums ──────────────────────────────────────────────────────────────────

  Widget _buildAlbumsContent() {
    if (_albumCategories.isEmpty) {
      return _emptyState('No albums found');
    }
    final cs = Theme.of(context).colorScheme;

    return Column(
      children: [
        // Elegant dropdown selector bar
        Container(
          height: 48,
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white.withValues(alpha: 0.05)
                : Colors.black.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: cs.onSurface.withValues(alpha: 0.08),
              width: 1,
            ),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _albumCategories.contains(_selectedAlbum) ? _selectedAlbum : null,
              icon: Icon(Icons.keyboard_arrow_down_rounded, color: cs.onSurface.withValues(alpha: 0.7)),
              isExpanded: true,
              dropdownColor: Theme.of(context).scaffoldBackgroundColor,
              borderRadius: BorderRadius.circular(12),
              style: TextStyle(
                color: cs.onSurface,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
              items: _albumCategories.map((String value) {
                return DropdownMenuItem<String>(
                  value: value,
                  child: Text(value),
                );
              }).toList(),
              onChanged: (newValue) {
                if (newValue != null) {
                  setState(() {
                    _selectedAlbum = newValue;
                    _updateFilteredItems();
                  });
                }
              },
            ),
          ),
        ),
        // Hairline divider
        Divider(
          height: 1,
          thickness: 0.5,
          color: cs.onSurface.withValues(alpha: 0.08),
        ),
        // Full width media items grid
        Expanded(child: _buildMediaItemsGrid(_filteredItems)),
      ],
    );
  }

  // ── People ──────────────────────────────────────────────────────────────────

  Widget _buildPeopleContent() {
    if (_selectedPersonId != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _drilldownHeader(
            label: _selectedPersonName ?? 'Person',
            onBack: () => setState(() {
              _selectedPersonId = null;
              _updateFilteredItems();
            }),
          ),
          Expanded(
            child: _isLoadingPersonItems
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _buildMediaItemsGrid(_filteredItems),
          ),
        ],
      );
    }

    if (_peopleList.isEmpty) {
      return _emptyState('No people detected yet');
    }

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
        childAspectRatio: 0.82,
      ),
      itemCount: _peopleList.length,
      itemBuilder: (ctx, i) {
        final p = _peopleList[i];
        final name = p['name'] as String? ?? 'Unknown';
        final cover = p['cover_image'] as String?;
        final cs = Theme.of(context).colorScheme;

        return GestureDetector(
          onTap: () => _onPersonSelected(p['id'] as String, name),
          child: Column(
            children: [
              Expanded(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: ClipOval(
                    child: cover != null && cover.isNotEmpty
                        ? ((p['cover_w'] as int? ?? 0) > 0
                            ? FacePreview(
                                imagePath: cover,
                                x: p['cover_x'] as int? ?? 0,
                                y: p['cover_y'] as int? ?? 0,
                                w: p['cover_w'] as int? ?? 0,
                                h: p['cover_h'] as int? ?? 0,
                              )
                            : Image.file(File(cover),
                                fit: BoxFit.cover))
                        : Container(
                            color: cs.onSurface.withValues(alpha: 0.06),
                            alignment: Alignment.center,
                            child: Text(
                              name.isNotEmpty
                                  ? name[0].toUpperCase()
                                  : '👤',
                              style: TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w700,
                                color: cs.onSurface
                                    .withValues(alpha: 0.45),
                              ),
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                name,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Tags ────────────────────────────────────────────────────────────────────

  Widget _buildTagsContent() {
    if (_selectedTag != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _drilldownHeader(
            label: '#$_selectedTag',
            onBack: () => setState(() {
              _selectedTag = null;
              _selectedTagMediaIds = [];
              _updateFilteredItems();
            }),
          ),
          Expanded(child: _buildMediaItemsGrid(_filteredItems)),
        ],
      );
    }

    if (_tagsList.isEmpty) return _emptyState('No tags detected yet');

    final cs = Theme.of(context).colorScheme;

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
      itemCount: _tagsList.length,
      itemBuilder: (ctx, i) {
        final tag = _tagsList[i];
        final label = tag['label'] as String;
        final count = tag['count'] as int;
        return _flatListTile(
          leading: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: cs.secondary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Text(
              '#',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: cs.secondary,
              ),
            ),
          ),
          title: label,
          trailing: '$count',
          onTap: () => setState(() {
            _selectedTag = label;
            _selectedTagMediaIds = List<String>.from(tag['media_ids'] ?? []);
            _updateFilteredItems();
          }),
        );
      },
    );
  }

  // ── Places ──────────────────────────────────────────────────────────────────

  Widget _buildPlacesContent() {
    if (_selectedPlace != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _drilldownHeader(
            label: _selectedPlace!,
            onBack: () => setState(() {
              _selectedPlace = null;
              _updateFilteredItems();
            }),
          ),
          Expanded(child: _buildMediaItemsGrid(_filteredItems)),
        ],
      );
    }

    if (_placesList.isEmpty) {
      return _emptyState('No locations tagged in your library yet');
    }

    final cs = Theme.of(context).colorScheme;

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _placesList.length,
      itemBuilder: (ctx, i) => _flatListTile(
        leading: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: Colors.redAccent.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.location_on_rounded,
              color: Colors.redAccent, size: 18),
        ),
        title: _placesList[i],
        onTap: () => setState(() {
          _selectedPlace = _placesList[i];
          _updateFilteredItems();
        }),
      ),
    );
  }

  // ── Media grid ──────────────────────────────────────────────────────────────

  Widget _buildMediaItemsGrid(List<GalleryItem> items) {
    if (items.isEmpty) {
      return _emptyState('Nothing here yet');
    }

    return GridView.builder(
      padding: const EdgeInsets.all(3),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: _T.gridGap,
        mainAxisSpacing: _T.gridGap,
      ),
      itemCount: items.length,
      itemBuilder: (ctx, i) {
        final item = items[i];
        final selected = _selectedItems.contains(item);
        final cs = Theme.of(context).colorScheme;

        return GestureDetector(
          onTap: () {
            HapticFeedback.lightImpact();
            _toggleItemSelection(item);
          },
          onLongPressStart: (_) {
            HapticFeedback.mediumImpact();
            _startPeek(item);
          },
          onLongPressEnd: (_) => _stopPeek(),
          onLongPressCancel: () => _stopPeek(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Thumbnail
              ClipRRect(
                borderRadius: BorderRadius.circular(_T.gridRadius),
                child: FastMediaPreview(
                  item: item,
                  fit: BoxFit.cover,
                ),
              ),
              // Selection dim overlay
              if (selected)
                ClipRRect(
                  borderRadius:
                      BorderRadius.circular(_T.gridRadius),
                  child: ColoredBox(
                    color: cs.primary.withValues(alpha: 0.22),
                  ),
                ),
              // Video badge
              if (item.mediaType == 'video')
                const Positioned(
                  bottom: 6,
                  right: 6,
                  child: Icon(Icons.play_circle_fill_rounded,
                      color: Colors.white70, size: 18),
                ),
              // Selection indicator (top-left)
              Positioned(
                top: 6,
                left: 6,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected
                        ? cs.primary
                        : Colors.black.withValues(alpha: 0.35),
                    border: Border.all(
                      color: Colors.white,
                      width: 1.5,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: selected
                      ? Icon(Icons.check_rounded,
                          size: 13,
                          color: cs.onPrimary)
                      : null,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Selection drawer ────────────────────────────────────────────────────────

  Widget _buildSelectionDrawer() {
    final items = _selectedItems.toList();
    final cs = Theme.of(context).colorScheme;

    return Container(
      height: _T.drawerH,
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border(
          top: BorderSide(
            color: cs.onSurface.withValues(alpha: 0.08),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          // Scrollable thumbnails + label
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Row(
                    children: [
                      Text(
                        '${items.length} selected',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: cs.primary,
                          letterSpacing: 0.1,
                        ),
                      ),
                      const Spacer(),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14),
                    itemCount: items.length,
                    itemBuilder: (ctx, i) {
                      final item = items[i];
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: GestureDetector(
                          onTap: () => _openSlideablePreview(i),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              ClipRRect(
                                borderRadius:
                                    BorderRadius.circular(6),
                                child: FastMediaPreview(
                                  item: item,
                                  fit: BoxFit.cover,
                                  width: _T.thumbSize,
                                  height: _T.thumbSize,
                                ),
                              ),
                              Positioned(
                                top: -5,
                                right: -5,
                                child: GestureDetector(
                                  onTap: () =>
                                      _toggleItemSelection(item),
                                  child: Container(
                                    width: 18,
                                    height: 18,
                                    decoration: BoxDecoration(
                                      color: Colors.black54,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                          color: Colors.white,
                                          width: 1),
                                    ),
                                    alignment: Alignment.center,
                                    child: const Icon(
                                      Icons.close_rounded,
                                      size: 10,
                                      color: Colors.white,
                                    ),
                                  ),
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
          // Import button — flat, no shadow
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 14),
            child: TextButton(
              onPressed: () =>
                  Navigator.pop(context, _selectedItems.toList()),
              style: TextButton.styleFrom(
                backgroundColor: cs.secondary,
                foregroundColor: cs.onSecondary,
                padding: const EdgeInsets.symmetric(
                    horizontal: 22, vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                elevation: 0,
                splashFactory: InkRipple.splashFactory,
              ),
              child: const Text(
                'Import',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  letterSpacing: -0.1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Peek overlay ─────────────────────────────────────────────────────────────

  Widget _buildPeekOverlay() {
    final item = _peekingItem!;
    final isVideo = item.mediaType == 'video';
    final initialized = _peekVideoController?.value.isInitialized ?? false;

    return GestureDetector(
      onTap: _stopPeek,
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.82),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: AspectRatio(
                    aspectRatio: isVideo && initialized
                        ? _peekVideoController!.value.aspectRatio
                        : (item.width > 0 && item.height > 0
                            ? item.width / item.height
                            : 1.0),
                    child: isVideo
                        ? (initialized
                            ? VideoPlayer(_peekVideoController!)
                            : const ColoredBox(
                                color: Colors.black26,
                                child: Center(
                                  child: CircularProgressIndicator(
                                    color: Colors.white54,
                                    strokeWidth: 2,
                                  ),
                                ),
                              ))
                        : Image.file(File(item.imageUrl),
                            fit: BoxFit.contain),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  isVideo ? 'Video preview · silent' : 'Image preview',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.none,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Shared micro-widgets ────────────────────────────────────────────────────

  Widget _emptyState(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.35),
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _drilldownHeader({
    required String label,
    required VoidCallback onBack,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 6, 16, 6),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: cs.onSurface.withValues(alpha: 0.07),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back_ios_new_rounded,
                size: 17, color: cs.onSurface.withValues(alpha: 0.65)),
            onPressed: onBack,
            splashRadius: 20,
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
              letterSpacing: -0.3,
            ),
          ),
        ],
      ),
    );
  }

  // Flat list tile (Tags / Places)
  Widget _flatListTile({
    required Widget leading,
    required String title,
    String? trailing,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
            ),
            if (trailing != null)
              Text(
                trailing,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurface.withValues(alpha: 0.38),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // Transparent text button (AppBar Done)
  Widget _flatBtn({
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 15,
        ),
      ),
    );
  }

  // Compact icon button
  Widget _iconBtn({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 48,
        height: kToolbarHeight,
        child: Icon(icon, color: color, size: 22),
      ),
    );
  }

  Future<void> _openSlideablePreview(int initialIndex) async {
    final items = _selectedItems.toList();
    if (items.isEmpty) return;

    final shouldImport = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => SelectedItemsPreviewScreen(
          selectedItems: items,
          initialIndex: initialIndex,
        ),
      ),
    );

    if (shouldImport == true && mounted) {
      Navigator.pop(context, _selectedItems.toList());
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Preview screen — full-screen swipeable viewer with flat bottom bar
// ─────────────────────────────────────────────────────────────────────────────

class SelectedItemsPreviewScreen extends StatefulWidget {
  final List<GalleryItem> selectedItems;
  final int initialIndex;

  const SelectedItemsPreviewScreen({
    super.key,
    required this.selectedItems,
    required this.initialIndex,
  });

  @override
  State<SelectedItemsPreviewScreen> createState() =>
      _SelectedItemsPreviewScreenState();
}

class _SelectedItemsPreviewScreenState
    extends State<SelectedItemsPreviewScreen> {
  late PageController _pageController;
  late int _currentIndex;
  final Map<int, VideoPlayerController> _videoControllers = {};

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController =
        PageController(initialPage: widget.initialIndex);
    _initializeVideoIfNeeded(_currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final c in _videoControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _initializeVideoIfNeeded(int index) {
    if (index < 0 || index >= widget.selectedItems.length) return;
    final item = widget.selectedItems[index];
    if (item.mediaType != 'video' ||
        _videoControllers.containsKey(index)) {
      return;
    }

    final ctrl = VideoPlayerController.file(File(item.imageUrl));
    ctrl.initialize().then((_) {
      setState(() {});
      ctrl
        ..setLooping(true)
        ..play();
    });
    _videoControllers[index] = ctrl;
  }

  void _onPageChanged(int index) {
    setState(() => _currentIndex = index);
    _videoControllers.forEach((i, c) {
      if (i != index) c.pause();
    });
    _initializeVideoIfNeeded(index);
    final c = _videoControllers[index];
    if (c != null && c.value.isInitialized) c.play();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final total = widget.selectedItems.length;

    return Scaffold(
      backgroundColor: Colors.black,
      // ── AppBar ────────────────────────────────────────────────────────────
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: Colors.white, size: 18),
          onPressed: () => Navigator.pop(context, false),
        ),
        title: Text(
          '${_currentIndex + 1} / $total',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          // ── Pager ──────────────────────────────────────────────────────────
          PageView.builder(
            controller: _pageController,
            itemCount: total,
            onPageChanged: _onPageChanged,
            itemBuilder: (ctx, i) {
              final item = widget.selectedItems[i];
              final isVideo = item.mediaType == 'video';
              final ctrl = _videoControllers[i];

              return Center(
                child: InteractiveViewer(
                  maxScale: 4.0,
                  child: isVideo
                      ? (ctrl != null &&
                              ctrl.value.isInitialized
                          ? AspectRatio(
                              aspectRatio:
                                  ctrl.value.aspectRatio,
                              child: VideoPlayer(ctrl),
                            )
                          : const CircularProgressIndicator(
                              color: Colors.white54,
                              strokeWidth: 2,
                            ))
                      : Image.file(
                          File(item.imageUrl),
                          fit: BoxFit.contain,
                        ),
                ),
              );
            },
          ),
          // ── Bottom bar ─────────────────────────────────────────────────────
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: EdgeInsets.fromLTRB(
                  20, 16, 20, MediaQuery.of(context).padding.bottom + 16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.72),
                    Colors.transparent,
                  ],
                ),
              ),
              child: Row(
                children: [
                  // Edit selection — ghost button
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () =>
                          Navigator.pop(context, false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(
                            color: Colors.white38, width: 1),
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(
                            vertical: 14),
                      ),
                      child: const Text(
                        'Edit selection',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Import — solid flat button
                  Expanded(
                    child: TextButton(
                      onPressed: () =>
                          Navigator.pop(context, true),
                      style: TextButton.styleFrom(
                        backgroundColor: cs.secondary,
                        foregroundColor: cs.onSecondary,
                        padding: const EdgeInsets.symmetric(
                            vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(10),
                        ),
                        elevation: 0,
                      ),
                      child: const Text(
                        'Import now',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          letterSpacing: -0.1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}