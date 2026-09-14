import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:ghost_gallery/models/recommend_models.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/ml_processing_service.dart';
import '../services/theme_persistence.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:async';
import '../services/recommends_persistence.dart';
import '../services/recommends_algorithm.dart';
import '../services/database_helper.dart';
import 'file_explorer_screen.dart';

import '../services/responsive_helper.dart';
import '../widgets/follow_us_dialog.dart';
import '../config/app_social_links.dart';

// ── Ghost AMOLED Black & Putty White palette ──────────────────────────────────
class GhostColors {
  static const bg = Color(0xFF000000); // AMOLED true black
  static const surface = Color(0xFF0A0A0C); // deep AMOLED surface
  static const card = Color(0xFF121214); // sleek dark card
  static const border = Color(0xFF222226); // dark graphite border
  static const blood = Color(0xFFEDEAE2); // putty white primary
  static const bloodBright = Color(0xFFF5F3ED); // bright putty white highlight
  static const ectoplasm = Color(0xFF5EEAD4); // subtle mint accent
  static const bone = Color(0xFFEDEAE2); // putty white
  static const ghost = Color(0xFFEDEAE2); // putty white ethereal
  static const purpleMist = Color(0xFF18181B); // dark container
  static const textPrim = Color(0xFFEDEAE2); // putty white foreground
  static const textSec = Color(0xFF9E9C96); // putty muted stone secondary
  static const cyan = Color(0xFF38BDF8);
  static const purple = Color(0xFFA78BFA);
}

// ── JetBrains Darcula palette ─────────────────────────────────────────────────
class DarculaColors {
  static const bg = Color(0xFF000000); // unchanged — true black is correct here
  static const bg2 = Color(0xFF0D0D0D); // unchanged
  static const border = Color(0xFF2B2B2B); // unchanged — JetBrains original
  static const accent = Color(0xFF5C9FD6); // slightly deeper, less washed-out
  static const accent2 = Color(
    0xFFB0BEC8,
  ); // cooler, lifted — actually readable
  static const text = Color(0xFFB0BEC8); // matches accent2 — Darcula's intent
  static const textSec = Color(
    0xFF707478,
  ); // up from 606366 — clearer on true black
  static const string_ = Color(
    0xFF5C8C54,
  ); // slightly more saturated — green pops
}

// ── Standard Dark palette ─────────────────────────────────────────────────────
class DarkColors {
  static const bg = Color(0xFF0E0E0E); // near-black with no blue cast
  static const bg2 = Color(
    0xFF1A1A2A,
  ); // cool blue-tinted surface — intentional depth
  static const border = Color(0xFF262636); // matches bg2 family — coherent ramp
  static const accent = Color(
    0xFF5BB8F5,
  ); // crisper sky blue — better contrast on bg2
  static const text = Color(
    0xFFE4E4EE,
  ); // barely-warm white — easier on the eyes
  static const textSec = Color(
    0xFF6A6A80,
  ); // purple-grey — harmonises with bg2 tint
}

// ─────────────────────────────────────────────────────────────────────────────
class SettingsScreen extends StatefulWidget {
  final String appTheme;
  final void Function(String) onThemeChanged;
  final String ghostyPersonality;
  final void Function(String) onGhostyChanged;
  final VoidCallback onConfigureWidgetPressed;

  const SettingsScreen({
    super.key,
    required this.appTheme,
    required this.onThemeChanged,
    required this.ghostyPersonality,
    required this.onGhostyChanged,
    required this.onConfigureWidgetPressed,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late String _currentTheme;

  // ── Gradient animation ────────────────────────────────────────────────────
  late AnimationController _gradCtrl;

  // ── Cache ─────────────────────────────────────────────────────────────────
  String? _cacheSize;
  bool _clearingCache = false;
  bool _reclustering = false;

  // ── Storage stats ─────────────────────────────────────────────────────────
  static const _kMediaChannel = MethodChannel(
    'in.sddev.ghost_gallery/media_manager',
  );
  static const _kAutoScanChannel = MethodChannel(
    'in.sddev.ghost_gallery/auto_scan',
  );

  int? _totalBytes;
  int? _freeBytes;
  int? _imageBytes;
  int? _videoBytes;
  bool _loadingStorage = true;

  int _dbSqliteBytes = 0;
  int _dbObjectBoxBytes = 0;
  int _faceCacheBytes = 0;
  int _otherCacheBytes = 0;
  int _vaultBytes = 0;
  int _generatedMemoriesBytes = 0;
  int _otherDocBytes = 0;
  bool _loadingDetailedStorage = true;

  bool _autoScanEnabled = true;
  bool _facesTaskScheduled = true;
  int _faceEligibleThreshold = 10;
  bool _enableRecommendations = true;
  List<RecommendGroup> _savedGroups = [];
  Map<String, String> _lastRuns = {};
  bool _runningRecommends = false;
  Timer? _recommendsStatusTimer;
  double _recommendsProgress = 0.0;
  String _recommendsMessage = '';

  @override
  void initState() {
    super.initState();
    _currentTheme = widget.appTheme;
    _gradCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);
    _loadCurrentTheme();
    _computeCacheSize();
    _fetchStorageStats();
    if (kDebugMode) {
      _fetchDetailedAppStorage();
    }
    _loadRecommendsStatus();
    _startRecommendsPolling();
    _loadAutoScanStatus();

    // Load scheduled status for face task and threshold
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() {
          _facesTaskScheduled = prefs.getBool('faces_task_scheduled') ?? true;
          _faceEligibleThreshold =
              prefs.getInt('face_eligible_threshold') ?? 10;
          _enableRecommendations =
              prefs.getBool('enable_recommendations') ?? true;
        });
      }
    });
  }

  @override
  void dispose() {
    _gradCtrl.dispose();

    _recommendsStatusTimer?.cancel();
    super.dispose();
  }

  void _startRecommendsPolling() {
    _recommendsStatusTimer?.cancel();
    _recommendsStatusTimer = Timer.periodic(const Duration(milliseconds: 500), (
      timer,
    ) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final db = DatabaseHelper.instance;
      final job = await db.getGenerationStatus();
      if (job == null) {
        if (_runningRecommends) {
          setState(() {
            _runningRecommends = false;
            _recommendsProgress = 0.0;
            _recommendsMessage = '';
          });
          _loadRecommendsStatus();
        }
        timer.cancel();
        return;
      }

      final status = job['status'] as String;
      final progress = (job['progress'] as num).toDouble();
      final message = job['message'] as String? ?? '';

      if (status == 'generating') {
        setState(() {
          _runningRecommends = true;
          _recommendsProgress = progress;
          _recommendsMessage = message;
        });
      } else if (status == 'completed') {
        setState(() {
          _runningRecommends = false;
          _recommendsProgress = 1.0;
          _recommendsMessage = 'Completed';
        });
        timer.cancel();
        await db.clearGenerationStatus();
        _loadRecommendsStatus();
      } else if (status == 'failed') {
        setState(() {
          _runningRecommends = false;
          _recommendsProgress = 0.0;
          _recommendsMessage = 'Failed: $message';
        });
        timer.cancel();
        await db.clearGenerationStatus();
        _loadRecommendsStatus();
      }
    });
  }

  Future<void> _loadCurrentTheme() async {
    try {
      final theme = await ThemePersistence.loadThemeName();
      if (theme != _currentTheme && mounted) {
        setState(() {
          _currentTheme = theme;
        });
      }
    } catch (_) {}
  }

  Future<void> _launchReport() async {
    final url = Uri.parse(AppSocialLinks.feedbackReport);
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.inAppBrowserView);
      } else {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('Error launching report: $e');
    }
  }

  Future<void> _launchPrivacyPolicy() async {
    final url = Uri.parse(AppSocialLinks.privacyPolicy);
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.inAppBrowserView);
      } else {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('Error launching privacy policy: $e');
    }
  }

  // ── Cache ─────────────────────────────────────────────────────────────────
  Future<void> _computeCacheSize() async {
    try {
      final dir = await getTemporaryDirectory();
      int total = 0;
      await for (final e in dir.list(recursive: true)) {
        if (e is File) total += await e.length();
      }
      if (mounted) {
        setState(() => _cacheSize = _fmt(total));
      }
    } catch (_) {
      if (mounted) setState(() => _cacheSize = '—');
    }
  }

  Future<void> _clearCache() async {
    setState(() => _clearingCache = true);
    try {
      final dir = await getTemporaryDirectory();
      await for (final e in dir.list(recursive: true)) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
    await _computeCacheSize();
    if (kDebugMode) {
      await _fetchDetailedAppStorage();
    }
    if (mounted) {
      setState(() => _clearingCache = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Cache cleared'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }

  // ── Storage stats ─────────────────────────────────────────────────────────
  Future<void> _fetchStorageStats() async {
    try {
      final result = await _kMediaChannel.invokeMapMethod<String, dynamic>(
        'getStorageStats',
      );
      if (result != null && mounted) {
        setState(() {
          _totalBytes = (result['totalBytes'] as num?)?.toInt();
          _freeBytes = (result['freeBytes'] as num?)?.toInt();
          _imageBytes = (result['imageBytes'] as num?)?.toInt();
          _videoBytes = (result['videoBytes'] as num?)?.toInt();
          _loadingStorage = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingStorage = false);
    }
  }

  Future<void> _fetchDetailedAppStorage() async {
    if (kIsWeb) {
      if (mounted) {
        setState(() {
          _loadingDetailedStorage = false;
        });
      }
      return;
    }

    try {
      int dbSqlite = 0;
      int dbObjectBox = 0;
      int facesCache = 0;
      int otherCache = 0;
      int vaultStorage = 0;
      int generatedMemories = 0;
      int otherDocs = 0;

      // 1. Temporary/Cache Directory
      try {
        final tempDir = await getTemporaryDirectory();
        if (await tempDir.exists()) {
          await for (final file in tempDir.list(recursive: true, followLinks: false)) {
            if (file is File) {
              final size = await file.length();
              if (file.path.contains('gh_faces')) {
                facesCache += size;
              } else {
                otherCache += size;
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Error detailed cache: $e');
      }

      // Also getApplicationCacheDirectory if different
      try {
        final appCacheDir = await getApplicationCacheDirectory();
        final tempDir = await getTemporaryDirectory();
        if (await appCacheDir.exists() && appCacheDir.path != tempDir.path) {
          await for (final file in appCacheDir.list(recursive: true, followLinks: false)) {
            if (file is File) {
              final size = await file.length();
              if (file.path.contains('gh_faces')) {
                facesCache += size;
              } else {
                otherCache += size;
              }
            }
          }
        }
      } catch (_) {}

      // 2. Application Documents Directory
      try {
        final docsDir = await getApplicationDocumentsDirectory();
        if (await docsDir.exists()) {
          await for (final file in docsDir.list(recursive: true, followLinks: false)) {
            if (file is File) {
              final size = await file.length();
              if (file.path.contains('objectbox')) {
                dbObjectBox += size;
              } else if (file.path.contains('.ghost_gallery_vault')) {
                vaultStorage += size;
              } else if (file.path.contains('ghost_recommends')) {
                generatedMemories += size;
              } else {
                otherDocs += size;
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Error detailed docs: $e');
      }

      // 3. Databases Directory
      try {
        final dbDir = Directory(await getDatabasesPath());
        if (await dbDir.exists()) {
          await for (final file in dbDir.list(recursive: true, followLinks: false)) {
            if (file is File) {
              final size = await file.length();
              if (file.path.contains('.ghost_gallery_vault')) {
                vaultStorage += size;
              } else {
                dbSqlite += size;
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Error detailed db: $e');
      }

      // 4. Support Directory (ApplicationSupportDirectory)
      try {
        final supportDir = await getApplicationSupportDirectory();
        final docsDir = await getApplicationDocumentsDirectory();
        if (await supportDir.exists() && supportDir.path != docsDir.path) {
          await for (final file in supportDir.list(recursive: true, followLinks: false)) {
            if (file is File) {
              final size = await file.length();
              if (file.path.contains('objectbox')) {
                dbObjectBox += size;
              } else if (file.path.contains('.ghost_gallery_vault')) {
                vaultStorage += size;
              } else if (file.path.contains('ghost_recommends')) {
                generatedMemories += size;
              } else {
                otherDocs += size;
              }
            }
          }
        }
      } catch (_) {}

      // 5. External Vault Directory (Android only)
      if (Platform.isAndroid) {
        try {
          final externalDirs = await getExternalStorageDirectories();
          if (externalDirs != null && externalDirs.isNotEmpty) {
            final extPath = externalDirs[0].path;
            String mediaBase = extPath.replaceAll('/Android/data/', '/Android/media/');
            if (mediaBase.endsWith('/files')) {
              mediaBase = mediaBase.substring(0, mediaBase.length - 6);
            }
            final extVaultDir = Directory(p.join(mediaBase, '.ghost_gallery_vault'));
            if (await extVaultDir.exists()) {
              await for (final file in extVaultDir.list(recursive: true, followLinks: false)) {
                if (file is File) {
                  vaultStorage += await file.length();
                }
              }
            }
          }
        } catch (e) {
          debugPrint('Error calculating external vault: $e');
        }
      }

      if (mounted) {
        setState(() {
          _dbSqliteBytes = dbSqlite;
          _dbObjectBoxBytes = dbObjectBox;
          _faceCacheBytes = facesCache;
          _otherCacheBytes = otherCache;
          _vaultBytes = vaultStorage;
          _generatedMemoriesBytes = generatedMemories;
          _otherDocBytes = otherDocs;
          _loadingDetailedStorage = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching detailed app storage sizes: $e');
      if (mounted) {
        setState(() {
          _loadingDetailedStorage = false;
        });
      }
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  String _fmt(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  // ── Theme flags ───────────────────────────────────────────────────────────
  bool get _isGhost {
    if (_currentTheme == 'system') {
      return MediaQuery.of(context).platformBrightness == Brightness.dark;
    }
    return _currentTheme == 'ghost';
  }

  bool get _isDarcula => _currentTheme == 'darcula';
  bool get _isDark {
    if (_currentTheme == 'system') {
      return MediaQuery.of(context).platformBrightness == Brightness.dark;
    }
    return _currentTheme != 'light';
  }

  Color get _bg => _isGhost
      ? GhostColors.bg
      : _isDarcula
      ? DarculaColors.bg
      : _currentTheme == 'dark'
      ? DarkColors.bg
      : Colors.white;
  Color get _cardBg => _isGhost
      ? GhostColors.card
      : _isDarcula
      ? DarculaColors.bg2
      : _currentTheme == 'dark'
      ? DarkColors.bg2
      : const Color(0xFFF5F5F5);
  Color get _divColor => _isGhost
      ? GhostColors.border
      : _isDarcula
      ? DarculaColors.border
      : _currentTheme == 'dark'
      ? DarkColors.border
      : Colors.black12;
  Color get _textPrim => _isGhost
      ? GhostColors.textPrim
      : _isDarcula
      ? DarculaColors.text
      : _currentTheme == 'dark'
      ? DarkColors.text
      : Colors.black87;
  Color get _textSec => _isGhost
      ? GhostColors.textSec
      : _isDarcula
      ? DarculaColors.textSec
      : _currentTheme == 'dark'
      ? DarkColors.textSec
      : Colors.grey.shade600;
  Color get _accent => _isGhost
      ? GhostColors.blood
      : _isDarcula
      ? DarculaColors.accent
      : _currentTheme == 'dark'
      ? DarkColors.accent
      : const Color(0xFF6750A4);
  Color get _accentBright => _isGhost ? GhostColors.bloodBright : _accent;
  Color get _titleColor => _isGhost
      ? GhostColors.ghost
      : _isDarcula
      ? DarculaColors.text
      : _currentTheme == 'dark'
      ? DarkColors.text
      : Colors.black87;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    context.isWatch ? 4 : 8,
                    context.isWatch ? 6 : 14,
                    context.isWatch ? 10 : 20,
                    context.isWatch ? 6 : 10,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.arrow_back_ios_new_rounded,
                          color: _titleColor,
                          size: context.isWatch ? 16 : 20,
                        ),
                        onPressed: () => Navigator.pop(context),
                      ),
                      SizedBox(width: context.isWatch ? 4 : 8),
                      Text(
                        'Settings',
                        style: TextStyle(
                          fontSize: context.isWatch ? 20 : 28,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                          color: _titleColor,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(
                      context.isWatch ? 8 : 16,
                      context.isWatch ? 4 : 8,
                      context.isWatch ? 8 : 16,
                      32 + MediaQuery.of(context).padding.bottom,
                    ),
                    children: [
                      _section('THEME', [_themeSelector()]),
                      // PERSONA hidden — will be re-enabled later
                      _section('STORAGE ANALYTICS', [
                        _storageOverviewCard(),
                        if (kDebugMode) ...[
                          _divider(),
                          _detailedStorageBreakdownCard(),
                        ],
                      ]),
                      _section('MAINTENANCE', [
                        _cacheTile(),
                        _divider(),
                        _reclusterFacesTile(),
                        _divider(),
                        _faceThresholdTile(),
                      ]),
                      _section('RECOMMENDATIONS', [
                        _recommendationsToggleTile(),
                        _divider(),
                        _deleteRecommendsTile(),
                      ]),
                      _section('FEATURES', [
                        _actionTile(
                          icon: Icons.widgets_outlined,
                          title: 'Configure Home Widget',
                          subtitle: 'Choose album shown on your widget',
                          onTap: widget.onConfigureWidgetPressed,
                        ),
                        _divider(),
                        _autoScanTile(),
                      ]),
                      _section('ABOUT', [
                        _infoRow('App', 'Ghost Gallery'),
                        _divider(),
                        _infoRow('Version', 'v2.6.5 · Ghost Series'),
                        _divider(),
                        _actionTile(
                          icon: Icons.hub_rounded,
                          title: 'Follow Us',
                          subtitle: 'We are open-source. Join Ghost Ecosystem.',
                          onTap: () => FollowUsDialog.show(context),
                        ),
                        _divider(),
                        _actionTile(
                          icon: Icons.privacy_tip_outlined,
                          title: 'Report Problem',
                          subtitle: 'Facing problem? Talk to our devloper.',
                          onTap: _launchReport,
                        ),
                        _actionTile(
                          icon: Icons.privacy_tip_outlined,
                          title: 'Privacy Policy',
                          subtitle: 'Read our privacy policy online',
                          onTap: _launchPrivacyPolicy,
                        ),
                        _divider(),
                        _actionTile(
                          icon: Icons.star_rate_rounded,
                          title: 'Rate Us',
                          subtitle: 'Show your love on the Play Store',
                          onTap: () async {
                            final url = Uri.parse(
                              'https://play.google.com/store/apps/details?id=in.sddev.ghost_gallery',
                            );
                            try {
                              if (await canLaunchUrl(url)) {
                                await launchUrl(
                                  url,
                                  mode: LaunchMode.externalApplication,
                                );
                              }
                            } catch (e) {
                              debugPrint('Error launching play store: $e');
                            }
                          },
                        ),
                        _actionTile(
                          icon: Icons.share_rounded,
                          title: 'Share App',
                          subtitle:
                              'Share Ghost Gallery with friends and family',
                          onTap: () {
                            Share.share(
                              'Check out Ghost Gallery - Your memories, haunted beautifully:\nhttps://play.google.com/store/apps/details?id=in.sddev.ghost_gallery',
                            );
                          },
                        ),
                      ]),
                      const SizedBox(height: 8),
                      _aboutFooter(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Section wrapper ────────────────────────────────────────────────────────
  Widget _section(String label, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 10),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.6,
                color: _isGhost ? GhostColors.blood.withAlpha(220) : _accent,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: _cardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _isGhost
                    ? GhostColors.blood.withAlpha(50)
                    : _divColor.withValues(alpha: 0.5),
                width: 1,
              ),
            ),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }

  Widget _divider() =>
      Divider(height: 1, color: _divColor, indent: 16, endIndent: 16);

  // ── Theme selector ─────────────────────────────────────────────────────────
  Widget _themeSelector() {
    final themes = [
      ('system', 'System', Icons.settings_brightness_outlined),
      ('light', 'Light', Icons.wb_sunny_outlined),
      ('dark', 'Dark', Icons.dark_mode_outlined),
      ('darcula', 'Darcula', Icons.nights_stay_outlined),
      ('ghost', '👻 Ghost', Icons.nights_stay_rounded),
    ];
    final isWatch = context.isWatch;
    final items = themes.map((t) {
      final active = _currentTheme == t.$1;
      final btnAccent = (t.$1 == 'ghost' || (t.$1 == 'system' && _isGhost))
          ? GhostColors.bloodBright
          : _accent;
      return GestureDetector(
        onTap: () {
          setState(() {
            _currentTheme = t.$1;
          });
          widget.onThemeChanged(t.$1);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOut,
          padding: EdgeInsets.symmetric(vertical: isWatch ? 6 : 10, horizontal: isWatch ? 8 : 4),
          decoration: BoxDecoration(
            color: active
                ? btnAccent.withAlpha(30)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: active ? btnAccent : _divColor,
              width: active ? 1.5 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                t.$3,
                size: isWatch ? 14 : 16,
                color: active ? btnAccent : _textSec,
              ),
              const SizedBox(height: 4),
              Text(
                t.$2,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: isWatch ? 9.5 : 10.5,
                  fontWeight: FontWeight.w600,
                  color: active ? btnAccent : _textSec,
                ),
              ),
            ],
          ),
        ),
      );
    }).toList();

    return Padding(
      padding: EdgeInsets.all(isWatch ? 4 : 8),
      child: isWatch
          ? Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: items.map((w) => SizedBox(width: 68, child: w)).toList(),
            )
          : Row(
              children: items
                  .map((w) => Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: w,
                        ),
                      ))
                  .toList(),
            ),
    );
  }

  // ── Storage overview ───────────────────────────────────────────────────────
  Widget _storageOverviewCard() {
    if (_loadingStorage) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: _accent),
          ),
        ),
      );
    }

    final total = _totalBytes ?? 0;
    final free = _freeBytes ?? 0;
    final images = _imageBytes ?? 0;
    final videos = _videoBytes ?? 0;
    final used = total - free;
    final media = images + videos;
    final otherUsed = (used - media).clamp(0, used);

    // Dynamic segment percentages
    final pctImg = total > 0 ? (images / total) : 0.0;
    final pctVid = total > 0 ? (videos / total) : 0.0;
    final pctOther = total > 0 ? (otherUsed / total) : 0.0;
    final pctFree = total > 0 ? (free / total) : 0.0;

    final double pctMedia = total > 0 ? (media / total).clamp(0.0, 1.0) : 0.0;
    final double pctImages = media > 0 ? (images / media).clamp(0.0, 1.0) : 0.0;

    // Custom themed colors for disk segments
    Color imgColor;
    Color vidColor;
    Color otherColor;
    Color freeColor;

    if (_isGhost) {
      imgColor = GhostColors.bloodBright;
      vidColor = GhostColors.purple;
      otherColor = const Color(0xFF381A4C);
      freeColor = const Color(0xFF16102B);
    } else if (_isDarcula) {
      imgColor = DarculaColors.accent;
      vidColor = DarculaColors.string_;
      otherColor = const Color(0xFF3C3F41);
      freeColor = const Color(0xFF222222);
    } else if (_currentTheme == 'dark') {
      imgColor = DarkColors.accent;
      vidColor = const Color(0xFF80CBC4);
      otherColor = const Color(0xFF37474F);
      freeColor = const Color(0xFF212121);
    } else {
      imgColor = const Color(0xFF6750A4);
      vidColor = const Color(0xFF03DAC6);
      otherColor = Colors.grey.shade400;
      freeColor = Colors.grey.shade200;
    }

    // Round flex calculations
    final flexImg = (pctImg * 1000).round();
    final flexVid = (pctVid * 1000).round();
    final flexOther = (pctOther * 1000).round();
    final flexFree = (pctFree * 1000).round();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header Row with Refresh ────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Storage Overview',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: _textPrim,
                  letterSpacing: 0.1,
                ),
              ),
              Row(
                children: [
                  Text(
                    '${_fmt(used)} of ${_fmt(total)} used',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: _textSec,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () {
                      setState(() => _loadingStorage = true);
                      _fetchStorageStats();
                    },
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: _accent.withAlpha(20),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.refresh, size: 14, color: _accent),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),

          // ── Premium Segmented Progress Bar ─────────────────────────────────
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              height: 12,
              color: freeColor,
              child: Row(
                children: [
                  if (flexImg > 0)
                    Expanded(
                      flex: flexImg,
                      child: Container(color: imgColor),
                    ),
                  if (flexVid > 0)
                    Expanded(
                      flex: flexVid,
                      child: Container(color: vidColor),
                    ),
                  if (flexOther > 0)
                    Expanded(
                      flex: flexOther,
                      child: Container(color: otherColor),
                    ),
                  if (flexFree > 0)
                    Expanded(
                      flex: flexFree,
                      child: Container(color: freeColor),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Grid Layout of Detailed Stats ──────────────────────────────────
          Row(
            children: [
              Expanded(
                child: _storageLegendTile(
                  imgColor,
                  'Photos',
                  _fmt(images),
                  pctImg,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _storageLegendTile(
                  vidColor,
                  'Videos',
                  _fmt(videos),
                  pctVid,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _storageLegendTile(
                  otherColor,
                  'Other',
                  _fmt(otherUsed),
                  pctOther,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _storageLegendTile(
                  freeColor,
                  'Free Space',
                  _fmt(free),
                  pctFree,
                ),
              ),
            ],
          ),

          // ── Summary Callout Panel ──────────────────────────────────────────
          if (total > 0) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: imgColor.withAlpha(15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: imgColor.withAlpha(40), width: 0.8),
              ),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome_outlined, size: 16, color: imgColor),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Gallery media occupies ${(pctMedia * 100).toStringAsFixed(1)}% of storage'
                      ' (${(pctImages * 100).toStringAsFixed(0)}% photos, ${((1 - pctImages) * 100).toStringAsFixed(0)}% videos)',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: _textPrim,
                        fontWeight: FontWeight.w500,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _detailedStorageBreakdownCard() {
    if (_loadingDetailedStorage) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: _accent),
          ),
        ),
      );
    }

    final totalDetailedBytes = _dbSqliteBytes +
        _dbObjectBoxBytes +
        _vaultBytes +
        _faceCacheBytes +
        _generatedMemoriesBytes +
        _otherCacheBytes +
        _otherDocBytes;

    Widget _detailRow(String name, int bytes, IconData icon, Color color, String desc) {
      final double percent = totalDetailedBytes > 0 ? (bytes / totalDetailedBytes) : 0.0;
      return InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => FileExplorerScreen(
                categoryName: name,
                appTheme: _currentTheme,
              ),
            ),
          ).then((_) {
            setState(() => _loadingDetailedStorage = true);
            _fetchDetailedAppStorage();
          });
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withAlpha(20),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 16),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          name,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: _textPrim,
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _fmt(bytes),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: _textPrim,
                              ),
                            ),
                            const SizedBox(width: 2),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 16,
                              color: _textSec,
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      desc,
                      style: TextStyle(
                        fontSize: 11,
                        color: _textSec,
                      ),
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: percent,
                        backgroundColor: _divColor,
                        valueColor: AlwaysStoppedAnimation<Color>(color),
                        minHeight: 3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Detailed Directory Analysis',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: _textPrim,
                  letterSpacing: 0.1,
                ),
              ),
              GestureDetector(
                onTap: () {
                  setState(() => _loadingDetailedStorage = true);
                  _fetchDetailedAppStorage();
                },
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: _accent.withAlpha(20),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.refresh, size: 14, color: _accent),
                ),
              ),
            ],
          ),
        ),
        _detailRow(
          'SQLite App Database',
          _dbSqliteBytes,
          Icons.storage_rounded,
          _isGhost ? GhostColors.bloodBright : Colors.blueAccent,
          'Saves main gallery entries, metadata, albums, and logs',
        ),
        _divider(),
        _detailRow(
          'Vector Database (ObjectBox)',
          _dbObjectBoxBytes,
          Icons.memory_rounded,
          _isGhost ? GhostColors.purple : Colors.deepPurpleAccent,
          'Stores local neural embeddings for faces & search indexing',
        ),
        _divider(),
        _detailRow(
          'Secure Vault Storage',
          _vaultBytes,
          Icons.vpn_key_rounded,
          _isGhost ? GhostColors.ectoplasm : Colors.greenAccent,
          'Holds biometrically encrypted photos and vault assets',
        ),
        _divider(),
        _detailRow(
          'Generated Memories Media',
          _generatedMemoriesBytes,
          Icons.auto_awesome_motion_rounded,
          Colors.pinkAccent,
          'Holds generated collage layouts, text cards, and slideshows',
        ),
        _divider(),
        _detailRow(
          'Cached Face Previews',
          _faceCacheBytes,
          Icons.face_retouching_natural_rounded,
          Colors.orangeAccent,
          'Stores cropped face thumbnails for custom clustering',
        ),
        _divider(),
        _detailRow(
          'Image Cache & Temp Files',
          _otherCacheBytes,
          Icons.cached_rounded,
          Colors.tealAccent,
          'Glide thumbnails, shared copies, and system cache',
        ),
        _divider(),
        _detailRow(
          'Configurations & Settings',
          _otherDocBytes,
          Icons.settings_suggest_rounded,
          Colors.grey,
          'User preferences, credentials, and app states',
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _storageLegendTile(
    Color color,
    String title,
    String value,
    double percent,
  ) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _cardBg.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _divColor, width: 0.8),
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 20,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 10,
                    color: _textSec,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: _textPrim,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '${(percent * 100).toStringAsFixed(1)}%',
            style: TextStyle(
              fontSize: 10.5,
              color: _textSec,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _legendChip(Color color, String label, String value) {
    return Expanded(
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 10, color: _textSec)),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _textPrim,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Cache tile ─────────────────────────────────────────────────────────────
  Widget _cacheTile() {
    final clearColor = _isGhost ? GhostColors.bloodBright : Colors.redAccent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Cache',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: _textPrim,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _cacheSize != null ? 'Size: $_cacheSize' : 'Calculating…',
                  style: TextStyle(fontSize: 12, color: _textSec),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: _clearingCache ? null : _clearCache,
            style: TextButton.styleFrom(
              foregroundColor: clearColor,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: clearColor, width: 1),
              ),
            ),
            child: _clearingCache
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: clearColor,
                    ),
                  )
                : const Text('Clear', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleFacesTask(bool value) async {
    setState(() => _facesTaskScheduled = value);
    if (value) {
      await MLProcessingService.instance.scheduleMidnightScanTask();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Daily midnight background scan scheduled! 👻'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } else {
      await MLProcessingService.instance.cancelMidnightScanTask();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Midnight background scan cancelled.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _instantRecluster() async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cardBg,
        title: Text('Instant Recluster', style: TextStyle(color: _textPrim)),
        content: Text(
          'This will delete all current face/people groupings and start a full re-clustering process immediately. This runs in the background. Are you sure?',
          style: TextStyle(color: _textSec),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: _textSec)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Recluster Now', style: TextStyle(color: _accentBright)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _reclustering = true);
    try {
      await MLProcessingService.instance.triggerFacesReclustering();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'All face data cleared. Face reclustering started immediately! 👻',
            ),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint('Recluster error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to trigger reclustering: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _reclustering = false);
      }
    }
  }

  Widget _reclusterFacesTile() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Midnight Background Scan',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: _textPrim,
                        fontSize: 14.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _facesTaskScheduled
                          ? 'Active: New files scan runs every night at 12:00 AM.'
                          : 'Paused: Midnight background scan is disabled.',
                      style: TextStyle(fontSize: 11.5, color: _textSec),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _facesTaskScheduled,
                onChanged: _reclustering ? null : _toggleFacesTask,
                activeThumbColor: _accentBright,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Full Library Re-cluster:',
                style: TextStyle(fontSize: 11.5, color: _textSec),
              ),
              TextButton(
                onPressed: _reclustering ? null : _instantRecluster,
                style: TextButton.styleFrom(
                  foregroundColor: _accentBright,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: _accentBright, width: 1),
                  ),
                ),
                child: _reclustering
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _accentBright,
                        ),
                      )
                    : const Text(
                        'Instant Recluster',
                        style: TextStyle(fontSize: 11),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _loadRecommendsStatus() async {
    try {
      final runs = await RecommendsPersistence.getAllLastRuns();
      final Map<String, String> temp = {};
      runs.forEach((key, value) {
        if (value != null) {
          temp[key.name] =
              "${value.month}/${value.day} ${value.hour}:${value.minute.toString().padLeft(2, '0')}";
        } else {
          temp[key.name] = "Never";
        }
      });
      final groups = await RecommendsPersistence.loadGroups();
      if (mounted) {
        setState(() {
          _lastRuns = temp;
          _savedGroups = groups;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadAutoScanStatus() async {
    try {
      final active = await _kAutoScanChannel.invokeMethod<bool>('getAutoScanStatus') ?? false;
      if (mounted) {
        setState(() {
          _autoScanEnabled = active;
        });
      }
    } catch (_) {}
  }

  Future<void> _toggleAutoScan(bool value) async {
    setState(() => _autoScanEnabled = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_scan_enabled', value);
    try {
      if (value) {
        await _kAutoScanChannel.invokeMethod('enableAutoScan');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Auto scanning enabled! 👻'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } else {
        await _kAutoScanChannel.invokeMethod('disableAutoScan');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Auto scanning disabled.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Failed to toggle auto scan: $e');
    }
  }

  Widget _autoScanTile() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Auto Scanning',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: _textPrim,
                    fontSize: 14.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _autoScanEnabled
                      ? 'Active: Scan for new media files in the background.'
                      : 'Paused: Background auto scanning is disabled.',
                  style: TextStyle(fontSize: 11.5, color: _textSec),
                ),
              ],
            ),
          ),
          Switch(
            value: _autoScanEnabled,
            onChanged: _toggleAutoScan,
            activeThumbColor: _accentBright,
          ),
        ],
      ),
    );
  }

  Future<void> _deleteGroup(String groupId) async {
    try {
      await RecommendsPersistence.deleteGroup(groupId);
      await _loadRecommendsStatus();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Memory group deleted! 🗑️'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('Delete group error: $e');
    }
  }

  Future<void> _triggerSingleType(RecommendType type) async {
    if (_runningRecommends) return;
    if (!_enableRecommendations) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Recommendation generation is disabled. Please enable it first!',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    setState(() {
      _runningRecommends = true;
      _recommendsProgress = 0.0;
      _recommendsMessage = 'Running ${type.name}...';
    });
    try {
      await DatabaseHelper.instance.setGenerationStatus(
        'generating',
        0.0,
        'Running ${type.name}...',
      );
      _startRecommendsPolling();

      await RecommendsAlgorithm.instance.runSingleType(type);
      await _loadRecommendsStatus();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Curated ${type.name} memories successfully! ✨'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Trigger ${type.name} failed: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      setState(() => _runningRecommends = false);
    }
  }

  Future<void> _triggerRecommendsRegen() async {
    if (!_enableRecommendations) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Recommendation generation is disabled. Please enable it first!',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    setState(() {
      _runningRecommends = true;
      _recommendsProgress = 0.0;
      _recommendsMessage = 'Starting scan...';
    });
    try {
      await DatabaseHelper.instance.setGenerationStatus(
        'generating',
        0.0,
        'Starting scan...',
      );
      _startRecommendsPolling();

      await RecommendsPersistence.clearAll();
      await RecommendsAlgorithm.instance.runIfNeeded(force: true);
      await _loadRecommendsStatus();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Recommends memory groups successfully cleared and regenerated! ✨',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Regenerate failed: $e')));
      }
      setState(() => _runningRecommends = false);
    }
  }

  IconData _getTypeIcon(RecommendType type) {
    switch (type) {
      case RecommendType.birthdaySpecial:
        return Icons.cake;
      case RecommendType.onThisDay:
        return Icons.calendar_today;
      case RecommendType.bestMoment:
        return Icons.star;
      case RecommendType.highlight:
        return Icons.person;
      case RecommendType.bestTrip:
        return Icons.flight_takeoff;
      case RecommendType.recapPreviousYear:
        return Icons.celebration;
    }
  }

  String _getTypeLabel(RecommendType type) {
    switch (type) {
      case RecommendType.birthdaySpecial:
        return "Birthday";
      case RecommendType.onThisDay:
        return "On This Day";
      case RecommendType.bestMoment:
        return "Best Moment";
      case RecommendType.highlight:
        return "Highlight";
      case RecommendType.bestTrip:
        return "Best Trip";
      case RecommendType.recapPreviousYear:
        return "Year Recap";
    }
  }

  Widget _faceThresholdTile() {
    final thresholdOptions = [1, 3, 5, 10, 20, 25, 30, 40, 45, 50];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Face Eligibility Threshold',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: _textPrim,
                    fontSize: 14.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Minimum photos required for a face to be shown as a person.',
                  style: TextStyle(fontSize: 11.5, color: _textSec),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: _cardBg.withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _divColor, width: 1),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: _faceEligibleThreshold,
                dropdownColor: _cardBg,
                icon: Icon(Icons.arrow_drop_down, color: _accentBright),
                style: TextStyle(
                  color: _textPrim,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
                onChanged: (int? newValue) async {
                  if (newValue != null) {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setInt('face_eligible_threshold', newValue);
                    setState(() {
                      _faceEligibleThreshold = newValue;
                    });
                  }
                },
                items: thresholdOptions.map<DropdownMenuItem<int>>((int value) {
                  return DropdownMenuItem<int>(
                    value: value,
                    child: Text('$value photos'),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _recommendationsToggleTile() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Recommendation Suggestions',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: _textPrim,
                    fontSize: 14.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _enableRecommendations
                      ? 'Suggestions will be generated daily.'
                      : 'Suggestion generation is paused.',
                  style: TextStyle(fontSize: 11.5, color: _textSec),
                ),
              ],
            ),
          ),
          Switch(
            value: _enableRecommendations,
            onChanged: (value) async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('enable_recommendations', value);
              setState(() {
                _enableRecommendations = value;
              });
            },
            activeThumbColor: _accentBright,
          ),
        ],
      ),
    );
  }

  Widget _deleteRecommendsTile() {
    final deleteColor = _isGhost ? GhostColors.bloodBright : Colors.redAccent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Delete All Recommendations',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: _textPrim,
                    fontSize: 14.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Clears all generated recommendation groups and files.',
                  style: TextStyle(fontSize: 11.5, color: _textSec),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () async {
              final bool? confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: _cardBg,
                  title: Text(
                    'Delete Recommendations?',
                    style: TextStyle(color: _textPrim),
                  ),
                  content: Text(
                    'This will delete all saved memory recommendations and their associated media files. Are you sure?',
                    style: TextStyle(color: _textSec),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text('Cancel', style: TextStyle(color: _textSec)),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(
                        'Delete',
                        style: TextStyle(color: deleteColor),
                      ),
                    ),
                  ],
                ),
              );
              if (confirm == true) {
                try {
                  final db = DatabaseHelper.instance;
                  final groups = await db.getRecommendGroups();
                  for (final g in groups) {
                    for (final item in g.items) {
                      final path = item.generatedFilePath;
                      if (path != null && path.isNotEmpty) {
                        final file = File(path);
                        if (await file.exists()) {
                          await file.delete();
                        }
                      }
                    }
                  }
                  await RecommendsPersistence.clearAll();
                  await _loadRecommendsStatus();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('All recommendations deleted! 🗑️'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                } catch (e) {
                  debugPrint('Failed to delete recommendations: $e');
                }
              }
            },
            style: TextButton.styleFrom(
              foregroundColor: deleteColor,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: deleteColor, width: 1),
              ),
            ),
            child: const Text('Delete All', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  // ── Action tile ────────────────────────────────────────────────────────────
  Widget _actionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: _accent, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: _textPrim,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: _textSec),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios_rounded, size: 13, color: _textSec),
          ],
        ),
      ),
    );
  }

  // ── Info row ───────────────────────────────────────────────────────────────
  Widget _infoRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(fontWeight: FontWeight.w600, color: _textPrim),
        ),
        Text(value, style: TextStyle(fontSize: 12, color: _textSec)),
      ],
    ),
  );

  // ── About footer — animated gradient Ghost Gallery text ────────────────────
  Widget _aboutFooter() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          AnimatedBuilder(
            animation: _gradCtrl,
            builder: (_, _) {
              final List<Color> colors = _isGhost
                  ? [
                      Color.lerp(
                        GhostColors.bloodBright,
                        GhostColors.purple,
                        _gradCtrl.value,
                      )!,
                      Color.lerp(
                        GhostColors.purple,
                        GhostColors.ectoplasm,
                        _gradCtrl.value,
                      )!,
                      Color.lerp(
                        GhostColors.ectoplasm,
                        GhostColors.bone,
                        1 - _gradCtrl.value,
                      )!,
                    ]
                  : _isDarcula
                  ? [
                      Color.lerp(
                        DarculaColors.accent,
                        DarculaColors.string_,
                        _gradCtrl.value,
                      )!,
                      Color.lerp(
                        DarculaColors.string_,
                        DarculaColors.accent2,
                        _gradCtrl.value,
                      )!,
                    ]
                  : [
                      Color.lerp(
                        const Color(0xFF6750A4),
                        const Color(0xFF9C6FFF),
                        _gradCtrl.value,
                      )!,
                      Color.lerp(
                        const Color(0xFF9C6FFF),
                        const Color(0xFF00E5FF),
                        _gradCtrl.value,
                      )!,
                    ];

              return ShaderMask(
                shaderCallback: (bounds) => LinearGradient(
                  colors: colors,
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  transform: _GradientShift(_gradCtrl.value),
                ).createShader(bounds),
                child: const Text(
                  '👻  Ghost Gallery',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                    color: Colors.white,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 6),
          Text(
            'Your memories, haunted beautifully.',
            style: TextStyle(fontSize: 12, color: _textSec, height: 1.5),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ── Sliding gradient shift ─────────────────────────────────────────────────────
class _GradientShift extends GradientTransform {
  final double progress;
  const _GradientShift(this.progress);

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(
      bounds.width * 0.3 * math.sin(progress * math.pi),
      0,
      0,
    );
  }
}
