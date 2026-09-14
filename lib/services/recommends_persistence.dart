// ═══════════════════════════════════════════════════════════════════════════
// recommends_persistence.dart
//
// Saves and loads RecommendGroup lists via SQLite tables in DatabaseHelper.
// Tracks the last run timestamp per type to avoid re-running too often.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/recommend_models.dart';
import 'database_helper.dart';

class RecommendsPersistence {
  static const _kLastRunKey = 'recommends_last_run_v1';

  // ── Save ────────────────────────────────────────────────────────────────

  static Future<void> saveGroups(List<RecommendGroup> groups) async {
    try {
      final db = DatabaseHelper.instance;
      // Auto-prune expired groups first
      await db.clearExpiredRecommendGroups();
      // Insert new/updated groups
      for (final g in groups) {
        await db.insertRecommendGroup(g);
      }
    } catch (e) {
      debugPrint('RecommendsPersistence: saveGroups error: $e');
    }
  }

  // ── Load (auto-prune expired) ────────────────────────────────────────────

  static Future<List<RecommendGroup>> loadGroups() async {
    try {
      final db = DatabaseHelper.instance;
      // Auto-prune expired
      await db.clearExpiredRecommendGroups();
      final groups = await db.getRecommendGroups();
      return groups.where((g) => g.items.isNotEmpty).toList();
    } catch (e) {
      debugPrint('RecommendsPersistence: loadGroups error: $e');
      return [];
    }
  }

  // ── Upsert (add or replace a group with the same id) ────────────────────

  static Future<void> upsertGroup(RecommendGroup group) async {
    try {
      final db = DatabaseHelper.instance;
      await db.insertRecommendGroup(group);
    } catch (e) {
      debugPrint('RecommendsPersistence: upsertGroup error: $e');
    }
  }

  // ── Append multiple groups (skips duplicates by id) ─────────────────────

  static Future<void> appendGroups(List<RecommendGroup> newGroups) async {
    try {
      final db = DatabaseHelper.instance;
      for (final g in newGroups) {
        await db.insertRecommendGroup(g);
      }
    } catch (e) {
      debugPrint('RecommendsPersistence: appendGroups error: $e');
    }
  }

  // ── Delete a single group (debug) ───────────────────────────────────────

  static Future<void> deleteGroup(String groupId) async {
    try {
      final db = DatabaseHelper.instance;
      await db.deleteRecommendGroup(groupId);
    } catch (e) {
      debugPrint('RecommendsPersistence: deleteGroup error: $e');
    }
  }

  // ── Delete all groups of a given type (debug) ────────────────────────────

  static Future<void> deleteGroupsByType(RecommendType type) async {
    try {
      final db = DatabaseHelper.instance;
      final groups = await db.getRecommendGroups();
      for (final g in groups) {
        if (g.type == type) {
          await db.deleteRecommendGroup(g.id);
        }
      }
    } catch (e) {
      debugPrint('RecommendsPersistence: deleteGroupsByType error: $e');
    }
  }

  // ── Clear ALL groups ────────────────────────────────────────────────────

  static Future<void> clearAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kLastRunKey);
      final db = DatabaseHelper.instance;
      await db.clearAllRecommendGroups();
    } catch (e) {
      debugPrint('RecommendsPersistence: clearAll error: $e');
    }
  }

  // ── Last-run tracking ───────────────────────────────────────────────────

  /// Returns the last time the given type was run, or null.
  static Future<DateTime?> getLastRun(RecommendType type) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kLastRunKey);
      if (raw == null) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final ts = map[type.name] as String?;
      if (ts == null) return null;
      return DateTime.tryParse(ts);
    } catch (_) {
      return null;
    }
  }

  /// Records the current time as the last run for the given type.
  static Future<void> recordRun(RecommendType type) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kLastRunKey) ?? '{}';
      final map = jsonDecode(raw) as Map<String, dynamic>;
      map[type.name] = DateTime.now().toIso8601String();
      await prefs.setString(_kLastRunKey, jsonEncode(map));
    } catch (e) {
      debugPrint('RecommendsPersistence: recordRun error: $e');
    }
  }

  /// Returns true if the type has not been run in the last [hours] hours.
  static Future<bool> shouldRun(RecommendType type, {int hours = 6}) async {
    final last = await getLastRun(type);
    if (last == null) return true;
    return DateTime.now().difference(last).inHours >= hours;
  }

  /// Returns a map of RecommendType → last run DateTime (for debug display).
  static Future<Map<RecommendType, DateTime?>> getAllLastRuns() async {
    final result = <RecommendType, DateTime?>{};
    for (final type in RecommendType.values) {
      result[type] = await getLastRun(type);
    }
    return result;
  }
}
