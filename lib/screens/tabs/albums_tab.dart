import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:ghost_gallery/screens/cleanup_suggestions_screen.dart';
import 'package:ghost_gallery/services/database_helper.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import '../../models/gallery_item.dart';
import '../album_detail_screen.dart';
import '../calendar_screen.dart';
import '../people_management_screen.dart';
import '../../services/favorites_persistence.dart';
import './video_preview_widget.dart';
import './fast_media_preview.dart';
import '../../services/vault_service.dart';
import '../vault/vault_setup_screen.dart';
import '../vault/vault_screen.dart';
import '../../services/media_permission_service.dart';
import '../collage_creator_screen.dart';
import '../../widgets/cached_tile_provider.dart';
import '../../widgets/cached_media_thumbnail.dart';
import '../../services/ui_preference_provider.dart';
import '../../services/entitlement_service.dart';
import '../../services/responsive_helper.dart';

class AlbumsTab extends StatefulWidget {
  final List<GalleryItem> allItems;
  final List<Map<String, dynamic>> peopleList;
  final Function(GalleryItem, [List<GalleryItem>?]) onItemTapped;
  final VoidCallback onPeoplePressed;
  final VoidCallback onMapPressed;
  final Future<void> Function() onRefresh;

  final String appTheme;

  const AlbumsTab({
    super.key,
    required this.allItems,
    required this.peopleList,
    required this.onItemTapped,
    required this.onPeoplePressed,
    required this.onMapPressed,
    required this.onRefresh,
    required this.appTheme,
  });

  @override
  State<AlbumsTab> createState() => _AlbumsTabState();
}

class _AlbumsTabState extends State<AlbumsTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late final PageController _categoryPageController;
  final MapController _miniMapController = MapController();
  final List<String> _categories = ["Intelligent", "Device", "Ghost", "Custom"];

  List<_AlbumItemUI> _folderAlbums = [];
  List<_AlbumItemUI> _customAlbumsUI = [];
  List<_AlbumItemUI> _ghostCreatedAlbums = [];
  List<_AlbumItemUI> _deviceAlbums = [];
  List<_AlbumItemUI> _favoriteAlbums = [];
  List<_AlbumItemUI> _allCategoryAlbums = [];

  Map<String, List<String>> _customAlbums = {};
  bool _isInit = true;
  bool _selectionMode = false;
  final Set<String> _selectedAlbumNames =
      {}; // Track custom albums by name for deletion
  int _recentlyDeletedCount = 0;
  Set<String> _favoriteIds = {};
  List<Map<String, dynamic>> _topTags = [];
  List<String> _documentMediaIds = [];

  int get _uniqueDaysCount {
    final seenDays = <String>{};
    for (final item in widget.allItems) {
      final dt = DateTime.fromMillisecondsSinceEpoch(item.dateTimestamp);
      final dayKey = '${dt.year}-${dt.month}-${dt.day}';
      seenDays.add(dayKey);
    }
    return seenDays.length;
  }

  int get _placesCount {
    final Set<String> uniquePlaces = {};
    for (final item in widget.allItems) {
      if (item.hasGps) {
        final loc = item.location.trim();
        if (loc.isNotEmpty && loc.toLowerCase() != 'unknown location') {
          final firstPart = loc.split(',').first.trim();
          if (firstPart.isNotEmpty) {
            uniquePlaces.add(firstPart.toLowerCase());
          }
        }
      }
    }
    return uniquePlaces.length;
  }

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = "";
  String _selectedCategory =
      "Intelligent"; // Intelligent, Favorite, Custom, Ghost, Device
  bool _isGridView = true;

  @override
  void initState() {
    super.initState();
    _categoryPageController = PageController(
      initialPage: _categories.indexOf(_selectedCategory),
    );
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text;
      });
    });
    _loadAll();
    UIPreferenceProvider.instance.addListener(_handleUIPreferencesChange);
  }

  @override
  void dispose() {
    UIPreferenceProvider.instance.removeListener(_handleUIPreferencesChange);
    _categoryPageController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _handleUIPreferencesChange() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant AlbumsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.allItems != widget.allItems ||
        oldWidget.peopleList != widget.peopleList ||
        oldWidget.allItems.length != widget.allItems.length) {
      _loadAll();
    }
  }

  Future<void> _loadAll() async {
    await Future.wait([
      _loadCustomAlbums(),
      _loadRecentlyDeletedCount(),
      _loadFavorites(),
      _loadTopTags(),
      _loadDocuments(),
    ]);
    _updateAlbumComputations();
  }

  void _updateAlbumComputations() {
    final Map<String, List<GalleryItem>> folderGroups = {};
    for (final item in widget.allItems) {
      folderGroups
          .putIfAbsent(_getFolderName(item.imageUrl), () => [])
          .add(item);
    }

    final folderAlbums = <_AlbumItemUI>[
      for (final f in folderGroups.keys)
        if (f.isNotEmpty)
          _AlbumItemUI(
            name: f,
            count: folderGroups[f]!.length,
            items: folderGroups[f]!,
          ),
    ];
    folderAlbums.sort((a, b) => b.count.compareTo(a.count));

    final customAlbums = <_AlbumItemUI>[
      for (final entry in _customAlbums.entries)
        _AlbumItemUI(
          name: entry.key,
          count: widget.allItems
              .where((x) => entry.value.contains(x.id))
              .length,
          items: widget.allItems
              .where((x) => entry.value.contains(x.id))
              .toList(),
          isCustom: true,
        ),
    ];
    customAlbums.sort((a, b) => b.count.compareTo(a.count));

    final ghostCreated = <_AlbumItemUI>[];
    final device = <_AlbumItemUI>[];

    device.add(
      _AlbumItemUI(
        name: 'Recents',
        count: widget.allItems.length,
        items: widget.allItems,
      ),
    );
    device.add(
      _AlbumItemUI(
        name: 'All Photos',
        count: widget.allItems.where((x) => x.mediaType == 'image').length,
        items: widget.allItems.where((x) => x.mediaType == 'image').toList(),
      ),
    );
    device.add(
      _AlbumItemUI(
        name: 'All Videos',
        count: widget.allItems.where((x) => x.mediaType == 'video').length,
        items: widget.allItems.where((x) => x.mediaType == 'video').toList(),
      ),
    );

    for (final album in folderAlbums) {
      final nameLower = album.name.toLowerCase();
      if (nameLower.contains('ghost') ||
          nameLower.contains('favorites') ||
          nameLower == 'ghost gallery' ||
          nameLower == 'ghost gallery edit') {
        ghostCreated.add(album);
      } else {
        device.add(album);
      }
    }

    final favorite = <_AlbumItemUI>[
      _AlbumItemUI(
        name: 'Favorites',
        count: widget.allItems.where((x) => _favoriteIds.contains(x.id)).length,
        items: widget.allItems
            .where((x) => _favoriteIds.contains(x.id))
            .toList(),
        isCustom: false,
      ),
    ];

    final allCategory = [...ghostCreated, ...device, ...customAlbums];

    if (mounted) {
      setState(() {
        _folderAlbums = folderAlbums;
        _customAlbumsUI = customAlbums;
        _ghostCreatedAlbums = ghostCreated;
        _deviceAlbums = device;
        _favoriteAlbums = favorite;
        _allCategoryAlbums = allCategory;
      });
    }
  }

  Future<void> _loadDocuments() async {
    try {
      final ids = await DatabaseHelper.instance.getDocumentMediaIds();
      if (mounted) {
        setState(() {
          _documentMediaIds = ids;
        });
      }
    } catch (e) {
      debugPrint('load documents error: $e');
    }
  }

  Future<void> _loadTopTags() async {
    try {
      final tags = await DatabaseHelper.instance.getTopTags(limit: 4);
      if (mounted) {
        setState(() {
          _topTags = tags;
        });
      }
    } catch (e) {
      debugPrint('load top tags error: $e');
    }
  }

  Future<void> _loadFavorites() async {
    try {
      final favs = await FavoritesPersistence.loadFavorites();
      if (mounted) {
        setState(() {
          _favoriteIds = favs;
        });
        _updateAlbumComputations();
      }
    } catch (_) {}
  }

  Future<void> _loadCustomAlbums() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/custom_albums.json');
      if (await file.exists()) {
        final decoded =
            json.decode(await file.readAsString()) as Map<String, dynamic>;
        if (mounted) {
          setState(() {
            _customAlbums = decoded.map(
              (k, v) => MapEntry(k, List<String>.from(v)),
            );
          });
          _updateAlbumComputations();
        }
      }
    } catch (e) {
      debugPrint('load albums error: $e');
    } finally {
      if (mounted) setState(() => _isInit = false);
    }
  }

  Future<void> _loadRecentlyDeletedCount() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/recently_deleted.json');
      if (await file.exists()) {
        final Map<String, dynamic> data = json.decode(
          await file.readAsString(),
        );
        final cutoff = DateTime.now().subtract(const Duration(days: 30));
        int count = 0;
        data.forEach((_, val) {
          final d = DateTime.tryParse(val['deletedAt'] ?? '');
          if (d != null && d.isAfter(cutoff)) count++;
        });
        if (mounted) setState(() => _recentlyDeletedCount = count);
      }
    } catch (_) {}
  }

  Future<void> _saveCustomAlbums() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/custom_albums.json');
      await file.writeAsString(json.encode(_customAlbums));
    } catch (e) {
      debugPrint('save albums error: $e');
    }
  }

  String _getFolderName(String path) {
    if (path.startsWith('http')) return 'Downloads';
    try {
      String name = File(
        path,
      ).parent.path.split(Platform.isWindows ? '\\' : '/').last;
      if (name.isEmpty || name == '0' || name == 'emulated') return 'Other';
      final lowerName = name.toLowerCase();
      if (lowerName == 'cameraroll' ||
          lowerName == 'camera-roll' ||
          lowerName == 'camera' ||
          lowerName == 'dcim') {
        return 'Camera';
      }
      if (lowerName.contains('whatsapp')) return 'WhatsApp';
      if (lowerName.contains('screenshot') ||
          lowerName.contains('screen shot') ||
          lowerName.contains('screen-shot')) {
        return 'Screenshots';
      }
      if (lowerName.contains('download')) return 'Downloads';
      if (lowerName.contains('telegram')) return 'Telegram';
      if (lowerName.contains('instagram')) return 'Instagram';
      if (name.length > 1) {
        return name[0].toUpperCase() + name.substring(1);
      }
      return name;
    } catch (_) {
      return 'Other';
    }
  }

  Future<void> _createNewAlbum() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'New Album',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Enter album name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final t = ctrl.text.trim();
              if (t.isNotEmpty) Navigator.pop(ctx, t);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF3F51B5),
              foregroundColor: Colors.white,
            ),
            child: const Text('Next'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    if (!mounted) return;
    if (_customAlbums.containsKey(name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Album with this name already exists!')),
      );
      return;
    }
    if (!mounted) return;
    final ids = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(
        builder: (_) => MediaSelectorScreen(
          allItems: widget.allItems,
          title: 'Add to $name',
        ),
      ),
    );
    if (ids != null && ids.isNotEmpty) {
      setState(() => _customAlbums[name] = ids);
      _updateAlbumComputations();
      await _saveCustomAlbums();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Created '$name' with ${ids.length} items")),
      );
    }
  }

  void _deleteSelectedCustomAlbums() {
    final toDelete = _selectedAlbumNames.toList();
    if (toDelete.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only custom albums can be deleted.')),
      );
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Delete ${toDelete.length} album(s)?'),
        content: const Text(
          'This removes the album containers. Your photos are NOT deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              setState(() {
                for (final n in toDelete) {
                  _customAlbums.remove(n);
                }
                _selectionMode = false;
                _selectedAlbumNames.clear();
              });
              _updateAlbumComputations();
              await _saveCustomAlbums();
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _openAlbum(_AlbumItemUI album) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AlbumDetailScreen(
          albumName: album.name,
          items: album.items,
          isCustom: album.isCustom,
          onItemTapped: widget.onItemTapped,
          onAlbumChanged: _loadAll,
        ),
      ),
    );
  }

  Widget _buildCover(GalleryItem? item, {bool isFolder = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (isFolder || item == null) {
      return Container(
        color: isDark ? const Color(0xFF1E1C15) : const Color(0xFFFFF8E1),
        child: const Center(
          child: Icon(Icons.folder, color: Color(0xFFFFB300), size: 36),
        ),
      );
    }
    if (item.mediaType == 'video') {
      return Stack(
        children: [
          Positioned.fill(
            child: FastMediaPreview(item: item, fit: BoxFit.cover),
          ),
          const Center(
            child: Icon(Icons.play_circle_fill, color: Colors.white, size: 24),
          ),
        ],
      );
    }
    return FastMediaPreview(item: item, fit: BoxFit.cover);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_isInit) return const Center(child: CircularProgressIndicator());

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = Theme.of(context).colorScheme.onSurface;
    final subColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.6);
    final bg = Theme.of(context).scaffoldBackgroundColor;

    // Use pre-computed state lists to avoid heavy computations in the build method.
    final folderAlbums = _folderAlbums;
    final customAlbums = _customAlbumsUI;
    final ghostCreatedAlbums = _ghostCreatedAlbums;
    final deviceAlbums = _deviceAlbums;
    final favoriteAlbums = _favoriteAlbums;
    final allCategoryAlbums = _allCategoryAlbums;

    List<_AlbumItemUI> searchFiltered(List<_AlbumItemUI> original) {
      if (_searchQuery.isEmpty) return original;
      return original
          .where(
            (a) => a.name.toLowerCase().contains(_searchQuery.toLowerCase()),
          )
          .toList();
    }

    Widget buildCategoryPage(String category, List<_AlbumItemUI> albums) {
      final filtered = searchFiltered(albums);

      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            bottom: 24 + MediaQuery.of(context).padding.bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (filtered.isEmpty)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Text('No albums found'),
                  ),
                )
              else if (_isGridView)
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: ResponsiveHelper.responsiveGridColumns(
                      context,
                      baseColumns: 3,
                      min: 2,
                      max: 8,
                    ),
                    crossAxisSpacing: context.isWatch ? 6 : 12,
                    mainAxisSpacing: context.isWatch ? 6 : 12,
                    childAspectRatio: 0.72,
                  ),
                  itemCount: filtered.length,
                  itemBuilder: (ctx, i) {
                    final album = filtered[i];
                    final cover = album.cover;
                    final isSelected = _selectedAlbumNames.contains(album.name);

                    return GestureDetector(
                      onTap: () {
                        if (_selectionMode) {
                          setState(() {
                            if (isSelected) {
                              _selectedAlbumNames.remove(album.name);
                            } else {
                              if (album.isCustom) {
                                _selectedAlbumNames.add(album.name);
                              }
                            }
                            if (_selectedAlbumNames.isEmpty) {
                              _selectionMode = false;
                            }
                          });
                        } else {
                          _openAlbum(album);
                        }
                      },
                      onLongPress: () {
                        if (!_selectionMode && album.isCustom) {
                          setState(() {
                            _selectionMode = true;
                            _selectedAlbumNames.add(album.name);
                          });
                        }
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: isSelected
                                ? Colors.blue.withValues(alpha: 0.6)
                                : (isDark
                                      ? Colors.white.withValues(alpha: 0.08)
                                      : Colors.black.withValues(alpha: 0.06)),
                            width: isSelected ? 2 : 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: isDark
                                  ? Colors.black.withValues(alpha: 0.4)
                                  : Colors.black.withValues(alpha: 0.1),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(17),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Positioned.fill(child: _buildCover(cover)),
                              Positioned.fill(
                                child: Container(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: [
                                        Colors.transparent,
                                        Colors.black.withValues(alpha: 0.15),
                                        Colors.black.withValues(alpha: 0.85),
                                      ],
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      stops: const [0.35, 0.65, 1.0],
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                bottom: 10,
                                left: 10,
                                right: 10,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      album.name,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                        shadows: [
                                          Shadow(
                                            blurRadius: 4,
                                            color: Colors.black54,
                                          ),
                                        ],
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${album.count} items',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: Colors.white.withValues(alpha: 0.75),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (_selectionMode && album.isCustom)
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 150,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isSelected
                                            ? Colors.blue.withValues(alpha: 0.25)
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(17),
                                      ),
                                    ),
                                  ),
                                ),
                              if (_selectionMode && album.isCustom)
                                Positioned(
                                  top: 6,
                                  right: 6,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: isSelected
                                          ? Colors.blue
                                          : Colors.black38,
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 1.5,
                                      ),
                                    ),
                                    padding: const EdgeInsets.all(2),
                                    child: Icon(
                                      isSelected ? Icons.check : Icons.circle,
                                      color: isSelected
                                          ? Colors.white
                                          : Colors.transparent,
                                      size: 13,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                )
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: filtered.length,
                  separatorBuilder: (ctx, idx) => Divider(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.black.withValues(alpha: 0.06),
                    height: 1,
                  ),
                  itemBuilder: (ctx, i) {
                    final album = filtered[i];
                    final cover = album.cover;
                    final isSelected = _selectedAlbumNames.contains(album.name);

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        vertical: 4,
                        horizontal: 8,
                      ),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 50,
                          height: 50,
                          child: _buildCover(cover),
                        ),
                      ),
                      title: Text(
                        album.name,
                        style: TextStyle(
                          color: textColor,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      subtitle: Text(
                        '${album.count} items',
                        style: TextStyle(color: subColor, fontSize: 13),
                      ),
                      trailing: _selectionMode && album.isCustom
                          ? Checkbox(
                              value: isSelected,
                              onChanged: (val) {
                                setState(() {
                                  if (val == true) {
                                    _selectedAlbumNames.add(album.name);
                                  } else {
                                    _selectedAlbumNames.remove(album.name);
                                  }
                                  if (_selectedAlbumNames.isEmpty) {
                                    _selectionMode = false;
                                  }
                                });
                              },
                            )
                          : Icon(Icons.chevron_right, color: subColor),
                      onTap: () {
                        if (_selectionMode) {
                          if (album.isCustom) {
                            setState(() {
                              if (isSelected) {
                                _selectedAlbumNames.remove(album.name);
                              } else {
                                _selectedAlbumNames.add(album.name);
                              }
                              if (_selectedAlbumNames.isEmpty) {
                                _selectionMode = false;
                              }
                            });
                          }
                        } else {
                          _openAlbum(album);
                        }
                      },
                      onLongPress: () {
                        if (!_selectionMode && album.isCustom) {
                          setState(() {
                            _selectionMode = true;
                            _selectedAlbumNames.add(album.name);
                          });
                        }
                      },
                    );
                  },
                ),
            ],
          ),
        ),
      );
    }

    Widget buildIntelligentPage() {
      if (_searchQuery.isNotEmpty) {
        return buildCategoryPage("IntelligentSearch", allCategoryAlbums);
      }
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.only(left: 16, right: 16, bottom: 24),
          child: GridView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: ResponsiveHelper.responsiveGridColumns(
                context,
                baseColumns: 3,
                min: 2,
                max: 8,
              ),
              crossAxisSpacing: context.isWatch ? 6 : 12,
              mainAxisSpacing: context.isWatch ? 6 : 12,
              childAspectRatio: 0.72,
            ),
            children: [
              _classCard(
                context,
                'People',
                '${widget.peopleList.length}',
                _buildPeopleCollage(context),
                widget.onPeoplePressed,
              ),
              _classCard(
                context,
                'Places',
                '$_placesCount',
                _buildPlacesMap(context),
                widget.onMapPressed,
              ),
              _classCard(
                context,
                'Calendar',
                '$_uniqueDaysCount Days',
                _buildCalendarCollage(context),
                () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => CalendarScreen(
                        allItems: widget.allItems,
                        onItemTapped: widget.onItemTapped,
                      ),
                    ),
                  ).then((_) {
                    widget.onRefresh();
                  });
                },
              ),
              _classCard(
                context,
                'Favorites',
                '${_favoriteIds.length}',
                _buildFavoritesCollage(context),
                () {
                  final favItems = widget.allItems
                      .where((x) => _favoriteIds.contains(x.id))
                      .toList();
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => AlbumDetailScreen(
                        albumName: 'Favorites',
                        items: favItems,
                        onItemTapped: widget.onItemTapped,
                      ),
                    ),
                  ).then((_) {
                    _loadFavorites();
                  });
                },
              ),
              _classCard(
                context,
                'Documents',
                '${_documentMediaIds.length}',
                _buildTagCollage(context, _documentMediaIds),
                () {
                  final Set<String> targetIds = Set<String>.from(
                    _documentMediaIds,
                  );
                  final docItems = widget.allItems
                      .where((x) => targetIds.contains(x.id))
                      .toList();
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => AlbumDetailScreen(
                        albumName: 'Documents',
                        items: docItems,
                        onItemTapped: widget.onItemTapped,
                      ),
                    ),
                  );
                },
                showPremiumIcon: false,
              ),
              ..._topTags.map((tag) {
                final label = tag['label'] as String;
                final count = tag['count'] as int;
                final mediaIds = List<String>.from(tag['media_ids']);
                final title = label.isNotEmpty
                    ? label[0].toUpperCase() + label.substring(1)
                    : '';
                return _classCard(
                  context,
                  title,
                  '$count',
                  _buildTagCollage(context, mediaIds),
                  () {
                    final Set<String> targetIds = Set<String>.from(mediaIds);
                    final tagItems = widget.allItems
                        .where((x) => targetIds.contains(x.id))
                        .toList();
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AlbumDetailScreen(
                          albumName: title,
                          items: tagItems,
                          onItemTapped: widget.onItemTapped,
                        ),
                      ),
                    );
                  },
                  showPremiumIcon: false,
                );
              }),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: bg,
      // ── App bar ────────────────────────────────────────────────────────
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        title: _selectionMode
            ? Text(
                '${_selectedAlbumNames.length} selected',
                style: TextStyle(color: textColor, fontWeight: FontWeight.bold),
              )
            : Text(
                '',
                style: TextStyle(
                  color: textColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
              ),
        actions: _selectionMode
            ? [
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _deleteSelectedCustomAlbums,
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _selectionMode = false;
                    _selectedAlbumNames.clear();
                  }),
                  child: const Text('Cancel'),
                ),
              ]
            : [
                if (_selectedCategory != "Intelligent") ...[
                  IconButton(
                    icon: Icon(_isGridView ? Icons.view_list : Icons.grid_view),
                    tooltip: _isGridView ? 'List view' : 'Grid view',
                    onPressed: () => setState(() {
                      _isGridView = !_isGridView;
                    }),
                  ),
                ],
                if (_selectedCategory == "Custom") ...[
                  IconButton(
                    icon: const Icon(Icons.check_box_outline_blank),
                    tooltip: 'Select',
                    onPressed: () => setState(() {
                      _selectionMode = true;
                      _selectedAlbumNames.clear();
                    }),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'New album',
                    onPressed: _createNewAlbum,
                  ),
                ],
              ],
      ),
      body: RefreshIndicator(
        onRefresh: widget.onRefresh,
        child: NestedScrollView(
          headerSliverBuilder: (BuildContext context, bool innerBoxIsScrolled) {
            return <Widget>[
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Utilities Grid at the very top ──────────────────────────
                    _buildUtilitiesGrid(context),
                    const SizedBox(height: 16),

                    // ── Search Bar ──────────────────────────────────────────────
                    Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.06)
                              : Colors.black.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.1)
                                : Colors.black.withValues(alpha: 0.06),
                            width: 1,
                          ),
                        ),
                        child: TextField(
                          controller: _searchController,
                          style: TextStyle(color: textColor, fontSize: 15),
                          decoration: InputDecoration(
                            hintText: 'Search albums...',
                            hintStyle: TextStyle(
                              color: isDark ? Colors.white54 : Colors.black54,
                              fontSize: 15,
                            ),
                            prefixIcon: Icon(
                              Icons.search,
                              color: isDark ? Colors.white70 : Colors.black54,
                            ),
                            suffixIcon: _searchQuery.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear),
                                    onPressed: () {
                                      _searchController.clear();
                                    },
                                  )
                                : null,
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 12,
                            ),
                          ),
                        ),
                      ),
                    ),

                    // ── Category Switcher ───────────────────────────────────────
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.only(
                        bottom: 20,
                        left: 16,
                        right: 16,
                      ),
                      child: Row(
                        children: [
                          _buildCategorySegment(
                            "Intelligent",
                            "Intelligent",
                            Icons.auto_awesome,
                          ),
                          _buildCategorySegment(
                            "Device",
                            "On Device",
                            Icons.phone_android,
                          ),
                          _buildCategorySegment(
                            "Ghost",
                            "Ghost Created",
                            Icons.supervised_user_circle_outlined,
                          ),
                          _buildCategorySegment(
                            "Custom",
                            "Custom",
                            Icons.folder_copy,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ];
          },
          body: PageView(
            controller: _categoryPageController,
            onPageChanged: (index) {
              if (_selectedCategory != _categories[index]) {
                setState(() {
                  _selectedCategory = _categories[index];
                  _selectionMode = false;
                  _selectedAlbumNames.clear();
                });
              }
            },
            children: [
              buildIntelligentPage(),
              buildCategoryPage("Device", deviceAlbums),
              buildCategoryPage("Ghost", ghostCreatedAlbums),
              buildCategoryPage("Custom", customAlbums),
            ],
          ),
        ),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Widget _buildCategorySegment(String category, String label, IconData icon) {
    final isSelected = _selectedCategory == category;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isIntelligent = category == "Intelligent";

    final activeBg = Theme.of(context).colorScheme.primary;
    final activeText = Theme.of(context).colorScheme.onPrimary;
    final inactiveText = isDark ? Colors.white70 : Colors.black87;

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () {
          setState(() {
            _selectedCategory = category;
            _selectionMode = false;
            _selectedAlbumNames.clear();
          });
          _categoryPageController.animateToPage(
            _categories.indexOf(category),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? (isIntelligent ? null : activeBg)
                : (isDark
                      ? Colors.white.withValues(alpha: 0.04)
                      : Colors.black.withValues(alpha: 0.03)),
            gradient: isSelected && isIntelligent
                ? const LinearGradient(
                    colors: [
                      Color(0xFFEC407A),
                      Color.fromARGB(255, 0, 166, 255),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            borderRadius: BorderRadius.circular(20),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color:
                          (isIntelligent ? const Color(0xFFEC407A) : activeBg)
                              .withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : [],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (category == "Ghost") ...[
                Text(
                  "👻",
                  style: TextStyle(
                    fontSize: 15,
                    color: isSelected
                        ? (isIntelligent ? Colors.white : activeText)
                        : inactiveText.withValues(alpha: 0.6),
                  ),
                ),
              ] else ...[
                Icon(
                  icon,
                  size: 15,
                  color: isSelected
                      ? (isIntelligent ? Colors.white : activeText)
                      : inactiveText.withValues(alpha: 0.6),
                ),
              ],
              const SizedBox(width: 6),

              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: isSelected
                      ? (isIntelligent ? Colors.white : activeText)
                      : inactiveText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUtilitiesGrid(BuildContext ctx) {
    final isDark = Theme.of(ctx).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: context.isWatch
            ? 1
            : (context.isTV ? 4 : (context.isTablet ? 3 : 2)),
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 2.3, // wider cards for 2-column grid
        children: [
          _utilityGridCard(
            ctx,
            icon: Icons.shield_outlined,
            color: const Color(0xFFFF9800), // Amber
            title: 'Secure Vault',
            count: 0,
            onTap: _openVault,
          ),
          _utilityGridCard(
            ctx,
            icon: Icons.cleaning_services_outlined,
            color: const Color(0xFFEC407A),
            title: 'Cleanup suggestions',
            count: 0,
            onTap: () {
              Navigator.push(
                ctx,
                MaterialPageRoute(
                  builder: (_) =>
                      CleanupSuggestionsScreen(appTheme: widget.appTheme),
                ),
              );
            },
          ),
          _utilityGridCard(
            ctx,
            icon: Icons.delete_outline,
            color: const Color(0xFFAB47BC),
            title: 'Recently deleted',
            count: _recentlyDeletedCount,
            onTap: () => Navigator.push(
              ctx,
              MaterialPageRoute(builder: (_) => const RecentlyDeletedScreen()),
            ).then((_) => _loadRecentlyDeletedCount()),
          ),
          _utilityGridCard(
            ctx,
            icon: Icons.dashboard_customize_outlined,
            color: Colors.blueAccent,
            title: 'Collage Creator',
            count: 0,
            onTap: () {
              Navigator.push(
                ctx,
                MaterialPageRoute(
                  builder: (_) => const CollageCreatorScreen(selectedItems: []),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _utilityGridCard(
    BuildContext ctx, {
    required IconData icon,
    required Color color,
    required String title,
    required int count,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(ctx).brightness == Brightness.dark;
    final txtCol = isDark ? Colors.white : Colors.black87;
    return Material(
      color: isDark
          ? Colors.white.withValues(alpha: 0.04)
          : Colors.black.withValues(alpha: 0.02),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: txtCol,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (count > 0) ...[
                      const SizedBox(height: 2),
                      Text(
                        '$count items',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _classCard(
    BuildContext ctx,
    String label,
    String count,
    Widget collage,
    VoidCallback onTap, {
    bool showPremiumIcon = false,
  }) {
    final isDark = Theme.of(ctx).brightness == Brightness.dark;
    final txtCol = isDark ? Colors.white : Colors.black87;
    final subCol = isDark ? Colors.white60 : Colors.black54;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.05),
          ),
          boxShadow: [
            BoxShadow(
              color: isDark
                  ? Colors.black.withValues(alpha: 0.3)
                  : Colors.black.withValues(alpha: 0.06),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
          color: isDark ? Colors.white.withValues(alpha: 0.04) : Colors.white,
        ),
        padding: const EdgeInsets.all(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: collage,
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: txtCol,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                count,
                style: TextStyle(fontSize: 10.5, color: subCol),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPeopleCollage(BuildContext ctx) {
    final covers = widget.peopleList
        .where((p) => (p['cover_image'] as String?)?.isNotEmpty == true)
        .take(4)
        .toList();
    return _collageContainer(ctx, 4, (i) {
      if (i < covers.length) {
        final p = covers[i];
        final path = p['cover_image'] as String;
        final isVideo =
            path.toLowerCase().endsWith('.mp4') ||
            path.toLowerCase().endsWith('.mov') ||
            path.toLowerCase().endsWith('.avi');
        return ClipOval(
          child: p['cover_w'] != null && (p['cover_w'] as int? ?? 0) > 0
              ? FacePreview(
                  imagePath: path,
                  x: p['cover_x'] as int? ?? 0,
                  y: p['cover_y'] as int? ?? 0,
                  w: p['cover_w'] as int? ?? 0,
                  h: p['cover_h'] as int? ?? 0,
                )
              : (path.startsWith('http')
                    ? Image.network(path, fit: BoxFit.cover)
                    : isVideo
                    ? VideoPreviewWidget(videoPath: path, maxWidth: 100)
                    : Image.file(
                        File(path),
                        cacheWidth: 100,
                        fit: BoxFit.cover,
                      )),
        );
      }
      return const CircleAvatar(
        backgroundColor: Colors.grey,
        child: Icon(Icons.person, size: 16, color: Colors.white70),
      );
    });
  }

  Widget _buildCalendarCollage(BuildContext ctx) {
    final sortedItems = List<GalleryItem>.from(widget.allItems)
      ..sort((a, b) => b.dateTimestamp.compareTo(a.dateTimestamp));

    final uniqueDates = <DateTime>[];
    final seenDays = <String>{};
    for (final item in sortedItems) {
      final dt = DateTime.fromMillisecondsSinceEpoch(item.dateTimestamp);
      final dayKey = '${dt.year}-${dt.month}-${dt.day}';
      if (!seenDays.contains(dayKey)) {
        seenDays.add(dayKey);
        uniqueDates.add(dt);
        if (uniqueDates.length >= 4) break;
      }
    }

    final isDark = Theme.of(ctx).brightness == Brightness.dark;
    final cardBg = isDark
        ? Theme.of(ctx).colorScheme.surfaceContainerHighest
        : Colors.white;
    final primaryColor = Theme.of(ctx).colorScheme.primary;
    final months = [
      'JAN',
      'FEB',
      'MAR',
      'APR',
      'MAY',
      'JUN',
      'JUL',
      'AUG',
      'SEP',
      'OCT',
      'NOV',
      'DEC',
    ];

    return _collageContainer(ctx, 4, (i) {
      if (i < uniqueDates.length) {
        final dt = uniqueDates[i];
        final monthStr = months[dt.month - 1];
        return Container(
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                monthStr,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: primaryColor,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${dt.day}',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(ctx).colorScheme.onSurface,
                ),
              ),
            ],
          ),
        );
      }
      return Container(
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.grey[200],
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          Icons.calendar_today,
          size: 16,
          color: isDark ? Colors.white38 : Colors.black38,
        ),
      );
    });
  }

  Widget _buildPlacesMap(BuildContext ctx) {
    final isDark = Theme.of(ctx).brightness == Brightness.dark;
    final mapStyleId = UIPreferenceProvider.instance.mapStyleId;
    String urlTemplate = isDark
        ? "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png"
        : "https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png";
    List<String> subdomains = const ['a', 'b', 'c', 'd'];

    if (mapStyleId == 'voyager') {
      urlTemplate = "https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png";
      subdomains = const ['a', 'b', 'c', 'd'];
    } else if (mapStyleId == 'dark') {
      urlTemplate = "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png";
      subdomains = const ['a', 'b', 'c', 'd'];
    } else if (mapStyleId == 'positron') {
      urlTemplate = "https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png";
      subdomains = const ['a', 'b', 'c', 'd'];
    } else if (mapStyleId == 'satellite') {
      urlTemplate = "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}";
      subdomains = const [];
    }

    // 1. Get all items with GPS coordinates
    final gpsItems = widget.allItems.where((item) => item.hasGps).toList();

    // 2. Group by country
    final Map<String, List<GalleryItem>> countryGroups = {};
    for (final item in gpsItems) {
      String country = (item.countryName ?? '').trim();
      if (country.isEmpty) {
        final parts = item.location.split(',');
        if (parts.isNotEmpty) {
          country = parts.last.trim();
        }
      }
      if (country.isEmpty ||
          country.toLowerCase() == 'unknown location' ||
          country.toLowerCase() == 'unknown') {
        continue;
      }
      countryGroups.putIfAbsent(country, () => []).add(item);
    }

    List<GalleryItem> countryItems = [];
    String countryName = '';
    if (countryGroups.isNotEmpty) {
      final sortedCountries = countryGroups.entries.toList()
        ..sort((a, b) => b.value.length.compareTo(a.value.length));
      countryName = sortedCountries.first.key;
      countryItems = sortedCountries.first.value;
    }

    // 3. Cluster this country's media items at 0.1° resolution (~11 km)
    final Map<String, List<GalleryItem>> clusters = {};
    for (final item in countryItems) {
      final latStr = item.latitude.toStringAsFixed(1);
      final lngStr = item.longitude.toStringAsFixed(1);
      final key = '${latStr}_$lngStr';
      clusters.putIfAbsent(key, () => []).add(item);
    }

    final hasLocations = countryItems.isNotEmpty;
    LatLngBounds? mapBounds;
    LatLng mapCenter = const LatLng(20.5937, 78.9629); // Default center

    if (hasLocations) {
      final countryBounds = _getCountryBounds(countryName);
      if (countryBounds != null) {
        mapBounds = countryBounds;
        mapCenter = LatLng(
          (countryBounds.southWest.latitude +
                  countryBounds.northEast.latitude) /
              2,
          (countryBounds.southWest.longitude +
                  countryBounds.northEast.longitude) /
              2,
        );
      } else {
        // Fallback: use item points but expand the bounds to feel like a "country" view rather than local city/state view
        final List<LatLng> points = countryItems
            .map((itm) => LatLng(itm.latitude, itm.longitude))
            .toList();
        final baseBounds = LatLngBounds.fromPoints(points);
        // Expand the bounds by a reasonable margin (e.g., 2.5 degrees on each side)
        mapBounds = LatLngBounds(
          LatLng(
            baseBounds.southWest.latitude - 2.5,
            baseBounds.southWest.longitude - 2.5,
          ),
          LatLng(
            baseBounds.northEast.latitude + 2.5,
            baseBounds.northEast.longitude + 2.5,
          ),
        );
        mapCenter = LatLng(
          (mapBounds.southWest.latitude + mapBounds.northEast.latitude) / 2,
          (mapBounds.southWest.longitude + mapBounds.northEast.longitude) / 2,
        );
      }
    }

    final markers = clusters.entries.map((entry) {
      final clusterItems = entry.value;
      double sumLat = 0;
      double sumLng = 0;
      for (final itm in clusterItems) {
        sumLat += itm.latitude;
        sumLng += itm.longitude;
      }
      final double avgLat = sumLat / clusterItems.length;
      final double avgLng = sumLng / clusterItems.length;

      clusterItems.sort((a, b) => b.dateTimestamp.compareTo(a.dateTimestamp));
      final coverItem = clusterItems.first;

      return Marker(
        point: LatLng(avgLat, avgLng),
        width: 32,
        height: 32,
        alignment: Alignment.center,
        child: MiniMapMarker(
          assetId: coverItem.id,
          coverPath: coverItem.imageUrl,
          count: clusterItems.length,
          isVideo: coverItem.mediaType == 'video',
        ),
      );
    }).toList();

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        children: [
          AbsorbPointer(
            absorbing:
                true, // Let taps outside the zoom buttons fall through to parent detector
            child: FlutterMap(
              mapController: _miniMapController,
              options: MapOptions(
                initialCameraFit: mapBounds != null
                    ? CameraFit.bounds(
                        bounds: mapBounds,
                        padding: const EdgeInsets.all(8),
                      )
                    : null,
                initialCenter: mapCenter,
                initialZoom: hasLocations ? 3.0 : 2.0,
                minZoom: 0.0,
                maxZoom: 18.0,
                interactionOptions: const InteractionOptions(
                  flags:
                      InteractiveFlag.none, // Disable pinch zoom, panning, etc.
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate: urlTemplate,
                  subdomains: subdomains,
                  userAgentPackageName: 'in.sddev.ghost_gallery',
                  tileProvider: CachedTileProvider(),
                ),
                if (markers.isNotEmpty) MarkerLayer(markers: markers),
              ],
            ),
          ),
          if (hasLocations)
            Positioned(
              right: 6,
              bottom: 6,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildZoomButton(
                    icon: Icons.add,
                    onPressed: () {
                      final currentCenter = _miniMapController.camera.center;
                      final currentZoom = _miniMapController.camera.zoom;
                      _miniMapController.move(
                        currentCenter,
                        (currentZoom + 0.8).clamp(0.0, 18.0),
                      );
                    },
                  ),
                  const SizedBox(height: 4),
                  _buildZoomButton(
                    icon: Icons.remove,
                    onPressed: () {
                      final currentCenter = _miniMapController.camera.center;
                      final currentZoom = _miniMapController.camera.zoom;
                      _miniMapController.move(
                        currentCenter,
                        (currentZoom - 0.8).clamp(0.0, 18.0),
                      );
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildZoomButton({
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.25),
            width: 0.8,
          ),
          boxShadow: const [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 3,
              offset: Offset(0, 1.5),
            ),
          ],
        ),
        child: Icon(icon, size: 13, color: Colors.white),
      ),
    );
  }

  LatLngBounds? _getCountryBounds(String countryName) {
    final name = countryName.toLowerCase().trim();
    if (name.contains('india')) {
      return LatLngBounds(const LatLng(6.5, 68.1), const LatLng(35.7, 97.4));
    } else if (name.contains('united states') ||
        name.contains('usa') ||
        name.contains('us')) {
      return LatLngBounds(
        const LatLng(24.4, -125.0),
        const LatLng(49.4, -66.9),
      );
    } else if (name.contains('united kingdom') ||
        name.contains('uk') ||
        name.contains('great britain')) {
      return LatLngBounds(const LatLng(49.9, -8.6), const LatLng(60.9, 1.8));
    } else if (name.contains('germany') || name.contains('deutschland')) {
      return LatLngBounds(const LatLng(47.2, 5.8), const LatLng(55.1, 15.0));
    } else if (name.contains('japan')) {
      return LatLngBounds(const LatLng(24.0, 122.9), const LatLng(45.6, 146.3));
    } else if (name.contains('australia')) {
      return LatLngBounds(
        const LatLng(-44.0, 112.9),
        const LatLng(-10.0, 154.0),
      );
    } else if (name.contains('canada')) {
      return LatLngBounds(
        const LatLng(41.7, -141.0),
        const LatLng(83.1, -52.6),
      );
    } else if (name.contains('france')) {
      return LatLngBounds(const LatLng(41.3, -5.2), const LatLng(51.1, 9.6));
    } else if (name.contains('brazil') || name.contains('brasil')) {
      return LatLngBounds(const LatLng(-33.8, -74.0), const LatLng(5.3, -34.7));
    }
    return null;
  }

  Widget _buildFavoritesCollage(BuildContext ctx) {
    final items = widget.allItems
        .where((x) => _favoriteIds.contains(x.id))
        .take(4)
        .toList();
    final isDark = Theme.of(ctx).brightness == Brightness.dark;
    return _collageContainer(ctx, 4, (i) {
      if (i < items.length) {
        final item = items[i];
        final isVideo = item.mediaType == 'video';
        return ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: item.imageUrl.startsWith('http')
              ? Image.network(item.imageUrl, fit: BoxFit.cover)
              : isVideo
              ? VideoPreviewWidget(videoPath: item.imageUrl, maxWidth: 100)
              : Image.file(
                  File(item.imageUrl),
                  cacheWidth: 100,
                  fit: BoxFit.cover,
                ),
        );
      }
      return Container(
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.grey[200],
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(Icons.favorite_border, size: 16, color: Colors.pinkAccent),
      );
    });
  }

  Widget _buildTagCollage(BuildContext ctx, List<String> mediaIds) {
    final Set<String> targetIds = Set<String>.from(mediaIds);
    final items = widget.allItems
        .where((x) => targetIds.contains(x.id))
        .take(4)
        .toList();
    return _collageContainer(ctx, 4, (i) {
      if (i < items.length) {
        final item = items[i];
        final isVideo = item.mediaType == 'video';
        return ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: item.imageUrl.startsWith('http')
              ? Image.network(item.imageUrl, fit: BoxFit.cover)
              : isVideo
              ? VideoPreviewWidget(videoPath: item.imageUrl, maxWidth: 100)
              : Image.file(
                  File(item.imageUrl),
                  cacheWidth: 100,
                  fit: BoxFit.cover,
                ),
        );
      }
      return Container(
        decoration: BoxDecoration(
          color: Colors.grey[300],
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Icon(Icons.label_outline, size: 16, color: Colors.white70),
      );
    });
  }

  Widget _collageContainer(
    BuildContext ctx,
    int count,
    Widget Function(int) builder,
  ) {
    final isDark = Theme.of(ctx).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.grey[100],
        borderRadius: BorderRadius.circular(14),
      ),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 3,
          mainAxisSpacing: 3,
        ),
        itemCount: count,
        itemBuilder: (_, i) => builder(i),
      ),
    );
  }

  Widget _utilityRow(
    BuildContext ctx, {
    required IconData icon,
    required Color color,
    required String title,
    required int count,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(ctx).brightness == Brightness.dark;
    final txtCol = isDark ? Colors.white : Colors.black87;
    final subCol = isDark ? Colors.white60 : Colors.black54;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Material(
        color: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.grey.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color, size: 20),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: txtCol,
                    ),
                  ),
                ),
                if (count > 0) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Icon(Icons.chevron_right_rounded, size: 20, color: subCol),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openVault() async {
    if (Platform.isAndroid) {
      final granted = await MediaPermissionService.ensureManageMediaPermission(
        context,
      );
      if (!granted) return;
    }

    final configured = await VaultService.instance.isVaultConfigured();
    if (!mounted) return;
    if (!configured) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const VaultSetupScreen()),
      ).then((_) => setState(() {}));
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          settings: const RouteSettings(name: 'vault'),
          builder: (_) => const VaultScreen(),
        ),
      ).then((_) => setState(() {}));
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
class _AlbumItemUI {
  final String name;
  final int count;
  final List<GalleryItem> items;
  final bool isCustom;

  const _AlbumItemUI({
    required this.name,
    required this.count,
    required this.items,
    this.isCustom = false,
  });

  GalleryItem? get cover {
    if (items.isEmpty) return null;
    final sorted = List<GalleryItem>.from(items)
      ..sort((a, b) => b.dateTimestamp.compareTo(a.dateTimestamp));
    return sorted.first;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Multi-select media picker
// ─────────────────────────────────────────────────────────────────────────────
class MediaSelectorScreen extends StatefulWidget {
  final List<GalleryItem> allItems;
  final String title;

  const MediaSelectorScreen({
    super.key,
    required this.allItems,
    required this.title,
  });

  @override
  State<MediaSelectorScreen> createState() => _MediaSelectorScreenState();
}

class _MediaSelectorScreenState extends State<MediaSelectorScreen> {
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    final textColor = Theme.of(context).colorScheme.onSurface;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
        foregroundColor: textColor,
        elevation: 0,
        title: Text(
          widget.title,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _selected.toList()),
            child: Text(
              'Done (${_selected.length})',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15,
                color: Color(0xFF3F51B5),
              ),
            ),
          ),
        ],
      ),
      body: widget.allItems.isEmpty
          ? const Center(child: Text('No items available.'))
          : GridView.builder(
              padding: const EdgeInsets.all(10),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: ResponsiveHelper.responsiveGridColumns(
                  context,
                  baseColumns: 3,
                  min: 2,
                  max: 8,
                ),
                crossAxisSpacing: 6,
                mainAxisSpacing: 6,
              ),
              itemCount: widget.allItems.length,
              itemBuilder: (ctx, i) {
                final item = widget.allItems[i];
                final isSelected = _selected.contains(item.id);
                final isVideo = item.mediaType == 'video';

                return GestureDetector(
                  onTap: () => setState(() {
                    if (isSelected) {
                      _selected.remove(item.id);
                    } else {
                      _selected.add(item.id);
                    }
                  }),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        FastMediaPreview(item: item, fit: BoxFit.cover),
                        if (isVideo)
                          const Center(
                            child: Icon(
                              Icons.play_circle_fill,
                              color: Colors.white,
                              size: 28,
                            ),
                          ),
                        if (isSelected)
                          Positioned.fill(
                            child: Container(
                              color: Colors.blue.withValues(alpha: 0.3),
                            ),
                          ),
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Icon(
                            isSelected
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            color: isSelected ? Colors.blue : Colors.white70,
                            size: 22,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// OtherAlbumsScreen — Grid of albums that are not on the main Albums tab
// ─────────────────────────────────────────────────────────────────────────────
class _OtherAlbumsScreen extends StatefulWidget {
  final List<_AlbumItemUI> albums;
  final Function(GalleryItem, [List<GalleryItem>?]) onItemTapped;
  final VoidCallback onRefresh;

  const _OtherAlbumsScreen({
    required this.albums,
    required this.onItemTapped,
    required this.onRefresh,
  });

  @override
  State<_OtherAlbumsScreen> createState() => _OtherAlbumsScreenState();
}

class _OtherAlbumsScreenState extends State<_OtherAlbumsScreen> {
  List<_AlbumItemUI> _albums = [];
  bool _selectionMode = false;
  final Set<int> _selectedAlbumIndices = {};

  @override
  void initState() {
    super.initState();
    _albums = List.from(widget.albums);
  }

  @override
  void didUpdateWidget(covariant _OtherAlbumsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.albums != oldWidget.albums) {
      _albums = List.from(widget.albums);
    }
  }

  void _deleteSelectedCustomAlbums() {
    final toDelete = _selectedAlbumIndices
        .where((i) => i < _albums.length && _albums[i].isCustom)
        .map((i) => _albums[i].name)
        .toList();
    if (toDelete.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only custom albums can be deleted.')),
      );
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Delete ${toDelete.length} album(s)?'),
        content: const Text(
          'This removes the album containers. Your photos are NOT deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                final dir = await getApplicationDocumentsDirectory();
                final file = File('${dir.path}/custom_albums.json');
                if (await file.exists()) {
                  final decoded =
                      json.decode(await file.readAsString())
                          as Map<String, dynamic>;
                  for (final n in toDelete) {
                    decoded.remove(n);
                  }
                  await file.writeAsString(json.encode(decoded));
                }
              } catch (e) {
                debugPrint(
                  "Error deleting albums from other albums screen: $e",
                );
              }
              setState(() {
                _albums.removeWhere((x) => toDelete.contains(x.name));
                _selectionMode = false;
                _selectedAlbumIndices.clear();
              });
              widget.onRefresh();
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = Theme.of(context).colorScheme.onSurface;
    final subColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.6);
    final bg = Theme.of(context).scaffoldBackgroundColor;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        foregroundColor: textColor,
        elevation: 0,
        title: _selectionMode
            ? Text(
                '${_selectedAlbumIndices.length} selected',
                style: TextStyle(color: textColor, fontWeight: FontWeight.bold),
              )
            : const Text(
                'Other albums',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
        leading: _selectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _selectionMode = false;
                  _selectedAlbumIndices.clear();
                }),
              )
            : null,
        actions: _selectionMode
            ? [
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _deleteSelectedCustomAlbums,
                ),
              ]
            : [
                IconButton(
                  icon: const Icon(Icons.check_box_outline_blank),
                  tooltip: 'Select',
                  onPressed: () => setState(() {
                    _selectionMode = true;
                    _selectedAlbumIndices.clear();
                  }),
                ),
              ],
      ),
      body: GridView.builder(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 16 + MediaQuery.of(context).padding.bottom,
        ),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: ResponsiveHelper.responsiveGridColumns(
            context,
            baseColumns: 3,
            min: 2,
            max: 8,
          ),
          crossAxisSpacing: context.isWatch ? 6 : 12,
          mainAxisSpacing: context.isWatch ? 8 : 16,
          childAspectRatio: 0.72,
        ),
        itemCount: _albums.length,
        itemBuilder: (ctx, i) {
          final album = _albums[i];
          final cover = album.cover;
          final isSelected = _selectedAlbumIndices.contains(i);

          return GestureDetector(
            onTap: () {
              if (_selectionMode) {
                setState(() {
                  if (isSelected) {
                    _selectedAlbumIndices.remove(i);
                  } else {
                    _selectedAlbumIndices.add(i);
                  }
                  if (_selectedAlbumIndices.isEmpty) _selectionMode = false;
                });
              } else {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AlbumDetailScreen(
                      albumName: album.name,
                      items: album.items,
                      isCustom: album.isCustom,
                      onItemTapped: widget.onItemTapped,
                      onAlbumChanged: () async {
                        widget.onRefresh();
                      },
                    ),
                  ),
                );
              }
            },
            onLongPress: () {
              if (!_selectionMode) {
                setState(() {
                  _selectionMode = true;
                  _selectedAlbumIndices.add(i);
                });
              }
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      width: double.infinity,
                      color: isDark ? Colors.white10 : Colors.grey[100],
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _buildCover(context, cover),
                          if (_selectionMode) ...[
                            Positioned.fill(
                              child: Container(
                                color: isSelected
                                    ? Colors.teal.withValues(alpha: 0.4)
                                    : Colors.black26,
                              ),
                            ),
                            Positioned(
                              top: 8,
                              right: 8,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? Colors.teal
                                      : Colors.white70,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 1.5,
                                  ),
                                ),
                                padding: const EdgeInsets.all(2),
                                child: Icon(
                                  isSelected ? Icons.check : Icons.circle,
                                  size: 14,
                                  color: isSelected
                                      ? Colors.white
                                      : Colors.transparent,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  album.name,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${album.count}',
                  style: TextStyle(fontSize: 10.5, color: subColor),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildCover(BuildContext context, GalleryItem? item) {
    if (item == null) {
      return Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Center(
          child: Icon(Icons.folder, color: Color(0xFFFFB300), size: 36),
        ),
      );
    }
    if (item.mediaType == 'video') {
      return Stack(
        children: [
          Positioned.fill(
            child: FastMediaPreview(item: item, fit: BoxFit.cover),
          ),
          const Center(
            child: Icon(Icons.play_circle_fill, color: Colors.white, size: 24),
          ),
        ],
      );
    }
    return FastMediaPreview(item: item, fit: BoxFit.cover);
  }
}

class MiniMapMarker extends StatelessWidget {
  final String coverPath;
  final String assetId;
  final int count;
  final bool isVideo;

  const MiniMapMarker({
    super.key,
    required this.coverPath,
    required this.assetId,
    required this.count,
    required this.isVideo,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = 26.0;

    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        // Pin tail
        Positioned(
          bottom: -3,
          child: CustomPaint(
            size: const Size(6, 4),
            painter: _MiniTrianglePainter(
              color: theme.colorScheme.surface,
              borderColor: theme.colorScheme.outline.withValues(alpha: 0.3),
            ),
          ),
        ),

        // Thumbnail circle
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: theme.colorScheme.surface, width: 1.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 2.0,
                offset: const Offset(0, 1.5),
              ),
            ],
          ),
          child: ClipOval(
            child: CachedMediaThumbnail(
              assetId: assetId,
              filePath: coverPath,
              isVideo: isVideo,
            ),
          ),
        ),

        // Badge count
        if (count > 1)
          Positioned(
            top: -4,
            right: -4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: theme.colorScheme.onPrimary,
                  width: 0.5,
                ),
              ),
              constraints: const BoxConstraints(minWidth: 10, minHeight: 10),
              child: Center(
                child: Text(
                  '+$count',
                  style: TextStyle(
                    color: theme.colorScheme.onPrimary,
                    fontSize: 7,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _MiniTrianglePainter extends CustomPainter {
  final Color color;
  final Color borderColor;

  _MiniTrianglePainter({required this.color, required this.borderColor});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0)
      ..close();

    canvas.drawPath(path, paint);

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;

    canvas.drawPath(path, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _MiniTrianglePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.borderColor != borderColor;
}
