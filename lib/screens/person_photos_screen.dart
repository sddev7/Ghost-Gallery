import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../widgets/premium_gate.dart';
import 'package:flutter/services.dart';
import '../models/gallery_item.dart';
import '../services/database_helper.dart';
import '../services/optional_features.dart';
import 'photo_viewer_screen.dart';
import 'tabs/fast_media_preview.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'collage_creator_screen.dart';
import 'people_management_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/trash_persistence.dart';
import '../services/media_permission_service.dart';
import 'package:ghost_gallery/widgets/add_to_album_dialog.dart';
import '../widgets/face_preview.dart';
import '../widgets/album_slideshow_background.dart';
import 'profile_cropper_screen.dart';
import 'vault/custom_media_picker.dart';
import '../services/ui_preference_provider.dart';
import '../widgets/photo_grid.dart';
import '../widgets/grid_scale_overlay.dart';
import '../services/burst_helper.dart';
import '../services/responsive_helper.dart';

class PersonPhotosScreen extends StatefulWidget {
  final Map<String, dynamic> person;

  const PersonPhotosScreen({super.key, required this.person});

  @override
  State<PersonPhotosScreen> createState() => _PersonPhotosScreenState();
}

class _PersonPhotosScreenState extends State<PersonPhotosScreen> {
  bool _isSelectionMode = false;
  final Set<String> _selectedItemIds = {};

  bool _isLoading = true;
  bool _onlyThisPerson = false;
  List<GalleryItem> _mediaItems = [];
  List<GalleryItem> _filteredItems = [];

  // Local state for person details
  late Map<String, dynamic> _personDetails;

  // Dynamic filter state
  List<String> _dynamicYears = ['All'];
  List<String> _dynamicTags = ['All'];
  String _selectedYear = 'All';
  String _selectedTag = 'All';

  // Pre-compiled map of item -> lowercase tag set for fast filtering
  final Map<String, Set<String>> _itemTagsMap = {};

  final ScrollController _scrollController = ScrollController();
  bool _isCollapsed = false;

  // Drag selection state
  final Map<String, BuildContext> _itemContexts = {};
  int _pointerCount = 0;
  String? _dragStartId;
  Offset? _dragStartPosition;
  bool _dragDirectionDecided = false;
  bool _isDraggingToSelect = false;
  bool _dragSelectInitialState = true;

  bool _columnHudVisible = false;
  Timer? _hudHideTimer;
  int _anchorItemIndex = 0;
  bool _pendingAnchorScroll = false;
  int _gridColumns = 3;
  double _scaleStartColumns = 3.0;
  OverlayEntry? _activeOverlayEntry;
  ValueNotifier<double>? _scaleNotifier;

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

  void _checkAutoScroll(Offset globalPos) {
    // Disabled to prevent scrolling screen when sliding to select
  }

  void _updateDragSelection(String currentId, List<GalleryItem> imageItems) {
    if (_dragStartId == null) return;
    final startIdx = imageItems.indexWhere((x) => x.id == _dragStartId);
    final endIdx = imageItems.indexWhere((x) => x.id == currentId);
    if (startIdx == -1 || endIdx == -1) return;

    final low = min(startIdx, endIdx);
    final high = max(startIdx, endIdx);

    bool changed = false;
    setState(() {
      for (int i = low; i <= high; i++) {
        final id = imageItems[i].id;
        if (_dragSelectInitialState) {
          if (!_selectedItemIds.contains(id)) {
            _selectedItemIds.add(id);
            changed = true;
          }
        } else {
          if (_selectedItemIds.contains(id)) {
            _selectedItemIds.remove(id);
            changed = true;
          }
        }
      }
      if (_selectedItemIds.isEmpty) _isSelectionMode = false;
    });

    if (changed) {
      HapticFeedback.lightImpact();
    }
  }

  void _scrollListener() {
    if (_scrollController.hasClients) {
      final double offset = _scrollController.offset;
      final double collapseHeight = 300.0 - kToolbarHeight;
      if (offset >= collapseHeight && !_isCollapsed) {
        setState(() {
          _isCollapsed = true;
        });
      } else if (offset < collapseHeight && _isCollapsed) {
        setState(() {
          _isCollapsed = false;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _personDetails = Map<String, dynamic>.from(widget.person);
    _scrollController.addListener(_scrollListener);
    _gridColumns = UIPreferenceProvider.instance.gridColumns;
    _scaleStartColumns = _gridColumns.toDouble();
    UIPreferenceProvider.instance.addListener(_handleUIPreferencesChange);
    _loadPhotos();
  }

  void _handleUIPreferencesChange() {
    if (mounted) {
      setState(() {
        _gridColumns = UIPreferenceProvider.instance.gridColumns;
      });
    }
  }

  @override
  void dispose() {
    UIPreferenceProvider.instance.removeListener(_handleUIPreferencesChange);
    _scrollController.removeListener(_scrollListener);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadPhotos() async {
    setState(() => _isLoading = true);
    final db = DatabaseHelper.instance;
    final personId = _personDetails['id'] as String;

    List<Map<String, dynamic>> rawData;
    if (_onlyThisPerson) {
      rawData = await db.getMediaItemsWithOnlyPerson(personId);
    } else {
      rawData = await db.getMediaItemsForPerson(personId);
    }

    final items = rawData.map((m) => GalleryItem.fromMap(m)).toList();
    items.sort((a, b) {
      final tsA = a.modifiedTimestamp ?? a.dateTimestamp;
      final tsB = b.modifiedTimestamp ?? b.dateTimestamp;
      return tsB.compareTo(tsA);
    });

    // 1. Build dynamic years
    final Set<String> years = {'All'};
    final now = DateTime.now();
    for (final item in items) {
      if (item.date.isNotEmpty) {
        final cleaned = item.date.toLowerCase().trim();
        if (cleaned == 'today' || cleaned == 'yesterday') {
          years.add(now.year.toString());
        } else {
          final match = RegExp(r'(\d{4})').firstMatch(item.date);
          if (match != null) {
            years.add(match.group(0)!);
          } else {
            final parsed = DateTime.tryParse(item.date);
            if (parsed != null) {
              years.add(parsed.year.toString());
            }
          }
        }
      }
    }
    final sortedYears = years.toList()..sort((a, b) => b.compareTo(a));

    // 2. Build dynamic tags and populate pre-compiled tag map
    _itemTagsMap.clear();
    final Map<String, int> tagCounts = {};

    for (final item in items) {
      final Set<String> itemTags = {};

      // Load OCR
      final ocrData = await db.getOcrTextsForMedia(item.id);
      for (final row in ocrData) {
        final text = row['text'] as String;
        final words = text
            .toLowerCase()
            .split(RegExp(r'\s+'))
            .where((w) => w.length > 3)
            .take(5);
        for (final w in words) {
          itemTags.add(w);
          tagCounts[w] = (tagCounts[w] ?? 0) + 1;
        }
      }

      // Load Objects
      final objData = await db.getObjectsForMedia(item.id);
      for (final row in objData) {
        final label = (row['label'] as String).toLowerCase();
        itemTags.add(label);
        tagCounts[label] = (tagCounts[label] ?? 0) + 1;
      }

      _itemTagsMap[item.id] = itemTags;
    }

    final sortedTagsList = tagCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final List<String> topTags = ['All'];
    topTags.addAll(sortedTagsList.map((e) => e.key).take(12));

    setState(() {
      _mediaItems = items;
      _filteredItems = items;
      _dynamicYears = sortedYears;
      _dynamicTags = topTags;
      _selectedYear = 'All';
      _selectedTag = 'All';
      _isLoading = false;
    });
  }

  String _getItemYear(GalleryItem item) {
    if (item.date.isEmpty) return "";
    final cleaned = item.date.toLowerCase().trim();
    if (cleaned == 'today' || cleaned == 'yesterday') {
      return DateTime.now().year.toString();
    }
    final match = RegExp(r'(\d{4})').firstMatch(item.date);
    if (match != null) {
      return match.group(0)!;
    }
    final parsed = DateTime.tryParse(item.date);
    if (parsed != null) {
      return parsed.year.toString();
    }
    return "";
  }

  void _applyFilters() {
    setState(() {
      _filteredItems = _mediaItems.where((item) {
        // 1. Year check
        bool matchesYear = true;
        if (_selectedYear != 'All') {
          matchesYear = _getItemYear(item) == _selectedYear;
        }

        // 2. Tag check
        bool matchesTag = true;
        if (_selectedTag != 'All') {
          final set = _itemTagsMap[item.id] ?? {};
          matchesTag = set.contains(_selectedTag.toLowerCase());
        }

        return matchesYear && matchesTag;
      }).toList();
    });
  }

  String _getDateRangeString() {
    if (_filteredItems.isEmpty) return "No dates available";

    final validDates = _filteredItems.where((x) => x.date.isNotEmpty).toList();
    if (validDates.isEmpty) return "No dates available";

    final latest = validDates.first.date;
    final earliest = validDates.last.date;

    if (earliest == latest) return earliest;
    return "$earliest - $latest";
  }

  void _confirmDeletePerson(String personId, String name) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Delete Person Profile?"),
        content: Text(
          "Are you sure you want to delete the profile for '$name'? "
          "Associated photos will not be deleted, but this face cluster will be removed.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context); // Close dialog
              Navigator.pop(context); // Close sheet

              await DatabaseHelper.instance.deletePerson(personId);

              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("Profile '$name' successfully deleted.")),
                );
                Navigator.pop(context, true); // Pop PersonPhotosScreen back to People
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text("Delete"),
          ),
        ],
      ),
    );
  }

  void _showEditDetailsSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final nameController = TextEditingController(
      text: _personDetails['name'] ?? "",
    );
    final dobController = TextEditingController(
      text: _personDetails['dob'] ?? "",
    );
    final relationController = TextEditingController(
      text: _personDetails['relation'] ?? "",
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white24 : Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                "Edit Person Details",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black87,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: "Name",
                  labelStyle: TextStyle(
                    color: isDark ? Colors.white70 : Colors.black54,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: Color(0xFF3F51B5),
                      width: 2,
                    ),
                  ),
                ),
                style: TextStyle(color: isDark ? Colors.white : Colors.black87),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: dobController,
                decoration: InputDecoration(
                  labelText: "Date of Birth (DOB)",
                  labelStyle: TextStyle(
                    color: isDark ? Colors.white70 : Colors.black54,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: Color(0xFF3F51B5),
                      width: 2,
                    ),
                  ),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.calendar_today, size: 20),
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: DateTime.now(),
                        firstDate: DateTime(1900),
                        lastDate: DateTime.now(),
                      );
                      if (picked != null) {
                        dobController.text =
                            "${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}";
                      }
                    },
                  ),
                ),
                style: TextStyle(color: isDark ? Colors.white : Colors.black87),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: relationController,
                decoration: InputDecoration(
                  labelText: "Relation (e.g. Friend, Family, Self)",
                  labelStyle: TextStyle(
                    color: isDark ? Colors.white70 : Colors.black54,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: Color(0xFF3F51B5),
                      width: 2,
                    ),
                  ),
                ),
                style: TextStyle(color: isDark ? Colors.white : Colors.black87),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () async {
                  final newName = nameController.text.trim();
                  final newDob = dobController.text.trim();
                  final newRelation = relationController.text.trim();
                  final savedName = newName.isEmpty ? 'Unknown Person' : newName;
                  final personId = _personDetails['id'] as String;
                  await DatabaseHelper.instance.updatePerson(
                    personId,
                    savedName,
                    newDob,
                    newRelation,
                  );
                  OptionalFeatures.updateEmbeddingsForPerson?.call(
                    personId,
                  ); // Asynchronous (non-blocking)
                  setState(() {
                    _personDetails['name'] = savedName;
                    _personDetails['dob'] = newDob;
                    _personDetails['relation'] = newRelation;
                  });
                  Navigator.pop(context, true);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text("Person details updated successfully."),
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF3F51B5),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  "Save Details",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => _confirmDeletePerson(_personDetails['id'] as String, _personDetails['name'] as String),
                icon: const Icon(Icons.delete_outline),
                label: const Text("Delete Person Profile"),
              ),
            ],
          ),
        );
      },
    );
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
      await MediaPermissionService.softDeleteWithPermission(context, itemsToDelete);
    }

    setState(() {
      _mediaItems.removeWhere((item) => _selectedItemIds.contains(item.id));
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
                          if (!_mediaItems.any((x) => x.id == item.id)) {
                            _mediaItems.add(item);
                          }
                          if (!_filteredItems.any((x) => x.id == item.id)) {
                            _filteredItems.add(item);
                          }
                        }
                      });
                      _applyFilters();
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
            _mediaItems.removeWhere((item) => _selectedItemIds.contains(item.id));
            _filteredItems.removeWhere((item) => _selectedItemIds.contains(item.id));
            _isSelectionMode = false;
            _selectedItemIds.clear();
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Media moved to Secure Vault.')),
          );
        }
      },
    );
  }

  Widget _buildFloatingSelectionBar() {
    final theme = Theme.of(context);
    final bgColor = theme.colorScheme.surface.withValues(alpha: 0.95);
    final borderColor = theme.colorScheme.outlineVariant.withValues(alpha: 0.6);

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
              color: Colors.black.withValues(alpha: 0.12),
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
    final activeColor = color ?? Theme.of(context).colorScheme.onSurface;
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

  Future<void> _removeSelectedFacesFromPerson() async {
    if (_selectedItemIds.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Remove from Cluster?"),
        content: Text(
          "Are you sure you want to remove the ${_selectedItemIds.length} selected face(s) from this person's profile?\n\n"
          "This will reset their association so they can be re-assigned or re-clustered.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text("Remove"),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _isLoading = true);

    try {
      final db = DatabaseHelper.instance;
      final personId = _personDetails['id'] as String;

      for (final mediaId in _selectedItemIds) {
        final faces = await db.getFacesForMedia(mediaId);
        for (final face in faces) {
          if (face['person_id'] == personId) {
            await db.updateFacePersonAssociation(face['id'] as String, null);
          }
        }
      }

      // Refresh person details cover image if needed
      final allFaces = await db.getAllFaces();
      final personFacesLeft = allFaces.where((f) => f['person_id'] == personId).toList();

      final String? currentCoverPath = _personDetails['cover_image'] as String?;
      final bool isCustomCover = (_personDetails['is_custom_cover'] as int? ?? 0) == 1 ||
          (currentCoverPath != null && currentCoverPath.contains('profile_pictures'));
      bool coverStillValid = false;
      if (isCustomCover && currentCoverPath != null && File(currentCoverPath).existsSync()) {
        coverStillValid = true;
      } else if (currentCoverPath != null) {
        for (final face in personFacesLeft) {
          final mediaId = face['media_id'] as String;
          if (_mediaItems.any((x) => x.id == mediaId && x.imageUrl == currentCoverPath)) {
            coverStillValid = true;
            break;
          }
        }
      }

      if (!coverStillValid && personFacesLeft.isNotEmpty) {
        final newFace = personFacesLeft.first;
        final mediaId = newFace['media_id'] as String;
        final mediaItem = await db.getMediaItemById(mediaId);
        if (mediaItem != null) {
          final path = mediaItem['image_path'] as String? ?? mediaItem['id'] as String;
          final bboxStr = newFace['bounding_box'] as String? ?? '';
          final parts = bboxStr.split(',');
          final bx = parts.isNotEmpty ? (int.tryParse(parts[0]) ?? 0) : 0;
          final by = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
          final bw = parts.length > 2 ? (int.tryParse(parts[2]) ?? 0) : 0;
          final bh = parts.length > 3 ? (int.tryParse(parts[3]) ?? 0) : 0;

          await db.updatePersonCover(personId, path, bx, by, bw, bh);

          _personDetails['cover_image'] = path;
          _personDetails['cover_x'] = bx;
          _personDetails['cover_y'] = by;
          _personDetails['cover_w'] = bw;
          _personDetails['cover_h'] = bh;
        }
      } else if (personFacesLeft.isEmpty && !isCustomCover) {
        await db.updatePersonCover(personId, null, 0, 0, 0, 0, isCustomCover: false);
        _personDetails['cover_image'] = null;
        _personDetails['cover_x'] = 0;
        _personDetails['cover_y'] = 0;
        _personDetails['cover_w'] = 0;
        _personDetails['cover_h'] = 0;
      }

      OptionalFeatures.updateEmbeddingsForPerson?.call(personId);

      await _loadPhotos();

      setState(() {
        _isSelectionMode = false;
        _selectedItemIds.clear();
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Selected faces successfully removed from profile.")),
        );
      }
    } catch (e) {
      debugPrint("Error removing faces: $e");
      setState(() => _isLoading = false);
    }
  }

  Future<void> _moveSelectedFacesToAnotherPerson() async {
    if (_selectedItemIds.isEmpty) return;

    final db = DatabaseHelper.instance;
    final currentPersonId = _personDetails['id'] as String;

    final allPeople = await db.getAllPeople();
    final otherPeople = allPeople.where((p) => p['id'] != currentPersonId).toList();

    if (otherPeople.isEmpty) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text("No other profiles"),
            content: const Text("There are no other person profiles in your gallery to move these faces to. Please create or detect other profiles first."),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("OK"),
              ),
            ],
          ),
        );
      }
      return;
    }

    final allFaces = await db.getAllFaces();
    final prefs = await SharedPreferences.getInstance();
    final threshold = prefs.getInt('face_eligible_threshold') ?? 10;

    final eligiblePeople = otherPeople.where((p) {
      final personId = p['id'] as String;
      final count = allFaces.where((f) => f['person_id'] == personId).length;
      return count >= threshold;
    }).toList();

    if (eligiblePeople.isEmpty) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text("No Eligible Profiles"),
            content: Text(
              "There are no other eligible person profiles (profiles with at least $threshold faces) in your gallery to move these faces to.\n\n"
              "Please adjust the minimum threshold in settings or cluster more faces first.",
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("OK"),
              ),
            ],
          ),
        );
      }
      return;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final targetPerson = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white24 : Colors.grey[300],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Text(
                    "Move Faces to Person",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  Expanded(
                    child: GridView.builder(
                      controller: scrollController,
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 20,
                        crossAxisSpacing: 16,
                        childAspectRatio: 0.75,
                      ),
                      itemCount: eligiblePeople.length,
                      itemBuilder: (context, idx) {
                        final p = eligiblePeople[idx];
                        final name = p['name'] as String;
                        final count = allFaces.where((f) => f['person_id'] == p['id']).length;

                        return GestureDetector(
                          onTap: () => Navigator.pop(ctx, p),
                          child: Column(
                            children: [
                              Expanded(
                                child: Container(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: isDark ? Colors.white12 : Colors.grey[300]!,
                                      width: 2,
                                    ),
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: ClipOval(
                                    child: (p['cover_image'] != null && (p['cover_w'] as int? ?? 0) > 0)
                                        ? FacePreview(
                                            imagePath: p['cover_image'] as String,
                                            x: p['cover_x'] as int? ?? 0,
                                            y: p['cover_y'] as int? ?? 0,
                                            w: p['cover_w'] as int? ?? 0,
                                            h: p['cover_h'] as int? ?? 0,
                                          )
                                        : Container(
                                            color: isDark ? Colors.white12 : Colors.grey[200],
                                            child: const Center(child: Text("👤", style: TextStyle(fontSize: 24))),
                                          ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                name,
                                style: TextStyle(
                                  color: isDark ? Colors.white : Colors.black87,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                "$count faces",
                                style: TextStyle(
                                  color: isDark ? Colors.white54 : Colors.black54,
                                  fontSize: 10,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (targetPerson == null) return;

    final targetPersonId = targetPerson['id'] as String;
    final targetName = targetPerson['name'] as String;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Confirm Move"),
        content: Text("Move ${_selectedItemIds.length} face(s) to the profile of '$targetName'?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Move"),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _isLoading = true);

    try {
      for (final mediaId in _selectedItemIds) {
        final faces = await db.getFacesForMedia(mediaId);
        for (final face in faces) {
          if (face['person_id'] == currentPersonId) {
            await db.updateFacePersonAssociation(face['id'] as String, targetPersonId);
          }
        }
      }

      final allFaces = await db.getAllFaces();

      // Update current person cover if needed
      final currentPersonFacesLeft = allFaces.where((f) => f['person_id'] == currentPersonId).toList();
      final String? currentCoverPath = _personDetails['cover_image'] as String?;
      final bool isCustomCover = (_personDetails['is_custom_cover'] as int? ?? 0) == 1 ||
          (currentCoverPath != null && currentCoverPath.contains('profile_pictures'));
      bool coverStillValid = false;
      if (isCustomCover && currentCoverPath != null && File(currentCoverPath).existsSync()) {
        coverStillValid = true;
      } else if (currentCoverPath != null) {
        for (final face in currentPersonFacesLeft) {
          final mediaId = face['media_id'] as String;
          if (_mediaItems.any((x) => x.id == mediaId && x.imageUrl == currentCoverPath)) {
            coverStillValid = true;
            break;
          }
        }
      }

      if (!coverStillValid && currentPersonFacesLeft.isNotEmpty) {
        final newFace = currentPersonFacesLeft.first;
        final mediaId = newFace['media_id'] as String;
        final mediaItem = await db.getMediaItemById(mediaId);
        if (mediaItem != null) {
          final path = mediaItem['image_path'] as String? ?? mediaItem['id'] as String;
          final bboxStr = newFace['bounding_box'] as String? ?? '';
          final parts = bboxStr.split(',');
          final bx = parts.isNotEmpty ? (int.tryParse(parts[0]) ?? 0) : 0;
          final by = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
          final bw = parts.length > 2 ? (int.tryParse(parts[2]) ?? 0) : 0;
          final bh = parts.length > 3 ? (int.tryParse(parts[3]) ?? 0) : 0;

          await db.updatePersonCover(currentPersonId, path, bx, by, bw, bh);

          _personDetails['cover_image'] = path;
          _personDetails['cover_x'] = bx;
          _personDetails['cover_y'] = by;
          _personDetails['cover_w'] = bw;
          _personDetails['cover_h'] = bh;
        }
      } else if (currentPersonFacesLeft.isEmpty && !isCustomCover) {
        await db.updatePersonCover(currentPersonId, null, 0, 0, 0, 0, isCustomCover: false);
        _personDetails['cover_image'] = null;
        _personDetails['cover_x'] = 0;
        _personDetails['cover_y'] = 0;
        _personDetails['cover_w'] = 0;
        _personDetails['cover_h'] = 0;
      }

      // Ensure target person gets cover image if they didn't have one
      final targetPersonFaces = allFaces.where((f) => f['person_id'] == targetPersonId).toList();
      if (targetPerson['cover_image'] == null || (targetPerson['cover_image'] as String).isEmpty) {
        if (targetPersonFaces.isNotEmpty) {
          final firstFace = targetPersonFaces.first;
          final mediaId = firstFace['media_id'] as String;
          final mediaItem = await db.getMediaItemById(mediaId);
          if (mediaItem != null) {
            final path = mediaItem['image_path'] as String? ?? mediaItem['id'] as String;
            final bboxStr = firstFace['bounding_box'] as String? ?? '';
            final parts = bboxStr.split(',');
            final bx = parts.isNotEmpty ? (int.tryParse(parts[0]) ?? 0) : 0;
            final by = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
            final bw = parts.length > 2 ? (int.tryParse(parts[2]) ?? 0) : 0;
            final bh = parts.length > 3 ? (int.tryParse(parts[3]) ?? 0) : 0;

            await db.updatePersonCover(targetPersonId, path, bx, by, bw, bh);
          }
        }
      }

      OptionalFeatures.updateEmbeddingsForPerson?.call(currentPersonId);
      OptionalFeatures.updateEmbeddingsForPerson?.call(targetPersonId);

      await _loadPhotos();

      setState(() {
        _isSelectionMode = false;
        _selectedItemIds.clear();
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Selected faces successfully moved to '$targetName'.")),
        );
      }
    } catch (e) {
      debugPrint("Error moving faces: $e");
      setState(() => _isLoading = false);
    }
  }

  void _showChangeProfilePictureSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final theme = Theme.of(context);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white24 : Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                "Change Profile Photo",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black87,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              ListTile(
                leading: Icon(Icons.people_outline, color: theme.colorScheme.primary),
                title: const Text("Choose from Person's Photos"),
                subtitle: const Text("Select from photos they appear in"),
                onTap: () {
                  Navigator.pop(context);
                  _chooseProfileFromPersonPhotos();
                },
              ),
              ListTile(
                leading: const Icon(Icons.restore_outlined, color: Colors.redAccent),
                title: const Text("Remove"),
                subtitle: const Text("Remove profile picture"),
                onTap: () {
                  Navigator.pop(context);
                  _resetToDefaultFace();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _chooseProfileFromPersonPhotos() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.5,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1A1A1A) : Colors.white,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white24 : Colors.grey[300],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Text(
                    "Choose Photo",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: _mediaItems.isEmpty
                        ? const Center(child: Text("No photos available"))
                        : GridView.builder(
                            controller: scrollController,
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 6,
                              mainAxisSpacing: 6,
                            ),
                            itemCount: _mediaItems.length,
                            itemBuilder: (context, index) {
                              final item = _mediaItems[index];
                              return GestureDetector(
                                onTap: () {
                                  Navigator.pop(context); // Close selection sheet
                                  _openCropper(item.imageUrl);
                                },
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: FastMediaPreview(
                                    item: item,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _chooseProfileFromCustomPicker() async {
    final List<GalleryItem>? selected = await Navigator.push<List<GalleryItem>>(
      context,
      MaterialPageRoute(builder: (_) => const CustomMediaPicker()),
    );
    if (selected != null && selected.isNotEmpty) {
      _openCropper(selected.first.imageUrl);
    }
  }

  void _openCropper(String imagePath) async {
    final newPath = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => ProfileCropperScreen(
          imagePath: imagePath,
          personId: _personDetails['id'] as String,
        ),
      ),
    );
    if (newPath != null) {
      await _reloadPersonDetails();
    }
  }

  Future<void> _resetToDefaultFace() async {
    setState(() => _isLoading = true);
    try {
      final db = DatabaseHelper.instance;
      final personId = _personDetails['id'] as String;

      final allFaces = await db.getAllFaces();
      final personFaces = allFaces.where((f) => f['person_id'] == personId).toList();

      if (personFaces.isNotEmpty) {
        final firstFace = personFaces.first;
        final mediaId = firstFace['media_id'] as String;
        final mediaItem = await db.getMediaItemById(mediaId);

        if (mediaItem != null) {
          final path = mediaItem['image_path'] as String? ?? mediaItem['id'] as String;
          final bboxStr = firstFace['bounding_box'] as String? ?? '';
          final parts = bboxStr.split(',');
          final bx = parts.isNotEmpty ? (int.tryParse(parts[0]) ?? 0) : 0;
          final by = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
          final bw = parts.length > 2 ? (int.tryParse(parts[2]) ?? 0) : 0;
          final bh = parts.length > 3 ? (int.tryParse(parts[3]) ?? 0) : 0;

          await db.updatePersonCover(personId, path, bx, by, bw, bh, isCustomCover: false);

          // Delete local cropped custom files to save space if applicable
          final currentCover = _personDetails['cover_image'] as String?;
          if (currentCover != null && currentCover.contains('/profile_pictures/')) {
            final file = File(currentCover);
            if (file.existsSync()) {
              file.deleteSync();
            }
          }

          await _reloadPersonDetails();

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Profile photo reset to default face.")),
            );
          }
        }
      } else {
        await db.updatePersonCover(personId, null, 0, 0, 0, 0, isCustomCover: false);
        await _reloadPersonDetails();
      }
    } catch (e) {
      debugPrint("Error resetting profile face: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _reloadPersonDetails() async {
    final db = DatabaseHelper.instance;
    final personId = _personDetails['id'] as String;
    final updatedPerson = await db.getPersonById(personId);
    if (updatedPerson != null) {
      setState(() {
        _personDetails = Map<String, dynamic>.from(updatedPerson);
      });
    }
    OptionalFeatures.updateEmbeddingsForPerson?.call(personId);
  }

  Widget _buildBlurredBackground() {
    Widget backgroundWidget;
    if (_mediaItems.isNotEmpty) {
      backgroundWidget = AlbumSlideshowBackground(items: _mediaItems);
    } else {
      final coverPath = _personDetails['cover_image'] as String?;
      final coverW = _personDetails['cover_w'] as int? ?? 0;
      final coverX = _personDetails['cover_x'] as int? ?? 0;
      final coverY = _personDetails['cover_y'] as int? ?? 0;
      final coverH = _personDetails['cover_h'] as int? ?? 0;

      if (coverPath != null && coverPath.isNotEmpty && File(coverPath).existsSync()) {
        if (coverW > 0) {
          backgroundWidget = FacePreview(
            imagePath: coverPath,
            x: coverX,
            y: coverY,
            w: coverW,
            h: coverH,
          );
        } else {
          backgroundWidget = Image.file(
            File(coverPath),
            fit: BoxFit.cover,
          );
        }
      } else {
        backgroundWidget = Container(
          color: Colors.grey[900],
          child: const Center(
            child: Icon(Icons.person, size: 80, color: Colors.white24),
          ),
        );
      }
    }

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          backgroundWidget,
          Positioned.fill(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 8.0, sigmaY: 8.0),
              child: Container(
                color: Colors.black.withValues(alpha: 0.35),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileHeaderContent() {
    final theme = Theme.of(context);
    final coverPath = _personDetails['cover_image'] as String?;
    final coverW = _personDetails['cover_w'] as int? ?? 0;
    final coverX = _personDetails['cover_x'] as int? ?? 0;
    final coverY = _personDetails['cover_y'] as int? ?? 0;
    final coverH = _personDetails['cover_h'] as int? ?? 0;

    final photoCount = _mediaItems.where((x) => x.mediaType == 'image').length;
    final videoCount = _mediaItems.where((x) => x.mediaType == 'video').length;
    final yearsCount = _dynamicYears.where((x) => x != 'All').length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 20, left: 24, right: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Circular Profile Photo with glow border
          GestureDetector(
            onTap: _showChangeProfilePictureSheet,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.transparent, width: 3),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 10,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ClipOval(
                    child: coverPath != null && coverPath.isNotEmpty && File(coverPath).existsSync()
                        ? (coverW > 0
                            ? FacePreview(
                                imagePath: coverPath,
                                x: coverX,
                                y: coverY,
                                w: coverW,
                                h: coverH,
                              )
                            : Image.file(File(coverPath), fit: BoxFit.cover))
                        : Container(
                            color: theme.colorScheme.primary.withValues(alpha: 0.2),
                            child: const Center(
                              child: Icon(Icons.person, size: 50, color: Colors.white70),
                            ),
                          ),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: const Icon(
                      Icons.camera_alt,
                      size: 12,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Name text
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _personDetails['name'] ?? "Face Cluster",
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  shadows: [
                    Shadow(
                      color: Colors.black45,
                      offset: Offset(0, 2),
                      blurRadius: 4,
                    ),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Relation / DOB Tags
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if ((_personDetails['relation'] as String? ?? "").isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.family_restroom, size: 12, color: Colors.white),
                      const SizedBox(width: 4),
                      Text(
                        _personDetails['relation'] as String,
                        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              if ((_personDetails['dob'] as String? ?? "").isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cake_outlined, size: 12, color: Colors.white),
                      const SizedBox(width: 4),
                      Text(
                        _personDetails['dob'] as String,
                        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          // Stats Row
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildStatItem("$photoCount", "Photos"),
              _buildStatDivider(),
              _buildStatItem("$videoCount", "Videos"),
              if (yearsCount > 0) ...[
                _buildStatDivider(),
                _buildStatItem("$yearsCount", "Years"),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String count, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          count,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  Widget _buildStatDivider() {
    return Container(
      height: 20,
      width: 1,
      color: Colors.white24,
      margin: const EdgeInsets.symmetric(horizontal: 24),
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

  List<_FlatItem> _buildFlatList(
    double screenWidth,
    List<String> sortedDates,
    Map<String, List<GalleryItem>> groupedItems,
  ) {
    final List<_FlatItem> flat = [];
    final double maxWidth = screenWidth - 24; // 12 padding on each side
    const double spacing = 3.0;

    for (final dateStr in sortedDates) {
      final items = groupedItems[dateStr] ?? [];
      if (items.isEmpty) continue;

      flat.add(_HeaderItem(dateStr));

      final columns = ResponsiveHelper.responsiveGridColumns(
        context,
        baseColumns: _gridColumns,
        min: 1,
        max: 10,
      );

      if (columns == 1) {
        flat.add(_RowItem(
          dateStr,
          [items.first],
          1,
          0,
          customAspectRatio: 4 / 3,
        ));

        for (int i = 1; i < items.length; i += 2) {
          final end = (i + 2 < items.length) ? i + 2 : items.length;
          flat.add(_RowItem(
            dateStr,
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

            flat.add(_JustifiedRowItem(
              dateStr,
              currentRow,
              actualHeight,
              rowIndex++,
            ));

            currentRow = [];
            currentAspectRatioSum = 0.0;
          }
        }

        if (currentRow.isNotEmpty) {
          flat.add(_JustifiedRowItem(
            dateStr,
            currentRow,
            targetHeight,
            rowIndex,
            isLastRow: true,
          ));
        }
      } else {
        for (int i = 0; i < items.length; i += columns) {
          final end = (i + columns < items.length) ? i + columns : items.length;
          flat.add(_RowItem(
            dateStr,
            items.sublist(i, end),
            columns,
            i ~/ columns,
          ));
        }
      }
    }
    return flat;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final theme = Theme.of(context);
    final titleColor = isDark ? Colors.white : Colors.black87;
    final subColor = isDark ? Colors.white60 : Colors.black54;
    final appBarIconColor = (_isCollapsed && !_isSelectionMode)
        ? (isDark ? Colors.white : Colors.black87)
        : Colors.white;

    String getDynamicDateLabel(GalleryItem item) {
      final ts = item.modifiedTimestamp ?? item.dateTimestamp;
      if (ts == 0) return item.date;
      final dt = DateTime.fromMillisecondsSinceEpoch(ts);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final yesterday = today.subtract(const Duration(days: 1));
      final itemDay = DateTime(dt.year, dt.month, dt.day);

      if (itemDay == today) return 'Today';
      if (itemDay == yesterday) return 'Yesterday';

      const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
      if (dt.year == now.year) {
        return '${months[dt.month - 1]} ${dt.day}';
      }
      return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
    }

    final collapsedItems = BurstHelper.collapseBursts(_filteredItems);
    final Map<String, List<GalleryItem>> groupedItems = {};
    for (final item in collapsedItems) {
      final label = getDynamicDateLabel(item);
      groupedItems.putIfAbsent(label, () => []).add(item);
    }
    final sortedDates = groupedItems.keys.toList();

    final burstMap = <String, int>{};
    for (final item in _filteredItems) {
      final key = BurstHelper.getBurstGroupKey(item);
      if (key != null) {
        burstMap[key] = (burstMap[key] ?? 0) + 1;
      }
    }

    final double screenWidth = MediaQuery.of(context).size.width;
    final List<_FlatItem> flatItems = _buildFlatList(screenWidth, sortedDates, groupedItems);

    return PopScope(
      canPop: !_isSelectionMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_isSelectionMode) {
          setState(() {
            _isSelectionMode = false;
            _selectedItemIds.clear();
          });
        }
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Stack(
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
                              _checkAutoScroll(event.position);
                              final id = _getItemIdAtPosition(event.position);
                              if (id != null) {
                                _updateDragSelection(id, collapsedItems);
                              }
                            }
                          }
                        },
                        onPointerUp: (event) {
                          setState(
                            () => _pointerCount = (_pointerCount - 1).clamp(0, 99),
                          );
                          _isDraggingToSelect = false;
                          _dragStartId = null;
                          _dragStartPosition = null;
                          _dragDirectionDecided = false;
                        },
                        onPointerCancel: (event) {
                          setState(
                            () => _pointerCount = (_pointerCount - 1).clamp(0, 99),
                          );
                          _isDraggingToSelect = false;
                          _dragStartId = null;
                          _dragStartPosition = null;
                          _dragDirectionDecided = false;
                        },
                        child: GestureDetector(
                          onScaleStart: (details) {
                            if (_pointerCount >= 2 || details.pointerCount >= 2) {
                              _scaleStartColumns = _gridColumns.toDouble();
                              _captureAnchor(collapsedItems);
                              final activeItemId = _getItemIdAtPosition(details.focalPoint);
                              if (activeItemId != null) {
                                try {
                                  final activeItem = collapsedItems.firstWhere(
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
                                    }
                                  }
                                } catch (e) {
                                  debugPrint('Scale start error: $e');
                                }
                              }
                              _showHud();
                            }
                          },
                          onScaleUpdate: (details) {
                            if (_pointerCount < 2 && details.pointerCount < 2) return;
                            _scaleNotifier?.value = details.scale.clamp(0.5, 2.5);

                            int target = _scaleStartColumns.toInt();
                            if (details.scale > 1.0) {
                              final double steps = (details.scale - 1.0) / 0.18;
                              target = (_scaleStartColumns - steps.floor()).clamp(1, 6).toInt();
                            } else if (details.scale < 1.0) {
                              final double steps = (1.0 - details.scale) / 0.15;
                              target = (_scaleStartColumns + steps.floor()).clamp(1, 6).toInt();
                            }

                            if (target != _gridColumns) {
                              _captureAnchor(collapsedItems);
                              UIPreferenceProvider.instance.setGridColumns(target);
                              _pendingAnchorScroll = true;
                              _showHud();
                            }
                          },
                          onScaleEnd: (details) {
                            _activeOverlayEntry?.remove();
                            _activeOverlayEntry = null;
                            _scaleNotifier?.dispose();
                            _scaleNotifier = null;
                            _hideHudAfterDelay();
                            if (_pendingAnchorScroll) {
                              _restoreAnchor(collapsedItems, _gridColumns);
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
                            // Collapsible Header SliverAppBar
                            SliverAppBar(
                              expandedHeight: 300,
                              pinned: true,
                              stretch: true,
                              backgroundColor: theme.scaffoldBackgroundColor,
                              elevation: 0,
                              leading: _isSelectionMode
                                  ? IconButton(
                                      icon: Icon(Icons.close, color: appBarIconColor),
                                      onPressed: () {
                                        setState(() {
                                          _isSelectionMode = false;
                                          _selectedItemIds.clear();
                                        });
                                      },
                                    )
                                  : IconButton(
                                      icon: Icon(Icons.arrow_back, color: appBarIconColor),
                                      onPressed: () => Navigator.pop(context),
                                    ),
                              title: AnimatedOpacity(
                                opacity: _isCollapsed || _isSelectionMode ? 1.0 : 0.0,
                                duration: const Duration(milliseconds: 200),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      _isSelectionMode
                                          ? '${_selectedItemIds.length} Selected'
                                          : (_personDetails['name'] ?? "Face Cluster"),
                                      style: TextStyle(
                                        color: _isSelectionMode ? titleColor : appBarIconColor,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    if (!_isSelectionMode) ...[
                                      const SizedBox(width: 6),
                                      const Text(
                                        "👑",
                                        style: TextStyle(fontSize: 16, color: Colors.amber),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              actions: _isSelectionMode
                                  ? [
                                      IconButton(
                                        icon: Icon(Icons.person_remove_outlined, color: appBarIconColor),
                                        tooltip: "Remove from cluster",
                                        onPressed: _removeSelectedFacesFromPerson,
                                      ),
                                      IconButton(
                                        icon: Icon(Icons.drive_file_move_outlined, color: appBarIconColor),
                                        tooltip: "Move to another person",
                                        onPressed: _moveSelectedFacesToAnotherPerson,
                                      ),
                                      IconButton(
                                        icon: Icon(
                                          _selectedItemIds.length == collapsedItems.length
                                              ? Icons.deselect_outlined
                                              : Icons.select_all,
                                          color: appBarIconColor,
                                        ),
                                        tooltip: _selectedItemIds.length == collapsedItems.length
                                            ? 'Deselect All'
                                            : 'Select All',
                                        onPressed: () {
                                          setState(() {
                                            if (_selectedItemIds.length == collapsedItems.length) {
                                              _selectedItemIds.clear();
                                              _isSelectionMode = false;
                                            } else {
                                              _selectedItemIds.addAll(collapsedItems.map((x) => x.id));
                                            }
                                          });
                                        },
                                      ),
                                    ]
                                  : [
                                      IconButton(
                                        icon: Icon(Icons.edit_outlined, color: appBarIconColor),
                                        tooltip: "Edit details",
                                        onPressed: _showEditDetailsSheet,
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.only(right: 16, top: 10, bottom: 10),
                                        child: GestureDetector(
                                          onTap: () {
                                            setState(() {
                                              _onlyThisPerson = !_onlyThisPerson;
                                            });
                                            _loadPhotos();
                                          },
                                          child: AnimatedContainer(
                                            duration: const Duration(milliseconds: 200),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 16,
                                              vertical: 4,
                                            ),
                                            alignment: Alignment.center,
                                            decoration: BoxDecoration(
                                              color: _onlyThisPerson
                                                  ? theme.colorScheme.primary
                                                  : (_isCollapsed
                                                      ? (isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.05))
                                                      : Colors.white24),
                                              borderRadius: BorderRadius.circular(20),
                                              border: Border.all(
                                                color: _isCollapsed ? Colors.transparent : Colors.white30,
                                                width: 1,
                                              ),
                                            ),
                                            child: Text(
                                              "Only",
                                              style: TextStyle(
                                                color: _onlyThisPerson
                                                    ? Colors.white
                                                    : (_isCollapsed ? titleColor : Colors.white),
                                                fontWeight: FontWeight.bold,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                              flexibleSpace: FlexibleSpaceBar(
                                stretchModes: const [
                                  StretchMode.zoomBackground,
                                  StretchMode.blurBackground,
                                ],
                                background: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    _buildBlurredBackground(),
                                    const DecoratedBox(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            Colors.black54,
                                            Colors.transparent,
                                            Colors.black87,
                                          ],
                                          stops: [0.0, 0.4, 1.0],
                                        ),
                                      ),
                                    ),
                                    _buildProfileHeaderContent(),
                                  ],
                                ),
                              ),
                            ),

                            SliverToBoxAdapter(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const SizedBox(height: 12),
                                  SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    physics: const BouncingScrollPhysics(),
                                    child: Row(
                                      children: [
                                        const SizedBox(width: 16),
                                        Center(
                                          child: Text(
                                            "Years: ",
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: subColor,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        ..._dynamicYears.map((year) => _buildYearPill(year)),
                                        const SizedBox(width: 8),
                                        VerticalDivider(
                                          color: isDark ? Colors.white24 : Colors.grey[300],
                                          width: 1,
                                          indent: 8,
                                          endIndent: 8,
                                        ),
                                        const SizedBox(width: 12),
                                        Center(
                                          child: Text(
                                            "Tags: ",
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: subColor,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        ..._dynamicTags.map((tag) => _buildTagPill(tag)),
                                        const SizedBox(width: 16),
                                      ],
                                    ),
                                  ),

                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                                    child: Row(
                                      children: [
                                        Icon(Icons.calendar_month_outlined, size: 14, color: subColor),
                                        const SizedBox(width: 6),
                                        Text(
                                          _getDateRangeString(),
                                          style: TextStyle(
                                            color: subColor,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Divider(indent: 16, endIndent: 16, height: 1, thickness: 0.5),
                                ],
                              ),
                            ),

                            // Media Grid Lists
                            if (_filteredItems.isEmpty)
                              const SliverFillRemaining(
                                hasScrollBody: false,
                                child: Center(
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(vertical: 40),
                                    child: Text(
                                      "No matching photos found!",
                                      style: TextStyle(color: Colors.grey, fontSize: 15),
                                    ),
                                  ),
                                ),
                              )
                            else ...[
                              SliverList.builder(
                                itemCount: flatItems.length,
                                itemBuilder: (context, index) {
                                  final flatItem = flatItems[index];
                                  if (flatItem is _HeaderItem) {
                                    return Padding(
                                      padding: const EdgeInsets.only(
                                        top: 14,
                                        left: 12,
                                        right: 12,
                                        bottom: 8,
                                      ),
                                      child: Text(
                                        flatItem.date,
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: isDark ? Colors.white : Colors.black87,
                                          letterSpacing: -0.3,
                                        ),
                                      ),
                                    );
                                  } else if (flatItem is _RowItem) {
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

                                    final bool isLastRowOfSection = (index + 1 >= flatItems.length) ||
                                        (flatItems[index + 1] is _HeaderItem);
                                    final double sectionBottomSpacing = isLastRowOfSection ? 16.0 : 3.0;

                                    return Padding(
                                      padding: EdgeInsets.only(
                                        left: 12,
                                        right: 12,
                                        bottom: sectionBottomSpacing,
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
                                                      await Navigator.push(
                                                        context,
                                                        MaterialPageRoute(
                                                          builder: (context) => PhotoViewerPage(
                                                            item: item,
                                                            allItems: _filteredItems,
                                                            ghostPersonality: "Sassy",
                                                            onDelete: (id) async {
                                                              if (id.isEmpty) {
                                                                _applyFilters();
                                                                return;
                                                              }
                                                              setState(() {
                                                                _mediaItems.removeWhere((x) => x.id == id);
                                                                _filteredItems.removeWhere((x) => x.id == id);
                                                              });
                                                              _applyFilters();
                                                            },
                                                          ),
                                                        ),
                                                      );
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
                                          );
                                        }),
                                      ),
                                    );
                                  } else if (flatItem is _JustifiedRowItem) {
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
                                    final double maxWidth = screenWidth - 24;

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

                                    final bool isLastRowOfSection = (index + 1 >= flatItems.length) ||
                                        (flatItems[index + 1] is _HeaderItem);
                                    final double sectionBottomSpacing = isLastRowOfSection ? 16.0 : 3.0;

                                    return Padding(
                                      padding: EdgeInsets.only(
                                        left: 12,
                                        right: 12,
                                        bottom: sectionBottomSpacing,
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

                                                    return PhotoGridTile(
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
                                                          await Navigator.push(
                                                            context,
                                                            MaterialPageRoute(
                                                              builder: (context) => PhotoViewerPage(
                                                                item: item,
                                                                allItems: _filteredItems,
                                                                ghostPersonality: "Sassy",
                                                                onDelete: (id) async {
                                                                  if (id.isEmpty) {
                                                                    _applyFilters();
                                                                    return;
                                                                  }
                                                                  setState(() {
                                                                    _mediaItems.removeWhere((x) => x.id == id);
                                                                    _filteredItems.removeWhere((x) => x.id == id);
                                                                  });
                                                                  _applyFilters();
                                                                },
                                                              ),
                                                            ),
                                                          );
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
                            ],
                            const SliverToBoxAdapter(
                              child: SizedBox(height: 90),
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
                        child: _ColumnHud(columns: _gridColumns),
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
              ),
      ),
    );
  }

  Widget _buildYearPill(String year) {
    final isSelected = _selectedYear == year;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(year, style: TextStyle(fontSize: 12, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
        selected: isSelected,
        onSelected: (_) {
          setState(() => _selectedYear = year);
          _applyFilters();
        },
        selectedColor: theme.colorScheme.primary.withValues(alpha: 0.15),
        checkmarkColor: theme.colorScheme.primary,
        backgroundColor: Colors.transparent,
        side: BorderSide(
          color: isSelected ? theme.colorScheme.primary : Colors.grey.withValues(alpha: 0.3),
          width: 1,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }

  Widget _buildTagPill(String tag) {
    final isSelected = _selectedTag == tag;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(tag, style: TextStyle(fontSize: 12, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
        selected: isSelected,
        onSelected: (_) {
          setState(() => _selectedTag = tag);
          _applyFilters();
        },
        selectedColor: theme.colorScheme.primary.withValues(alpha: 0.15),
        checkmarkColor: theme.colorScheme.primary,
        backgroundColor: Colors.transparent,
        side: BorderSide(
          color: isSelected ? theme.colorScheme.primary : Colors.grey.withValues(alpha: 0.3),
          width: 1,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }
}

// Flat list models for PersonPhotosScreen
abstract class _FlatItem {}

class _HeaderItem extends _FlatItem {
  final String date;
  _HeaderItem(this.date);
}

class _RowItem extends _FlatItem {
  final String date;
  final List<GalleryItem> items;
  final int columns;
  final int rowIndex;
  final double? customAspectRatio;
  _RowItem(this.date, this.items, this.columns, this.rowIndex, {this.customAspectRatio});
}

class _JustifiedRowItem extends _FlatItem {
  final String date;
  final List<GalleryItem> items;
  final double height;
  final int rowIndex;
  final bool isLastRow;
  _JustifiedRowItem(this.date, this.items, this.height, this.rowIndex, {this.isLastRow = false});
}

class _ColumnHud extends StatelessWidget {
  final int columns;
  const _ColumnHud({required this.columns});

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
