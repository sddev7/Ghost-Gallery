import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

class AddToAlbumDialog extends StatefulWidget {
  final List<String> selectedItemIds;
  final VoidCallback? onComplete;

  const AddToAlbumDialog({
    super.key,
    required this.selectedItemIds,
    this.onComplete,
  });

  static Future<void> show(BuildContext context, List<String> selectedItemIds, {VoidCallback? onComplete}) async {
    await showDialog(
      context: context,
      builder: (context) => AddToAlbumDialog(
        selectedItemIds: selectedItemIds,
        onComplete: onComplete,
      ),
    );
  }

  @override
  State<AddToAlbumDialog> createState() => _AddToAlbumDialogState();
}

class _AddToAlbumDialogState extends State<AddToAlbumDialog> {
  Map<String, List<String>> _customAlbums = {};
  List<String> _customAlbumNames = [];
  bool _isLoading = true;
  String? _selectedAlbum;
  bool _isCreatingNew = false;
  final _newAlbumCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadCustomAlbums();
  }

  @override
  void dispose() {
    _newAlbumCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCustomAlbums() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/custom_albums.json');
      if (await file.exists()) {
        final decoded = json.decode(await file.readAsString()) as Map<String, dynamic>;
        _customAlbums = decoded.map((k, v) => MapEntry(k, List<String>.from(v)));
        _customAlbumNames = _customAlbums.keys.toList()..sort();
      }
    } catch (e) {
      debugPrint('Error loading custom albums: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isCreatingNew = _customAlbumNames.isEmpty;
          if (_customAlbumNames.isNotEmpty) {
            _selectedAlbum = _customAlbumNames.first;
          }
        });
      }
    }
  }

  Future<void> _saveToAlbum(String albumName) async {
    _customAlbums.putIfAbsent(albumName, () => []);
    final albumList = _customAlbums[albumName]!;
    for (final id in widget.selectedItemIds) {
      if (!albumList.contains(id)) {
        albumList.add(id);
      }
    }
    _customAlbums[albumName] = albumList;

    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/custom_albums.json');
      await file.writeAsString(json.encode(_customAlbums));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Added successfully to custom album '$albumName'!"),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    } catch (e) {
      debugPrint("Error writing custom albums: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Failed to add to album: $e"),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    }

    widget.onComplete?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDarkTheme = theme.brightness == Brightness.dark;
    
    // Fallbacks matching Ghost horror card color if under Ghost theme
    final cardColor = theme.cardColor;
    final onSurface = theme.colorScheme.onSurface;
    final accent = theme.colorScheme.primary;
    final muted = theme.colorScheme.onSurfaceVariant;
    final border = theme.dividerColor;

    if (_isLoading) {
      return AlertDialog(
        backgroundColor: cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: SizedBox(
          height: 100,
          child: Center(
            child: CircularProgressIndicator(color: accent),
          ),
        ),
      );
    }

    return AlertDialog(
      backgroundColor: cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        'Add to album',
        style: TextStyle(color: onSurface, fontWeight: FontWeight.bold),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!_isCreatingNew && _customAlbumNames.isNotEmpty) ...[
              DropdownButtonFormField<String>(
                value: _selectedAlbum,
                dropdownColor: cardColor,
                style: TextStyle(color: onSurface),
                decoration: InputDecoration(
                  labelText: 'Select Custom Album',
                  labelStyle: TextStyle(color: muted, fontSize: 13),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: border),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: accent),
                  ),
                ),
                items: _customAlbumNames
                    .map((a) => DropdownMenuItem(
                          value: a,
                          child: Text(a, style: TextStyle(color: onSurface)),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _selectedAlbum = v),
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                icon: Icon(Icons.add_circle_outline, color: accent, size: 18),
                label: Text('Create New Custom Album',
                    style: TextStyle(color: accent, fontSize: 13)),
                onPressed: () => setState(() {
                  _isCreatingNew = true;
                  _selectedAlbum = null;
                }),
              ),
            ] else ...[
              if (_customAlbumNames.isNotEmpty)
                TextButton.icon(
                  icon: Icon(Icons.arrow_back, color: muted, size: 18),
                  label: Text('Back to custom albums',
                      style: TextStyle(color: muted, fontSize: 13)),
                  onPressed: () => setState(() {
                    _isCreatingNew = false;
                    _selectedAlbum = _customAlbumNames.first;
                  }),
                ),
              const SizedBox(height: 4),
              TextField(
                controller: _newAlbumCtrl,
                autofocus: true,
                style: TextStyle(color: onSurface),
                decoration: InputDecoration(
                  hintText: 'New album name',
                  hintStyle: TextStyle(color: muted),
                  labelText: 'Album Name',
                  labelStyle: TextStyle(color: muted, fontSize: 13),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: border),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: accent),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel', style: TextStyle(color: muted)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: () async {
            final albumName = _isCreatingNew
                ? _newAlbumCtrl.text.trim()
                : (_selectedAlbum ?? '');
            if (albumName.isEmpty) return;
            Navigator.pop(context);
            await _saveToAlbum(albumName);
          },
          child: const Text(
            'Add',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
