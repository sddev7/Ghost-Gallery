import 'package:flutter/material.dart';
import '../models/gallery_item.dart';
import '../services/database_helper.dart';
import '../services/duplicate_detector.dart';
import '../services/media_permission_service.dart';
import '../services/trash_persistence.dart';
import '../widgets/cached_media_thumbnail.dart';
import '../services/responsive_helper.dart';

// ── Scan phase enum ───────────────────────────────────────────────────────────
enum _Phase { idle, scanning, done }

class CleanupSuggestionsScreen extends StatefulWidget {
  final String appTheme;
  const CleanupSuggestionsScreen({super.key, required this.appTheme});
  @override
  State<CleanupSuggestionsScreen> createState() => _State();
}

class _State extends State<CleanupSuggestionsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;

  _Phase _phase = _Phase.idle;
  String _phaseLabel = '';
  double _phaseProgress = 0.0;

  DuplicateScanResult? _result;
  List<GalleryItem> _screenshots = [];
  List<GalleryItem> _largeFiles = [];
  final Set<String> _sel = {};

  // ── lifecycle ───────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  // ── helpers ─────────────────────────────────────────────────────────────────
  double _mb(String s) {
    try {
      final c = s.toUpperCase().replaceAll(',', '').trim();
      final p = c.split(RegExp(r'\s+'));
      final v = double.tryParse(p.first) ?? 0.0;
      if (c.contains('GB')) return v * 1024;
      if (c.contains('KB')) return v / 1024;
      if (c.contains('MB')) return v;
      if (c.contains('B')) return v / (1024 * 1024);
      return v;
    } catch (_) { return 0.0; }
  }

  double _totalSavingsMb() {
    final groups = _result?.groups ?? [];
    final all = [...groups.expand((g) => g.items), ..._largeFiles, ..._screenshots];
    return all.where((i) => _sel.contains(i.id)).toSet()
        .fold(0.0, (s, i) => s + _mb(i.size));
  }

  Color _accent(BuildContext context) => widget.appTheme == 'ghost'
      ? const Color(0xFFFF3333)
      : Theme.of(context).colorScheme.primary;

  // ── data loading ─────────────────────────────────────────────────────────────
  Future<void> _load() async {
    setState(() { _phase = _Phase.scanning; _phaseLabel = 'Loading library…'; _phaseProgress = 0; _sel.clear(); });
    try {
      final raw = await DatabaseHelper.instance.getAllMediaItemsLite();
      final all = raw.map((m) => GalleryItem.fromMap(m)).toList();

      final screenshots = all.where((i) {
        final p = i.imageUrl.toLowerCase();
        return p.contains('screenshot') || i.albumCategory.toLowerCase() == 'screenshots';
      }).toList();

      final large = all.where((i) => _mb(i.size) >= 15).toList()
        ..sort((a, b) => _mb(b.size).compareTo(_mb(a.size)));

      final result = await DuplicateDetector.scan(all, onPhase: (label, prog) {
        if (mounted) setState(() { _phaseLabel = label; _phaseProgress = prog; });
      });

      for (final g in result.groups) {
        for (int i = 1; i < g.items.length; i++) {
          _sel.add(g.items[i].id);
        }
      }
      for (final s in screenshots) {
        _sel.add(s.id);
      }

      setState(() { _result = result; _screenshots = screenshots; _largeFiles = large; _phase = _Phase.done; });
    } catch (e) {
      debugPrint('Cleanup error: $e');
      setState(() => _phase = _Phase.done);
    }
  }

  // ── selection ─────────────────────────────────────────────────────────────────
  void _toggle(String id) => setState(() => _sel.contains(id) ? _sel.remove(id) : _sel.add(id));

  void _selectAllTab(int tab) {
    List<GalleryItem> items = [];
    if (tab == 0) {
      for (final g in (_result?.groups ?? [])) {
        items.addAll(g.items.skip(1));
      }
    } else if (tab == 1) {
      items = _largeFiles;
    } else {
      items = _screenshots;
    }
    final allSel = items.isNotEmpty && items.every((i) => _sel.contains(i.id));
    setState(() {
      if (allSel) {
        for (final i in items) { _sel.remove(i.id); }
      } else {
        for (final i in items) { _sel.add(i.id); }
      }
    });
  }

  // ── delete (permanent — no trash) ────────────────────────────────────────────
  Future<void> _delete() async {
    final groups = _result?.groups ?? [];
    final all = [...groups.expand((g) => g.items), ..._largeFiles, ..._screenshots];
    final toDelete = all.where((i) => _sel.contains(i.id)).toSet().toList();
    if (toDelete.isEmpty) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Permanently?'),
        content: Text(
          'Permanently delete ${toDelete.length} item${toDelete.length == 1 ? '' : 's'}?\n'
          'This cannot be undone. Frees ~${_totalSavingsMb().toStringAsFixed(1)} MB.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red.shade600)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await MediaPermissionService.showBatchProgressDialog<void>(
      context: context,
      title: 'Deleting…',
      totalCount: toDelete.length,
      action: (onProgress) => TrashPersistence.permanentlyDeleteItems(
        toDelete,
        context: context,
        onProgress: onProgress,
      ),
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Deleted ${toDelete.length} item${toDelete.length == 1 ? '' : 's'} permanently.'),
        behavior: SnackBarBehavior.floating,
      ));
      _load();
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = _accent(context);
    final groups = _result?.groups ?? [];

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
        title: const Text('Cleanup', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Re-scan',
            onPressed: _phase == _Phase.scanning ? null : _load,
          ),
        ],
      ),
      body: Column(
        children: [
          // ── scan progress OR savings banner ────────────────────────────────
          if (_phase == _Phase.scanning)
            _ScanCard(label: _phaseLabel, progress: _phaseProgress, accent: accent)
          else
            _buildBanner(theme, accent, groups),

          // ── tab bar ────────────────────────────────────────────────────────
          _buildTabBar(theme, accent, groups),
          const SizedBox(height: 4),

          // ── content ───────────────────────────────────────────────────────
          if (_phase == _Phase.scanning)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  _buildDuplicatesTab(theme, accent, groups),
                  _buildLargeTab(theme, accent),
                  _buildScreenshotsTab(theme, accent),
                ],
              ),
            ),

          // ── sticky bottom bar ──────────────────────────────────────────────
          _buildBottomBar(theme, accent),
        ],
      ),
    );
  }

  // ── savings banner ───────────────────────────────────────────────────────────
  Widget _buildBanner(ThemeData theme, Color accent, List<DuplicateGroup> groups) {
    final isWatch = context.isWatch;
    final mb = _totalSavingsMb();
    final exact = groups.where((g) => g.type == DuplicateType.exact).length;
    final video = groups.where((g) => g.type == DuplicateType.video).length;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Container(
          margin: EdgeInsets.fromLTRB(isWatch ? 8 : 16, isWatch ? 4 : 8, isWatch ? 8 : 16, isWatch ? 4 : 8),
          padding: EdgeInsets.symmetric(horizontal: isWatch ? 10 : 20, vertical: isWatch ? 10 : 16),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: accent.withValues(alpha: 0.18)),
          ),
          child: Row(
            children: [
              Container(
                padding: EdgeInsets.all(isWatch ? 6 : 10),
                decoration: BoxDecoration(color: accent.withValues(alpha: 0.15), shape: BoxShape.circle),
                child: Icon(Icons.auto_delete_outlined, color: accent, size: isWatch ? 18 : 26),
              ),
              SizedBox(width: isWatch ? 10 : 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Potential Savings', style: TextStyle(fontSize: isWatch ? 9 : 11, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
                    Text('${mb.toStringAsFixed(1)} MB', style: TextStyle(fontSize: isWatch ? 18 : 28, fontWeight: FontWeight.w800, color: theme.colorScheme.onSurface, letterSpacing: -0.5)),
                    Text('$exact exact · $video video · ${_screenshots.length} screenshots', style: TextStyle(fontSize: isWatch ? 9 : 11, color: theme.colorScheme.onSurface.withValues(alpha: 0.5))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── tab bar ──────────────────────────────────────────────────────────────────
  Widget _buildTabBar(ThemeData theme, Color accent, List<DuplicateGroup> groups) {
    final isWatch = context.isWatch;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Container(
          margin: EdgeInsets.symmetric(horizontal: isWatch ? 8 : 16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: TabBar(
            controller: _tabs,
            isScrollable: isWatch,
            dividerColor: Colors.transparent,
            indicator: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(10)),
            indicatorSize: TabBarIndicatorSize.tab,
            labelColor: Colors.white,
            unselectedLabelColor: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            labelStyle: TextStyle(fontSize: isWatch ? 10 : 11, fontWeight: FontWeight.w700),
            unselectedLabelStyle: TextStyle(fontSize: isWatch ? 10 : 11, fontWeight: FontWeight.w500),
            tabs: [
              Tab(text: isWatch ? 'Dup (${groups.length})' : 'Duplicate (${groups.length})'),
              Tab(text: isWatch ? 'Large (${_largeFiles.length})' : 'Large (${_largeFiles.length})'),
              Tab(text: isWatch ? 'Shots (${_screenshots.length})' : 'Screenshots (${_screenshots.length})'),
            ],
          ),
        ),
      ),
    );
  }

  // ── bottom bar ───────────────────────────────────────────────────────────────
  Widget _buildBottomBar(ThemeData theme, Color accent) {
    final isWatch = context.isWatch;
    final count = _sel.length;
    final mb = _totalSavingsMb();
    return Container(
      padding: EdgeInsets.fromLTRB(isWatch ? 8 : 16, 8, isWatch ? 8 : 16, (isWatch ? 8 : 10) + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
        color: theme.cardColor,
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4))),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ElevatedButton(
            onPressed: count == 0 ? null : _delete,
            style: ElevatedButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.white,
              disabledBackgroundColor: theme.colorScheme.outlineVariant.withValues(alpha: 0.25),
              elevation: 0,
              minimumSize: Size(double.infinity, isWatch ? 38 : 50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: Text(
              count == 0 ? 'Select items to clean' : 'Clean $count items · ${mb.toStringAsFixed(1)} MB',
              style: TextStyle(fontSize: isWatch ? 12 : 14, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ),
    );
  }

  // ── select-all header ────────────────────────────────────────────────────────
  Widget _buildSelectHeader(int tab, List<GalleryItem> items, Color accent) {
    final allSel = items.isNotEmpty && items.every((i) => _sel.contains(i.id));
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 12, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('${items.length} items', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5))),
          TextButton.icon(
            onPressed: () => _selectAllTab(tab),
            icon: Icon(allSel ? Icons.deselect : Icons.select_all, size: 16),
            label: Text(allSel ? 'Deselect All' : 'Select All', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ── empty state ───────────────────────────────────────────────────────────────
  Widget _empty(ThemeData theme, String msg) => Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.check_circle_outline_rounded, size: 56, color: theme.colorScheme.onSurface.withValues(alpha: 0.2)),
      const SizedBox(height: 12),
      Text(msg, style: TextStyle(fontSize: 14, color: theme.colorScheme.onSurface.withValues(alpha: 0.4))),
    ]),
  );

  // ═══════════════════════════════════════════════════════════════════════════
  // TAB CONTENT — stubs replaced in next chunks
  // ═══════════════════════════════════════════════════════════════════════════
  Widget _buildDuplicatesTab(ThemeData theme, Color accent, List<DuplicateGroup> groups) {
    if (groups.isEmpty) return _empty(theme, 'No duplicates found  🎉');

    // Group by date label so we can render sticky section headers
    final Map<String, List<DuplicateGroup>> byDate = {};
    for (final g in groups) {
      byDate.putIfAbsent(g.dateLabel, () => []).add(g);
    }
    final dates = byDate.keys.toList();

    // Flatten into a mixed list of [String (date header) | DuplicateGroup]
    final List<dynamic> rows = [];
    for (final date in dates) {
      rows.add(date);
      rows.addAll(byDate[date]!);
    }

    // Collect duplicates-only items for Select All header
    final allDupItems = <GalleryItem>[];
    for (final g in groups) {
      allDupItems.addAll(g.items.skip(1));
    }

    return Column(
      children: [
        _buildSelectHeader(0, allDupItems, accent),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            itemCount: rows.length,
            itemBuilder: (ctx, i) {
              final row = rows[i];
              // ── Date section header ────────────────────────────────────────
              if (row is String) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                  child: Row(children: [
                    Icon(Icons.calendar_today_outlined, size: 13, color: theme.colorScheme.onSurface.withValues(alpha: 0.45)),
                    const SizedBox(width: 6),
                    Text(row, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: theme.colorScheme.onSurface.withValues(alpha: 0.55))),
                  ]),
                );
              }
              // ── Duplicate group card ───────────────────────────────────────
              final g = row as DuplicateGroup;
              final badge = g.type == DuplicateType.exact ? 'EXACT' : 'VIDEO';
              final badgeColor = g.type == DuplicateType.exact ? Colors.deepOrange : Colors.indigo;
              return Card(
                color: theme.cardColor,
                elevation: 0,
                margin: const EdgeInsets.only(bottom: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // header row
                      Row(children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(color: badgeColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
                          child: Text(badge, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: badgeColor, letterSpacing: 0.8)),
                        ),
                        const SizedBox(width: 8),
                        Text('${g.items.length} copies', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface)),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(color: accent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
                          child: Text('Saves ${g.wastedMb.toStringAsFixed(1)} MB', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: accent)),
                        ),
                      ]),
                      const SizedBox(height: 4),
                      Text(g.reason, style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withValues(alpha: 0.5))),
                      const SizedBox(height: 10),
                      // thumbnail row
                      SizedBox(
                        height: 90,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: g.items.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 6),
                          itemBuilder: (ctx2, idx) {
                            final item = g.items[idx];
                            final isKeep = idx == 0;
                            final isSel = _sel.contains(item.id);
                            return GestureDetector(
                              onTap: isKeep ? null : () => _toggle(item.id),
                              child: Stack(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: CachedMediaThumbnail(
                                      assetId: item.id,
                                      filePath: item.imageUrl,
                                      isVideo: item.mediaType == 'video',
                                      width: 80,
                                      height: 90,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                  if (isSel && !isKeep)
                                    Positioned.fill(child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Container(color: Colors.black38),
                                    )),
                                  // KEEP / checked badge
                                  Positioned(top: 4, right: 4,
                                    child: Container(
                                      width: 20, height: 20,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: isKeep ? Colors.green.shade600 : (isSel ? accent : Colors.black45),
                                        border: Border.all(color: Colors.white, width: 1.5),
                                      ),
                                      child: Icon(isKeep ? Icons.check : (isSel ? Icons.close : null), size: 12, color: Colors.white),
                                    ),
                                  ),
                                  // size label
                                  Positioned(bottom: 4, left: 4,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                                      child: Text(item.size, style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
  // ── Large Files tab (crash fixed: uses CachedMediaThumbnail) ────────────────
  Widget _buildLargeTab(ThemeData theme, Color accent) {
    if (_largeFiles.isEmpty) return _empty(theme, 'No large files found');
    return Column(
      children: [
        _buildSelectHeader(1, _largeFiles, accent),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            itemCount: _largeFiles.length,
            itemBuilder: (ctx, i) {
              final item = _largeFiles[i];
              final isSel = _sel.contains(item.id);
              return Card(
                color: theme.cardColor,
                elevation: 0,
                margin: const EdgeInsets.only(bottom: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: isSel ? accent : theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                    width: isSel ? 1.5 : 1,
                  ),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _toggle(item.id),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      children: [
                        // Safe thumbnail — never decodes full resolution
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: CachedMediaThumbnail(
                            assetId: item.id,
                            filePath: item.imageUrl,
                            isVideo: item.mediaType == 'video',
                            width: 56,
                            height: 56,
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.imageUrl.split('/').last,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${item.mediaType.toUpperCase()} · ${item.resolution}',
                                style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(color: accent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
                              child: Text(item.size, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: accent)),
                            ),
                            const SizedBox(height: 4),
                            Icon(
                              isSel ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                              size: 22,
                              color: isSel ? accent : theme.colorScheme.outlineVariant,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ── Screenshots tab ──────────────────────────────────────────────────────────
  Widget _buildScreenshotsTab(ThemeData theme, Color accent) {
    if (_screenshots.isEmpty) return _empty(theme, 'No screenshots found');
    return Column(
      children: [
        _buildSelectHeader(2, _screenshots, accent),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3, crossAxisSpacing: 8, mainAxisSpacing: 8, childAspectRatio: 0.78,
            ),
            itemCount: _screenshots.length,
            itemBuilder: (ctx, i) {
              final item = _screenshots[i];
              final isSel = _sel.contains(item.id);
              return GestureDetector(
                onTap: () => _toggle(item.id),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CachedMediaThumbnail(
                        assetId: item.id,
                        filePath: item.imageUrl,
                        isVideo: false,
                        fit: BoxFit.cover,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      if (isSel) Container(color: Colors.black38),
                      Positioned(top: 6, right: 6,
                        child: Container(
                          width: 20, height: 20,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isSel ? accent : Colors.black45,
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                          child: isSel ? const Icon(Icons.check, size: 12, color: Colors.white) : const SizedBox.shrink(),
                        ),
                      ),
                      Positioned(bottom: 0, left: 0, right: 0,
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black54]),
                          ),
                          child: Text(item.size, style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Scan progress card widget
// ═══════════════════════════════════════════════════════════════════════════
class _ScanCard extends StatelessWidget {
  final String label;
  final double progress;
  final Color accent;
  const _ScanCard({required this.label, required this.progress, required this.accent});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: accent)),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
            Text('${(progress * 100).toInt()}%', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: accent)),
          ]),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
              valueColor: AlwaysStoppedAnimation<Color>(accent),
            ),
          ),
        ],
      ),
    );
  }
}

