import 'package:flutter/material.dart';
import 'package:ghost_gallery/models/gallery_item.dart';
import 'package:ghost_gallery/screens/album_detail_screen.dart';
import 'package:ghost_gallery/screens/tabs/fast_media_preview.dart';
import 'package:ghost_gallery/services/collection_source.dart';
import 'package:ghost_gallery/services/responsive_helper.dart';

class CalendarScreen extends StatefulWidget {
  final List<GalleryItem> allItems;
  final Function(GalleryItem, [List<GalleryItem>?]) onItemTapped;

  const CalendarScreen({
    super.key,
    required this.allItems,
    required this.onItemTapped,
  });

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  late List<GalleryItem> _localItems;
  late Map<String, List<GalleryItem>> _itemsByDate;
  late PageController _pageController;
  late int _currentPageIndex;
  late DateTime _currentMonth;

  // Base date for page indexing: Jan 2000
  static const int _startYear = 2000;

  @override
  void initState() {
    super.initState();
    _localItems = List.from(widget.allItems);
    _groupItemsByDate();
    
    // Set initial page to the current month/year
    final now = DateTime.now();
    _currentPageIndex = (now.year - _startYear) * 12 + (now.month - 1);
    _currentMonth = DateTime(now.year, now.month);
    _pageController = PageController(initialPage: _currentPageIndex);
  }

  @override
  void didUpdateWidget(covariant CalendarScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.allItems != oldWidget.allItems) {
      setState(() {
        _localItems = List.from(widget.allItems);
        _groupItemsByDate();
      });
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _groupItemsByDate() {
    final Map<String, List<GalleryItem>> grouped = {};
    for (final item in _localItems) {
      final dt = _getItemDateTime(item);
      final key = "${dt.year}-${dt.month}-${dt.day}";
      grouped.putIfAbsent(key, () => []).add(item);
    }
    // Sort items within each day (latest first)
    for (final key in grouped.keys) {
      grouped[key]!.sort((a, b) {
        final tsA = a.modifiedTimestamp ?? a.dateTimestamp;
        final tsB = b.modifiedTimestamp ?? b.dateTimestamp;
        return tsB.compareTo(tsA);
      });
    }
    _itemsByDate = grouped;
  }

  DateTime _getItemDateTime(GalleryItem item) {
    final ts = item.modifiedTimestamp ?? item.dateTimestamp;
    if (ts > 0) {
      return DateTime.fromMillisecondsSinceEpoch(ts);
    }
    try {
      return DateTime.parse(item.date);
    } catch (_) {
      return DateTime.now();
    }
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentPageIndex = index;
      final year = _startYear + (index ~/ 12);
      final month = (index % 12) + 1;
      _currentMonth = DateTime(year, month);
    });
  }

  void _goToPreviousMonth() {
    _pageController.previousPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _goToNextMonth() {
    _pageController.nextPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  String _formatDateTitle(DateTime date) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return "${months[date.month - 1]} ${date.day}, ${date.year}";
  }

  List<DateTime> _generateCalendarDays(DateTime month) {
    final firstDay = DateTime(month.year, month.month, 1);
    
    // weekday is 1 (Monday) to 7 (Sunday)
    // Align Sunday as start index (0)
    final int prefixDays = firstDay.weekday % 7;
    
    final List<DateTime> days = [];
    
    // Previous month padding
    final prevMonthLastDay = DateTime(month.year, month.month, 0);
    for (int i = prefixDays - 1; i >= 0; i--) {
      days.add(DateTime(month.year, month.month - 1, prevMonthLastDay.day - i));
    }
    
    // Current month days
    final lastDay = DateTime(month.year, month.month + 1, 0).day;
    for (int i = 1; i <= lastDay; i++) {
      days.add(DateTime(month.year, month.month, i));
    }
    
    // Next month padding (up to 42 items for grid consistency)
    final remaining = 42 - days.length;
    for (int i = 1; i <= remaining; i++) {
      days.add(DateTime(month.year, month.month + 1, i));
    }
    
    return days;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subTextColor = isDark ? Colors.white60 : Colors.black54;
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final isWatch = context.isWatch;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
        foregroundColor: textColor,
        elevation: 0,
        title: Text(
          "Memory Calendar",
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: isWatch ? 15 : 20),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),
            // Month Selector Row with Dropdown selectors
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: isWatch ? 8.0 : 16.0),
                  child: Container(
                    padding: EdgeInsets.symmetric(vertical: isWatch ? 2 : 4, horizontal: isWatch ? 4 : 8),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.04)
                          : Colors.black.withValues(alpha: 0.02),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : Colors.black.withValues(alpha: 0.05),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          icon: Icon(Icons.chevron_left_rounded, color: textColor, size: isWatch ? 18 : 24),
                          onPressed: _goToPreviousMonth,
                          padding: EdgeInsets.zero,
                          visualDensity: isWatch ? VisualDensity.compact : VisualDensity.standard,
                          tooltip: "Previous Month",
                        ),
                        
                        // Month & Year Selector Dropdowns
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            DropdownButtonHideUnderline(
                              child: DropdownButton<int>(
                                value: _currentMonth.month,
                                dropdownColor: Theme.of(context).cardColor,
                                icon: Icon(Icons.arrow_drop_down_rounded, size: isWatch ? 16 : 20, color: textColor),
                                style: TextStyle(
                                  fontSize: isWatch ? 12 : 16,
                                  fontWeight: FontWeight.bold,
                                  color: textColor,
                                ),
                                items: List.generate(12, (index) {
                                  const fullMonths = [
                                    'January', 'February', 'March', 'April', 'May', 'June',
                                    'July', 'August', 'September', 'October', 'November', 'December'
                                  ];
                                  const shortMonths = [
                                    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
                                  ];
                                  return DropdownMenuItem<int>(
                                    value: index + 1,
                                    child: Text(isWatch ? shortMonths[index] : fullMonths[index]),
                                  );
                                }),
                                onChanged: (val) {
                                  if (val != null) {
                                    final newIndex = (_currentMonth.year - _startYear) * 12 + (val - 1);
                                    _pageController.jumpToPage(newIndex);
                                  }
                                },
                              ),
                            ),
                            SizedBox(width: isWatch ? 2 : 4),
                            DropdownButtonHideUnderline(
                              child: DropdownButton<int>(
                                value: _currentMonth.year,
                                dropdownColor: Theme.of(context).cardColor,
                                icon: Icon(Icons.arrow_drop_down_rounded, size: isWatch ? 16 : 20, color: textColor),
                                style: TextStyle(
                                  fontSize: isWatch ? 12 : 16,
                                  fontWeight: FontWeight.bold,
                                  color: textColor,
                                ),
                                items: List.generate(50, (index) {
                                  final year = _startYear + index;
                                  return DropdownMenuItem<int>(
                                    value: year,
                                    child: Text("$year"),
                                  );
                                }),
                                onChanged: (val) {
                                  if (val != null) {
                                    final newIndex = (val - _startYear) * 12 + (_currentMonth.month - 1);
                                    _pageController.jumpToPage(newIndex);
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                        
                        IconButton(
                          icon: Icon(Icons.chevron_right_rounded, color: textColor, size: isWatch ? 18 : 24),
                          onPressed: _goToNextMonth,
                          padding: EdgeInsets.zero,
                          visualDensity: isWatch ? VisualDensity.compact : VisualDensity.standard,
                          tooltip: "Next Month",
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(height: isWatch ? 8 : 16),
            // Weekday Headers
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: isWatch ? 6.0 : 12.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: ['S', 'M', 'T', 'W', 'T', 'F', 'S'].map((day) {
                      final isWeekend = day == 'S';
                      return Expanded(
                        child: Center(
                          child: Text(
                            day,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: isWatch ? 10 : 13,
                              color: isWeekend
                                  ? Colors.redAccent.withValues(alpha: 0.8)
                                  : subTextColor,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ),
            SizedBox(height: isWatch ? 6 : 10),
            // Calendar Grid inside PageView
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: PageView.builder(
                    controller: _pageController,
                    onPageChanged: _onPageChanged,
                    itemBuilder: (context, pageIndex) {
                      final year = _startYear + (pageIndex ~/ 12);
                      final month = (pageIndex % 12) + 1;
                      final targetMonth = DateTime(year, month);
                      final calendarDays = _generateCalendarDays(targetMonth);

                      return Padding(
                        padding: EdgeInsets.symmetric(horizontal: isWatch ? 4.0 : 10.0),
                        child: GridView.builder(
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 7,
                        crossAxisSpacing: 6,
                        mainAxisSpacing: 10,
                        childAspectRatio: 1.0, // Square aspect ratio for centered circles
                      ),
                      itemCount: calendarDays.length,
                      itemBuilder: (context, dayIndex) {
                        final day = calendarDays[dayIndex];
                        final isCurrentMonth = day.month == targetMonth.month;
                        final isToday = day.year == DateTime.now().year &&
                            day.month == DateTime.now().month &&
                            day.day == DateTime.now().day;
                        
                        final dayKey = "${day.year}-${day.month}-${day.day}";
                        final itemsForDay = _itemsByDate[dayKey] ?? [];
                        final hasMedia = itemsForDay.isNotEmpty;
                        final latestItem = hasMedia ? itemsForDay.first : null;

                        return GestureDetector(
                          onTap: () async {
                            if (hasMedia) {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => AlbumDetailScreen(
                                    albumName: _formatDateTitle(day),
                                    items: itemsForDay,
                                    onItemTapped: widget.onItemTapped,
                                    isLocationAlbum: true, // DB update query fallback
                                  ),
                                ),
                              );
                              // Refresh from CollectionSource and local state
                              await CollectionSource.instance.refresh();
                              if (mounted) {
                                setState(() {
                                  _localItems = List.from(CollectionSource.instance.items);
                                  _groupItemsByDate();
                                });
                              }
                            }
                          },
                          child: Opacity(
                            opacity: isCurrentMonth ? 1.0 : 0.35,
                            child: Center(
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  // Circle Bubble base (Image or Placeholder)
                                  Container(
                                    width: 50,
                                    height: 50,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: isToday
                                            ? Theme.of(context).colorScheme.primary
                                            : (isDark
                                                ? Colors.white.withValues(alpha: 0.15)
                                                : Colors.black.withValues(alpha: 0.1)),
                                        width: isToday ? 2.0 : 1.0,
                                      ),
                                      boxShadow: hasMedia
                                          ? [
                                              BoxShadow(
                                                color: Colors.black.withValues(alpha: 0.15),
                                                blurRadius: 4,
                                                offset: const Offset(0, 2),
                                              ),
                                            ]
                                          : [],
                                    ),
                                    child: ClipOval(
                                      child: hasMedia && latestItem != null
                                          ? FastMediaPreview(
                                              item: latestItem,
                                              fit: BoxFit.cover,
                                              showBadges: false, // Removes HDR/Burst overlays
                                            )
                                          : Container(
                                              color: isDark
                                                  ? Colors.white.withValues(alpha: 0.05)
                                                  : Colors.black.withValues(alpha: 0.03),
                                            ),
                                    ),
                                  ),
                                  
                                  // Dark Overlay on top of image for maximum date readability
                                  if (hasMedia)
                                    IgnorePointer(
                                      child: Container(
                                        width: 50,
                                        height: 50,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: Colors.black.withValues(alpha: 0.35),
                                        ),
                                      ),
                                    ),
                                  
                                  // Date text overlaid in the center of the bubble
                                  IgnorePointer(
                                    child: Text(
                                      "${day.day}",
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: isToday ? FontWeight.bold : FontWeight.w600,
                                        color: hasMedia
                                            ? Colors.white
                                            : (isToday
                                                ? Theme.of(context).colorScheme.primary
                                                : textColor),
                                        shadows: hasMedia
                                            ? const [
                                                Shadow(
                                                  blurRadius: 3.0,
                                                  color: Colors.black54,
                                                  offset: Offset(0, 1),
                                                ),
                                              ]
                                            : [],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    ),
  ),
);
  }
}
