import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ghost_gallery/screens/home_screen.dart';
import 'package:ghost_gallery/screens/greeting_screen.dart';
import 'package:ghost_gallery/services/ml_processing_service.dart';
import 'package:ghost_gallery/services/theme_persistence.dart';
import 'package:ghost_gallery/services/ui_preference_provider.dart';
import 'package:ghost_gallery/widgets/subscription_guard.dart';
import 'package:ghost_gallery/services/entitlement_service.dart';

// ── Ghost AMOLED Black & Putty White palette ──────────────────────────────────
const _kGhostBg        = Color(0xFF000000); // AMOLED true black
const _kGhostCard      = Color(0xFF121214); // AMOLED dark card bg
const _kGhostBorder    = Color(0xFF222226); // dark graphite border
const _kGhostBlood     = Color(0xFFEDEAE2); // putty white primary
const _kGhostBloodBright = Color(0xFFF5F3ED); // bright putty white highlight
const _kGhostText      = Color(0xFFEDEAE2); // putty white text
const _kGhostCyan      = Color(0xFF38BDF8);
const _kGhostPurple    = Color(0xFF9E9C96); // putty muted stone

// ── Dark (standard Material dark) ──────────────────────────────────────────────
const _kMaterialDarkBg     = Color(0xFF121212); // standard Material dark bg
const _kMaterialDarkSurface = Color(0xFF1E1E1E); // card/surface
const _kMaterialDarkBorder = Color(0xFF2C2C2C); // divider
const _kMaterialDarkAccent = Color(0xFF90CAF9); // Material blue 200
const _kMaterialDarkText   = Color(0xFFE0E0E0); // near-white text

// ── Darcula palette (pure JetBrains Darcula) ────────────────────────────────────
const _kDarkBg     = Color(0xFF000000); // true black
const _kDarkBg2    = Color(0xFF0D0D0D); // barely-off card
const _kDarkBorder = Color(0xFF2B2B2B); // classic Darcula border
const _kDarkAccent = Color(0xFF6897BB); // JetBrains Darcula blue
const _kDarkText   = Color(0xFFA9B7C6); // default Darcula text

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Cap Flutter's global image cache to prevent OOM on large media libraries
  PaintingBinding.instance.imageCache.maximumSize = 150;                // max 150 image entries
  PaintingBinding.instance.imageCache.maximumSizeBytes = 80 << 20;     // 80 MB ceiling

  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  
  final prefs = await SharedPreferences.getInstance();                                      
  final bool hasLaunchedBefore = prefs.getBool('ghost_has_launched_before') ?? false;
  final String initialTheme = await ThemePersistence.loadThemeName();

  await UIPreferenceProvider.instance.init();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: _kGhostBg,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  await EntitlementService.instance.init();
  MLProcessingService.instance.initializeWorkmanager();
  runApp(MyApp(
    hasLaunchedBefore: hasLaunchedBefore,
    initialTheme: initialTheme,
  ));
}

class MyApp extends StatefulWidget {
  final bool hasLaunchedBefore;
  final String initialTheme;
  const MyApp({
    super.key,
    required this.hasLaunchedBefore,
    required this.initialTheme,
  });
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  late String _appTheme;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appTheme = widget.initialTheme;
    _applySystemUI(_appTheme);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    if (_appTheme == 'system') {
      _applySystemUI(_appTheme);
    }
  }

  void setTheme(String name) {
    setState(() => _appTheme = name);
    ThemePersistence.saveThemeName(name);
    _applySystemUI(name);
  }

  void _applySystemUI(String name) {
    final bool isSystemDark = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    final bool dark = name == 'system' ? isSystemDark : name != 'light';
    final resolvedName = name == 'system' ? (isSystemDark ? 'ghost' : 'light') : name;
    final navBg = resolvedName == 'ghost'
        ? _kGhostBg
        : resolvedName == 'darcula'
            ? _kDarkBg
            : resolvedName == 'dark'
                ? _kMaterialDarkBg
                : Colors.white;
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: navBg,
      systemNavigationBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ghost Gallery',
      debugShowCheckedModeBanner: false,
      themeMode: _appTheme == 'system'
          ? ThemeMode.system
          : _appTheme == 'light'
              ? ThemeMode.light
              : ThemeMode.dark,
      theme: _lightTheme(),
      darkTheme: _appTheme == 'darcula'
          ? _darculaTheme()
          : _appTheme == 'dark'
              ? _darkTheme()
              : _ghostTheme(),
      home: widget.hasLaunchedBefore
          ? GalleryHomeScreen(
              appTheme: _appTheme,
              onThemeChanged: setTheme,
            )
          : GreetingScreen(
              appTheme: _appTheme,
              onThemeChanged: setTheme,
            ),
    );
  }

  ThemeData _lightTheme() => ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF9FAFB),
        cardColor: Colors.white,
        dividerColor: const Color(0xFFE5E7EB),
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF4F46E5), // Indigo
          primaryContainer: Color(0xFFEEF2F6),
          secondary: Color(0xFF0EA5E9), // Sky Blue
          surface: Colors.white,
          onSurface: Color(0xFF1F2937), // Dark grey text
          outline: Color(0xFFE5E7EB),
          outlineVariant: Color(0xFFD1D5DB),
        ),
        fontFamily: 'Roboto',
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF9FAFB),
          foregroundColor: Color(0xFF1F2937),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: const TextStyle(color: Color(0xFF1F2937), fontSize: 20, fontWeight: FontWeight.bold),
          contentTextStyle: const TextStyle(color: Color(0xFF4B5563), fontSize: 15),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Colors.white,
          indicatorColor: const Color(0xFF4F46E5).withAlpha(25),
          iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
                color: s.contains(WidgetState.selected)
                    ? const Color(0xFF4F46E5)
                    : const Color(0xFF6B7280),
              )),
          labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
                fontSize: 11,
                fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
                color: s.contains(WidgetState.selected)
                    ? const Color(0xFF4F46E5)
                    : const Color(0xFF6B7280),
              )),
        ),
      );

  // ── Dark — standard Material dark ────────────────────────────────────────────
  ThemeData _darkTheme() => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _kMaterialDarkBg,
        cardColor: _kMaterialDarkSurface,
        dividerColor: _kMaterialDarkBorder,
        colorScheme: const ColorScheme.dark(
          primary: _kMaterialDarkAccent,
          secondary: Color(0xFF80CBC4),
          surface: _kMaterialDarkSurface,
          onSurface: _kMaterialDarkText,
          surfaceContainerHighest: Color(0xFF2A2A2A),
          outline: _kMaterialDarkBorder,
        ),
        fontFamily: 'Roboto',
        appBarTheme: const AppBarTheme(
          backgroundColor: _kMaterialDarkBg,
          foregroundColor: _kMaterialDarkText,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: _kMaterialDarkSurface,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: const TextStyle(color: _kMaterialDarkText, fontSize: 20, fontWeight: FontWeight.bold),
          contentTextStyle: const TextStyle(color: Color(0xFFCCCCCC), fontSize: 15),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: _kMaterialDarkSurface,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: _kMaterialDarkSurface,
          indicatorColor: _kMaterialDarkAccent.withAlpha(40),
          iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
                color: s.contains(WidgetState.selected)
                    ? _kMaterialDarkAccent
                    : const Color(0xFF757575),
              )),
          labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
                fontSize: 11,
                fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
                color: s.contains(WidgetState.selected)
                    ? _kMaterialDarkAccent
                    : const Color(0xFF757575),
              )),
        ),
      );

  // ── Darcula — pure JetBrains black ─────────────────────────────────────────
  ThemeData _darculaTheme() => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _kDarkBg,
        cardColor: _kDarkBg2,
        dividerColor: _kDarkBorder,
        colorScheme: const ColorScheme.dark(
          primary: _kDarkAccent,
          secondary: Color(0xFF8888AA),
          surface: _kDarkBg2,
          onSurface: _kDarkText,
          surfaceContainerHighest: Color(0xFF1A1A1A),
          outline: _kDarkBorder,
        ),
        fontFamily: 'Roboto',
        appBarTheme: const AppBarTheme(
          backgroundColor: _kDarkBg,
          foregroundColor: _kDarkText,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: _kDarkBg2,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: const TextStyle(color: _kDarkText, fontSize: 20, fontWeight: FontWeight.bold),
          contentTextStyle: const TextStyle(color: Color(0xFFBBBBBB), fontSize: 15),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: _kDarkBg2,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: _kDarkBg2,
          indicatorColor: _kDarkAccent.withAlpha(40),
          iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
                color: s.contains(WidgetState.selected)
                    ? _kDarkAccent
                    : const Color(0xFF606366),
              )),
          labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
                fontSize: 11,
                fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
                color: s.contains(WidgetState.selected)
                    ? _kDarkAccent
                    : const Color(0xFF606366),
              )),
        ),
      );

  // ── Ghost — AMOLED black and Putty white ──────────────────────────────────
  ThemeData _ghostTheme() => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _kGhostBg,
        cardColor: _kGhostCard,
        dividerColor: _kGhostBorder,
        colorScheme: ColorScheme.dark(
          primary: _kGhostBlood,
          onPrimary: const Color(0xFF000000),
          primaryContainer: const Color(0xFF1E1E22),
          onPrimaryContainer: _kGhostBloodBright,
          secondary: _kGhostPurple,
          onSecondary: const Color(0xFF000000),
          surface: _kGhostCard,
          onSurface: _kGhostText,
          surfaceContainerHighest: const Color(0xFF18181B),
          outline: _kGhostBorder,
          outlineVariant: const Color(0xFF2E2E34),
        ),
        fontFamily: 'Roboto',
        appBarTheme: const AppBarTheme(
          backgroundColor: _kGhostBg,
          foregroundColor: _kGhostText,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: _kGhostCard,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: const TextStyle(color: _kGhostBloodBright, fontSize: 20, fontWeight: FontWeight.bold),
          contentTextStyle: const TextStyle(color: Color(0xFFC8C6BE), fontSize: 15),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: _kGhostCard,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: _kGhostCard,
          indicatorColor: _kGhostBlood.withAlpha(35),
          iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
                color: s.contains(WidgetState.selected)
                    ? _kGhostBloodBright
                    : const Color(0xFF787672),
              )),
          labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
                fontSize: 11,
                fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
                color: s.contains(WidgetState.selected)
                    ? _kGhostBloodBright
                    : const Color(0xFF787672),
              )),
        ),
      );
}
