import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:ghost_gallery/widgets/face_preview.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/database_helper.dart';
import '../services/optional_features.dart';
import '../services/responsive_helper.dart';
import 'person_photos_screen.dart';
export '../widgets/face_preview.dart';

class PeopleManagementScreen extends StatefulWidget {
  final VoidCallback onDataChanged;
  const PeopleManagementScreen({super.key, required this.onDataChanged});

  @override
  State<PeopleManagementScreen> createState() => _PeopleManagementScreenState();
}

class _PeopleManagementScreenState extends State<PeopleManagementScreen> {
  List<Map<String, dynamic>> _people = [];
  List<Map<String, dynamic>> _faces = [];
  List<Map<String, dynamic>> _mediaItems = [];
  bool _isLoading = true;
  int _faceEligibleThreshold = 10;

  // Selection mode for merging clusters
  bool _isMergeMode = false;
  final List<String> _selectedPersonIds = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final db = DatabaseHelper.instance;
    final people = await db.getAllPeople();
    final faces = await db.getAllFaces();
    final media = await db.getAllMediaItems();
    final prefs = await SharedPreferences.getInstance();
    final threshold = prefs.getInt('face_eligible_threshold') ?? 10;

    setState(() {
      _people = people;
      _faces = faces;
      _mediaItems = media;
      _faceEligibleThreshold = threshold;
      _isLoading = false;
    });
  }

  // Count how many faces exist in a person's cluster
  int _getFacesCount(String personId) {
    return _faces.where((f) => f['person_id'] == personId).length;
  }

  // Find a representative face image path for a person's cluster
  String? _getRepresentativeFacePath(String personId) {
    final personFaces = _faces.where((f) => f['person_id'] == personId);
    if (personFaces.isEmpty) return null;

    final mediaId = personFaces.first['media_id'] as String;
    final mediaMatches = _mediaItems.where((x) => x['id'] == mediaId);
    if (mediaMatches.isEmpty) return null;

    return mediaMatches.first['path'] as String;
  }

  void _toggleMergeSelection(String personId) {
    setState(() {
      if (_selectedPersonIds.contains(personId)) {
        _selectedPersonIds.remove(personId);
      } else {
        _selectedPersonIds.add(personId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isWatch = context.isWatch;
    final columns = ResponsiveHelper.responsiveGridColumns(
      context,
      mobile: 3,
      watch: 2,
      tablet: 5,
      tv: 7,
    );

    // Filter people who have at least the configured number of face images (eligible threshold)
    final filteredPeople = _people.where((p) {
      return _getFacesCount(p['id'] as String) >= _faceEligibleThreshold;
    }).toList();
    // Sort in DESC order of face image counts
    filteredPeople.sort((a, b) {
      final countA = _getFacesCount(a['id'] as String);
      final countB = _getFacesCount(b['id'] as String);
      return countB.compareTo(countA);
    });

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isMergeMode ? "${_selectedPersonIds.length} Selected" : "People",
          style: TextStyle(fontSize: isWatch ? 15 : 20),
        ),
        leading: _isMergeMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    _isMergeMode = false;
                    _selectedPersonIds.clear();
                  });
                },
              )
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.pop(context),
              ),
        actions: [
          if (!_isMergeMode)
            IconButton(
              icon: const Icon(Icons.merge_type_outlined),
              tooltip: "Merge Clusters",
              onPressed: () {
                setState(() {
                  _isMergeMode = true;
                  _selectedPersonIds.clear();
                });
              },
            )
          else ...[
            if (_selectedPersonIds.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: "Delete Selected",
                onPressed: _performBatchDelete,
              ),
            IconButton(
              icon: const Icon(Icons.select_all),
              tooltip: "Select All",
              onPressed: () {
                setState(() {
                  _selectedPersonIds.clear();
                  _selectedPersonIds.addAll(
                    filteredPeople.map((p) => p['id'] as String),
                  );
                });
              },
            ),
          ],
        ],
      ),
      body: filteredPeople.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    "👻",
                    style: TextStyle(
                      fontSize: 48,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text("No face clusters detected yet!"),
                  Text(
                    "Ensure background scanner completes.",
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            )
          : GridView.builder(
              padding: EdgeInsets.only(
                left: isWatch ? 8 : 20,
                right: isWatch ? 8 : 20,
                top: isWatch ? 8 : 20,
                bottom: (isWatch ? 8 : 20) + MediaQuery.of(context).padding.bottom,
              ),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: isWatch ? 10 : 20,
                crossAxisSpacing: isWatch ? 8 : 16,
                childAspectRatio: columns >= 6 ? 0.95 : 0.8,
              ),
              itemCount: filteredPeople.length,
              itemBuilder: (context, index) {
                final person = filteredPeople[index];
                final personId = person['id'] as String;
                final name = person['name'] as String;
                final faceCount = _getFacesCount(personId);
                final facePath = _getRepresentativeFacePath(personId);

                final isSelected = _selectedPersonIds.contains(personId);

                return GestureDetector(
                  onTap: () async {
                    if (_isMergeMode) {
                      _toggleMergeSelection(personId);
                    } else {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => PersonPhotosScreen(person: person),
                        ),
                      );
                      _loadData();
                      widget.onDataChanged();
                    }
                  },
                  onLongPress: () {
                    if (!_isMergeMode) {
                      setState(() {
                        _isMergeMode = true;
                        _selectedPersonIds.add(personId);
                      });
                    }
                  },
                  child: Stack(
                    children: [
                      // Cluster Circle & Info
                      Column(
                        children: [
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: isSelected
                                      ? Colors.blue
                                      : Theme.of(
                                          context,
                                        ).colorScheme.outline.withValues(alpha: 0.2),
                                  width: isSelected ? 3 : 1,
                                ),
                              ),
                              padding: const EdgeInsets.all(3),
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: Container(
                                      decoration: const BoxDecoration(
                                        shape: BoxShape.circle,
                                      ),
                                      clipBehavior: Clip.antiAlias,
                                      child: ClipOval(
                                        child: (person['cover_image'] != null && (person['cover_w'] as int? ?? 0) > 0)
                                            ? FacePreview(
                                                imagePath: person['cover_image'] as String,
                                                x: person['cover_x'] as int? ?? 0,
                                                y: person['cover_y'] as int? ?? 0,
                                                w: person['cover_w'] as int? ?? 0,
                                                h: person['cover_h'] as int? ?? 0,
                                              )
                                            : (facePath == null
                                                ? Container(
                                                    color: Colors.grey[300],
                                                    child: const Center(child: Text("👤")),
                                                  )
                                                : facePath.startsWith('http')
                                                    ? Image.network(
                                                        facePath,
                                                        fit: BoxFit.cover,
                                                        width: double.infinity,
                                                        height: double.infinity,
                                                      )
                                                    : Image.file(
                                                        File(facePath),
                                                        cacheWidth: 150,
                                                        fit: BoxFit.cover,
                                                        width: double.infinity,
                                                        height: double.infinity,
                                                      )),
                                      ),
                                    ),
                                  ),
                                  if (_isMergeMode)
                                    Positioned.fill(
                                      child: AnimatedContainer(
                                        duration: const Duration(milliseconds: 150),
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: isSelected
                                              ? Colors.blue.withValues(alpha: 0.35)
                                              : Colors.transparent,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            name,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                          Text(
                            "$faceCount photos",
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.outline,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),

                      // Selection overlay checkboxes in Merge Mode
                      if (_isMergeMode)
                        Positioned(
                          top: 4,
                          right: 4,
                          child: Icon(
                            isSelected
                                ? Icons.check_circle
                                : Icons.circle_outlined,
                            color: isSelected
                                ? Colors.blue
                                : Colors.white.withValues(alpha: 0.8),
                            size: 22,
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),

      // Floating Merge trigger button in Merge Mode
      floatingActionButton: _isMergeMode && _selectedPersonIds.length >= 2
          ? FloatingActionButton.extended(
              onPressed: _performMerge,
              icon: const Icon(Icons.merge_type),
              label: Text("Merge ${_selectedPersonIds.length} Clusters"),
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
            )
          : null,
    );
  }

  // Executes cluster merging database action
  void _performMerge() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Merge Clusters?"),
        content: Text(
          "Are you sure you want to merge these ${_selectedPersonIds.length} clusters? "
          "The app will consolidate all faces under the first person profile.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              final db = DatabaseHelper.instance;

              // Target is the first selected person ID, sources are the rest
              final target = _selectedPersonIds.first;
              final sources = _selectedPersonIds.sublist(1);

              setState(() {
                _isLoading = true;
              });

              await db.mergePeople(target, sources);
              OptionalFeatures.updateEmbeddingsForPerson?.call(target); // Asynchronous (non-blocking)
              widget.onDataChanged(); // Trigger home update

              setState(() {
                _isMergeMode = false;
                _selectedPersonIds.clear();
              });
              await _loadData();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Clusters successfully merged!')),
              );
            },
            child: const Text("Merge"),
          ),
        ],
      ),
    );
  }

  Future<void> _performBatchDelete() async {
    if (_selectedPersonIds.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Selected Profiles?'),
        content: Text(
          'Are you sure you want to delete ${_selectedPersonIds.length} selected person profile(s)?\n\n'
          'Associated photos will not be deleted, but these face clusters will be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() {
      _isLoading = true;
    });

    final db = DatabaseHelper.instance;
    try {
      for (final personId in _selectedPersonIds) {
        await db.deletePerson(personId);
      }
      widget.onDataChanged(); // Trigger home update
      
      setState(() {
        _isMergeMode = false;
        _selectedPersonIds.clear();
      });
      await _loadData();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Selected profiles successfully deleted.')),
        );
      }
    } catch (e) {
      debugPrint("Error deleting people: $e");
      setState(() {
        _isLoading = false;
      });
    }
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
              Navigator.pop(context); // Close detail sheet
              
              setState(() {
                _isLoading = true;
              });
              
              await DatabaseHelper.instance.deletePerson(personId);
              widget.onDataChanged();
              await _loadData();
              
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("Profile '$name' successfully deleted.")),
                );
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

  // Slide-up sheet showing person details and form parameters
  void _showPersonDetailSheet(Map<String, dynamic> person) {
    final String id = person['id'] as String;
    final nameController = TextEditingController(
      text: person['name'] as String,
    );
    final dobController = TextEditingController(
      text: person['dob'] as String? ?? '',
    );
    final relationController = TextEditingController(
      text: person['relation'] as String? ?? '',
    );

    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Filter media items containing this person's face
    final personFaces = _faces
        .where((f) => f['person_id'] == id)
        .map((f) => f['media_id'])
        .toSet();
    final personMedia = _mediaItems
        .where((x) => personFaces.contains(x['id']))
        .toList();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1C1B1F) : Colors.white,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
              ),
              padding: EdgeInsets.fromLTRB(24, 16, 24, 24 + MediaQuery.of(context).padding.bottom),
              child: SingleChildScrollView(
                controller: scrollController,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 20),
                        decoration: BoxDecoration(
                          color: Colors.grey[400],
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                    Text(
                      "Profile Parameters",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Forms Fields
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: "Full Name",
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.person),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: dobController,
                      decoration: const InputDecoration(
                        labelText: "Date of Birth (DOB)",
                        hintText: "YYYY-MM-DD",
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.cake),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: relationController,
                      decoration: const InputDecoration(
                        labelText: "Relation with Them",
                        hintText: "Family, Friend, Self, Colleague...",
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.people),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Save Button
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () async {
                          Navigator.pop(context);
                          final db = DatabaseHelper.instance;

                          setState(() {
                            _isLoading = true;
                          });

                          await db.updatePerson(
                            id,
                            nameController.text.trim(),
                            dobController.text.trim(),
                            relationController.text.trim(),
                          );
                          OptionalFeatures.updateEmbeddingsForPerson?.call(id); // Asynchronous (non-blocking)
                          widget.onDataChanged(); // Refresh parent

                          await _loadData();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Person details updated!'),
                            ),
                          );
                        },
                        child: const Text("Save Details"),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                          side: const BorderSide(color: Colors.red),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () => _confirmDeletePerson(id, person['name'] as String),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text("Delete Person Profile"),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Media Grid involving this person
                    const Text(
                      "Associated Media Grid",
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    personMedia.isEmpty
                        ? const Text(
                            "No photos linked directly to this person cluster.",
                          )
                        : GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 3,
                                  mainAxisSpacing: 8,
                                  crossAxisSpacing: 8,
                                  childAspectRatio: 1,
                                ),
                            itemCount: personMedia.length,
                            itemBuilder: (context, idx) {
                              final item = personMedia[idx];
                              final path = item['path'] as String;

                              // Find face coordinates for this specific media item
                              final faceMatches = _faces.where((f) => f['media_id'] == item['id'] && f['person_id'] == id);
                              Map<String, dynamic>? faceMatch;
                              if (faceMatches.isNotEmpty) {
                                faceMatch = faceMatches.first;
                              }

                              final String bboxStr = faceMatch?['bounding_box'] as String? ?? '';
                              final parts = bboxStr.split(',');
                              final bx = parts.isNotEmpty ? (int.tryParse(parts[0]) ?? 0) : 0;
                              final by = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
                              final bw = parts.length > 2 ? (int.tryParse(parts[2]) ?? 0) : 0;
                              final bh = parts.length > 3 ? (int.tryParse(parts[3]) ?? 0) : 0;

                              return ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: (bboxStr.isNotEmpty && bw > 0)
                                    ? FacePreview(
                                        imagePath: path,
                                        x: bx,
                                        y: by,
                                        w: bw,
                                        h: bh,
                                      )
                                    : (path.startsWith('http')
                                        ? Image.network(path, fit: BoxFit.cover)
                                        : Image.file(
                                            File(path),
                                            cacheWidth: 200,
                                            fit: BoxFit.cover,
                                          )),
                              );
                            },
                          ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

