import 'package:flutter/material.dart';
import '../models/gallery_item.dart';
import 'tag_photos_screen.dart';
import './tabs/fast_media_preview.dart';
import '../services/responsive_helper.dart';

class AllPlacesScreen extends StatefulWidget {
  final List<MapEntry<String, List<GalleryItem>>> sortedPlaces;

  const AllPlacesScreen({super.key, required this.sortedPlaces});

  @override
  State<AllPlacesScreen> createState() => _AllPlacesScreenState();
}

class _AllPlacesScreenState extends State<AllPlacesScreen> {
  int _columns = 3;

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

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
        foregroundColor: textColor,
        elevation: 0,
        title: Text(
          "All Places",
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: isWatch ? 15 : 20),
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
      body: widget.sortedPlaces.isEmpty
          ? Center(
              child: Text(
                "No places recorded yet.",
                style: TextStyle(color: subTextColor),
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
              itemCount: widget.sortedPlaces.length,
              itemBuilder: (context, index) {
                final entry = widget.sortedPlaces[index];
                final placeName = entry.key;
                final items = entry.value;
                final firstItem = items.isNotEmpty ? items.first : null;

                return GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) =>
                            TagPhotosScreen(tagName: placeName, items: items),
                      ),
                    );
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.04)
                          : Colors.grey[100],
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isDark ? Colors.white10 : Colors.grey[300]!,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(16),
                            ),
                            child: firstItem != null
                                ? FastMediaPreview(
                                    item: firstItem,
                                    fit: BoxFit.cover,
                                  )
                                : Container(
                                    color: isDark
                                        ? Colors.white10
                                        : Colors.grey[200],
                                    child: Icon(
                                      Icons.place_outlined,
                                      color: subTextColor,
                                      size: 28,
                                    ),
                                  ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Text(
                                placeName,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: textColor,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                "${items.length} items",
                                style: TextStyle(
                                  fontSize: 9.5,
                                  color: subTextColor,
                                ),
                              ),
                            ],
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
