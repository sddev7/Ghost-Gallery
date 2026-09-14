import 'package:flutter/material.dart';
import '../models/gallery_item.dart';
import 'tag_photos_screen.dart';
import './tabs/fast_media_preview.dart';
import '../services/entitlement_service.dart';
import '../services/responsive_helper.dart';

class AllTagsScreen extends StatelessWidget {
  final List<GalleryItem> allItems;
  final List<MapEntry<String, int>> sortedTags;
  final Map<String, String> ocrTexts;
  final Map<String, Set<String>> tags;

  const AllTagsScreen({
    super.key,
    required this.allItems,
    required this.sortedTags,
    required this.ocrTexts,
    required this.tags,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subTextColor = isDark ? Colors.white60 : Colors.black54;
    final isWatch = context.isWatch;
    final columns = ResponsiveHelper.responsiveGridColumns(
      context,
      mobile: 2,
      watch: 1,
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
          "All Categories & Tags",
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: isWatch ? 14 : 20),
        ),
      ),
      body: sortedTags.isEmpty
          ? Center(
              child: Text(
                "No tags generated yet.",
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
                crossAxisCount: columns,
                crossAxisSpacing: isWatch ? 6 : 12,
                mainAxisSpacing: isWatch ? 6 : 12,
                childAspectRatio: columns == 1 ? 1.3 : (columns >= 4 ? 1.0 : 0.9),
              ),
              itemCount: sortedTags.length,
              itemBuilder: (context, index) {
                final entry = sortedTags[index];
                final tagName = entry.key;
                final count = entry.value;

                // Find cover item for this tag
                final lowerTag = tagName.toLowerCase();
                final items = allItems.where((x) {
                  final textMatch = ocrTexts[x.id]?.contains(lowerTag) ?? false;
                  final tagMatch = tags[x.id]?.contains(lowerTag) ?? false;
                  return textMatch || tagMatch;
                }).toList();

                final GalleryItem? firstItem = items.isNotEmpty ? items.first : null;

                return GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => TagPhotosScreen(
                          tagName: tagName,
                          items: items,
                        ),
                      ),
                    );
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white.withValues(alpha: 0.04) : Colors.grey[100],
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
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                            child: firstItem != null
                                ? FastMediaPreview(
                                    item: firstItem,
                                    fit: BoxFit.cover,
                                  )
                                : Container(
                                    color: isDark ? Colors.white10 : Colors.grey[200],
                                    child: Icon(Icons.tag, color: subTextColor, size: 36),
                                  ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  ValueListenableBuilder<EntitlementStatus>(
                                    valueListenable: EntitlementService.instance.statusNotifier,
                                    builder: (context, status, _) {
                                      final isPremium = status == EntitlementStatus.subscribed ||
                                          status == EntitlementStatus.trialRunning;
                                      return Icon(
                                        Icons.workspace_premium_rounded,
                                        size: 16,
                                        color: isPremium ? Colors.grey : Colors.amber,
                                      );
                                    },
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      tagName,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        color: textColor,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                "$count items",
                                style: TextStyle(
                                  fontSize: 11,
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
