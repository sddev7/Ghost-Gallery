// ═══════════════════════════════════════════════════════════════════════════
// map_view_screen.dart
//
// Aves-style beautiful GPS Cluster Map using flutter_map and latlong2.
//   ✅ Interactive OpenStreetMap tiles (smooth gestures & real-world mapping)
//   ✅ Dynamically clusters media items taken within 0.1° resolution (~11 km)
//   ✅ Embeds elegant circular cover-image markers using LocationMapMarker
//   ✅ Shows interactive count badge (+X) for clusters
//   ✅ Fully responsive bottom sheet displaying grid of clustered photos
//   ✅ Tapping a photo triggers the primary PhotoViewerPage smoothly
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:ghost_gallery/services/database_helper.dart';
import 'package:ghost_gallery/models/gallery_item.dart';
import 'package:ghost_gallery/widgets/location_map_marker.dart';
import 'photo_viewer_screen.dart';
import 'album_detail_screen.dart';
import 'package:ghost_gallery/widgets/cached_tile_provider.dart';
import 'package:ghost_gallery/services/ui_preference_provider.dart';
import 'package:ghost_gallery/services/responsive_helper.dart';

class MapStyle {
  final String id;
  final String name;
  final String urlTemplate;
  final List<String> subdomains;
  final IconData icon;

  const MapStyle({
    required this.id,
    required this.name,
    required this.urlTemplate,
    required this.subdomains,
    required this.icon,
  });
}

class MapViewScreen extends StatefulWidget {
  final GalleryItem? highlightItem;
  const MapViewScreen({super.key, this.highlightItem});

  @override
  State<MapViewScreen> createState() => _MapViewScreenState();
}

class _MapViewScreenState extends State<MapViewScreen> {
  final MapController _mapController = MapController();
  List<GalleryItem> _mediaItems = [];
  bool _isLoading = true;

  // Track the selected cluster key to animate borders/selections
  String? _selectedClusterKey;

  MapStyle? _selectedStyle;
  bool _showStyleSelector = false;

  final List<MapStyle> _mapStyles = const [
    MapStyle(
      id: 'voyager',
      name: 'Voyager',
      urlTemplate: "https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png",
      subdomains: ['a', 'b', 'c', 'd'],
      icon: Icons.map_rounded,
    ),
    MapStyle(
      id: 'dark',
      name: 'Dark Matter',
      urlTemplate: "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png",
      subdomains: ['a', 'b', 'c', 'd'],
      icon: Icons.dark_mode_rounded,
    ),
    MapStyle(
      id: 'positron',
      name: 'Sleek Grey',
      urlTemplate: "https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png",
      subdomains: ['a', 'b', 'c', 'd'],
      icon: Icons.brightness_medium_rounded,
    ),
    MapStyle(
      id: 'satellite',
      name: 'Satellite',
      urlTemplate: "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
      subdomains: [],
      icon: Icons.satellite_rounded,
    ),
  ];

  MapStyle get _currentStyle {
    final styleId = UIPreferenceProvider.instance.mapStyleId;
    return _mapStyles.firstWhere(
      (style) => style.id == styleId,
      orElse: () {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return isDark ? _mapStyles[1] : _mapStyles[0];
      },
    );
  }

  void _zoom(double delta) {
    try {
      final currentZoom = _mapController.camera.zoom;
      final newZoom = (currentZoom + delta).clamp(0.0, 18.0);
      _mapController.move(_mapController.camera.center, newZoom);
    } catch (e) {
      debugPrint('Error zooming: $e');
    }
  }

  Widget _buildIconButton({
    required IconData icon,
    required VoidCallback onTap,
    String? tooltip,
  }) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: Tooltip(
        message: tooltip ?? '',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(alpha: 0.92),
              shape: BoxShape.circle,
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Icon(
              icon,
              color: theme.colorScheme.onSurface,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStyleOption(MapStyle style, bool isSelected) {
    final theme = Theme.of(context);
    return Tooltip(
      message: style.name,
      child: GestureDetector(
        onTap: () {
          UIPreferenceProvider.instance.setMapStyleId(style.id);
          setState(() {
            _showStyleSelector = false;
          });
        },
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: isSelected
                ? theme.colorScheme.primary
                : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            shape: BoxShape.circle,
            border: Border.all(
              color: isSelected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
              width: 1.5,
            ),
          ),
          child: Icon(
            style.icon,
            size: 18,
            color: isSelected
                ? theme.colorScheme.onPrimary
                : theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadLocationData();
    UIPreferenceProvider.instance.addListener(_handleUIPreferencesChange);
  }

  @override
  void dispose() {
    UIPreferenceProvider.instance.removeListener(_handleUIPreferencesChange);
    super.dispose();
  }

  void _handleUIPreferencesChange() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadLocationData() async {
    final db = DatabaseHelper.instance;
    final maps = await db.getAllMediaItems();
    final items = maps.map((m) => GalleryItem.fromMap(m)).toList();

    // Filter out items that have no GPS coordinate or default 0.0,0.0
    final validGpsItems = items.where((item) => item.hasGps).toList();

    setState(() {
      _mediaItems = validGpsItems;
      _isLoading = false;
    });

    if (widget.highlightItem != null) {
      final highlightKey = _getClusterKey(widget.highlightItem!);
      setState(() {
        _selectedClusterKey = highlightKey;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _mapController.move(
          LatLng(
            widget.highlightItem!.latitude,
            widget.highlightItem!.longitude,
          ),
          3.0,
        );
      });
    }
  }

  // Round coordinates to 1 decimal place (~11km bounding area)
  String _getClusterKey(GalleryItem item) {
    final latStr = item.latitude.toStringAsFixed(1);
    final lngStr = item.longitude.toStringAsFixed(1);
    return '${latStr}_$lngStr';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (_isLoading) {
      return Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // ── Step 1: Perform coordinate-based clustering ────────────────────────
    final Map<String, List<GalleryItem>> clusters = {};
    for (final item in _mediaItems) {
      final key = _getClusterKey(item);
      if (!clusters.containsKey(key)) {
        clusters[key] = [];
      }
      clusters[key]!.add(item);
    }

    // Determine initial map bounds/center based on items
    final hasLocations = _mediaItems.isNotEmpty;
    final List<LatLng> allPoints = _mediaItems
        .map((itm) => LatLng(itm.latitude, itm.longitude))
        .toList();
    final LatLngBounds? mapBounds = hasLocations
        ? LatLngBounds.fromPoints(allPoints)
        : null;
    final LatLng mapCenter = hasLocations
        ? LatLng(_mediaItems.first.latitude, _mediaItems.first.longitude)
        : const LatLng(20.5937, 78.9629);

    // Create markers from cluster data
    final markers = clusters.entries.map((entry) {
      final key = entry.key;
      final clusterItems = entry.value;

      // Compute average coordinate for the cluster
      double sumLat = 0;
      double sumLng = 0;
      for (final itm in clusterItems) {
        sumLat += itm.latitude;
        sumLng += itm.longitude;
      }
      final double avgLat = sumLat / clusterItems.length;
      final double avgLng = sumLng / clusterItems.length;

      // Find the most recent cover photo
      clusterItems.sort((a, b) => b.dateTimestamp.compareTo(a.dateTimestamp));
      final coverItem = clusterItems.first;
      final isWatch = context.isWatch;
      final markerSize = isWatch ? 44.0 : 60.0;

      return Marker(
        point: LatLng(avgLat, avgLng),
        width: markerSize,
        height: markerSize,
        alignment: Alignment.center,
        child: LocationMapMarker(
          assetId: coverItem.id,
          coverPath: coverItem.imageUrl,
          count: clusterItems.length,
          isSelected: _selectedClusterKey == key,
          isVideo: coverItem.mediaType == 'video',
          onTap: () {
            setState(() {
              _selectedClusterKey = key;
            });
            final String locationTitle = clusterItems.first.shortAddress;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => AlbumDetailScreen(
                  albumName: locationTitle,
                  items: clusterItems,
                  isLocationAlbum: true,
                  onItemTapped: (item, [customList]) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PhotoViewerPage(
                          item: item,
                          allItems: customList ?? clusterItems,
                          ghostPersonality: "Dynamic Explorer",
                          onDelete: (id) async {
                            _loadLocationData();
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
            );
          },
        ),
      );
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "Memories Map",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: "Refresh database locations",
            onPressed: () {
              setState(() {
                _isLoading = true;
              });
              _loadLocationData();
            },
          ),
          if (_mediaItems.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.center_focus_strong_rounded),
              tooltip: "Center on photos",
              onPressed: () {
                if (mapBounds != null) {
                  _mapController.fitCamera(
                    CameraFit.bounds(
                      bounds: mapBounds,
                      padding: const EdgeInsets.all(50),
                    ),
                  );
                } else {
                  _mapController.move(mapCenter, 7.5);
                }
              },
            ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // ── GPS MAP VIEWPORT (Dynamic OpenStreetMap Layer) ──────────────────
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCameraFit: mapBounds != null
                  ? CameraFit.bounds(
                      bounds: mapBounds,
                      padding: const EdgeInsets.all(50),
                    )
                  : null,
              initialCenter: mapCenter,
              initialZoom: hasLocations ? 3.0 : 2.0,
              minZoom: 0.0,
              maxZoom: 18.0,
            ),
            children: [
              TileLayer(
                key: ValueKey(_currentStyle.id),
                urlTemplate: _currentStyle.urlTemplate,
                subdomains: _currentStyle.subdomains,
                userAgentPackageName: 'in.sddev.ghost_gallery',
                tileProvider: CachedTileProvider(),
              ),
              MarkerLayer(markers: markers),
            ],
          ),

          // ── Premium Floating Informational Guide Overlay ────────────────────
          if (!context.isWatch)
            Positioned(
              left: 16,
              right: 84, // Reduced width to fit map action buttons on the right
              bottom: 24,
              child: SafeArea(
                top: false,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.4,
                          ),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.15),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: theme.colorScheme.primaryContainer,
                            radius: 18,
                            child: const Icon(
                              Icons.explore_outlined,
                              size: 18,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _mediaItems.isEmpty
                                      ? "No Geotagged Media Found"
                                      : "Explore Your Memories",
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  _mediaItems.isEmpty
                                      ? "Add photos with GPS data to populate your travel clusters."
                                      : "Tap a custom circular thumbnail badge to view cluster albums.",
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // ── Zoom and Style Floating Actions Column ──────────────────────────
          Positioned(
            right: context.isWatch ? 8 : 16,
            bottom: context.isWatch ? 12 : 24,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildIconButton(
                    icon: Icons.layers_rounded,
                    tooltip: "Change map style",
                    onTap: () {
                      setState(() {
                        _showStyleSelector = !_showStyleSelector;
                      });
                    },
                  ),
                  SizedBox(height: context.isWatch ? 6 : 12),
                  _buildIconButton(
                    icon: Icons.add_rounded,
                    tooltip: "Zoom in",
                    onTap: () => _zoom(1),
                  ),
                  SizedBox(height: context.isWatch ? 4 : 8),
                  _buildIconButton(
                    icon: Icons.remove_rounded,
                    tooltip: "Zoom out",
                    onTap: () => _zoom(-1),
                  ),
                ],
              ),
            ),
          ),

          // ── Map Style Selector Panel ────────────────────────────────────────
          Positioned(
            right: 72,
            bottom: 24,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 108), // Align with style layer button
                child: AnimatedSlide(
                  offset: _showStyleSelector ? Offset.zero : const Offset(0.1, 0),
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutQuad,
                  child: AnimatedOpacity(
                    opacity: _showStyleSelector ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutQuad,
                    child: IgnorePointer(
                      ignoring: !_showStyleSelector,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: BackdropFilter(
                          filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surface.withValues(alpha: 0.85),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                                width: 1,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.15),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: _mapStyles.map((style) {
                                final isSelected = _currentStyle.id == style.id;
                                return _buildStyleOption(style, isSelected);
                              }).toList(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
