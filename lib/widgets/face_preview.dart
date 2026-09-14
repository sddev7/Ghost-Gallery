import 'dart:io';
import 'package:flutter/material.dart';
import '../services/database_helper.dart';
import '../services/face_cache_helper.dart';

class FacePreview extends StatefulWidget {
  final String imagePath;
  final int x;
  final int y;
  final int w;
  final int h;

  const FacePreview({
    super.key,
    required this.imagePath,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  @override
  State<FacePreview> createState() => _FacePreviewState();
}

class _FacePreviewState extends State<FacePreview> {
  File? _cachedFile;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _initFace();
  }

  @override
  void didUpdateWidget(FacePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imagePath != widget.imagePath ||
        oldWidget.x != widget.x ||
        oldWidget.y != widget.y ||
        oldWidget.w != widget.w ||
        oldWidget.h != widget.h) {
      _initFace();
    }
  }

  Future<void> _initFace() async {
    setState(() {
      _isLoading = true;
      _hasError = false;
    });

    try {
      // 1. Try retrieving from cache
      var file = await FaceCacheHelper.getCachedFaceFile(
        widget.imagePath,
        widget.x,
        widget.y,
        widget.w,
        widget.h,
      );

      if (file != null && file.existsSync()) {
        if (mounted) {
          setState(() {
            _cachedFile = file;
            _isLoading = false;
          });
        }
        return;
      }

      // 2. Crop and cache asynchronously
      file = await FaceCacheHelper.cropAndCacheFace(
        widget.imagePath,
        widget.x,
        widget.y,
        widget.w,
        widget.h,
      );

      if (file != null && file.existsSync()) {
        if (mounted) {
          setState(() {
            _cachedFile = file;
            _isLoading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _hasError = true;
          });
        }
      }
    } catch (e) {
      debugPrint("FacePreview init error: $e");
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return Container(
        color: Colors.grey[900],
        child: const Center(
          child: Text("👤", style: TextStyle(fontSize: 24)),
        ),
      );
    }

    if (_isLoading || _cachedFile == null) {
      return Container(
        color: Colors.grey[900],
        child: const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    return Image.file(
      _cachedFile!,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
    );
  }
}

String? getPersonIdFromGroupId(String groupId) {
  if (groupId.startsWith('demo_')) return null;
  String? temp;
  if (groupId.startsWith('birthday_')) {
    temp = groupId.substring('birthday_'.length);
  } else if (groupId.startsWith('highlight_')) {
    temp = groupId.substring('highlight_'.length);
  } else if (groupId.startsWith('person_')) {
    return groupId;
  }
  if (temp != null) {
    // If temp ends with _YYYY (4-digit year suffix), strip it.
    final match = RegExp(r'_(\d{4})$').firstMatch(temp);
    if (match != null) {
      return temp.substring(0, match.start);
    }
    return temp;
  }
  return null;
}

class PersonFaceIcon extends StatefulWidget {
  final String groupId;
  final double size;
  final Widget fallback;

  const PersonFaceIcon({
    super.key,
    required this.groupId,
    this.size = 28,
    required this.fallback,
  });

  @override
  State<PersonFaceIcon> createState() => _PersonFaceIconState();
}

class _PersonFaceIconState extends State<PersonFaceIcon> {
  Map<String, dynamic>? _person;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadPerson();
  }

  @override
  void didUpdateWidget(PersonFaceIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId) {
      _loadPerson();
    }
  }

  Future<void> _loadPerson() async {
    try {
      final personId = getPersonIdFromGroupId(widget.groupId);
      if (personId != null) {
        final person = await DatabaseHelper.instance.getPersonById(personId);
        if (mounted) {
          setState(() {
            _person = person;
            _loaded = true;
          });
        }
        return;
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _person == null) {
      return widget.fallback;
    }

    final coverPath = _person!['cover_image'] as String?;
    final coverW = _person!['cover_w'] as int? ?? 0;
    final coverX = _person!['cover_x'] as int? ?? 0;
    final coverY = _person!['cover_y'] as int? ?? 0;
    final coverH = _person!['cover_h'] as int? ?? 0;

    if (coverPath != null &&
        coverPath.isNotEmpty &&
        File(coverPath).existsSync() &&
        coverW > 0) {
      return Container(
        width: widget.size,
        height: widget.size,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
        ),
        clipBehavior: Clip.antiAlias,
        child: ClipOval(
          child: FacePreview(
            imagePath: coverPath,
            x: coverX,
            y: coverY,
            w: coverW,
            h: coverH,
          ),
        ),
      );
    }

    return widget.fallback;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
/// Robust person avatar that:
///   1. Parses the personId from a groupId like "highlight_<personId>_<year>"
///   2. Tries the person's cover_image (with face crop)
///   3. Falls back to the first face row in the DB for that person
///   4. Renders with ClipOval for a perfect circle
// ─────────────────────────────────────────────────────────────────────────────
class PersonAvatar extends StatefulWidget {
  /// The full group id, e.g. "highlight_abc123_2025"
  final String groupId;
  final double size;
  final Widget fallback;

  const PersonAvatar({
    super.key,
    required this.groupId,
    this.size = 36,
    required this.fallback,
  });

  @override
  State<PersonAvatar> createState() => _PersonAvatarState();
}

class _PersonAvatarState extends State<PersonAvatar> {
  _AvatarData? _data;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PersonAvatar old) {
    super.didUpdateWidget(old);
    if (old.groupId != widget.groupId) _load();
  }

  Future<void> _load() async {
    try {
      final personId = getPersonIdFromGroupId(widget.groupId);
      debugPrint("[PersonAvatar._load] groupId: ${widget.groupId} -> parsed personId: $personId");
      if (personId == null) {
        if (mounted) setState(() => _loaded = true);
        return;
      }

      // 1. Try cover_image from people table
      final person = await DatabaseHelper.instance.getPersonById(personId);
      if (person != null) {
        final path = person['cover_image'] as String?;
        final w = person['cover_w'] as int? ?? 0;
        debugPrint("[PersonAvatar._load] Found person record. path: $path, w: $w");
        if (path != null && path.isNotEmpty && w > 0) {
          final fileExists = File(path).existsSync();
          debugPrint("[PersonAvatar._load] cover_image File exists: $fileExists");
          if (fileExists && mounted) {
            setState(() {
              _data = _AvatarData(
                imagePath: path,
                x: person['cover_x'] as int? ?? 0,
                y: person['cover_y'] as int? ?? 0,
                w: w,
                h: person['cover_h'] as int? ?? 0,
              );
              _loaded = true;
            });
            return;
          }
        }
      } else {
        debugPrint("[PersonAvatar._load] No person record found in DB for personId: $personId");
      }

      // 2. Fall back: first face row for this person
      final allFaces = await DatabaseHelper.instance.getAllFaces();
      final personFaces = allFaces.where((f) => f['person_id'] == personId).toList();
      debugPrint("[PersonAvatar._load] fallback checking faces: found ${personFaces.length} faces for personId: $personId");

      for (final face in personFaces) {
        final bbox = (face['bounding_box'] as String? ?? '').split(',');
        if (bbox.length < 4) continue;
        final bx = int.tryParse(bbox[0]) ?? 0;
        final by = int.tryParse(bbox[1]) ?? 0;
        final bw = int.tryParse(bbox[2]) ?? 0;
        final bh = int.tryParse(bbox[3]) ?? 0;
        if (bw <= 0 || bh <= 0) continue;

        // Need the media path for this face
        final mediaId = face['media_id'] as String?;
        if (mediaId == null) continue;
        final mediaItem = await DatabaseHelper.instance.getMediaItemById(mediaId);
        if (mediaItem == null) continue;

        final imgPath = mediaItem['path'] as String? ?? '';
        final fileExists = imgPath.isNotEmpty && File(imgPath).existsSync();
        debugPrint("[PersonAvatar._load] face media path: $imgPath, exists: $fileExists");
        if (!fileExists) continue;

        if (mounted) {
          setState(() {
            _data = _AvatarData(
              imagePath: imgPath,
              x: bx,
              y: by,
              w: bw,
              h: bh,
            );
            _loaded = true;
          });
        }
        return;
      }

      // Nothing found → show fallback
      debugPrint("[PersonAvatar._load] Nothing found for personId: $personId, showing fallback.");
      if (mounted) setState(() => _loaded = true);
    } catch (e) {
      debugPrint('PersonAvatar._load error: $e');
      if (mounted) setState(() => _loaded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      // While loading show a subtle shimmer placeholder
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: const CircleAvatar(
          backgroundColor: Colors.black26,
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white54),
          ),
        ),
      );
    }

    if (_data == null) return widget.fallback;

    return ClipOval(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: FacePreview(
          imagePath: _data!.imagePath,
          x: _data!.x,
          y: _data!.y,
          w: _data!.w,
          h: _data!.h,
        ),
      ),
    );
  }
}

class _AvatarData {
  final String imagePath;
  final int x, y, w, h;
  const _AvatarData({
    required this.imagePath,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });
}

