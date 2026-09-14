import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:flutter/services.dart';

// Reuse Ghost, Darcula, and Dark colors for theme matching
class ExplorerColors {
  static const bgGhost = Color(0xFF000000);
  static const surfaceGhost = Color(0xFF0A0A0C);
  static const cardGhost = Color(0xFF121214);
  static const borderGhost = Color(0xFF222226);
  static const accentGhost = Color(0xFFEDEAE2);
  static const accentBrightGhost = Color(0xFFF5F3ED);
  static const textPrimGhost = Color(0xFFEDEAE2);
  static const textSecGhost = Color(0xFF9E9C96);

  static const bgDarcula = Color(0xFF000000);
  static const cardDarcula = Color(0xFF0D0D0D);
  static const borderDarcula = Color(0xFF2B2B2B);
  static const accentDarcula = Color(0xFF5C9FD6);
  static const textDarcula = Color(0xFFB0BEC8);
  static const textSecDarcula = Color(0xFF707478);

  static const bgDark = Color(0xFF0E0E0E);
  static const cardDark = Color(0xFF1A1A2A);
  static const borderDark = Color(0xFF262636);
  static const accentDark = Color(0xFF5BB8F5);
  static const textDark = Color(0xFFE4E4EE);
  static const textSecDark = Color(0xFF6A6A80);
}

class ExplorerRoot {
  final String name;
  final Directory directory;
  final bool Function(FileSystemEntity)? filter;

  ExplorerRoot({
    required this.name,
    required this.directory,
    this.filter,
  });
}

class FileItem {
  final FileSystemEntity entity;
  final String name;
  final bool isDirectory;
  final int size; // Byte size for files, item count for directories
  final DateTime lastModified;

  FileItem({
    required this.entity,
    required this.name,
    required this.isDirectory,
    required this.size,
    required this.lastModified,
  });
}

class FileExplorerScreen extends StatefulWidget {
  final String categoryName;
  final String appTheme;

  const FileExplorerScreen({
    super.key,
    required this.categoryName,
    required this.appTheme,
  });

  @override
  State<FileExplorerScreen> createState() => _FileExplorerScreenState();
}

class _FileExplorerScreenState extends State<FileExplorerScreen> {
  // Theme Helper Getters
  bool get _isGhost {
    if (widget.appTheme == 'system') {
      return MediaQuery.of(context).platformBrightness == Brightness.dark;
    }
    return widget.appTheme == 'ghost';
  }

  bool get _isDarcula => widget.appTheme == 'darcula';
  
  Color get _bg => _isGhost
      ? ExplorerColors.bgGhost
      : _isDarcula
          ? ExplorerColors.bgDarcula
          : widget.appTheme == 'dark'
              ? ExplorerColors.bgDark
              : Colors.white;

  Color get _cardBg => _isGhost
      ? ExplorerColors.cardGhost
      : _isDarcula
          ? ExplorerColors.cardDarcula
          : widget.appTheme == 'dark'
              ? ExplorerColors.cardDark
              : const Color(0xFFF5F5F5);

  Color get _divColor => _isGhost
      ? ExplorerColors.borderGhost
      : _isDarcula
          ? ExplorerColors.borderDarcula
          : widget.appTheme == 'dark'
              ? ExplorerColors.borderDark
              : Colors.black12;

  Color get _textPrim => _isGhost
      ? ExplorerColors.textPrimGhost
      : _isDarcula
          ? ExplorerColors.textDarcula
          : widget.appTheme == 'dark'
              ? ExplorerColors.textDark
              : Colors.black87;

  Color get _textSec => _isGhost
      ? ExplorerColors.textSecGhost
      : _isDarcula
          ? ExplorerColors.textSecDarcula
          : widget.appTheme == 'dark'
              ? ExplorerColors.textSecDark
              : Colors.grey.shade600;

  Color get _accent => _isGhost
      ? ExplorerColors.accentGhost
      : _isDarcula
          ? ExplorerColors.accentDarcula
          : widget.appTheme == 'dark'
              ? ExplorerColors.accentDark
              : const Color(0xFF6750A4);

  Color get _accentBright => _isGhost ? ExplorerColors.accentBrightGhost : _accent;

  // File Explorer State variables
  List<ExplorerRoot> _roots = [];
  List<ExplorerRoot> _activeRoots = [];
  bool _loadingRoots = true;
  bool _loadingContents = false;

  // Navigation Stack
  final List<Directory> _navigationStack = [];
  final List<String> _navigationNames = [];

  // Content List
  List<FileItem> _currentItems = [];
  String _searchQuery = '';
  String _sortBy = 'name'; // 'name', 'size', 'date'
  bool _showHiddenFiles = false;

  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initializeRoots();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _initializeRoots() async {
    setState(() => _loadingRoots = true);
    
    try {
      final List<ExplorerRoot> tempRoots = [];

      final tempDir = await getTemporaryDirectory();
      final docsDir = await getApplicationDocumentsDirectory();
      
      Directory? appCacheDir;
      try {
        appCacheDir = await getApplicationCacheDirectory();
      } catch (_) {}

      Directory? supportDir;
      try {
        supportDir = await getApplicationSupportDirectory();
      } catch (_) {}

      String? dbPath;
      try {
        dbPath = await getDatabasesPath();
      } catch (_) {}

      switch (widget.categoryName) {
        case 'SQLite App Database':
          if (dbPath != null) {
            tempRoots.add(ExplorerRoot(
              name: 'Databases Directory',
              directory: Directory(dbPath),
              filter: (entity) => !p.basename(entity.path).contains('.ghost_gallery_vault'),
            ));
          }
          break;

        case 'Vector Database (ObjectBox)':
          tempRoots.add(ExplorerRoot(
            name: 'Documents ObjectBox',
            directory: Directory(p.join(docsDir.path, 'objectbox')),
          ));
          if (supportDir != null) {
            tempRoots.add(ExplorerRoot(
              name: 'Support ObjectBox',
              directory: Directory(p.join(supportDir.path, 'objectbox')),
            ));
          }
          break;

        case 'Secure Vault Storage':
          tempRoots.add(ExplorerRoot(
            name: 'Documents Vault',
            directory: Directory(p.join(docsDir.path, '.ghost_gallery_vault')),
          ));
          if (supportDir != null) {
            tempRoots.add(ExplorerRoot(
              name: 'Support Vault',
              directory: Directory(p.join(supportDir.path, '.ghost_gallery_vault')),
            ));
          }
          if (dbPath != null) {
            tempRoots.add(ExplorerRoot(
              name: 'Database Vault',
              directory: Directory(p.join(dbPath, '.ghost_gallery_vault')),
            ));
          }
          if (Platform.isAndroid) {
            final externalDirs = await getExternalStorageDirectories();
            if (externalDirs != null && externalDirs.isNotEmpty) {
              final extPath = externalDirs[0].path;
              String mediaBase = extPath.replaceAll('/Android/data/', '/Android/media/');
              if (mediaBase.endsWith('/files')) {
                mediaBase = mediaBase.substring(0, mediaBase.length - 6);
              }
              tempRoots.add(ExplorerRoot(
                name: 'External Vault (Android)',
                directory: Directory(p.join(mediaBase, '.ghost_gallery_vault')),
              ));
            }
          }
          break;

        case 'Generated Memories Media':
          tempRoots.add(ExplorerRoot(
            name: 'Documents Memories',
            directory: Directory(p.join(docsDir.path, 'ghost_recommends')),
          ));
          if (supportDir != null) {
            tempRoots.add(ExplorerRoot(
              name: 'Support Memories',
              directory: Directory(p.join(supportDir.path, 'ghost_recommends')),
            ));
          }
          break;

        case 'Cached Face Previews':
          tempRoots.add(ExplorerRoot(
            name: 'Temporary Face Cache',
            directory: Directory(p.join(tempDir.path, 'gh_faces')),
          ));
          if (appCacheDir != null) {
            tempRoots.add(ExplorerRoot(
              name: 'Application Face Cache',
              directory: Directory(p.join(appCacheDir.path, 'gh_faces')),
            ));
          }
          break;

        case 'Image Cache & Temp Files':
          tempRoots.add(ExplorerRoot(
            name: 'Temporary Cache',
            directory: tempDir,
            filter: (entity) => !entity.path.contains('gh_faces'),
          ));
          if (appCacheDir != null) {
            tempRoots.add(ExplorerRoot(
              name: 'Application Cache',
              directory: appCacheDir,
              filter: (entity) => !entity.path.contains('gh_faces'),
            ));
          }
          break;

        case 'Configurations & Settings':
        default:
          tempRoots.add(ExplorerRoot(
            name: 'Documents Preferences',
            directory: docsDir,
            filter: (entity) {
              final name = p.basename(entity.path);
              return name != 'objectbox' &&
                  name != '.ghost_gallery_vault' &&
                  name != 'ghost_recommends';
            },
          ));
          if (supportDir != null) {
            tempRoots.add(ExplorerRoot(
              name: 'Support Preferences',
              directory: supportDir,
              filter: (entity) {
                final name = p.basename(entity.path);
                return name != 'objectbox' &&
                    name != '.ghost_gallery_vault' &&
                    name != 'ghost_recommends';
              },
            ));
          }
          break;
      }

      final List<ExplorerRoot> existingRoots = [];
      for (final root in tempRoots) {
        if (await root.directory.exists()) {
          existingRoots.add(root);
        }
      }

      setState(() {
        _roots = tempRoots;
        _activeRoots = existingRoots;
        _loadingRoots = false;
      });

      // Auto navigate if only one active root exists
      if (_activeRoots.length == 1) {
        _navigateToDir(_activeRoots.first.directory, _activeRoots.first.name);
      }
    } catch (e) {
      debugPrint('Error initializing explorer roots: $e');
      setState(() => _loadingRoots = false);
    }
  }

  Future<void> _navigateToDir(Directory dir, String displayName) async {
    setState(() {
      _navigationStack.add(dir);
      _navigationNames.add(displayName);
      _loadingContents = true;
      _searchQuery = '';
      _searchController.clear();
    });
    await _loadCurrentDirectoryContents();
  }

  void _navigateBack() {
    if (_navigationStack.isNotEmpty) {
      setState(() {
        _navigationStack.removeLast();
        _navigationNames.removeLast();
        _searchQuery = '';
        _searchController.clear();
      });
      if (_navigationStack.isNotEmpty) {
        _loadCurrentDirectoryContents();
      } else {
        setState(() {
          _currentItems = [];
        });
      }
    }
  }

  void _navigateToBreadcrumb(int index) {
    if (index < _navigationStack.length - 1) {
      setState(() {
        final removeCount = _navigationStack.length - 1 - index;
        for (int i = 0; i < removeCount; i++) {
          _navigationStack.removeLast();
          _navigationNames.removeLast();
        }
        _searchQuery = '';
        _searchController.clear();
      });
      _loadCurrentDirectoryContents();
    }
  }

  Future<void> _loadCurrentDirectoryContents() async {
    if (_navigationStack.isEmpty) return;
    setState(() => _loadingContents = true);

    final dir = _navigationStack.last;
    
    // Find active filter if we are in one of the root directories
    bool Function(FileSystemEntity)? currentFilter;
    for (final root in _roots) {
      if (root.directory.path == dir.path) {
        currentFilter = root.filter;
        break;
      }
    }

    final List<FileItem> items = [];
    try {
      if (await dir.exists()) {
        final list = await dir.list(recursive: false).toList();
        for (final entity in list) {
          if (currentFilter != null && !currentFilter(entity)) {
            continue;
          }
          final name = p.basename(entity.path);
          
          // Hide system/hidden files unless enabled
          if (name.startsWith('.') && !_showHiddenFiles) {
            // But show the main category roots even if they start with a dot
            bool isCategoryRoot = false;
            for (final r in _roots) {
              if (r.directory.path == entity.path) {
                isCategoryRoot = true;
                break;
              }
            }
            if (!isCategoryRoot) continue;
          }

          final isDir = entity is Directory;
          int size = 0;
          DateTime lastModified = DateTime.now();

          if (!isDir && entity is File) {
            try {
              size = await entity.length();
              lastModified = await entity.lastModified();
            } catch (_) {}
          } else if (isDir && entity is Directory) {
            try {
              final subList = await entity.list(recursive: false).toList();
              size = subList.length;
            } catch (_) {}
            try {
              final stat = await entity.stat();
              lastModified = stat.modified;
            } catch (_) {}
          }

          items.add(FileItem(
            entity: entity,
            name: name,
            isDirectory: isDir,
            size: size,
            lastModified: lastModified,
          ));
        }
      }
    } catch (e) {
      debugPrint('Error loading files: $e');
    }

    setState(() {
      _currentItems = items;
      _loadingContents = false;
    });
  }

  // Delete a specific file or folder
  Future<void> _deleteItem(FileItem item) async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cardBg,
        title: Text(
          item.isDirectory ? 'Delete Directory' : 'Delete File',
          style: TextStyle(color: _textPrim, fontWeight: FontWeight.bold),
        ),
        content: Text(
          'Are you sure you want to permanently delete "${item.name}"? This action cannot be undone and might affect app behavior.',
          style: TextStyle(color: _textSec, fontSize: 13.5, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: _textSec)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: _accent),
            child: const Text('Delete', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _loadingContents = true);

    try {
      if (item.isDirectory) {
        final dir = Directory(item.entity.path);
        await dir.delete(recursive: true);
      } else {
        final file = File(item.entity.path);
        await file.delete();
      }
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${item.name} deleted successfully.'),
          backgroundColor: _accent.withOpacity(0.8),
        ),
      );
    } catch (e) {
      debugPrint('Error deleting: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to delete item: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }

    await _loadCurrentDirectoryContents();
  }

  // Preview an image fullscreen
  void _previewImage(FileItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            title: Text(item.name, style: const TextStyle(color: Colors.white, fontSize: 14)),
            iconTheme: const IconThemeData(color: Colors.white),
            actions: [
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  Navigator.pop(context);
                  _deleteItem(item);
                },
              ),
            ],
          ),
          body: Center(
            child: InteractiveViewer(
              child: Image.file(
                File(item.entity.path),
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Center(
                  child: Text('Failed to load image', style: TextStyle(color: Colors.redAccent)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Preview a text file in a bottom sheet/dialog
  Future<void> _previewTextFile(FileItem item) async {
    setState(() => _loadingContents = true);
    String fileContents = '';
    try {
      final file = File(item.entity.path);
      // Read first 100KB to avoid memory overflow for large files
      final length = await file.length();
      if (length > 100 * 1024) {
        final stream = file.openRead(0, 100 * 1024);
        final bytes = await stream.reduce((a, b) => [...a, ...b]);
        fileContents = String.fromCharCodes(bytes) + '\n\n... [Truncated. File too large]';
      } else {
        fileContents = await file.readAsString();
      }
    } catch (e) {
      fileContents = 'Error reading file: $e';
    }
    setState(() => _loadingContents = false);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (_, scrollController) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.name,
                              style: TextStyle(
                                color: _textPrim,
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _fmt(item.size),
                              style: TextStyle(color: _textSec, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.copy_rounded, color: _accent, size: 20),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: fileContents));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Content copied to clipboard!'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                      ),
                      IconButton(
                        icon: Icon(Icons.close_rounded, color: _textSec),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
                Divider(color: _divColor, height: 1),
                
                // Code viewer body
                Expanded(
                  child: Container(
                    width: double.infinity,
                    color: _isGhost
                        ? ExplorerColors.bgGhost.withOpacity(0.5)
                        : Colors.black.withOpacity(0.05),
                    child: ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.all(16),
                      children: [
                        SelectableText(
                          fileContents,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: _textPrim,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Show detailed attributes of the file
  void _showFileDetails(FileItem item) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cardBg,
        title: Row(
          children: [
            Icon(
              item.isDirectory ? Icons.folder_rounded : Icons.insert_drive_file_rounded,
              color: _accent,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Properties',
                style: TextStyle(color: _textPrim, fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDetailRow('Name', item.name),
            _buildDetailRow('Path', item.entity.path),
            _buildDetailRow(
              item.isDirectory ? 'Contents' : 'Size',
              item.isDirectory ? '${item.size} items' : _fmt(item.size),
            ),
            _buildDetailRow('Modified', item.lastModified.toLocal().toString().split('.')[0]),
            _buildDetailRow('Type', item.isDirectory ? 'Directory' : 'File (${p.extension(item.entity.path)})'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Close', style: TextStyle(color: _accent)),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(color: _textSec, fontSize: 11, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: TextStyle(color: _textPrim, fontSize: 13, height: 1.3),
          ),
        ],
      ),
    );
  }

  String _fmt(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  // Decide icon based on file type/extension
  Widget _getIconForFile(FileItem item) {
    if (item.isDirectory) {
      return Icon(Icons.folder_rounded, color: _accent, size: 28);
    }

    final ext = p.extension(item.name).toLowerCase();
    
    if (ext == '.db' || ext == '.sqlite' || ext == '.sqlite3') {
      return const Icon(Icons.storage_rounded, color: Colors.blueAccent, size: 28);
    }
    
    if (ext == '.png' || ext == '.jpg' || ext == '.jpeg' || ext == '.webp' || ext == '.gif') {
      // Return a small image thumbnail if it's cached or readable!
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(
          File(item.entity.path),
          width: 28,
          height: 28,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const Icon(Icons.image_rounded, color: Colors.orangeAccent, size: 28),
        ),
      );
    }

    if (ext == '.json' || ext == '.xml' || ext == '.txt' || ext == '.log' || ext == '.properties') {
      return const Icon(Icons.description_rounded, color: Colors.amber, size: 28);
    }

    if (widget.categoryName == 'Secure Vault Storage') {
      return Icon(Icons.lock_rounded, color: _accentBright, size: 28);
    }

    return Icon(Icons.insert_drive_file_outlined, color: _textSec, size: 28);
  }

  // Handle tile click actions
  void _onItemTapped(FileItem item) {
    if (item.isDirectory) {
      _navigateToDir(Directory(item.entity.path), item.name);
    } else {
      final ext = p.extension(item.name).toLowerCase();
      if (ext == '.png' || ext == '.jpg' || ext == '.jpeg' || ext == '.webp' || ext == '.gif') {
        _previewImage(item);
      } else if (ext == '.json' || ext == '.xml' || ext == '.txt' || ext == '.log' || ext == '.properties') {
        _previewTextFile(item);
      } else {
        _showFileDetails(item);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<FileItem> filteredItems = _currentItems.where((item) {
      final nameMatches = item.name.toLowerCase().contains(_searchQuery.toLowerCase());
      return nameMatches;
    }).toList();

    // Apply Sorting
    filteredItems.sort((a, b) {
      // Folders always go first
      if (a.isDirectory && !b.isDirectory) return -1;
      if (!a.isDirectory && b.isDirectory) return 1;

      switch (_sortBy) {
        case 'size':
          return b.size.compareTo(a.size); // larger first
        case 'date':
          return b.lastModified.compareTo(a.lastModified); // newer first
        case 'name':
        default:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
    });

    final bool isRootLevel = _navigationStack.isEmpty;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: _textPrim),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () {
            if (isRootLevel) {
              Navigator.pop(context);
            } else {
              _navigateBack();
            }
          },
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.categoryName,
              style: TextStyle(
                color: _textPrim,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (!isRootLevel)
              Text(
                'Browsing: ${_navigationNames.last}',
                style: TextStyle(color: _textSec, fontSize: 11),
              ),
          ],
        ),
        actions: [
          // Filter out hidden files toggle
          IconButton(
            icon: Icon(
              _showHiddenFiles ? Icons.visibility_rounded : Icons.visibility_off_rounded,
              color: _textSec,
              size: 20,
            ),
            tooltip: _showHiddenFiles ? 'Hide system files' : 'Show system files',
            onPressed: () {
              setState(() {
                _showHiddenFiles = !_showHiddenFiles;
              });
              if (!isRootLevel) {
                _loadCurrentDirectoryContents();
              }
            },
          ),
          // Sorting menu
          if (!isRootLevel)
            PopupMenuButton<String>(
              icon: Icon(Icons.sort_rounded, color: _textSec, size: 20),
              color: _cardBg,
              onSelected: (val) {
                setState(() => _sortBy = val);
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'name',
                  child: Row(
                    children: [
                      Icon(Icons.title_rounded, size: 16, color: _sortBy == 'name' ? _accent : _textSec),
                      const SizedBox(width: 8),
                      Text('Name', style: TextStyle(color: _textPrim, fontSize: 13)),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'size',
                  child: Row(
                    children: [
                      Icon(Icons.sd_storage_rounded, size: 16, color: _sortBy == 'size' ? _accent : _textSec),
                      const SizedBox(width: 8),
                      Text('Size', style: TextStyle(color: _textPrim, fontSize: 13)),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'date',
                  child: Row(
                    children: [
                      Icon(Icons.date_range_rounded, size: 16, color: _sortBy == 'date' ? _accent : _textSec),
                      const SizedBox(width: 8),
                      Text('Date Modified', style: TextStyle(color: _textPrim, fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Breadcrumbs or roots header
            if (!isRootLevel) _buildBreadcrumbsHeader(),

            // Search Bar
            if (!isRootLevel && _currentItems.isNotEmpty) _buildSearchBar(),

            // Main body
            Expanded(
              child: _loadingRoots || _loadingContents
                  ? Center(
                      child: CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(_accent),
                        strokeWidth: 2.5,
                      ),
                    )
                  : isRootLevel
                      ? _buildRootsList()
                      : filteredItems.isEmpty
                          ? _buildEmptyState()
                          : _buildFilesList(filteredItems),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBreadcrumbsHeader() {
    return Container(
      height: 38,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: _cardBg.withOpacity(0.3),
        border: Border(bottom: BorderSide(color: _divColor, width: 0.5)),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _navigationNames.length,
        itemBuilder: (context, idx) {
          final name = _navigationNames[idx];
          final isLast = idx == _navigationNames.length - 1;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () => _navigateToBreadcrumb(idx),
                child: Text(
                  name,
                  style: TextStyle(
                    color: isLast ? _accentBright : _textSec,
                    fontWeight: isLast ? FontWeight.w600 : FontWeight.normal,
                    fontSize: 11.5,
                  ),
                ),
              ),
              if (!isLast)
                Icon(
                  Icons.chevron_right_rounded,
                  color: _textSec.withOpacity(0.5),
                  size: 14,
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Container(
        height: 38,
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _divColor, width: 0.8),
        ),
        child: TextField(
          controller: _searchController,
          style: TextStyle(color: _textPrim, fontSize: 13),
          cursorColor: _accent,
          decoration: InputDecoration(
            hintText: 'Search files...',
            hintStyle: TextStyle(color: _textSec.withOpacity(0.7), fontSize: 13),
            prefixIcon: Icon(Icons.search_rounded, color: _textSec, size: 18),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            suffixIcon: _searchQuery.isNotEmpty
                ? GestureDetector(
                    onTap: () {
                      setState(() {
                        _searchQuery = '';
                        _searchController.clear();
                      });
                    },
                    child: Icon(Icons.clear_rounded, color: _textSec, size: 16),
                  )
                : null,
          ),
          onChanged: (val) {
            setState(() {
              _searchQuery = val;
            });
          },
        ),
      ),
    );
  }

  Widget _buildRootsList() {
    if (_activeRoots.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_off_rounded, color: _textSec, size: 48),
            const SizedBox(height: 14),
            Text(
              'No directories exist yet',
              style: TextStyle(color: _textPrim, fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              'The application hasn\'t generated these files yet.',
              style: TextStyle(color: _textSec, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _activeRoots.length,
      itemBuilder: (context, idx) {
        final root = _activeRoots[idx];
        return Card(
          color: _cardBg,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: _divColor, width: 0.8),
          ),
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _accent.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.folder_copy_rounded, color: _accent, size: 22),
            ),
            title: Text(
              root.name,
              style: TextStyle(color: _textPrim, fontWeight: FontWeight.bold, fontSize: 14),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                root.directory.path,
                style: TextStyle(color: _textSec, fontSize: 10.5),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            trailing: Icon(Icons.arrow_forward_ios_rounded, color: _textSec, size: 14),
            onTap: () => _navigateToDir(root.directory, root.name),
          ),
        );
      },
    );
  }

  Widget _buildFilesList(List<FileItem> items) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      itemCount: items.length,
      separatorBuilder: (_, __) => Divider(color: _divColor, height: 1),
      itemBuilder: (context, idx) {
        final item = items[idx];
        
        final subtitleText = item.isDirectory
            ? '${item.size} items'
            : '${_fmt(item.size)} • ${item.lastModified.toLocal().toString().split(' ')[0]}';

        return Dismissible(
          key: Key(item.entity.path),
          direction: DismissDirection.endToStart,
          background: Container(
            color: Colors.redAccent,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            child: const Icon(Icons.delete_forever_rounded, color: Colors.white),
          ),
          confirmDismiss: (_) async {
            await _deleteItem(item);
            return false; // Let setState update the list after deletion
          },
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            leading: _getIconForFile(item),
            title: Text(
              item.name,
              style: TextStyle(
                color: _textPrim,
                fontSize: 13.5,
                fontWeight: item.isDirectory ? FontWeight.w600 : FontWeight.normal,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              subtitleText,
              style: TextStyle(color: _textSec, fontSize: 11),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(Icons.info_outline_rounded, color: _textSec, size: 18),
                  onPressed: () => _showFileDetails(item),
                ),
                Icon(
                  item.isDirectory ? Icons.arrow_forward_ios_rounded : Icons.chevron_right_rounded,
                  color: _textSec.withOpacity(0.5),
                  size: 14,
                ),
              ],
            ),
            onTap: () => _onItemTapped(item),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off_rounded, color: _textSec, size: 40),
          const SizedBox(height: 12),
          Text(
            _searchQuery.isNotEmpty ? 'No matches found' : 'This folder is empty',
            style: TextStyle(color: _textPrim, fontSize: 14, fontWeight: FontWeight.bold),
          ),
          if (_searchQuery.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Try adjusting your search terms.',
              style: TextStyle(color: _textSec, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}
