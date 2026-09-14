import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../models/gallery_item.dart';
import '../services/database_helper.dart';
import 'vault/custom_media_picker.dart';
import '../services/responsive_helper.dart';

class PhotoState {
  final GalleryItem item;
  Offset offset;
  double scale;
  double rotation;

  PhotoState({
    required this.item,
    this.offset = Offset.zero,
    this.scale = 1.0,
    this.rotation = 0.0,
  });
}

class CollageLayout {
  final String name;
  final int requiredImages;
  final Widget Function(double spacing, double borderRadius, Widget Function(int) buildCell) builder;
  final Widget Function(Color color) iconBuilder;

  CollageLayout({
    required this.name,
    required this.requiredImages,
    required this.builder,
    required this.iconBuilder,
  });
}

class CollageCreatorScreen extends StatefulWidget {
  final List<GalleryItem> selectedItems;

  const CollageCreatorScreen({super.key, required this.selectedItems});

  @override
  State<CollageCreatorScreen> createState() => _CollageCreatorScreenState();
}

class _CollageCreatorScreenState extends State<CollageCreatorScreen> {
  final GlobalKey _repaintKey = GlobalKey();
  
  int _activeLayout = 0; 
  final double _spacing = 2.0;
  final double _borderRadius = 0.0;
  bool _isSaving = false;

  // Media Picker state
  List<GalleryItem> _allMedia = [];
  final List<GalleryItem> _chosenItems = [];

  // Gesture states
  final List<PhotoState> _photoStates = [];
  Offset _initialOffset = Offset.zero;
  double _initialScale = 1.0;
  Offset _initialFocalPoint = Offset.zero;

  late final List<CollageLayout> _layouts = [
    // 2 Images
    CollageLayout(
      name: 'Vertical Split',
      requiredImages: 2,
      builder: (spacing, radius, buildCell) => Row(
        children: [
          Expanded(child: buildCell(0)),
          SizedBox(width: spacing),
          Expanded(child: buildCell(1)),
        ],
      ),
      iconBuilder: (color) => Row(
        children: [
          Expanded(child: Container(decoration: BoxDecoration(border: Border(right: BorderSide(color: color, width: 1.2))))),
          Expanded(child: Container()),
        ],
      ),
    ),
    CollageLayout(
      name: 'Horizontal Split',
      requiredImages: 2,
      builder: (spacing, radius, buildCell) => Column(
        children: [
          Expanded(child: buildCell(0)),
          SizedBox(height: spacing),
          Expanded(child: buildCell(1)),
        ],
      ),
      iconBuilder: (color) => Column(
        children: [
          Expanded(child: Container(decoration: BoxDecoration(border: Border(bottom: BorderSide(color: color, width: 1.2))))),
          Expanded(child: Container()),
        ],
      ),
    ),
    // 3 Images
    CollageLayout(
      name: '3 Columns Split',
      requiredImages: 3,
      builder: (spacing, radius, buildCell) => Row(
        children: [
          Expanded(child: buildCell(0)),
          SizedBox(width: spacing),
          Expanded(child: buildCell(1)),
          SizedBox(width: spacing),
          Expanded(child: buildCell(2)),
        ],
      ),
      iconBuilder: (color) => Row(
        children: [
          Expanded(child: Container(decoration: BoxDecoration(border: Border(right: BorderSide(color: color, width: 1.2))))),
          Expanded(child: Container(decoration: BoxDecoration(border: Border(right: BorderSide(color: color, width: 1.2))))),
          Expanded(child: Container()),
        ],
      ),
    ),
    CollageLayout(
      name: 'Left-featured Split',
      requiredImages: 3,
      builder: (spacing, radius, buildCell) => Row(
        children: [
          Expanded(child: buildCell(0)),
          SizedBox(width: spacing),
          Expanded(
            child: Column(
              children: [
                Expanded(child: buildCell(1)),
                SizedBox(height: spacing),
                Expanded(child: buildCell(2)),
              ],
            ),
          ),
        ],
      ),
      iconBuilder: (color) => Row(
        children: [
          Expanded(child: Container(decoration: BoxDecoration(border: Border(right: BorderSide(color: color, width: 1.2))))),
          Expanded(
            child: Column(
              children: [
                Expanded(child: Container(decoration: BoxDecoration(border: Border(bottom: BorderSide(color: color, width: 1.2))))),
                Expanded(child: Container()),
              ],
            ),
          ),
        ],
      ),
    ),
    CollageLayout(
      name: 'Top-featured Split',
      requiredImages: 3,
      builder: (spacing, radius, buildCell) => Column(
        children: [
          Expanded(child: buildCell(0)),
          SizedBox(height: spacing),
          Expanded(
            child: Row(
              children: [
                Expanded(child: buildCell(1)),
                SizedBox(width: spacing),
                Expanded(child: buildCell(2)),
              ],
            ),
          ),
        ],
      ),
      iconBuilder: (color) => Column(
        children: [
          Expanded(child: Container(decoration: BoxDecoration(border: Border(bottom: BorderSide(color: color, width: 1.2))))),
          Expanded(
            child: Row(
              children: [
                Expanded(child: Container(decoration: BoxDecoration(border: Border(right: BorderSide(color: color, width: 1.2))))),
                Expanded(child: Container()),
              ],
            ),
          ),
        ],
      ),
    ),
    // 4 Images
    CollageLayout(
      name: '2x2 Grid',
      requiredImages: 4,
      builder: (spacing, radius, buildCell) => Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: buildCell(0)),
                SizedBox(width: spacing),
                Expanded(child: buildCell(1)),
              ],
            ),
          ),
          SizedBox(height: spacing),
          Expanded(
            child: Row(
              children: [
                Expanded(child: buildCell(2)),
                SizedBox(width: spacing),
                Expanded(child: buildCell(3)),
              ],
            ),
          ),
        ],
      ),
      iconBuilder: (color) => Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: Container(decoration: BoxDecoration(border: Border(right: BorderSide(color: color, width: 1.2), bottom: BorderSide(color: color, width: 1.2))))),
                Expanded(child: Container(decoration: BoxDecoration(border: Border(bottom: BorderSide(color: color, width: 1.2))))),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(child: Container(decoration: BoxDecoration(border: Border(right: BorderSide(color: color, width: 1.2))))),
                Expanded(child: Container()),
              ],
            ),
          ),
        ],
      ),
    ),
    CollageLayout(
      name: '4 Columns Split',
      requiredImages: 4,
      builder: (spacing, radius, buildCell) => Row(
        children: [
          Expanded(child: buildCell(0)),
          SizedBox(width: spacing),
          Expanded(child: buildCell(1)),
          SizedBox(width: spacing),
          Expanded(child: buildCell(2)),
          SizedBox(width: spacing),
          Expanded(child: buildCell(3)),
        ],
      ),
      iconBuilder: (color) => Row(
        children: [
          Expanded(child: Container(decoration: BoxDecoration(border: Border(right: BorderSide(color: color, width: 1.2))))),
          Expanded(child: Container(decoration: BoxDecoration(border: Border(right: BorderSide(color: color, width: 1.2))))),
          Expanded(child: Container(decoration: BoxDecoration(border: Border(right: BorderSide(color: color, width: 1.2))))),
          Expanded(child: Container()),
        ],
      ),
    ),
    CollageLayout(
      name: 'Left-featured Stack',
      requiredImages: 4,
      builder: (spacing, radius, buildCell) => Row(
        children: [
          Expanded(child: buildCell(0)),
          SizedBox(width: spacing),
          Expanded(
            child: Column(
              children: [
                Expanded(child: buildCell(1)),
                SizedBox(height: spacing),
                Expanded(child: buildCell(2)),
                SizedBox(height: spacing),
                Expanded(child: buildCell(3)),
              ],
            ),
          ),
        ],
      ),
      iconBuilder: (color) => Row(
        children: [
          Expanded(child: Container(decoration: BoxDecoration(border: Border(right: BorderSide(color: color, width: 1.2))))),
          Expanded(
            child: Column(
              children: [
                Expanded(child: Container(decoration: BoxDecoration(border: Border(bottom: BorderSide(color: color, width: 1.2))))),
                Expanded(child: Container(decoration: BoxDecoration(border: Border(bottom: BorderSide(color: color, width: 1.2))))),
                Expanded(child: Container()),
              ],
            ),
          ),
        ],
      ),
    ),
    // 5 Images
    CollageLayout(
      name: 'Top-featured Row',
      requiredImages: 5,
      builder: (spacing, radius, buildCell) => Column(
        children: [
          Expanded(child: buildCell(0)),
          SizedBox(height: spacing),
          Expanded(
            child: Row(
              children: [
                Expanded(child: buildCell(1)),
                SizedBox(width: spacing),
                Expanded(child: buildCell(2)),
                SizedBox(width: spacing),
                Expanded(child: buildCell(3)),
                SizedBox(width: spacing),
                Expanded(child: buildCell(4)),
              ],
            ),
          ),
        ],
      ),
      iconBuilder: (color) => Column(
        children: [
          Expanded(child: Container(decoration: BoxDecoration(border: Border(bottom: BorderSide(color: color, width: 1.2))))),
          Expanded(
            child: Row(
              children: [
                Expanded(child: Container(decoration: BoxDecoration(border: Border(right: BorderSide(color: color, width: 1.2))))),
                Expanded(child: Container(decoration: BoxDecoration(border: Border(right: BorderSide(color: color, width: 1.2))))),
                Expanded(child: Container(decoration: BoxDecoration(border: Border(right: BorderSide(color: color, width: 1.2))))),
                Expanded(child: Container()),
              ],
            ),
          ),
        ],
      ),
    ),
    CollageLayout(
      name: 'Left-featured Column Stack',
      requiredImages: 5,
      builder: (spacing, radius, buildCell) => Row(
        children: [
          Expanded(child: buildCell(0)),
          SizedBox(width: spacing),
          Expanded(
            child: Column(
              children: [
                Expanded(child: buildCell(1)),
                SizedBox(height: spacing),
                Expanded(child: buildCell(2)),
                SizedBox(height: spacing),
                Expanded(child: buildCell(3)),
                SizedBox(height: spacing),
                Expanded(child: buildCell(4)),
              ],
            ),
          ),
        ],
      ),
      iconBuilder: (color) => Row(
        children: [
          Expanded(child: Container(decoration: BoxDecoration(border: Border(right: BorderSide(color: color, width: 1.2))))),
          Expanded(
            child: Column(
              children: [
                Expanded(child: Container(decoration: BoxDecoration(border: Border(bottom: BorderSide(color: color, width: 1.2))))),
                Expanded(child: Container(decoration: BoxDecoration(border: Border(bottom: BorderSide(color: color, width: 1.2))))),
                Expanded(child: Container(decoration: BoxDecoration(border: Border(bottom: BorderSide(color: color, width: 1.2))))),
                Expanded(child: Container()),
              ],
            ),
          ),
        ],
      ),
    ),
    // 6 Images
    CollageLayout(
      name: '3x2 Grid',
      requiredImages: 6,
      builder: (spacing, radius, buildCell) => Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: buildCell(0)),
                SizedBox(width: spacing),
                Expanded(child: buildCell(1)),
                SizedBox(width: spacing),
                Expanded(child: buildCell(2)),
              ],
            ),
          ),
          SizedBox(height: spacing),
          Expanded(
            child: Row(
              children: [
                Expanded(child: buildCell(3)),
                SizedBox(width: spacing),
                Expanded(child: buildCell(4)),
                SizedBox(width: spacing),
                Expanded(child: buildCell(5)),
              ],
            ),
          ),
        ],
      ),
      iconBuilder: (color) => Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: Container(decoration: BoxDecoration(border: Border(right: BorderSide(color: color, width: 1.2), bottom: BorderSide(color: color, width: 1.2))))),
                Expanded(child: Container(decoration: BoxDecoration(border: Border(right: BorderSide(color: color, width: 1.2), bottom: BorderSide(color: color, width: 1.2))))),
                Expanded(child: Container(decoration: BoxDecoration(border: Border(bottom: BorderSide(color: color, width: 1.2))))),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(child: Container(decoration: BoxDecoration(border: Border(right: BorderSide(color: color, width: 1.2))))),
                Expanded(child: Container(decoration: BoxDecoration(border: Border(right: BorderSide(color: color, width: 1.2))))),
                Expanded(child: Container()),
              ],
            ),
          ),
        ],
      ),
    ),
    CollageLayout(
      name: '2x3 Grid',
      requiredImages: 6,
      builder: (spacing, radius, buildCell) => Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: buildCell(0)),
                SizedBox(width: spacing),
                Expanded(child: buildCell(1)),
              ],
            ),
          ),
          SizedBox(height: spacing),
          Expanded(
            child: Row(
              children: [
                Expanded(child: buildCell(2)),
                SizedBox(width: spacing),
                Expanded(child: buildCell(3)),
              ],
            ),
          ),
          SizedBox(height: spacing),
          Expanded(
            child: Row(
              children: [
                Expanded(child: buildCell(4)),
                SizedBox(width: spacing),
                Expanded(child: buildCell(5)),
              ],
            ),
          ),
        ],
      ),
      iconBuilder: (color) => Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: Container(decoration: BoxDecoration(border: Border(right: BorderSide(color: color, width: 1.2), bottom: BorderSide(color: color, width: 1.2))))),
                Expanded(child: Container(decoration: BoxDecoration(border: Border(bottom: BorderSide(color: color, width: 1.2))))),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(child: Container(decoration: BoxDecoration(border: Border(right: BorderSide(color: color, width: 1.2), bottom: BorderSide(color: color, width: 1.2))))),
                Expanded(child: Container(decoration: BoxDecoration(border: Border(bottom: BorderSide(color: color, width: 1.2))))),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(child: Container(decoration: BoxDecoration(border: Border(right: BorderSide(color: color, width: 1.2))))),
                Expanded(child: Container()),
              ],
            ),
          ),
        ],
      ),
    ),
  ];

  @override
  void initState() {
    super.initState();
    
    // Support 2-6 images only. Clamp initial items to 6 max.
    final initialItems = widget.selectedItems.length > 6 
        ? widget.selectedItems.sublist(0, 6) 
        : widget.selectedItems;
    _chosenItems.addAll(initialItems);

    // Default to the first layout matching the item count, or 0
    final count = _chosenItems.length;
    int initialLayoutIndex = 0;
    for (int i = 0; i < _layouts.length; i++) {
      if (_layouts[i].requiredImages == count) {
        initialLayoutIndex = i;
        break;
      }
    }
    _activeLayout = initialLayoutIndex;

    _syncPhotoStates();
    _loadAllMedia();
  }

  Future<void> _loadAllMedia() async {
    try {
      final maps = await DatabaseHelper.instance.getAllMediaItems();
      final items = maps.map((m) => GalleryItem.fromMap(m)).toList();
      setState(() {
        _allMedia = items;
      });
    } catch (e) {
      debugPrint("Error loading media items: $e");
    }
  }

  void _syncPhotoStates() {
    final newStates = <PhotoState>[];
    for (final item in _chosenItems) {
      final existing = _photoStates.firstWhere(
        (p) => p.item.id == item.id,
        orElse: () => PhotoState(item: item),
      );
      newStates.add(existing);
    }
    _photoStates.clear();
    _photoStates.addAll(newStates);
  }

  PhotoState _getOrCreatePhotoState(GalleryItem item) {
    for (final state in _photoStates) {
      if (state.item.id == item.id) {
        return state;
      }
    }
    final newState = PhotoState(item: item);
    _photoStates.add(newState);
    return newState;
  }

  void _saveHistory() {
    // Keep internal history if desired, otherwise double tap handles resets
  }

  Future<void> _saveCollage() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

    try {
      await Future.delayed(const Duration(milliseconds: 150));

      final boundary = _repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) {
        throw Exception("Render RepaintBoundary not found.");
      }

      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw Exception("Failed to convert image bytes.");
      }

      final bytes = byteData.buffer.asUint8List();

      String finalPath = '';
      String finalId = '';

      if (Platform.isAndroid) {
        final fileName = 'collage_${DateTime.now().millisecondsSinceEpoch}.png';
        final savedResult = await const MethodChannel(
          'in.sddev.ghost_gallery/media_manager',
        ).invokeMethod<Map<dynamic, dynamic>>(
          'saveImageToGallery',
          {
            'bytes': bytes,
            'title': fileName,
            'relativePath': 'Pictures/Ghost Collages',
          },
        );
        if (savedResult == null) {
          throw Exception("Failed to save collage to Gallery.");
        }
        finalPath = savedResult['path']?.toString() ?? '';
        finalId = savedResult['id']?.toString() ?? '';
      } else {
        final dir = await getApplicationDocumentsDirectory();
        final collagesDir = Directory('${dir.path}/Ghost Collages');
        if (!collagesDir.existsSync()) {
          collagesDir.createSync(recursive: true);
        }
        final fileName = 'collage_${DateTime.now().millisecondsSinceEpoch}.png';
        final file = File('${collagesDir.path}/$fileName');
        await file.writeAsBytes(bytes);
        finalPath = file.path;
        finalId = 'collage_${DateTime.now().millisecondsSinceEpoch}';
      }

      // Add to SQLite DB
      final Map<String, dynamic> itemMap = {
        'id': finalId,
        'path': finalPath,
        'media_type': 'image',
        'date': 'Today',
        'date_timestamp': DateTime.now().millisecondsSinceEpoch,
        'location': 'Ghost Collage Studio',
        'latitude': 0.0,
        'longitude': 0.0,
        'width': 1200,
        'height': 1200,
        'size': '${(bytes.length / 1024 / 1024).toStringAsFixed(2)} MB',
        'camera_info': 'Ghost Collage Studio',
        'album_name': 'Ghost Collages',
        'album_category': 'Collages',
        'is_processed': 1,
        'flags': 0,
      };

      await DatabaseHelper.instance.batchInsertMediaItems([itemMap]);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Collage successfully saved and persisted!'),
            backgroundColor: Colors.teal,
            behavior: SnackBarBehavior.floating,
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      debugPrint('Save collage failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save: $e'), 
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _selectLayout(int index) async {
    final layout = _layouts[index];
    final needed = layout.requiredImages;
    final current = _chosenItems.length;

    if (current < needed) {
      final selected = await _showAddImagesBottomSheet(needed - current);
      if (selected != null && selected.isNotEmpty) {
        setState(() {
          _chosenItems.addAll(selected);
          _activeLayout = index;
          _syncPhotoStates();
        });
      }
    } else {
      setState(() {
        _activeLayout = index;
        _syncPhotoStates();
      });
    }
  }

  Future<List<GalleryItem>?> _showAddImagesBottomSheet(int count) async {
    final List<GalleryItem>? result = await Navigator.push<List<GalleryItem>>(
      context,
      MaterialPageRoute(
        builder: (context) => const CustomMediaPicker(),
      ),
    );
    if (result == null || result.isEmpty) return null;
    
    // Exclude already chosen items
    final filteredResult = result.where((m) => !_chosenItems.any((c) => c.id == m.id)).toList();
    
    if (filteredResult.length > count) {
      return filteredResult.sublist(0, count);
    }
    return filteredResult;
  }

  Widget _buildCollageContent() {
    if (_chosenItems.isEmpty) {
      return const Center(
        child: Text(
          "No media chosen.",
          style: TextStyle(color: Colors.white70, fontSize: 13),
          textAlign: TextAlign.center,
        ),
      );
    }

    final layout = _layouts[_activeLayout];
    return layout.builder(
      _spacing,
      _borderRadius,
      _buildCell,
    );
  }

  Widget _buildCell(int index) {
    if (index < _chosenItems.length) {
      final item = _chosenItems[index];
      final photo = _getOrCreatePhotoState(item);
      
      return DragTarget<int>(
        onWillAcceptWithDetails: (details) => details.data != index,
        onAcceptWithDetails: (details) {
          final sourceIndex = details.data;
          setState(() {
            final temp = _chosenItems[sourceIndex];
            _chosenItems[sourceIndex] = _chosenItems[index];
            _chosenItems[index] = temp;
            _syncPhotoStates();
          });
        },
        builder: (context, candidateData, rejectedData) {
          final isHovered = candidateData.isNotEmpty;
          
          return LongPressDraggable<int>(
            data: index,
            feedback: Material(
              color: Colors.transparent,
              child: SizedBox(
                width: 120,
                height: 120,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(
                    File(item.imageUrl),
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),
            childWhenDragging: Opacity(
              opacity: 0.3,
              child: _collageImageWrapper(photo),
            ),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              decoration: BoxDecoration(
                border: Border.all(
                  color: isHovered ? Colors.tealAccent : Colors.transparent,
                  width: isHovered ? 4.0 : 0.0,
                ),
              ),
              child: _collageImageWrapper(photo),
            ),
          );
        },
      );
    } else {
      return GestureDetector(
        onTap: () async {
          final needed = _layouts[_activeLayout].requiredImages;
          final selected = await _showAddImagesBottomSheet(needed - _chosenItems.length);
          if (selected != null && selected.isNotEmpty) {
            setState(() {
              _chosenItems.addAll(selected);
              _syncPhotoStates();
            });
          }
        },
        child: Container(
          color: const Color(0xFF191B24),
          child: const Center(
            child: Icon(Icons.add_rounded, color: Colors.white24, size: 28),
          ),
        ),
      );
    }
  }

  Widget _collageImageWrapper(PhotoState photo) {
    final file = File(photo.item.imageUrl);

    return ClipRRect(
      borderRadius: BorderRadius.circular(_borderRadius),
      child: GestureDetector(
        onScaleStart: (details) {
          _saveHistory();
          _initialOffset = photo.offset;
          _initialScale = photo.scale;
          _initialFocalPoint = details.localFocalPoint;
        },
        onScaleUpdate: (details) {
          setState(() {
            final dragDelta = details.localFocalPoint - _initialFocalPoint;
            photo.offset = _initialOffset + dragDelta;
            if (details.scale != 1.0) {
              photo.scale = (_initialScale * details.scale).clamp(1.0, 5.0);
            }
          });
        },
        onDoubleTap: () {
          _saveHistory();
          setState(() {
            photo.offset = Offset.zero;
            photo.scale = 1.0;
          });
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SizedBox(
              width: constraints.maxWidth,
              height: constraints.maxHeight,
              child: ClipRect(
                child: Transform.translate(
                  offset: photo.offset,
                  child: Transform.scale(
                    scale: photo.scale,
                    child: Image.file(
                      file,
                      cacheWidth: 1000,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      errorBuilder: (_, _, _) => Container(
                        color: Colors.grey[900],
                        child: const Icon(Icons.broken_image, color: Colors.white30),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
        ),
      ),
    );
  }

  Widget _buildMiniLayoutIcon(CollageLayout layout, bool isActive) {
    final isWatch = context.isWatch;
    final color = isActive ? Colors.black : const Color(0xFFEDEAE2);
    final bgColor = isActive ? const Color(0xFFEDEAE2) : Colors.transparent;
    final iconSize = isWatch ? 42.0 : 56.0;

    return Container(
      width: iconSize,
      height: iconSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bgColor,
        shape: BoxShape.circle,
        border: Border.all(
          color: isActive ? Colors.transparent : Colors.white24,
          width: 1.5,
        ),
      ),
      child: Container(
        width: isWatch ? 18.0 : 24.0,
        height: isWatch ? 18.0 : 24.0,
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 1.2),
          borderRadius: BorderRadius.circular(2),
        ),
        child: layout.iconBuilder(color),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF000000);
    const bottomBarColor = Color(0xFF121214);
    final isWatch = context.isWatch;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: const Color(0xFFEDEAE2), size: isWatch ? 20 : 24),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          Padding(
            padding: EdgeInsets.only(right: isWatch ? 8 : 16, top: isWatch ? 6 : 10, bottom: isWatch ? 6 : 10),
            child: _isSaving
                ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.tealAccent))
                : ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFEDEAE2),
                      foregroundColor: Colors.black,
                      shape: const StadiumBorder(),
                      padding: EdgeInsets.symmetric(horizontal: isWatch ? 12 : 24),
                      elevation: 0,
                    ),
                    onPressed: _saveCollage,
                    child: Text('Done', style: TextStyle(fontWeight: FontWeight.bold, fontSize: isWatch ? 12 : 14)),
                  ),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Collage Canvas center area
          Expanded(
            child: Container(
              alignment: Alignment.center,
              padding: EdgeInsets.symmetric(horizontal: isWatch ? 8 : 16, vertical: isWatch ? 8 : 16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600, maxHeight: 600),
                  child: AspectRatio(
                    aspectRatio: 0.8,
                    child: RepaintBoundary(
                      key: _repaintKey,
                      child: Container(
                        color: Colors.black,
                        child: _buildCollageContent(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Bottom Bar containing Layout Selector
          Container(
            color: bottomBarColor,
            padding: EdgeInsets.fromLTRB(isWatch ? 8 : 16, isWatch ? 10 : 20, isWatch ? 8 : 16, (isWatch ? 12 : 32) + MediaQuery.of(context).padding.bottom),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Layout selector row
                    SizedBox(
                      height: isWatch ? 46 : 60,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: _layouts.length,
                        itemBuilder: (ctx, idx) {
                          final layout = _layouts[idx];
                          final isActive = _activeLayout == idx;
                          
                          return GestureDetector(
                            onTap: () => _selectLayout(idx),
                            child: Padding(
                              padding: EdgeInsets.only(right: isWatch ? 10 : 16),
                              child: _buildMiniLayoutIcon(layout, isActive),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
