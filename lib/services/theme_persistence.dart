import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:flutter/widgets.dart';

/// Persists which app theme is active: 'light', 'dark', 'darcula', 'ghost', or 'system'
class ThemePersistence {
  static const String _themeKey = 'app_theme_name';

  static Future<File> _getLegacyPrefFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/theme_pref.txt');
  }

  static Future<String> loadThemeName() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // 1. Try to load from SharedPreferences
      final content = prefs.getString(_themeKey);
      if (content == 'light' || content == 'dark' || content == 'darcula' || content == 'ghost' || content == 'system') {
        return content!;
      }

      // 2. Fallback / Migration: Try to load from legacy file
      try {
        final file = await _getLegacyPrefFile();
        if (await file.exists()) {
          final legacyContent = (await file.readAsString()).trim();
          if (legacyContent == 'light' || legacyContent == 'dark' || legacyContent == 'darcula' || legacyContent == 'ghost' || legacyContent == 'system') {
            // Save to SharedPreferences for future use
            await prefs.setString(_themeKey, legacyContent);
            // Try to clean up the legacy file
            try {
              await file.delete();
            } catch (_) {}
            return legacyContent;
          }
        }
      } catch (_) {}
    } catch (_) {}
    
    return 'system'; // Default to system theme
  }

  static Future<void> saveThemeName(String name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_themeKey, name);

      // Also try to remove legacy file if we write new theme
      try {
        final file = await _getLegacyPrefFile();
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    } catch (_) {}
  }

  // Legacy compatibility
  static Future<bool> loadThemeIsDark() async {
    final name = await loadThemeName();
    if (name == 'system') {
      return WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    }
    return name != 'light';
  }

  static Future<void> saveThemeIsDark(bool isDark) async {
    await saveThemeName(isDark ? 'ghost' : 'light');
  }
}
