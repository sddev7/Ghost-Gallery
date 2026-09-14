import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../../models/gallery_item.dart';
import '../../models/vault_models.dart';
import '../../services/collection_source.dart';
import '../../services/vault_service.dart';
import '../../services/device_media_scanner.dart';
import '../photo_viewer_screen.dart';
import 'custom_media_picker.dart';
import 'vault_settings_screen.dart';
import 'vault_unlock_screen.dart';
import '../../services/responsive_helper.dart';


class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key});

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;
  List<VaultAlbum> _albums = [];
  List<VaultItem> _generalItems = [];
  bool _isLoading = true;
  bool _isSelectionMode = false;
  final Set<String> _selectedItemIds = {};
  // Drag-to-select state
  bool _isDragging = false;
  String? _dragStartId;
  bool _dragSelectState = true;
  final Map<String, GlobalKey> _itemKeys = {};

  Color get _primaryColor => Theme.of(context).colorScheme.primary;
  Color get _accentColor => Theme.of(context).colorScheme.secondary;
  Color get _bgColor => Theme.of(context).scaffoldBackgroundColor;
  Color get _cardColor => Theme.of(context).cardColor;
  Color get _textColor => Theme.of(context).colorScheme.onSurface;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 2, vsync: this);
    VaultService.instance.secureScreen(true);
    _loadVaultData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    VaultService.instance.lockVault();
    VaultService.instance.secureScreen(false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      VaultService.instance.lockVault();
      VaultService.instance.secureScreen(false);
      if (mounted) {
        Navigator.popUntil(
          context,
          (route) => route.settings.name == 'vault' || route.isFirst,
        );
      }
      setState(() {});
    } else if (state == AppLifecycleState.resumed) {
      // Re-enable secure screen when returning to vault screen if still unlocked
      if (VaultService.instance.isUnlocked) {
        VaultService.instance.secureScreen(true);
      }
    }
  }

  Future<void> _loadVaultData() async {
    setState(() => _isLoading = true);
    try {
      final albums = await VaultService.instance.getVaultAlbums();
      final filteredAlbums = albums.where((a) => a.id != 'general').toList();
      final generalItems = await VaultService.instance.getVaultItems('general');
      setState(() {
        _albums = filteredAlbums;
        _generalItems = generalItems;
        _isLoading = false;
      });
      
      // Trigger background pre-decryption of all thumbnails
      VaultService.instance.preDecryptAllThumbnails().then((_) {
        if (mounted) setState(() {});
      });
    } catch (e) {
      debugPrint('Error loading vault data: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addMedia() async {
    final List<GalleryItem>? selectedItems =
        await Navigator.push<List<GalleryItem>>(
          context,
          MaterialPageRoute(builder: (_) => const CustomMediaPicker()),
        );

    if (selectedItems == null || selectedItems.isEmpty) return;

    try {
      await _runWithProgressDialog<void>(
        context: context,
        title: 'Importing to Vault',
        totalCount: selectedItems.length,
        action: (progressNotifier, statusNotifier) async {
          int count = 0;
          for (final item in selectedItems) {
            statusNotifier.value = 'Securing file ${count + 1} of ${selectedItems.length}...';
            progressNotifier.value = count / selectedItems.length;

            await VaultService.instance.addMediaToVault(
              filePath: item.imageUrl,
              albumId: 'general',
              originalMediaId: item.id,
              mimeType: item.mimeType,
              mediaType: item.mediaType,
              width: item.width,
              height: item.height,
              dateTaken: item.dateTimestamp,
            );
            count++;
          }
          statusNotifier.value = 'Refreshing media gallery...';
          progressNotifier.value = 1.0;
          await CollectionSource.instance.refresh();
        },
      );

      await _loadVaultData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Successfully secured ${selectedItems.length} item(s) in Vault',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error adding items: $e')));
      }
      _loadVaultData();
    }
  }

  Future<void> _createNewAlbum() async {
    final nameController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text(
          'Create New Album',
          style: TextStyle(color: _textColor, fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: nameController,
          autofocus: true,
          style: TextStyle(color: _textColor),
          decoration: InputDecoration(
            labelText: 'Album Name',
            labelStyle: TextStyle(color: _textColor.withValues(alpha: 0.5)),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: _primaryColor),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Cancel',
              style: TextStyle(color: _textColor.withValues(alpha: 0.54)),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              if (nameController.text.isNotEmpty) {
                await VaultService.instance.createVaultAlbum(
                  nameController.text,
                );
                Navigator.pop(context);
                _loadVaultData();
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _primaryColor,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
            ),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _toggleSelection(String itemId) {
    setState(() {
      if (_selectedItemIds.contains(itemId)) {
        _selectedItemIds.remove(itemId);
        if (_selectedItemIds.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedItemIds.add(itemId);
        _isSelectionMode = true;
      }
    });
  }

  Future<void> _restoreSelected() async {
    if (_selectedItemIds.isEmpty) return;
    try {
      final itemsToRestore = _generalItems.where((x) => _selectedItemIds.contains(x.id)).toList();
      bool someRestoredToFallback = false;

      await _runWithProgressDialog<void>(
        context: context,
        title: 'Restoring Media',
        totalCount: itemsToRestore.length,
        action: (progressNotifier, statusNotifier) async {
          int count = 0;
          for (final item in itemsToRestore) {
            statusNotifier.value = 'Restoring file ${count + 1} of ${itemsToRestore.length}...';
            progressNotifier.value = count / itemsToRestore.length;

            final restoredPath = await VaultService.instance.removeFromVault(
              item: item,
              restore: true,
            );
            if (restoredPath.contains("Ghost Vault Restore")) {
              someRestoredToFallback = true;
            }
            count++;
          }
          statusNotifier.value = 'Syncing media library...';
          progressNotifier.value = 1.0;
          await DeviceMediaScanner.instance.scanAndSyncDeviceMedia(force: true);
          await CollectionSource.instance.refresh();
        },
      );

      setState(() {
        _isSelectionMode = false;
        _selectedItemIds.clear();
      });
      await _loadVaultData();

      if (mounted) {
        final msg = someRestoredToFallback
            ? 'Items restored to "Ghost Vault Restore" folder due to permission issues'
            : 'Items successfully restored to their original location';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error restoring items: $e')));
      }
      _loadVaultData();
    }
  }

  Future<void> _deleteSelected() async {
    if (_selectedItemIds.isEmpty) return;

    final confirm =
        await showDialog<bool>(
          context: context,
          builder: (ctx) {
            final isDark = Theme.of(ctx).brightness == Brightness.dark;
            final cardColor = isDark ? const Color(0xFF0F0F18) : Colors.white;
            final textColor = isDark ? const Color(0xFFCDCDCD) : Colors.black87;
            final warningColor = isDark
                ? const Color(0xFFCC0000)
                : const Color(0xFFD32F2F);

            return AlertDialog(
              backgroundColor: cardColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: warningColor),
                  const SizedBox(width: 8),
                  Text(
                    'Permanently Delete?',
                    style: TextStyle(
                      color: warningColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ],
              ),
              content: Text(
                'Are you sure you want to permanently delete the ${_selectedItemIds.length} selected item(s)?\n\n'
                '⚠️ WARNING: These items will be permanently removed from both the Secure Vault and your device storage. This action cannot be undone.',
                style: TextStyle(color: textColor, height: 1.45, fontSize: 14),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(
                    'Cancel',
                    style: TextStyle(
                      color: isDark ? Colors.grey[400] : Colors.grey[700],
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: warningColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                  ),
                  child: const Text(
                    'Delete Permanently',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!confirm) return;

    try {
      final itemsToDelete = _generalItems.where((x) => _selectedItemIds.contains(x.id)).toList();
      await _runWithProgressDialog<void>(
        context: context,
        title: 'Deleting Files',
        totalCount: itemsToDelete.length,
        action: (progressNotifier, statusNotifier) async {
          int count = 0;
          for (final item in itemsToDelete) {
            statusNotifier.value = 'Permanently deleting file ${count + 1} of ${itemsToDelete.length}...';
            progressNotifier.value = count / itemsToDelete.length;

            await VaultService.instance.deleteVaultItem(item);
            count++;
          }
          progressNotifier.value = 1.0;
        },
      );

      setState(() {
        _isSelectionMode = false;
        _selectedItemIds.clear();
      });
      await _loadVaultData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Selected items deleted permanently from Vault and device',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error deleting items: $e')));
      }
      _loadVaultData();
    }
  }

  // Securely decrypt and swipe files in PhotoViewerPage
  Future<void> _openSecureViewer(int initialIndex) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final tempDir = await getTemporaryDirectory();
      final cacheDir = Directory(p.join(tempDir.path, 'vault_view_cache'));
      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
      }
      await cacheDir.create(recursive: true);

      // Decrypt selected item first
      final currentItem = _generalItems[initialIndex];
      final currentBytes = await VaultService.instance.getDecryptedBytes(
        currentItem,
      );
      final currentExt = p.extension(currentItem.originalName).isNotEmpty
          ? p.extension(currentItem.originalName)
          : (currentItem.mediaType == 'video' ? '.mp4' : '.jpg');
      final currentTempFile = File(
        p.join(cacheDir.path, '${currentItem.id}$currentExt'),
      );
      await currentTempFile.writeAsBytes(currentBytes);

      // Map all general items to GalleryItem objects
      final List<GalleryItem> galleryItems = [];
      for (int i = 0; i < _generalItems.length; i++) {
        final item = _generalItems[i];
        final ext = p.extension(item.originalName).isNotEmpty
            ? p.extension(item.originalName)
            : (item.mediaType == 'video' ? '.mp4' : '.jpg');
        final tempPath = p.join(cacheDir.path, '${item.id}$ext');

        galleryItems.add(
          GalleryItem(
            id: item.id,
            imageUrl: tempPath,
            date: _formatDate(item.dateTaken),
            mediaType: item.mediaType,
            dateTimestamp: item.dateTaken,
            resolution: '${item.width}x${item.height}',
            size: '',
            width: item.width,
            height: item.height,
            mimeType: item.mimeType,
            rotationDegrees: 0,
            isFlipped: false,
            cameraInfo: '',
            albumName: 'Vault',
            albumCategory: 'Vault',
            latitude: 0.0,
            longitude: 0.0,
            location: '',
            xmpSubjects: '',
            rating: 0,
            isProcessed: false,
            flags: 0,
            category: 'Vault',
            description: 'Secured Vault Item',
            ghostComment: 'This file is securely encrypted in the Vault.',
          ),
        );
      }

      if (mounted) {
        Navigator.pop(context); // Close loading indicator
      }

      // Background decrypt of the remaining items
      _decryptRemainingItemsInBackground(cacheDir.path);

      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PhotoViewerPage(
              item: galleryItems[initialIndex],
              allItems: galleryItems,
              ghostPersonality: 'Ghost',
              isVault: true,
              onDelete: (id) async {
                final idx = _generalItems.indexWhere(
                  (element) => element.id == id,
                );
                if (idx != -1) {
                  final vaultItem = _generalItems[idx];
                  await VaultService.instance.deleteVaultItem(vaultItem);
                  await _loadVaultData();
                }
              },
            ),
          ),
        );
      }

      // Cleanup
      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to load item: $e')));
      }
    }
  }

  Future<void> _decryptRemainingItemsInBackground(String cacheDirPath) async {
    final dir = Directory(cacheDirPath);
    for (final item in _generalItems) {
      if (!await dir.exists()) {
        debugPrint('VaultScreen: Cache directory no longer exists, aborting pre-decryption');
        break;
      }
      try {
        final ext = p.extension(item.originalName).isNotEmpty
            ? p.extension(item.originalName)
            : (item.mediaType == 'video' ? '.mp4' : '.jpg');
        final tempFile = File(p.join(cacheDirPath, '${item.id}$ext'));
        if (await tempFile.exists()) continue;

        final bytes = await VaultService.instance.getDecryptedBytes(item);
        if (!await dir.exists()) break;
        await tempFile.writeAsBytes(bytes);
      } catch (e) {
        debugPrint('Error pre-decrypting item: $e');
      }
    }
  }

  String _formatDate(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (!VaultService.instance.isUnlocked) {
      return VaultUnlockScreen(
        onUnlockSuccess: () {
          setState(() {
            _loadVaultData();
          });
        },
      );
    }

    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: _isSelectionMode
            ? Text(
                '${_selectedItemIds.length} Selected',
                style: TextStyle(color: _textColor),
              )
            : Text(
                'Secure Vault',
                style: TextStyle(
                  color: _textColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
        leading: _isSelectionMode
            ? IconButton(
                icon: Icon(Icons.close, color: _textColor),
                onPressed: () {
                  setState(() {
                    _isSelectionMode = false;
                    _selectedItemIds.clear();
                  });
                },
              )
            : IconButton(
                icon: Icon(
                  Icons.arrow_back_ios_new,
                  color: _textColor.withValues(alpha: 0.7),
                ),
                onPressed: () => Navigator.pop(context),
              ),
        actions: [
          if (_isSelectionMode)
            IconButton(
              icon: Icon(
                _selectedItemIds.length == _generalItems.length
                    ? Icons.deselect_rounded
                    : Icons.select_all_rounded,
                color: _textColor,
              ),
              onPressed: () {
                setState(() {
                  if (_selectedItemIds.length == _generalItems.length) {
                    _selectedItemIds.clear();
                    _isSelectionMode = false;
                  } else {
                    _selectedItemIds.clear();
                    _selectedItemIds.addAll(_generalItems.map((e) => e.id));
                  }
                });
              },
              tooltip: _selectedItemIds.length == _generalItems.length
                  ? 'Deselect All'
                  : 'Select All',
            ),
          if (!_isSelectionMode)
            IconButton(
              icon: Icon(
                Icons.settings_outlined,
                color: _textColor.withValues(alpha: 0.7),
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const VaultSettingsScreen(),
                  ),
                ).then((_) => _loadVaultData());
              },
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: _primaryColor,
          labelColor: _textColor,
          unselectedLabelColor: _textColor.withValues(alpha: 0.38),
          tabs: const [
            Tab(text: 'General'),
            Tab(text: 'Albums'),
          ],
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: _primaryColor))
          : TabBarView(
              controller: _tabController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                RepaintBoundary(child: _buildGeneralTab()),
                RepaintBoundary(child: _buildAlbumsTab()),
              ],
            ),
      floatingActionButton: _isSelectionMode
          ? null
          : FloatingActionButton(
              backgroundColor: _primaryColor,
              onPressed: _addMedia,
              child: Icon(
                Icons.add,
                color: Theme.of(context).colorScheme.onPrimary,
              ),
            ),
      bottomNavigationBar: _isSelectionMode
          ? _buildSelectionActionToolbar()
          : null,
    );
  }

  Widget _buildGeneralTab() {
    return RefreshIndicator(
      color: _primaryColor,
      onRefresh: () async {
        await _loadVaultData();
      },
      child: _generalItems.isEmpty
          ? SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.6,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.shield_outlined,
                        size: 72,
                        color: _textColor.withValues(alpha: 0.15),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No Secured Items',
                        style: TextStyle(
                          color: _textColor.withValues(alpha: 0.7),
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Tap the + button to encrypt and hide files',
                        style: TextStyle(
                          color: _textColor.withValues(alpha: 0.4),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(8.0),
              child: GridView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: ResponsiveHelper.responsiveGridColumns(
                    context,
                    baseColumns: 3,
                    min: 1,
                    max: 8,
                  ),
                  crossAxisSpacing: 6,
                  mainAxisSpacing: 6,
                ),
                itemCount: _generalItems.length,
                itemBuilder: (context, index) {
                  final item = _generalItems[index];
                  final isSelected = _selectedItemIds.contains(item.id);
                  final key = _itemKeys.putIfAbsent(item.id, () => GlobalKey());

                  return GestureDetector(
                    key: key,
                    onLongPressStart: (_) {
                      HapticFeedback.mediumImpact();
                      _isDragging = true;
                      _dragStartId = item.id;
                      _dragSelectState = !_selectedItemIds.contains(item.id);
                      _toggleSelection(item.id);
                    },
                    onLongPressMoveUpdate: (details) {
                      if (!_isDragging) return;
                      final hit = _hitTestItemAt(details.globalPosition);
                      if (hit != null && hit != _dragStartId) {
                        final already = _selectedItemIds.contains(hit);
                        if (_dragSelectState && !already) {
                          HapticFeedback.selectionClick();
                          setState(() {
                            _selectedItemIds.add(hit);
                            _isSelectionMode = true;
                          });
                        } else if (!_dragSelectState && already) {
                          HapticFeedback.selectionClick();
                          setState(() {
                            _selectedItemIds.remove(hit);
                            if (_selectedItemIds.isEmpty) _isSelectionMode = false;
                          });
                        }
                      }
                    },
                    onLongPressEnd: (_) => setState(() => _isDragging = false),
                    onTap: () {
                      if (_isSelectionMode) {
                        HapticFeedback.lightImpact();
                        _toggleSelection(item.id);
                      } else {
                        _openSecureViewer(index);
                      }
                    },
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: isSelected
                                ? Border.all(color: _primaryColor, width: 2.5)
                                : null,
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(isSelected ? 6 : 8),
                            child: VaultImageWidget(item: item),
                          ),
                        ),
                        if (item.isVideo)
                          const Positioned(
                            bottom: 6,
                            right: 6,
                            child: Icon(
                              Icons.play_circle_fill,
                              color: Colors.white,
                              size: 22,
                            ),
                          ),
                        Positioned(
                          top: 6,
                          left: 6,
                          child: AnimatedOpacity(
                            opacity: _isSelectionMode ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 200),
                            child: AnimatedScale(
                              scale: isSelected ? 1.0 : 0.7,
                              duration: const Duration(milliseconds: 150),
                              child: Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isSelected ? _primaryColor : Colors.black54,
                                  border: Border.all(color: Colors.white, width: 1.5),
                                ),
                                padding: const EdgeInsets.all(2),
                                child: isSelected
                                    ? Icon(
                                        Icons.check,
                                        size: 14,
                                        color: Theme.of(context).colorScheme.onPrimary,
                                      )
                                    : const SizedBox(width: 14, height: 14),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
    );
  }

  String? _hitTestItemAt(Offset globalPos) {
    for (final entry in _itemKeys.entries) {
      final ctx = entry.value.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final local = box.globalToLocal(globalPos);
      if (local.dx >= 0 &&
          local.dx <= box.size.width &&
          local.dy >= 0 &&
          local.dy <= box.size.height) {
        return entry.key;
      }
    }
    return null;
  }

  Widget _buildAlbumsTab() {
    if (_albums.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [
                    _primaryColor.withValues(alpha: 0.2),
                    _accentColor.withValues(alpha: 0.1),
                  ],
                ),
              ),
              child: Icon(
                Icons.folder_special_rounded,
                size: 44,
                color: _accentColor.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'No Secured Albums',
              style: TextStyle(
                color: _textColor.withValues(alpha: 0.7),
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Create albums to organize your hidden files',
              style: TextStyle(
                color: _textColor.withValues(alpha: 0.4),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 28),
            ElevatedButton.icon(
              onPressed: _createNewAlbum,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Create Album'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _primaryColor,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${_albums.length} Albums',
                style: TextStyle(
                  color: _textColor.withValues(alpha: 0.55),
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              TextButton.icon(
                onPressed: _createNewAlbum,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('New Album'),
                style: TextButton.styleFrom(foregroundColor: _accentColor),
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 80),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: context.isWatch
                  ? 1
                  : (context.isTV ? 4 : (context.isTablet ? 3 : 2)),
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 0.88,
            ),
            itemCount: _albums.length,
            itemBuilder: (context, index) {
              final album = _albums[index];
              return VaultAlbumCard(
                album: album,
                primaryColor: _primaryColor,
                accentColor: _accentColor,
                textColor: _textColor,
                cardColor: _cardColor,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => VaultAlbumItemsScreen(album: album),
                    ),
                  ).then((_) => _loadVaultData());
                },
                onLongPress: () => _showAlbumContextMenu(context, album),
              );
            },
          ),
        ),
      ],
    );
  }

  void _showAlbumContextMenu(BuildContext context, VaultAlbum album) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: _cardColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: _textColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  album.name,
                  style: TextStyle(
                    color: _textColor,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: Icon(
                  Icons.drive_file_rename_outline,
                  color: _accentColor,
                ),
                title: Text('Rename', style: TextStyle(color: _textColor)),
                onTap: () async {
                  Navigator.pop(ctx);
                  final ctrl = TextEditingController(text: album.name);
                  final name = await showDialog<String>(
                    context: context,
                    builder: (_) => AlertDialog(
                      backgroundColor: _cardColor,
                      title: Text(
                        'Rename Album',
                        style: TextStyle(color: _textColor),
                      ),
                      content: TextField(
                        controller: ctrl,
                        autofocus: true,
                        style: TextStyle(color: _textColor),
                        decoration: const InputDecoration(
                          labelText: 'Album Name',
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel'),
                        ),
                        ElevatedButton(
                          onPressed: () =>
                              Navigator.pop(context, ctrl.text.trim()),
                          child: const Text('Rename'),
                        ),
                      ],
                    ),
                  );
                  if (name != null && name.isNotEmpty) {
                    setState(() => _isLoading = true);
                    try {
                      await VaultService.instance.renameVaultAlbum(
                        album.id,
                        name,
                      );
                      await _loadVaultData();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Album renamed to "$name"')),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Error renaming album: $e')),
                        );
                      }
                      setState(() => _isLoading = false);
                    }
                  }
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.settings_backup_restore,
                  color: _accentColor,
                ),
                title: Text(
                  'Move Out of Vault',
                  style: TextStyle(color: _textColor),
                ),
                subtitle: Text(
                  'Restore all items to original gallery',
                  style: TextStyle(
                    color: _textColor.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    final items = await VaultService.instance.getVaultItems(
                      album.id,
                    );
                    bool someRestoredToFallback = false;

                    await _runWithProgressDialog<void>(
                      context: context,
                      title: 'Restoring Album Items',
                      totalCount: items.length,
                      action: (progressNotifier, statusNotifier) async {
                        int count = 0;
                        for (final item in items) {
                          statusNotifier.value = 'Restoring file ${count + 1} of ${items.length}...';
                          progressNotifier.value = count / items.length;

                          final restoredPath = await VaultService.instance.removeFromVault(
                            item: item,
                            restore: true,
                          );
                          if (restoredPath.contains("Ghost Vault Restore")) {
                            someRestoredToFallback = true;
                          }
                          count++;
                        }
                        statusNotifier.value = 'Deleting empty album...';
                        progressNotifier.value = 1.0;
                        await VaultService.instance.deleteVaultAlbum(
                          album.id,
                          deleteItems: false,
                        );
                        if (Platform.isAndroid) {
                          statusNotifier.value = 'Syncing media library...';
                          await DeviceMediaScanner.instance.scanAndSyncDeviceMedia(
                            force: true,
                          );
                        }
                        await CollectionSource.instance.refresh();
                      },
                    );

                    await _loadVaultData();
                    if (mounted) {
                      final msg = someRestoredToFallback
                          ? 'All album items restored to "Ghost Vault Restore" folder and album deleted'
                          : 'All album items restored and album deleted';
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(msg),
                        ),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Error moving items out of vault: $e'),
                        ),
                      );
                    }
                    _loadVaultData();
                  }
                },
              ),
              ListTile(
                leading: Icon(Icons.move_to_inbox_rounded, color: _accentColor),
                title: Text(
                  'Move to General',
                  style: TextStyle(color: _textColor),
                ),
                subtitle: Text(
                  'Move items to General and delete this album',
                  style: TextStyle(
                    color: _textColor.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  setState(() => _isLoading = true);
                  try {
                    await VaultService.instance.deleteVaultAlbum(
                      album.id,
                      deleteItems: false,
                    );
                    await _loadVaultData();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Items moved to General and album deleted',
                          ),
                        ),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error moving items: $e')),
                      );
                    }
                    setState(() => _isLoading = false);
                  }
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_forever_rounded,
                  color: Colors.redAccent,
                ),
                title: const Text(
                  'Delete Album & Items',
                  style: TextStyle(color: Colors.redAccent),
                ),
                subtitle: Text(
                  'Permanently delete all items and this album',
                  style: TextStyle(
                    color: Colors.redAccent.withValues(alpha: 0.6),
                    fontSize: 11,
                  ),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  final confirm =
                      await showDialog<bool>(
                        context: context,
                        builder: (dialogCtx) {
                          final isDark =
                              Theme.of(dialogCtx).brightness == Brightness.dark;
                          final cardColor = isDark
                              ? const Color(0xFF0F0F18)
                              : Colors.white;
                          final textColor = isDark
                              ? const Color(0xFFCDCDCD)
                              : Colors.black87;
                          final warningColor = isDark
                              ? const Color(0xFFCC0000)
                              : const Color(0xFFD32F2F);

                          return AlertDialog(
                            backgroundColor: cardColor,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            title: Row(
                              children: [
                                Icon(
                                  Icons.warning_amber_rounded,
                                  color: warningColor,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Delete Album & Items?',
                                  style: TextStyle(
                                    color: warningColor,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                  ),
                                ),
                              ],
                            ),
                            content: Text(
                              'Are you sure you want to delete the album "${album.name}" and permanently delete all of its ${album.itemCount} item(s)?\n\n'
                              '⚠️ WARNING: All items in this album will be permanently deleted from both the Secure Vault and device storage. This action cannot be undone.',
                              style: TextStyle(
                                color: textColor,
                                height: 1.4,
                                fontSize: 14,
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(dialogCtx, false),
                                child: Text(
                                  'Cancel',
                                  style: TextStyle(
                                    color: isDark
                                        ? Colors.grey[400]
                                        : Colors.grey[700],
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              ElevatedButton(
                                onPressed: () => Navigator.pop(dialogCtx, true),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: warningColor,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                                child: const Text(
                                  'Delete Permanently',
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          );
                        },
                      ) ??
                      false;
                  if (confirm) {
                    try {
                      final items = await VaultService.instance.getVaultItems(
                        album.id,
                      );
                      await _runWithProgressDialog<void>(
                        context: context,
                        title: 'Deleting Album & Items',
                        totalCount: items.length,
                        action: (progressNotifier, statusNotifier) async {
                          int count = 0;
                          for (final item in items) {
                            statusNotifier.value = 'Permanently deleting file ${count + 1} of ${items.length}...';
                            progressNotifier.value = count / items.length;

                            await VaultService.instance.deleteVaultItem(item);
                            count++;
                          }
                          statusNotifier.value = 'Deleting album...';
                          progressNotifier.value = 1.0;
                          await VaultService.instance.deleteVaultAlbum(
                            album.id,
                            deleteItems: false,
                          );
                        },
                      );

                      await _loadVaultData();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Album and all items deleted permanently',
                            ),
                          ),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Error deleting album: $e')),
                        );
                      }
                      _loadVaultData();
                    }
                  }
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSelectionActionToolbar() {
    return BottomAppBar(
      color: _cardColor,
      child: SizedBox(
        height: 60,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            IconButton(
              icon: Icon(Icons.settings_backup_restore, color: _textColor),
              onPressed: _restoreSelected,
              tooltip: 'Restore selected',
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              onPressed: _deleteSelected,
              tooltip: 'Delete selected',
            ),
          ],
        ),
      ),
    );
  }
}

class VaultAlbumCard extends StatelessWidget {
  final VaultAlbum album;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Color primaryColor, accentColor, textColor, cardColor;

  const VaultAlbumCard({
    super.key,
    required this.album,
    required this.onTap,
    required this.primaryColor,
    required this.accentColor,
    required this.textColor,
    required this.cardColor,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<VaultItem?>(
      future: VaultService.instance.getAlbumCoverItem(album.id),
      builder: (context, snapshot) {
        final coverItem = snapshot.data;
        return GestureDetector(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Cover image
                  coverItem != null
                      ? VaultImageWidget(item: coverItem)
                      : Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                primaryColor.withValues(alpha: 0.15),
                                accentColor.withValues(alpha: 0.08),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                          child: Center(
                            child: Icon(
                              Icons.folder_special_rounded,
                              size: 52,
                              color: accentColor.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                  // Gradient overlay
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.78),
                          ],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0.45, 1.0],
                        ),
                      ),
                    ),
                  ),
                  // Lock icon top-right
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: Colors.black38,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.lock_rounded,
                        size: 14,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                  // Album info bottom
                  Positioned(
                    bottom: 12,
                    left: 12,
                    right: 12,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          album.name,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(
                              Icons.photo_library_rounded,
                              size: 11,
                              color: Colors.white54,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${album.itemCount} items',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white60,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class VaultImageWidget extends StatefulWidget {
  final VaultItem item;
  const VaultImageWidget({super.key, required this.item});

  @override
  State<VaultImageWidget> createState() => _VaultImageWidgetState();
}

class _VaultImageWidgetState extends State<VaultImageWidget> {
  late Future<Uint8List> _bytesFuture;

  @override
  void initState() {
    super.initState();
    _bytesFuture = _getBytes();
  }

  @override
  void didUpdateWidget(VaultImageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.item.id != oldWidget.item.id) {
      _bytesFuture = _getBytes();
    }
  }

  Future<Uint8List> _getBytes() async {
    if (widget.item.isVideo) {
      try {
        return await VaultService.instance.getVideoThumbnail(widget.item);
      } catch (e) {
        debugPrint('VaultImageWidget: failed to load video thumbnail: $e');
      }
    } else {
      try {
        return await VaultService.instance.getImageThumbnail(widget.item);
      } catch (e) {
        debugPrint('VaultImageWidget: failed to load image thumbnail: $e');
      }
    }
    return VaultService.instance.getDecryptedBytes(widget.item);
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return FutureBuilder<Uint8List>(
      future: _bytesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _ShimmerPlaceholder(isVideo: widget.item.isVideo);
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return Container(
            color: onSurface.withValues(alpha: 0.05),
            child: Center(
              child: widget.item.isVideo
                  ? Icon(
                      Icons.videocam_rounded,
                      color: onSurface.withValues(alpha: 0.3),
                      size: 32,
                    )
                  : Icon(
                      Icons.broken_image_rounded,
                      color: onSurface.withValues(alpha: 0.24),
                      size: 28,
                    ),
            ),
          );
        }
        return _FadeInImageMemory(bytes: snapshot.data!);
      },
    );
  }
}

class _ShimmerPlaceholder extends StatefulWidget {
  final bool isVideo;
  const _ShimmerPlaceholder({required this.isVideo});

  @override
  State<_ShimmerPlaceholder> createState() => _ShimmerPlaceholderState();
}

class _ShimmerPlaceholderState extends State<_ShimmerPlaceholder>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    )..repeat(reverse: true);
    _animation = Tween<double>(begin: 0.3, end: 0.7).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return FadeTransition(
      opacity: _animation,
      child: Container(
        color: onSurface.withValues(alpha: 0.08),
        child: Center(
          child: Icon(
            widget.isVideo ? Icons.videocam_rounded : Icons.image_rounded,
            color: onSurface.withValues(alpha: 0.18),
            size: 28,
          ),
        ),
      ),
    );
  }
}

class _FadeInImageMemory extends StatefulWidget {
  final Uint8List bytes;
  const _FadeInImageMemory({required this.bytes});

  @override
  State<_FadeInImageMemory> createState() => _FadeInImageMemoryState();
}

class _FadeInImageMemoryState extends State<_FadeInImageMemory> {
  double _opacity = 0.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {
          _opacity = 1.0;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _opacity,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeIn,
      child: Image.memory(
        widget.bytes,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
      ),
    );
  }
}

class VaultAlbumSlideshowBackground extends StatefulWidget {
  final List<VaultItem> items;

  const VaultAlbumSlideshowBackground({
    super.key,
    required this.items,
  });

  @override
  State<VaultAlbumSlideshowBackground> createState() => _VaultAlbumSlideshowBackgroundState();
}

class _VaultAlbumSlideshowBackgroundState extends State<VaultAlbumSlideshowBackground> {
  List<VaultItem> _slideshowItems = [];
  int _currentIndex = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _setupItems();
    if (_slideshowItems.isNotEmpty) {
      _startTimer();
    }
  }

  @override
  void didUpdateWidget(covariant VaultAlbumSlideshowBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.items != oldWidget.items) {
      _setupItems();
      if (_slideshowItems.isNotEmpty && _timer == null) {
        _startTimer();
      } else if (_slideshowItems.isEmpty) {
        _timer?.cancel();
        _timer = null;
      }
    }
  }

  void _setupItems() {
    if (widget.items.isEmpty) {
      _slideshowItems = [];
      return;
    }
    final random = Random();
    final allItems = List<VaultItem>.from(widget.items);
    allItems.shuffle(random);
    _slideshowItems = allItems.take(12).toList();
    _currentIndex = 0;
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 7), (timer) {
      if (!mounted || _slideshowItems.length <= 1) return;
      setState(() {
        _currentIndex = (_currentIndex + 1) % _slideshowItems.length;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_slideshowItems.isEmpty) {
      return Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFF130F40), // Obsidian midnight violet
              Color(0xFF000000),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
      );
    }

    final currentItem = _slideshowItems[_currentIndex];

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 1500),
      switchInCurve: Curves.easeIn,
      switchOutCurve: Curves.easeOut,
      layoutBuilder: (Widget? currentChild, List<Widget> previousChildren) {
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ...previousChildren,
            ?currentChild,
          ],
        );
      },
      child: VaultKenBurnsImage(
        key: ValueKey<String>('${currentItem.id}_$_currentIndex'),
        item: currentItem,
      ),
    );
  }
}

class VaultKenBurnsImage extends StatefulWidget {
  final VaultItem item;

  const VaultKenBurnsImage({
    required this.item,
    super.key,
  });

  @override
  State<VaultKenBurnsImage> createState() => _VaultKenBurnsImageState();
}

class _VaultKenBurnsImageState extends State<VaultKenBurnsImage> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<Alignment> _alignmentAnimation;
  late Future<Uint8List> _bytesFuture;

  @override
  void initState() {
    super.initState();
    _bytesFuture = _getBytes();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    );

    final random = Random();
    
    final zoomIn = random.nextBool();
    _scaleAnimation = Tween<double>(
      begin: zoomIn ? 1.05 : 1.25,
      end: zoomIn ? 1.25 : 1.05,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    final double startX = (random.nextDouble() * 0.4) - 0.2;
    final double startY = (random.nextDouble() * 0.4) - 0.2;
    final double endX = (random.nextDouble() * 0.4) - 0.2;
    final double endY = (random.nextDouble() * 0.4) - 0.2;

    _alignmentAnimation = AlignmentTween(
      begin: Alignment(startX, startY),
      end: Alignment(endX, endY),
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    _controller.forward();
  }

  Future<Uint8List> _getBytes() async {
    if (widget.item.isVideo) {
      try {
        return await VaultService.instance.getVideoThumbnail(widget.item);
      } catch (_) {}
    } else {
      try {
        return await VaultService.instance.getImageThumbnail(widget.item);
      } catch (_) {}
    }
    return VaultService.instance.getDecryptedBytes(widget.item);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _bytesFuture,
      builder: (context, snapshot) {
        final hasData = snapshot.hasData && !snapshot.hasError;
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return SizedBox.expand(
              child: ClipRect(
                child: Transform.scale(
                  scale: _scaleAnimation.value,
                  alignment: _alignmentAnimation.value,
                  child: hasData
                      ? Image.memory(
                          snapshot.data!,
                          fit: BoxFit.cover,
                        )
                      : Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Color(0xFF130F40),
                                Color(0xFF000000),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                        ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class VaultAlbumItemsScreen extends StatefulWidget {
  final VaultAlbum album;
  const VaultAlbumItemsScreen({super.key, required this.album});

  @override
  State<VaultAlbumItemsScreen> createState() => _VaultAlbumItemsScreenState();
}

class _VaultAlbumItemsScreenState extends State<VaultAlbumItemsScreen> {
  List<VaultItem> _items = [];
  bool _isLoading = true;
  bool _isSelectionMode = false;
  final Set<String> _selectedItemIds = {};
  bool _isDragging = false;
  String? _dragStartId;
  bool _dragSelectState = true;
  final Map<String, GlobalKey> _itemKeys = {};

  final ScrollController _scrollController = ScrollController();
  bool _isCollapsed = false;

  void _scrollListener() {
    if (_scrollController.hasClients) {
      final double offset = _scrollController.offset;
      final double collapseHeight = 320.0 - kToolbarHeight;
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
    _scrollController.addListener(_scrollListener);
    _loadAlbumItems();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_scrollListener);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadAlbumItems() async {
    setState(() => _isLoading = true);
    final items = await VaultService.instance.getVaultItems(widget.album.id);
    items.sort((a, b) => b.dateTaken.compareTo(a.dateTaken));
    setState(() {
      _items = items;
      _isLoading = false;
    });
  }

  void _toggleSelection(String itemId) {
    setState(() {
      if (_selectedItemIds.contains(itemId)) {
        _selectedItemIds.remove(itemId);
        if (_selectedItemIds.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedItemIds.add(itemId);
        _isSelectionMode = true;
      }
    });
  }

  String? _hitTestItemAt(Offset globalPos) {
    for (final entry in _itemKeys.entries) {
      final ctx = entry.value.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final local = box.globalToLocal(globalPos);
      if (local.dx >= 0 &&
          local.dx <= box.size.width &&
          local.dy >= 0 &&
          local.dy <= box.size.height) {
        return entry.key;
      }
    }
    return null;
  }

  Future<void> _restoreSelected() async {
    if (_selectedItemIds.isEmpty) return;
    try {
      final itemsToRestore = _items.where((x) => _selectedItemIds.contains(x.id)).toList();
      bool someRestoredToFallback = false;

      await _runWithProgressDialog<void>(
        context: context,
        title: 'Restoring Media',
        totalCount: itemsToRestore.length,
        action: (progressNotifier, statusNotifier) async {
          int count = 0;
          for (final item in itemsToRestore) {
            statusNotifier.value = 'Restoring file ${count + 1} of ${itemsToRestore.length}...';
            progressNotifier.value = count / itemsToRestore.length;

            final restoredPath = await VaultService.instance.removeFromVault(
              item: item,
              restore: true,
            );
            if (restoredPath.contains("Ghost Vault Restore")) {
              someRestoredToFallback = true;
            }
            count++;
          }
          statusNotifier.value = 'Syncing media library...';
          progressNotifier.value = 1.0;
          await DeviceMediaScanner.instance.scanAndSyncDeviceMedia(force: true);
          await CollectionSource.instance.refresh();
        },
      );

      setState(() {
        _isSelectionMode = false;
        _selectedItemIds.clear();
      });
      await _loadAlbumItems();

      if (mounted) {
        final msg = someRestoredToFallback
            ? 'Items restored to "Ghost Vault Restore" folder due to permission issues'
            : 'Items successfully restored to their original location';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error restoring items: $e')));
      }
      _loadAlbumItems();
    }
  }

  Future<void> _deleteSelected() async {
    if (_selectedItemIds.isEmpty) return;

    final confirm =
        await showDialog<bool>(
          context: context,
          builder: (ctx) {
            final isDark = Theme.of(ctx).brightness == Brightness.dark;
            final cardColor = isDark ? const Color(0xFF0F0F18) : Colors.white;
            final textColor = isDark ? const Color(0xFFCDCDCD) : Colors.black87;
            final warningColor = isDark
                ? const Color(0xFFCC0000)
                : const Color(0xFFD32F2F);

            return AlertDialog(
              backgroundColor: cardColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: warningColor),
                  const SizedBox(width: 8),
                  Text(
                    'Permanently Delete?',
                    style: TextStyle(
                      color: warningColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ],
              ),
              content: Text(
                'Are you sure you want to permanently delete the ${_selectedItemIds.length} selected item(s)?\n\n'
                '⚠️ WARNING: These items will be permanently removed from both the Secure Vault and your device storage. This action cannot be undone.',
                style: TextStyle(color: textColor, height: 1.45, fontSize: 14),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(
                    'Cancel',
                    style: TextStyle(
                      color: isDark ? Colors.grey[400] : Colors.grey[700],
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: warningColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                  ),
                  child: const Text(
                    'Delete Permanently',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!confirm) return;

    try {
      final itemsToDelete = _items.where((x) => _selectedItemIds.contains(x.id)).toList();
      await _runWithProgressDialog<void>(
        context: context,
        title: 'Deleting Files',
        totalCount: itemsToDelete.length,
        action: (progressNotifier, statusNotifier) async {
          int count = 0;
          for (final item in itemsToDelete) {
            statusNotifier.value = 'Permanently deleting file ${count + 1} of ${itemsToDelete.length}...';
            progressNotifier.value = count / itemsToDelete.length;

            await VaultService.instance.deleteVaultItem(item);
            count++;
          }
          progressNotifier.value = 1.0;
        },
      );

      setState(() {
        _isSelectionMode = false;
        _selectedItemIds.clear();
      });
      await _loadAlbumItems();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Selected items deleted permanently from Vault and device',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error deleting items: $e')));
      }
      _loadAlbumItems();
    }
  }

  Widget _buildSelectionActionToolbar() {
    final cardColor = Theme.of(context).cardColor;
    final textColor = Theme.of(context).colorScheme.onSurface;

    return BottomAppBar(
      color: cardColor,
      child: SizedBox(
        height: 60,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            IconButton(
              icon: Icon(Icons.settings_backup_restore, color: textColor),
              onPressed: _restoreSelected,
              tooltip: 'Restore selected',
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              onPressed: _deleteSelected,
              tooltip: 'Delete selected',
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openSecureViewer(int initialIndex) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final tempDir = await getTemporaryDirectory();
      final cacheDir = Directory(p.join(tempDir.path, 'vault_view_cache'));
      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
      }
      await cacheDir.create(recursive: true);

      // Decrypt selected item first
      final currentItem = _items[initialIndex];
      final currentBytes = await VaultService.instance.getDecryptedBytes(
        currentItem,
      );
      final currentExt = p.extension(currentItem.originalName).isNotEmpty
          ? p.extension(currentItem.originalName)
          : (currentItem.mediaType == 'video' ? '.mp4' : '.jpg');
      final currentTempFile = File(
        p.join(cacheDir.path, '${currentItem.id}$currentExt'),
      );
      await currentTempFile.writeAsBytes(currentBytes);

      // Map album items to GalleryItem objects
      final List<GalleryItem> galleryItems = [];
      for (int i = 0; i < _items.length; i++) {
        final item = _items[i];
        final ext = p.extension(item.originalName).isNotEmpty
            ? p.extension(item.originalName)
            : (item.mediaType == 'video' ? '.mp4' : '.jpg');
        final tempPath = p.join(cacheDir.path, '${item.id}$ext');

        galleryItems.add(
          GalleryItem(
            id: item.id,
            imageUrl: tempPath,
            date: _formatDate(item.dateTaken),
            mediaType: item.mediaType,
            dateTimestamp: item.dateTaken,
            resolution: '${item.width}x${item.height}',
            size: '',
            width: item.width,
            height: item.height,
            mimeType: item.mimeType,
            rotationDegrees: 0,
            isFlipped: false,
            cameraInfo: '',
            albumName: widget.album.name,
            albumCategory: widget.album.name,
            latitude: 0.0,
            longitude: 0.0,
            location: '',
            xmpSubjects: '',
            rating: 0,
            isProcessed: false,
            flags: 0,
            category: 'Vault',
            description: 'Secured Vault Item',
            ghostComment: 'This file is securely encrypted in the Vault.',
          ),
        );
      }

      if (mounted) {
        Navigator.pop(context); // Close loading indicator
      }

      // Background decrypt remaining items
      _decryptRemainingItemsInBackground(cacheDir.path);

      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PhotoViewerPage(
              item: galleryItems[initialIndex],
              allItems: galleryItems,
              ghostPersonality: 'Ghost',
              isVault: true,
              onDelete: (id) async {
                final idx = _items.indexWhere((element) => element.id == id);
                if (idx != -1) {
                  final vaultItem = _items[idx];
                  await VaultService.instance.deleteVaultItem(vaultItem);
                  await _loadAlbumItems();
                }
              },
            ),
          ),
        );
      }

      // Cleanup
      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to load item: $e')));
      }
    }
  }

  Future<void> _decryptRemainingItemsInBackground(String cacheDirPath) async {
    final dir = Directory(cacheDirPath);
    for (final item in _items) {
      if (!await dir.exists()) {
        debugPrint('VaultScreen: Album cache directory no longer exists, aborting pre-decryption');
        break;
      }
      try {
        final ext = p.extension(item.originalName).isNotEmpty
            ? p.extension(item.originalName)
            : (item.mediaType == 'video' ? '.mp4' : '.jpg');
        final tempFile = File(p.join(cacheDirPath, '${item.id}$ext'));
        if (await tempFile.exists()) continue;

        final bytes = await VaultService.instance.getDecryptedBytes(item);
        if (!await dir.exists()) break;
        await tempFile.writeAsBytes(bytes);
      } catch (e) {
        debugPrint('Error pre-decrypting album item: $e');
      }
    }
  }

  Future<void> _addMediaToAlbum() async {
    final List<GalleryItem>? selectedItems =
        await Navigator.push<List<GalleryItem>>(
          context,
          MaterialPageRoute(builder: (_) => const CustomMediaPicker()),
        );

    if (selectedItems == null || selectedItems.isEmpty) return;

    try {
      await _runWithProgressDialog<void>(
        context: context,
        title: 'Importing to Album',
        totalCount: selectedItems.length,
        action: (progressNotifier, statusNotifier) async {
          int count = 0;
          for (final item in selectedItems) {
            statusNotifier.value = 'Securing file ${count + 1} of ${selectedItems.length}...';
            progressNotifier.value = count / selectedItems.length;

            await VaultService.instance.addMediaToVault(
              filePath: item.imageUrl,
              albumId: widget.album.id,
              originalMediaId: item.id,
              mimeType: item.mimeType,
              mediaType: item.mediaType,
              width: item.width,
              height: item.height,
              dateTaken: item.dateTimestamp,
            );
            count++;
          }
          statusNotifier.value = 'Refreshing media gallery...';
          progressNotifier.value = 1.0;
          await CollectionSource.instance.refresh();
        },
      );

      await _loadAlbumItems();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Successfully secured ${selectedItems.length} item(s) to ${widget.album.name}',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error adding items: $e')));
      }
      _loadAlbumItems();
    }
  }

  String _formatDate(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  String _getDynamicDateLabel(VaultItem item) {
    final ts = item.dateTaken;
    if (ts == 0) return _formatDate(ts);
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final itemDay = DateTime(dt.year, dt.month, dt.day);

    if (itemDay == today) return 'Today';
    if (itemDay == yesterday) return 'Yesterday';

    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final weekdayStr = weekdays[dt.weekday - 1];
    final monthStr = months[dt.month - 1];

    if (dt.year == now.year) {
      return '$weekdayStr, ${dt.day} $monthStr';
    }
    return '$weekdayStr, ${dt.day} $monthStr, ${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final appBarColor = isDark
        ? const Color(0xFF0F0F18).withValues(alpha: _isCollapsed ? 1.0 : 0.0)
        : Colors.white.withValues(alpha: _isCollapsed ? 1.0 : 0.0);
    final appBarIconColor = _isCollapsed
        ? (isDark ? Colors.white : Colors.black87)
        : Colors.white;
    final leadIconColor = _isSelectionMode
        ? (isDark ? Colors.white : Colors.black87)
        : appBarIconColor;
    final titleColor = isDark ? Colors.white : Colors.black87;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: _isLoading
          ? Center(
              child: CircularProgressIndicator(
                color: Theme.of(context).colorScheme.primary,
              ),
            )
          : RefreshIndicator(
              color: Theme.of(context).colorScheme.primary,
              onRefresh: _loadAlbumItems,
              child: CustomScrollView(
                controller: _scrollController,
                physics: _isSelectionMode
                    ? const NeverScrollableScrollPhysics()
                    : const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(),
                      ),
                slivers: [
                  SliverAppBar(
                    expandedHeight: 320.0,
                    pinned: true,
                    backgroundColor: appBarColor,
                    elevation: 0,
                    leading: _isSelectionMode
                        ? IconButton(
                            icon: Icon(Icons.close, color: leadIconColor),
                            onPressed: () {
                              setState(() {
                                _isSelectionMode = false;
                                _selectedItemIds.clear();
                              });
                            },
                          )
                        : IconButton(
                            icon: Icon(
                              Icons.arrow_back_ios_new,
                              color: leadIconColor,
                            ),
                            onPressed: () => Navigator.pop(context),
                          ),
                    actions: [
                      if (_isSelectionMode)
                        IconButton(
                          icon: Icon(
                            _selectedItemIds.length == _items.length
                                ? Icons.deselect_rounded
                                : Icons.select_all_rounded,
                            color: leadIconColor,
                          ),
                          onPressed: () {
                            setState(() {
                              if (_selectedItemIds.length == _items.length) {
                                _selectedItemIds.clear();
                                _isSelectionMode = false;
                              } else {
                                _selectedItemIds.clear();
                                _selectedItemIds.addAll(_items.map((e) => e.id));
                              }
                            });
                          },
                          tooltip: _selectedItemIds.length == _items.length
                              ? 'Deselect All'
                              : 'Select All',
                        ),
                    ],
                    flexibleSpace: FlexibleSpaceBar(
                      stretchModes: const [StretchMode.zoomBackground],
                      background: Stack(
                        fit: StackFit.expand,
                        children: [
                          VaultAlbumSlideshowBackground(items: _items),
                          Container(color: Colors.black.withValues(alpha: 0.2)),
                          Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Colors.black.withValues(alpha: 0.0),
                                  Colors.black.withValues(alpha: 0.75),
                                ],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              ),
                            ),
                          ),
                          Positioned(
                            left: 16,
                            bottom: 16,
                            right: 16,
                            child: AnimatedOpacity(
                              opacity: _isCollapsed || _isSelectionMode ? 0.0 : 1.0,
                              duration: const Duration(milliseconds: 200),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    widget.album.name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 32,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: -0.5,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${_items.length} items',
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.75),
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    title: _isSelectionMode
                        ? Text(
                            '${_selectedItemIds.length} Selected',
                            style: TextStyle(color: appBarIconColor),
                          )
                        : AnimatedOpacity(
                            opacity: _isCollapsed ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 200),
                            child: Text(
                              widget.album.name,
                              style: TextStyle(
                                color: titleColor,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                  ),
                  SliverPadding(
                    padding: EdgeInsets.only(
                      left: 12,
                      right: 12,
                      top: 8,
                      bottom: 16 + MediaQuery.of(context).padding.bottom,
                    ),
                    sliver: _items.isEmpty
                        ? SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(
                              child: Text(
                                'No items in this album',
                                style: TextStyle(color: onSurface.withValues(alpha: 0.38)),
                              ),
                            ),
                          )
                        : Builder(
                            builder: (context) {
                              final Map<String, List<VaultItem>> groupedItems = {};
                              for (final item in _items) {
                                final dateLabel = _getDynamicDateLabel(item);
                                groupedItems.putIfAbsent(dateLabel, () => []).add(item);
                              }
                              final sortedDates = groupedItems.keys.toList();

                              return SliverList(
                                delegate: SliverChildBuilderDelegate(
                                  (context, dateIdx) {
                                    final dateStr = sortedDates[dateIdx];
                                    final listForDate = groupedItems[dateStr]!;

                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Container(
                                            margin: const EdgeInsets.symmetric(
                                              vertical: 10,
                                            ),
                                            child: Text(
                                              dateStr,
                                              style: TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.bold,
                                                color: titleColor,
                                                letterSpacing: -0.3,
                                              ),
                                            ),
                                          ),
                                          GridView.builder(
                                            padding: EdgeInsets.zero,
                                            shrinkWrap: true,
                                            physics: const NeverScrollableScrollPhysics(),
                                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                              crossAxisCount: ResponsiveHelper.responsiveGridColumns(
                                                context,
                                                baseColumns: 3,
                                                min: 1,
                                                max: 8,
                                              ),
                                              crossAxisSpacing: 6,
                                              mainAxisSpacing: 6,
                                            ),
                                            itemCount: listForDate.length,
                                            itemBuilder: (context, itemIdx) {
                                              final item = listForDate[itemIdx];
                                              final isSelected = _selectedItemIds.contains(item.id);
                                              final key = _itemKeys.putIfAbsent(item.id, () => GlobalKey());
                                              final globalIndex = _items.indexWhere((x) => x.id == item.id);

                                              return GestureDetector(
                                                key: key,
                                                onLongPressStart: (_) {
                                                  HapticFeedback.mediumImpact();
                                                  _isDragging = true;
                                                  _dragStartId = item.id;
                                                  _dragSelectState = !_selectedItemIds.contains(item.id);
                                                  _toggleSelection(item.id);
                                                },
                                                onLongPressMoveUpdate: (details) {
                                                  if (!_isDragging) return;
                                                  final hit = _hitTestItemAt(details.globalPosition);
                                                  if (hit != null && hit != _dragStartId) {
                                                    final already = _selectedItemIds.contains(hit);
                                                    if (_dragSelectState && !already) {
                                                      HapticFeedback.selectionClick();
                                                      setState(() {
                                                        _selectedItemIds.add(hit);
                                                        _isSelectionMode = true;
                                                      });
                                                    } else if (!_dragSelectState && already) {
                                                      HapticFeedback.selectionClick();
                                                      setState(() {
                                                        _selectedItemIds.remove(hit);
                                                        if (_selectedItemIds.isEmpty) {
                                                          _isSelectionMode = false;
                                                        }
                                                      });
                                                    }
                                                  }
                                                },
                                                onLongPressEnd: (_) => setState(() => _isDragging = false),
                                                onTap: () {
                                                  if (_isSelectionMode) {
                                                    HapticFeedback.lightImpact();
                                                    _toggleSelection(item.id);
                                                  } else {
                                                    _openSecureViewer(globalIndex);
                                                  }
                                                },
                                                child: Stack(
                                                  fit: StackFit.expand,
                                                  children: [
                                                    AnimatedContainer(
                                                      duration: const Duration(milliseconds: 150),
                                                      decoration: BoxDecoration(
                                                        borderRadius: BorderRadius.circular(8),
                                                        border: isSelected
                                                            ? Border.all(
                                                                color: Theme.of(context).colorScheme.primary,
                                                                width: 2.5,
                                                              )
                                                            : null,
                                                      ),
                                                      child: ClipRRect(
                                                        borderRadius: BorderRadius.circular(
                                                          isSelected ? 6 : 8,
                                                        ),
                                                        child: VaultImageWidget(item: item),
                                                      ),
                                                    ),
                                                    if (item.isVideo)
                                                      const Positioned(
                                                        bottom: 6,
                                                        right: 6,
                                                        child: Icon(
                                                          Icons.play_circle_fill,
                                                          color: Colors.white,
                                                          size: 22,
                                                        ),
                                                      ),
                                                    Positioned(
                                                      top: 6,
                                                      left: 6,
                                                      child: AnimatedOpacity(
                                                        opacity: _isSelectionMode ? 1.0 : 0.0,
                                                        duration: const Duration(milliseconds: 200),
                                                        child: AnimatedScale(
                                                          scale: isSelected ? 1.0 : 0.7,
                                                          duration: const Duration(milliseconds: 150),
                                                          child: Container(
                                                            decoration: BoxDecoration(
                                                              shape: BoxShape.circle,
                                                              color: isSelected
                                                                  ? Theme.of(context).colorScheme.primary
                                                                  : Colors.black54,
                                                              border: Border.all(
                                                                color: Colors.white,
                                                                width: 1.5,
                                                              ),
                                                            ),
                                                            padding: const EdgeInsets.all(2),
                                                            child: isSelected
                                                                ? Icon(
                                                                    Icons.check,
                                                                    size: 14,
                                                                    color: Theme.of(context).colorScheme.onPrimary,
                                                                  )
                                                                : const SizedBox(width: 14, height: 14),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              );
                                            },
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                  childCount: sortedDates.length,
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
      bottomNavigationBar: _isSelectionMode
          ? _buildSelectionActionToolbar()
          : null,
      floatingActionButton: _isSelectionMode
          ? null
          : FloatingActionButton(
              backgroundColor: Theme.of(context).colorScheme.primary,
              onPressed: _addMediaToAlbum,
              child: Icon(
                Icons.add,
                color: Theme.of(context).colorScheme.onPrimary,
              ),
            ),
    );
  }
}

// ── Progress Dialog for Vault Operations ─────────────────────────────────────

class _ProgressDialog extends StatelessWidget {
  final String title;
  final ValueNotifier<double> progressNotifier;
  final ValueNotifier<String> statusNotifier;

  const _ProgressDialog({
    required this.title,
    required this.progressNotifier,
    required this.statusNotifier,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? const Color(0xFF0F0F18) : Colors.white;
    final textColor = isDark ? const Color(0xFFCDCDCD) : Colors.black87;

    return PopScope(
      canPop: false, // Prevent dismissing by back button
      child: AlertDialog(
        backgroundColor: cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          title,
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            ValueListenableBuilder<String>(
              valueListenable: statusNotifier,
              builder: (context, status, _) {
                return Text(
                  status,
                  style: TextStyle(color: textColor, fontSize: 14),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                );
              },
            ),
            const SizedBox(height: 16),
            ValueListenableBuilder<double>(
              valueListenable: progressNotifier,
              builder: (context, progress, _) {
                final double? value = progress >= 0 ? progress.clamp(0.0, 1.0) : null;
                return Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: value,
                        backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (progress >= 0)
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          '${(progress * 100).toStringAsFixed(0)}%',
                          style: TextStyle(
                            color: textColor.withValues(alpha: 0.6),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

Future<T?> _runWithProgressDialog<T>({
  required BuildContext context,
  required String title,
  required int totalCount,
  required Future<T> Function(
    ValueNotifier<double> progressNotifier,
    ValueNotifier<String> statusNotifier,
  ) action,
}) async {
  final progressNotifier = ValueNotifier<double>(0.0);
  final statusNotifier = ValueNotifier<String>('Starting...');

  // Show dialog
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _ProgressDialog(
      title: title,
      progressNotifier: progressNotifier,
      statusNotifier: statusNotifier,
    ),
  );

  try {
    final result = await action(progressNotifier, statusNotifier);
    if (Navigator.canPop(context)) {
      Navigator.pop(context); // Close progress dialog
    }
    return result;
  } catch (e) {
    if (Navigator.canPop(context)) {
      Navigator.pop(context); // Close progress dialog on error
    }
    rethrow;
  }
}
