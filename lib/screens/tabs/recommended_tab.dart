import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../widgets/premium_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/gallery_item.dart';
import '../../models/recommend_models.dart';
import '../../services/database_helper.dart';
import '../../services/recommends_persistence.dart';
import '../../services/recommends_algorithm.dart';
import '../../services/ml_processing_service.dart';
import '../../services/device_media_scanner.dart';
import '../recommends_viewer_screen.dart';
import '../../widgets/ken_burns_wrapper.dart';
import '../../widgets/face_preview.dart';
import '../../services/responsive_helper.dart';

class RecommendedTab extends StatefulWidget {
  final List<GalleryItem> allItems;
  final Function(GalleryItem, [List<GalleryItem>?]) onItemTapped;

  const RecommendedTab({
    super.key,
    required this.allItems,
    required this.onItemTapped,
  });

  @override
  State<RecommendedTab> createState() => _RecommendedTabState();
}

class _RecommendedTabState extends State<RecommendedTab>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  List<RecommendGroup> _groups = [];
  bool _isLoading = true;
  bool _isGenerating = false;
  bool _completedToday = false;
  bool _isEnabled = true;

  Timer? _statusTimer;
  double _generationProgress = 0.0;
  String _generationMessage = '';

  late final AnimationController _listAnimController;

  @override
  void initState() {
    super.initState();
    _listAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _loadMemories();
    _startPollingStatus();
    _checkIfCompletedToday();

    DeviceMediaScanner.instance.addListener(_onScannerChanged);
    MLProcessingService.instance.isProcessingNotifier.addListener(
      _onProcessingChanged,
    );
    MLProcessingService.instance.isFacesProcessingNotifier.addListener(
      _onProcessingChanged,
    );
    MLProcessingService.instance.isSyncingNotifier.addListener(
      _onProcessingChanged,
    );
    MLProcessingService.instance.progressNotifier.addListener(
      _onProcessingChanged,
    );
    MLProcessingService.instance.logNotifier.addListener(
      _onProcessingChanged,
    );
  }

  @override
  void didUpdateWidget(covariant RecommendedTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadMemories();
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _listAnimController.dispose();
    DeviceMediaScanner.instance.removeListener(_onScannerChanged);
    MLProcessingService.instance.isProcessingNotifier.removeListener(
      _onProcessingChanged,
    );
    MLProcessingService.instance.isFacesProcessingNotifier.removeListener(
      _onProcessingChanged,
    );
    MLProcessingService.instance.isSyncingNotifier.removeListener(
      _onProcessingChanged,
    );
    MLProcessingService.instance.progressNotifier.removeListener(
      _onProcessingChanged,
    );
    MLProcessingService.instance.logNotifier.removeListener(
      _onProcessingChanged,
    );
    super.dispose();
  }

  void _onScannerChanged() {
    if (mounted) setState(() {});
  }

  void _onProcessingChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _checkIfCompletedToday() async {
    final prefs = await SharedPreferences.getInstance();
    final lastRunMs = prefs.getInt('last_recommends_daily_run') ?? 0;
    if (lastRunMs == 0) {
      if (mounted) setState(() => _completedToday = false);
      return;
    }
    final lastRun = DateTime.fromMillisecondsSinceEpoch(lastRunMs);
    final now = DateTime.now();
    final isSameDay =
        lastRun.year == now.year &&
        lastRun.month == now.month &&
        lastRun.day == now.day;
    if (mounted) {
      setState(() {
        _completedToday = isSameDay;
      });
    }
  }

  void _startPollingStatus() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(milliseconds: 500), (
      timer,
    ) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final db = DatabaseHelper.instance;
      final job = await db.getGenerationStatus();
      if (job == null) {
        if (_isGenerating) {
          setState(() {
            _isGenerating = false;
            _generationProgress = 0.0;
            _generationMessage = '';
          });
          _loadMemories();
        }
        timer.cancel();
        return;
      }

      final status = job['status'] as String;
      final progress = (job['progress'] as num).toDouble();
      final message = job['message'] as String? ?? '';

      if (status == 'generating') {
        setState(() {
          _isGenerating = true;
          _generationProgress = progress;
          _generationMessage = message;
        });
      } else if (status == 'completed') {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(
          'last_recommends_daily_run',
          DateTime.now().millisecondsSinceEpoch,
        );
        setState(() {
          _isGenerating = false;
          _generationProgress = 1.0;
          _generationMessage = 'Completed';
          _completedToday = true;
        });
        timer.cancel();
        await db.clearGenerationStatus();
        await _loadMemories();
        if (mounted) {
          _showSnack(
            "Generated ${_groups.length} memory groups",
            success: true,
          );
        }
      } else if (status == 'failed') {
        setState(() {
          _isGenerating = false;
          _generationProgress = 0.0;
          _generationMessage = 'Failed: $message';
        });
        timer.cancel();
        await db.clearGenerationStatus();
        _loadMemories();
        if (mounted) {
          _showSnack("Memory scan failed: $message", success: false);
        }
      }
    });
  }

  void _showSnack(String text, {required bool success}) {
    final color = success ? const Color(0xFF1F8A4C) : const Color(0xFFB3261E);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  Future<void> _loadMemories() async {
    setState(() => _isLoading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final isEnabled = prefs.getBool('enable_recommendations') ?? true;
      if (!isEnabled) {
        setState(() {
          _isEnabled = false;
          _groups = [];
          _isLoading = false;
        });
        return;
      }

      final groups = await RecommendsPersistence.loadGroups();
      final now = DateTime.now();
      final validGroups = groups
          .where((g) => g.expiresAt.isAfter(now) && g.items.isNotEmpty)
          .toList();
      validGroups.sort((a, b) => b.generatedAt.compareTo(a.generatedAt));

      setState(() {
        _isEnabled = true;
        _groups = validGroups;
        _isLoading = false;
      });
      _listAnimController.forward(from: 0);
    } catch (e) {
      debugPrint("RecommendedTab: Failed to load memories: $e");
      setState(() => _isLoading = false);
    }
  }

  bool _isSystemWorking() {
    return _isGenerating ||
        DeviceMediaScanner.instance.isScanning ||
        MLProcessingService.instance.isProcessingNotifier.value ||
        MLProcessingService.instance.isFacesProcessingNotifier.value ||
        MLProcessingService.instance.isSyncingNotifier.value;
  }

  Future<void> _triggerFullCuration() async {
    if (_isSystemWorking()) return;

    _showSnack("Starting full curation pipeline...", success: true);

    try {
      await DatabaseHelper.instance.setGenerationStatus(
        'generating',
        0.0,
        'Starting curation...',
      );
      setState(() {
        _isGenerating = true;
        _generationProgress = 0.0;
        _generationMessage = 'Starting curation...';
      });
      _startPollingStatus();

      // 1. Scan device media
      await DeviceMediaScanner.instance.scanAndSyncDeviceMedia(force: true);

      // 2. Schedule background tasks / run foregound tasks
      if (Platform.isAndroid) {
        await MLProcessingService.instance.scheduleBackgroundTask(force: true);
        await MLProcessingService.instance.triggerFacesTaskNow();
      }

      // 3. Run recommendations generation
      await RecommendsAlgorithm.instance.runIfNeeded(force: true);
    } catch (e) {
      debugPrint("RecommendedTab: Full curation failed: $e");
      if (mounted) {
        _showSnack(
          "Curation pipeline failed, please try again.",
          success: false,
        );
      }
      setState(() => _isGenerating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final bg = theme.scaffoldBackgroundColor;
    final isDark = theme.brightness == Brightness.dark;


    if (_isLoading) {
      return Container(
        color: bg,
        child: const Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    }

    if (!_isEnabled) {
      final textColor = theme.colorScheme.onSurface;
      final subColor = theme.colorScheme.onSurface.withValues(alpha: 0.6);
      return Container(
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.04)
                      : Colors.black.withValues(alpha: 0.03),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.auto_awesome_rounded,
                  size: 64,
                  color: theme.colorScheme.primary.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Recommendations Disabled',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                "Daily suggestions, birthday specials, and memory journeys are currently turned off. Enable 'Suggestions & recommendations' setting to start generating memory recommendations.",
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: subColor,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    if (_groups.isEmpty) {
      double? activeProgress;
      String activeMessage = '';

      if (_isGenerating) {
        activeProgress = _generationProgress;
        activeMessage = _generationMessage;
      } else if (DeviceMediaScanner.instance.isScanning ||
          MLProcessingService.instance.isSyncingNotifier.value) {
        activeProgress = 0.05;
        activeMessage = 'Scanning device media...';
      } else if (MLProcessingService.instance.isProcessingNotifier.value) {
        activeProgress = MLProcessingService.instance.progressNotifier.value;
        activeMessage = MLProcessingService.instance.logNotifier.value;
      } else if (MLProcessingService.instance.isFacesProcessingNotifier.value) {
        activeProgress = 0.90;
        activeMessage = 'Grouping faces & profiles...';
      }

      return Container(
        color: bg,
        child: GhostMascotWidget(
          isWorking: _isSystemWorking(),
          isCompletedToday: _completedToday,
          progress: activeProgress,
          statusMessage: activeMessage,
          onSlapped: _triggerFullCuration,
        ),
      );
    }

    final birthdayGroups = _groups
        .where((g) => g.type == RecommendType.birthdaySpecial)
        .toList();
    final onThisDayGroups = _groups
        .where((g) => g.type == RecommendType.onThisDay)
        .toList();
    final bestMomentGroups = _groups
        .where((g) => g.type == RecommendType.bestMoment)
        .toList();
    final highlightGroups = _groups
        .where((g) => g.type == RecommendType.highlight)
        .toList();
    final tripGroups = _groups
        .where((g) => g.type == RecommendType.bestTrip)
        .toList();
    final recapGroups = _groups
        .where((g) => g.type == RecommendType.recapPreviousYear)
        .toList();

    final sections = <Widget>[];
    int sectionIndex = 0;

    void addSection(Widget header, Widget body) {
      sections.add(
        _AnimatedSection(
          index: sectionIndex++,
          controller: _listAnimController,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [header, body, const SizedBox(height: 20)],
          ),
        ),
      );
    }

    if (bestMomentGroups.isNotEmpty) {
      addSection(
        _buildSectionHeader("Best Moments", Icons.star_outline),
        _buildBestMomentsSection(bestMomentGroups, isDark),
      );
    }

    if (birthdayGroups.isNotEmpty) {
      addSection(
        _buildSectionHeader("Birthday Specials", Icons.cake_outlined),
        SizedBox(
          height: 200,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: birthdayGroups.length,
            itemBuilder: (ctx, i) =>
                _buildBirthdayCard(birthdayGroups[i], isDark),
          ),
        ),
      );
    }

    if (onThisDayGroups.isNotEmpty) {
      addSection(
        _buildSectionHeader("On This Day", Icons.calendar_today_outlined),
        SizedBox(
          height: 170,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: onThisDayGroups.length,
            itemBuilder: (ctx, i) =>
                _buildOnThisDayCard(onThisDayGroups[i], isDark),
          ),
        ),
      );
    }

    if (tripGroups.isNotEmpty) {
      addSection(
        _buildSectionHeader("Travel Journeys", Icons.flight_takeoff_outlined),
        SizedBox(
          height: 180,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: tripGroups.length,
            itemBuilder: (ctx, i) => _buildTripCard(tripGroups[i], isDark),
          ),
        ),
      );
    }

    if (highlightGroups.isNotEmpty) {
      addSection(
        _buildSectionHeader("People Highlights", Icons.person_outline),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: context.isWatch
                  ? 1
                  : (context.isTV ? 4 : (context.isTablet ? 3 : 2)),
              crossAxisSpacing: context.isWatch ? 8 : 12,
              mainAxisSpacing: context.isWatch ? 8 : 12,
              childAspectRatio: 0.85,
            ),
            itemCount: highlightGroups.length,
            itemBuilder: (ctx, i) =>
                _buildHighlightCard(highlightGroups[i], isDark),
          ),
        ),
      );
    }

    if (recapGroups.isNotEmpty) {
      addSection(
        _buildSectionHeader("Yearly Recap", Icons.celebration_outlined),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: recapGroups
                .map((g) => _buildRecapCard(g, isDark))
                .toList(),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: bg,
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _loadMemories,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.only(
                    top: context.isWatch ? 6 : 12,
                    bottom: 80,
                  ),
                  children: sections,
                ),
              ),
            ),
          ),
          if (_isGenerating)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: ClipRRect(
                child: LinearProgressIndicator(
                  value: _generationProgress,
                  backgroundColor: Colors.transparent,
                  color: theme.colorScheme.primary,
                  minHeight: 3,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
      child: Row(
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary, size: 20),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
          ),
        ],
      ),
    );
  }

  void _openGroup(RecommendGroup group) async {
    await Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (context, animation, secondaryAnimation) =>
            RecommendsViewerScreen(group: group),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position:
                  Tween<Offset>(
                    begin: const Offset(0, 0.04),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutCubic,
                    ),
                  ),
              child: child,
            ),
          );
        },
      ),
    );
    _loadMemories();
  }

  Widget _buildCoverImage(RecommendGroup group) {
    final coverItem = group.items.isNotEmpty
        ? group.items.firstWhere(
            (item) => !item.isVideo && item.displayPath != null,
            orElse: () => group.items.first,
          )
        : null;

    if (coverItem != null &&
        coverItem.displayPath != null &&
        !coverItem.isVideo) {
      return Image.file(
        File(coverItem.displayPath!),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          return Container(
            color: Colors.grey.withValues(alpha: 0.15),
            child: const Center(
              child: Icon(
                Icons.broken_image_outlined,
                size: 28,
                color: Colors.grey,
              ),
            ),
          );
        },
      );
    } else if (coverItem != null && coverItem.isVideo) {
      return Container(
        color: Colors.grey.withValues(alpha: 0.15),
        child: const Center(
          child: Icon(
            Icons.movie_creation_outlined,
            size: 28,
            color: Colors.grey,
          ),
        ),
      );
    } else {
      return Container(
        color: Colors.grey.withValues(alpha: 0.15),
        child: const Center(
          child: Icon(Icons.photo_outlined, size: 28, color: Colors.grey),
        ),
      );
    }
  }

  // ----- Card builders -----

  Widget _buildBestMomentsSection(List<RecommendGroup> groups, bool isDark) {
    if (groups.length == 1) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: _buildBestMomentCard(groups.first, isDark, isHero: true),
      );
    }

    // Multiple groups - build PageView carousel with dots indicator
    return _BestMomentsCarousel(
      groups: groups,
      isDark: isDark,
      openGroup: _openGroup,
      coverImageBuilder: _buildCoverImage,
      titleBlockBuilder: _titleBlock,
    );
  }

  // ----- Card builders -----

  Widget _buildBirthdayCard(RecommendGroup group, bool isDark) {
    return PremiumGate(
      borderRadius: BorderRadius.circular(18),
      child: _TapScale(
      onTap: () => _openGroup(group),
      child: Container(
        width: 190,
        margin: const EdgeInsets.only(right: 12, bottom: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: Theme.of(context).cardColor,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.05),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            fit: StackFit.expand,
            children: [
              KenBurnsWrapper(
                duration: const Duration(seconds: 14),
                index: group.items.length + 1,
                child: _buildCoverImage(group),
              ),
              _bottomGradient(),
              _badge("BIRTHDAY", Icons.cake_outlined, const Color(0xFFEC4899)),
              
              // ── Bottom bar: face avatar inline-left of title ──
              Positioned(
                bottom: 8,
                left: 8,
                right: 8,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Face / profile image circle
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.8),
                          width: 1.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.45),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: PersonAvatar(
                        groupId: group.id,
                        size: 36,
                        fallback: Container(
                          color: const Color(0xFFEC4899),
                          child: const Icon(
                            Icons.cake_rounded,
                            size: 20,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Title + subtitle
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            group.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              shadows: [
                                Shadow(
                                  color: Colors.black45,
                                  offset: Offset(0, 1),
                                  blurRadius: 4,
                                ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            group.subtitle,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 10,
                              shadows: const [
                                Shadow(
                                  color: Colors.black45,
                                  offset: Offset(0, 1),
                                  blurRadius: 3,
                                ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ));
  }

  Widget _buildOnThisDayCard(RecommendGroup group, bool isDark) {
    return PremiumGate(
      borderRadius: BorderRadius.circular(16),
      child: _TapScale(
      onTap: () => _openGroup(group),
      child: Container(
        width: 130,
        margin: const EdgeInsets.only(right: 12, bottom: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Theme.of(context).cardColor,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.05),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            fit: StackFit.expand,
            children: [
              KenBurnsWrapper(
                duration: const Duration(seconds: 16),
                index: group.items.length + 2,
                child: _buildCoverImage(group),
              ),
              _bottomGradient(),
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: const BoxDecoration(
                    color: Color(0xFF3B82F6),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.calendar_today,
                    size: 10,
                    color: Colors.white,
                  ),
                ),
              ),
              Positioned(
                bottom: 8,
                left: 8,
                right: 8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      group.subtitle,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 8,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ));
  }

  Widget _buildBestMomentCard(
    RecommendGroup group,
    bool isDark, {
    bool isHero = false,
  }) {
    final cardHeight = isHero ? 220.0 : 140.0;
    return PremiumGate(
      borderRadius: BorderRadius.circular(24),
      child: _TapScale(
      onTap: () => _openGroup(group),
      child: Container(
        height: cardHeight,
        margin: EdgeInsets.only(bottom: isHero ? 0 : 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          color: Theme.of(context).cardColor,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Stack(
            fit: StackFit.expand,
            children: [
              KenBurnsWrapper(
                duration: const Duration(seconds: 12),
                index: group.items.length,
                child: _buildCoverImage(group),
              ),
              _bottomGradient(strong: isHero),
              Positioned(
                top: 12,
                right: 12,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    color: Colors.black.withValues(alpha: 0.35),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.star_rounded,
                          size: 14,
                          color: Color(0xFFF59E0B),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          "BEST MOMENT",
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.95),
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              _titleBlock(
                group,
                fontSize: isHero ? 18 : 14,
                padding: isHero ? 18 : 14,
                subtitleSize: isHero ? 12 : 10,
              ),
            ],
          ),
        ),
      ),
    ));
  }

  Widget _buildHighlightCard(RecommendGroup group, bool isDark) {
    return PremiumGate(
      borderRadius: BorderRadius.circular(16),
      child: _TapScale(
      onTap: () => _openGroup(group),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Theme.of(context).cardColor,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.05),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Background – ken-burns photo collage
              KenBurnsWrapper(
                duration: const Duration(seconds: 18),
                index: group.items.length + 3,
                child: _buildCoverImage(group),
              ),
              _bottomGradient(),

              // ── Bottom bar: face avatar inline-left of title ──
              Positioned(
                bottom: 8,
                left: 8,
                right: 8,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Face / profile image circle
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.8),
                          width: 1.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.45),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: PersonAvatar(
                        groupId: group.id,
                        size: 36,
                        fallback: Container(
                          color: const Color(0xFF14B8A6),
                          child: const Icon(
                            Icons.person_rounded,
                            size: 20,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Title + subtitle
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            group.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            group.subtitle,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 9,
                              shadows: [Shadow(color: Colors.black54, blurRadius: 3)],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ));
  }

  Widget _buildTripCard(RecommendGroup group, bool isDark) {
    return PremiumGate(
      borderRadius: BorderRadius.circular(18),
      child: _TapScale(
      onTap: () => _openGroup(group),
      child: Container(
        width: 240,
        margin: const EdgeInsets.only(right: 12, bottom: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: Theme.of(context).cardColor,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.05),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            fit: StackFit.expand,
            children: [
              KenBurnsWrapper(
                duration: const Duration(seconds: 15),
                index: group.items.length + 4,
                child: _buildCoverImage(group),
              ),
              _bottomGradient(),
              _badge("TRIP", Icons.flight_takeoff, const Color(0xFF6366F1)),
              _titleBlock(group),
            ],
          ),
        ),
      ),
    ));
  }

  Widget _buildRecapCard(RecommendGroup group, bool isDark) {
    return PremiumGate(
      borderRadius: BorderRadius.circular(24),
      child: _TapScale(
      onTap: () => _openGroup(group),
      child: Container(
        height: 160,
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          color: Theme.of(context).cardColor,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Stack(
            fit: StackFit.expand,
            children: [
              KenBurnsWrapper(
                duration: const Duration(seconds: 12),
                index: group.items.length + 5,
                child: _buildCoverImage(group),
              ),
              _bottomGradient(strong: true),
              _badge(
                "YEAR RECAP",
                Icons.celebration,
                const Color(0xFF8B5CF6),
                alignRight: true,
                dark: true,
              ),
              _titleBlock(group, fontSize: 16, padding: 16, subtitleSize: 11),
            ],
          ),
        ),
      ),
    ));
  }

  // ----- Shared visual helpers -----

  Widget _bottomGradient({bool strong = false}) {
    return Positioned.fill(
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.black.withValues(alpha: strong ? 0.82 : 0.65),
            ],
            stops: const [0.4, 1.0],
          ),
        ),
      ),
    );
  }

  Widget _badge(
    String label,
    IconData icon,
    Color color, {
    bool alignRight = false,
    bool dark = false,
  }) {
    return Positioned(
      top: 10,
      left: alignRight ? null : 10,
      right: alignRight ? 10 : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 10, color: dark ? Colors.black87 : Colors.white),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: dark ? Colors.black87 : Colors.white,
                fontSize: 8,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _titleBlock(
    RecommendGroup group, {
    double fontSize = 13,
    double padding = 10,
    double subtitleSize = 10,
  }) {
    return Positioned(
      bottom: padding,
      left: padding,
      right: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            group.title,
            style: TextStyle(
              color: Colors.white,
              fontSize: fontSize,
              fontWeight: FontWeight.w800,
              shadows: const [
                Shadow(
                  color: Colors.black45,
                  offset: Offset(0, 1),
                  blurRadius: 4,
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            group.subtitle,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: subtitleSize,
              shadows: const [
                Shadow(
                  color: Colors.black45,
                  offset: Offset(0, 1),
                  blurRadius: 3,
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// A premium, animated carousel for multiple Best Moments memory groups.
class _BestMomentsCarousel extends StatefulWidget {
  final List<RecommendGroup> groups;
  final bool isDark;
  final Function(RecommendGroup) openGroup;
  final Widget Function(RecommendGroup) coverImageBuilder;
  final Widget Function(
    RecommendGroup, {
    double fontSize,
    double padding,
    double subtitleSize,
  })
  titleBlockBuilder;

  const _BestMomentsCarousel({
    required this.groups,
    required this.isDark,
    required this.openGroup,
    required this.coverImageBuilder,
    required this.titleBlockBuilder,
  });

  @override
  State<_BestMomentsCarousel> createState() => _BestMomentsCarouselState();
}

class _BestMomentsCarouselState extends State<_BestMomentsCarousel> {
  int _currentPage = 0;
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 0.92);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 220,
          child: PageView.builder(
            controller: _pageController,
            itemCount: widget.groups.length,
            onPageChanged: (index) {
              setState(() {
                _currentPage = index;
              });
            },
            itemBuilder: (context, index) {
              final group = widget.groups[index];
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: _buildBestMomentHeroCard(group),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(
            widget.groups.length,
            (index) => AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              margin: const EdgeInsets.symmetric(horizontal: 4),
              height: 6,
              width: _currentPage == index ? 18 : 6,
              decoration: BoxDecoration(
                color: _currentPage == index
                    ? Theme.of(context).colorScheme.primary
                    : (widget.isDark ? Colors.white24 : Colors.black12),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBestMomentHeroCard(RecommendGroup group) {
    return PremiumGate(
      borderRadius: BorderRadius.circular(24),
      child: _TapScale(
      onTap: () => widget.openGroup(group),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          color: Theme.of(context).cardColor,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: widget.isDark ? 0.3 : 0.08),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Stack(
            fit: StackFit.expand,
            children: [
              KenBurnsWrapper(
                duration: const Duration(seconds: 12),
                index: group.items.length,
                child: widget.coverImageBuilder(group),
              ),
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.82),
                      ],
                      stops: const [0.4, 1.0],
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 12,
                right: 12,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    color: Colors.black.withValues(alpha: 0.35),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.star_rounded,
                          size: 14,
                          color: Color(0xFFF59E0B),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          "BEST MOMENT",
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.95),
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              widget.titleBlockBuilder(
                group,
                fontSize: 18,
                padding: 18,
                subtitleSize: 12,
              ),
            ],
          ),
        ),
      ),
    ));
  }
}

/// Animated fade + slide-up wrapper for staggered section entrance.
class _AnimatedSection extends StatelessWidget {
  final int index;
  final AnimationController controller;
  final Widget child;

  const _AnimatedSection({
    required this.index,
    required this.controller,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final start = (index * 0.08).clamp(0.0, 0.7);
    final end = (start + 0.5).clamp(0.0, 1.0);
    final animation = CurvedAnimation(
      parent: controller,
      curve: Interval(start, end, curve: Curves.easeOutCubic),
    );

    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        return Opacity(
          opacity: animation.value,
          child: Transform.translate(
            offset: Offset(0, (1 - animation.value) * 18),
            child: child,
          ),
        );
      },
    );
  }
}

/// Simple scale-down-on-tap wrapper for tactile feedback.
class _TapScale extends StatefulWidget {
  final VoidCallback onTap;
  final Widget child;

  const _TapScale({required this.onTap, required this.child});

  @override
  State<_TapScale> createState() => _TapScaleState();
}

class _TapScaleState extends State<_TapScale> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.96),
      onTapCancel: () => setState(() => _scale = 1.0),
      onTapUp: (_) => setState(() => _scale = 1.0),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// Flat pill button with subtle press animation.
class _FlatButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  const _FlatButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  State<_FlatButton> createState() => _FlatButtonState();
}

class _FlatButtonState extends State<_FlatButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.97),
      onTapCancel: () => setState(() => _scale = 1.0),
      onTapUp: (_) => setState(() => _scale = 1.0),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, color: Colors.white, size: 18),
              const SizedBox(width: 10),
              Text(
                widget.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Flat circular progress ring with subtle pulsing scale animation.
class _PulsingProgressRing extends StatefulWidget {
  final double progress;

  const _PulsingProgressRing({required this.progress});

  @override
  State<_PulsingProgressRing> createState() => _PulsingProgressRingState();
}

class _PulsingProgressRingState extends State<_PulsingProgressRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final scale = 1.0 + (_controller.value * 0.03);
        return Transform.scale(scale: scale, child: child);
      },
      child: SizedBox(
        width: 96,
        height: 96,
        child: Stack(
          alignment: Alignment.center,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: widget.progress),
              duration: const Duration(milliseconds: 300),
              builder: (context, value, _) => CircularProgressIndicator(
                value: value,
                strokeWidth: 5,
                backgroundColor: isDark ? Colors.white12 : Colors.black12,
                valueColor: AlwaysStoppedAnimation<Color>(
                  theme.colorScheme.primary,
                ),
              ),
            ),
            Text(
              "${(widget.progress * 100).toInt()}%",
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class GhostMascotWidget extends StatefulWidget {
  final VoidCallback onSlapped;
  final bool isWorking;
  final bool isCompletedToday;
  final double? progress;
  final String statusMessage;

  const GhostMascotWidget({
    super.key,
    required this.onSlapped,
    required this.isWorking,
    required this.isCompletedToday,
    required this.progress,
    required this.statusMessage,
  });

  @override
  State<GhostMascotWidget> createState() => _GhostMascotWidgetState();
}

class _GhostMascotWidgetState extends State<GhostMascotWidget>
    with TickerProviderStateMixin {
  late final AnimationController _floatController;
  late final AnimationController _shakeController;
  int _slapCount = 0;
  DateTime? _lastTapTime;
  bool _wakingUp = false;

  @override
  void initState() {
    super.initState();
    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);

    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
  }

  @override
  void dispose() {
    _floatController.dispose();
    _shakeController.dispose();
    super.dispose();
  }

  void _handleTap() {
    if (widget.isWorking || _wakingUp) return;

    final now = DateTime.now();
    if (_lastTapTime == null ||
        now.difference(_lastTapTime!) > const Duration(seconds: 2)) {
      _slapCount = 1;
    } else {
      _slapCount++;
    }
    _lastTapTime = now;

    // Shake on each slap
    _shakeController.forward(from: 0.0);

    if (_slapCount >= 5) {
      // Slapped awake!
      setState(() {
        _wakingUp = true;
      });
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (mounted) {
          setState(() {
            _wakingUp = false;
            _slapCount = 0;
          });
          widget.onSlapped();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Determine state
    final String imagePath;
    final String titleText;
    final String subtitleText;

    if (widget.isWorking) {
      imagePath = 'assets/ghost_work.png';
      titleText = 'Curating Your Highlights';
      subtitleText = widget.statusMessage.isNotEmpty
          ? widget.statusMessage
          : 'Analyzing library media...';
    } else if (_wakingUp) {
      imagePath = 'assets/ghost_wakeup.png';
      titleText = 'Ouch! 👻';
      subtitleText = 'Okay, okay, I\'m waking up! Going to work now...';
    } else if (widget.isCompletedToday) {
      imagePath = 'assets/all_done.png';
      titleText = 'All Caught Up!';
      subtitleText = 'Ghost wants you to add more photos';
    } else {
      imagePath = 'assets/ghost_sleep.png';
      titleText = 'He is Sleeping...';
      subtitleText =
          'Slap him awake (tap 5 times quickly) to start memory curation!';
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Ghost Mascot with Animation & Gestures
            GestureDetector(
              onTap: _handleTap,
              child: AnimatedBuilder(
                animation: Listenable.merge([
                  _floatController,
                  _shakeController,
                ]),
                builder: (context, child) {
                  // Float animation
                  double floatOffset = 0.0;
                  if (!widget.isWorking && !_wakingUp) {
                    floatOffset =
                        math.sin(_floatController.value * 2 * math.pi) * 12;
                  }

                  // Shake animation
                  double shakeOffset = 0.0;
                  if (_shakeController.isAnimating) {
                    final t = _shakeController.value;
                    shakeOffset = math.sin(t * 4 * math.pi) * 8 * (1.0 - t);
                  }

                  return Transform.translate(
                    offset: Offset(shakeOffset, floatOffset),
                    child: Transform.scale(
                      scale: _wakingUp ? 1.15 : 1.0,
                      child: Container(
                        width: 200,
                        height: 200,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: theme.colorScheme.primary.withValues(
                                alpha: widget.isWorking
                                    ? 0.35
                                    : (_wakingUp ? 0.5 : 0.15),
                              ),
                              blurRadius: widget.isWorking ? 48 : 32,
                              spreadRadius: widget.isWorking ? 12 : 4,
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(100),
                          child: Image.asset(
                            imagePath,
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) {
                              return Icon(
                                widget.isWorking
                                    ? Icons.auto_awesome
                                    : (widget.isCompletedToday
                                          ? Icons.check_circle_outline
                                          : Icons.nights_stay),
                                size: 100,
                                color: theme.colorScheme.primary,
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 36),

            // Title
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Text(
                titleText,
                key: ValueKey(titleText),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 12),

            // Subtitle
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Text(
                subtitleText,
                key: ValueKey(subtitleText),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: (theme.textTheme.bodyMedium?.color ?? (isDark ? Colors.white : Colors.black)).withValues(alpha: 0.6),
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
            ),

            if (widget.isWorking) ...[
              const SizedBox(height: 32),
              // Pulse/Progress
              _PulsingProgressRing(progress: widget.progress ?? 0.0),
            ],
          ],
        ),
      ),
    );
  }
}
