import 'dart:io';
import 'package:flutter/material.dart';
import 'person_photos_screen.dart';
import 'people_management_screen.dart';
import '../services/database_helper.dart';
import '../services/responsive_helper.dart';

class AllPeopleScreen extends StatefulWidget {
  final List<Map<String, dynamic>> peopleList;

  const AllPeopleScreen({
    super.key,
    required this.peopleList,
  });

  @override
  State<AllPeopleScreen> createState() => _AllPeopleScreenState();
}

class _AllPeopleScreenState extends State<AllPeopleScreen> {
  int _columns = 3;
  late List<Map<String, dynamic>> _peopleList;
  bool _changesMade = false;

  @override
  void initState() {
    super.initState();
    _peopleList = List.from(widget.peopleList);
  }

  Future<void> _refresh() async {
    final db = DatabaseHelper.instance;
    final people = await db.getEligiblePeopleForUi();
    if (mounted) {
      setState(() {
        _peopleList = people;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subTextColor = isDark ? Colors.white60 : Colors.black54;
    final isWatch = context.isWatch;
    final effectiveColumns = ResponsiveHelper.responsiveGridColumns(
      context,
      mobile: _columns,
      watch: 2,
      tablet: 4,
      tv: 6,
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.pop(context, _changesMade);
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
          foregroundColor: textColor,
          elevation: 0,
          title: Text(
            "All People",
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: isWatch ? 15 : 20),
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context, _changesMade),
          ),
          actions: isWatch
              ? null
              : [
                  Row(
                    children: [3, 4, 5, 6].map((col) {
                      final isSelected = _columns == col;
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text("$col", style: const TextStyle(fontSize: 11)),
                          selected: isSelected,
                          onSelected: (val) {
                            if (val) {
                              setState(() {
                                _columns = col;
                              });
                            }
                          },
                          visualDensity: VisualDensity.compact,
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(width: 8),
                ],
        ),
        body: _peopleList.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.face_retouching_natural_outlined,
                        size: 64,
                        color: subTextColor.withValues(alpha: 0.5),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        "Once the AI finishes scanning for faces in your library, faces will show here.",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: textColor,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        "The AI will understand your usage behavior and run the whole library scan when you are away from your phone.",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: subTextColor,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : GridView.builder(
                padding: EdgeInsets.only(
                  left: isWatch ? 8 : 16,
                  right: isWatch ? 8 : 16,
                  top: isWatch ? 8 : 16,
                  bottom: (isWatch ? 8 : 16) + MediaQuery.of(context).padding.bottom,
                ),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: effectiveColumns,
                  crossAxisSpacing: isWatch ? 6 : 10,
                  mainAxisSpacing: isWatch ? 6 : 10,
                  childAspectRatio: effectiveColumns >= 6 ? 1.0 : 0.85,
                ),
                itemCount: _peopleList.length,
                itemBuilder: (context, index) {
                  final p = _peopleList[index];
                  final String name = p['name'] as String? ?? "Face Cluster";
                  final String? coverPath = p['cover_image'] as String?;

                  return GestureDetector(
                    onTap: () async {
                      final result = await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => PersonPhotosScreen(
                            person: p,
                          ),
                        ),
                      );
                      if (result == true) {
                        _changesMade = true;
                        await _refresh();
                      }
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white.withValues(alpha: 0.04) : Colors.grey[100],
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isDark ? Colors.white10 : Colors.grey[300]!,
                        ),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isDark ? Colors.white10 : Colors.grey[200],
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: ClipOval(
                                child: coverPath != null && coverPath.isNotEmpty && File(coverPath).existsSync()
                                    ? (p['cover_w'] != null && (p['cover_w'] as int? ?? 0) > 0
                                        ? FacePreview(
                                            imagePath: coverPath,
                                            x: p['cover_x'] as int? ?? 0,
                                            y: p['cover_y'] as int? ?? 0,
                                            w: p['cover_w'] as int? ?? 0,
                                            h: p['cover_h'] as int? ?? 0,
                                          )
                                        : Image.file(
                                            File(coverPath),
                                            fit: BoxFit.cover,
                                          ))
                                    : Center(
                                        child: Text(
                                          name.isNotEmpty ? name[0].toUpperCase() : '👤',
                                          style: TextStyle(fontSize: 20, color: textColor),
                                        ),
                                      ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            name,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: textColor,
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
