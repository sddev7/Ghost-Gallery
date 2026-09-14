// ═══════════════════════════════════════════════════════════════════════════
// recommends_algorithm.dart — Part 1
//
// Core service for the memory recommendation engine.
// Filters media items into groups, scores them, and handles generation
// of slideshow videos, collages, and text overlays.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/recommend_models.dart';
import 'database_helper.dart';
import 'recommends_persistence.dart';
import 'recommends_notification_service.dart';
import 'device_media_scanner.dart';
import 'ml_processing_service.dart';
import '../widgets/face_preview.dart';

class RecommendsAlgorithm {
  static final RecommendsAlgorithm instance = RecommendsAlgorithm._();
  RecommendsAlgorithm._();

  bool _isProcessing = false;
  bool get isProcessing => _isProcessing;

  final Random _random = Random();

  // ── Quality Scoring ──────────────────────────────────────────────────────

  double calculateScore(Map<String, dynamic> item, DateTime now) {
    // Megapixels (width * height)
    final w = item['width'] as int? ?? 1;
    final h = item['height'] as int? ?? 1;
    final mp = (w * h) / 1000000.0;
    final mpScore = (mp / 12.0).clamp(0.0, 1.0) * 0.3; // max 12MP weight

    // Star rating (0-5)
    final rating = item['rating'] as int? ?? 0;
    final ratingScore = (rating / 5.0).clamp(0.0, 1.0) * 0.4;

    // HDR / Portrait modes (indicated in subjects/album/tags)
    final category = item['album_category'] as String? ?? '';
    final isFav = item['flags'] != null && ((item['flags'] as int) & 1) != 0;
    final favScore = isFav ? 0.15 : 0.0;

    // Recency weight (slight bias towards recent years, but not too strong)
    final ts = item['date_timestamp'] as int? ?? 0;
    final diffDays = now.difference(DateTime.fromMillisecondsSinceEpoch(ts)).inDays.abs();
    final recencyScore = (1.0 - (diffDays / (365 * 10)).clamp(0.0, 1.0)) * 0.15;

    return mpScore + ratingScore + favScore + recencyScore;
  }

  double calculateWeightedScore(Map<String, dynamic> item, DateTime now, Map<String, double> multipliers) {
    final baseScore = calculateScore(item, now);
    final multiplier = multipliers[item['id']] ?? 1.0;
    return baseScore * multiplier;
  }

  // ── Trigger Engine ────────────────────────────────────────────────────────

  Future<void> runIfNeeded({bool force = false}) async {
    if (_isProcessing) return;

    final prefs = await SharedPreferences.getInstance();
    final isEnabled = prefs.getBool('enable_recommendations') ?? true;
    if (!isEnabled) {
      debugPrint('RecommendsAlgorithm: Skipped. Recommendation generation is disabled in settings.');
      return;
    }

    // 1. Must not run if any ML process like Tier 3 and 4 is running (HIGH Priority)
    final isMlRunning = await MLProcessingService.isAnyMlProcessingRunning();
    if (isMlRunning) {
      debugPrint('RecommendsAlgorithm: Deferring run because ML process (Tier 3/4) is running.');
      return;
    }

    // 2. Once run in a day (unless forced)
    final now = DateTime.now();
    if (!force) {
      final lastRunMs = prefs.getInt('last_recommends_daily_run') ?? 0;
      final lastRun = DateTime.fromMillisecondsSinceEpoch(lastRunMs);
      if (now.difference(lastRun).inHours < 24) {
        debugPrint('RecommendsAlgorithm: Skipped. Already run in the last 24 hours.');
        return;
      }
    }

    _isProcessing = true;
    final db = DatabaseHelper.instance;
    try {
      await db.clearExpiredRecommendGroups();

      debugPrint('RecommendsAlgorithm: Starting memory trigger scans...');
      await db.setGenerationStatus('generating', 0.05, 'Scanning library for new media...');
      await Future.delayed(const Duration(milliseconds: 50));
      
      try {
        await DeviceMediaScanner.instance.scanAndSyncDeviceMedia(force: force);
      } catch (e) {
        debugPrint('RecommendsAlgorithm: Media scan failed: $e');
      }
      
      await db.setGenerationStatus('generating', 0.15, 'Analyzing library media...');
      await Future.delayed(const Duration(milliseconds: 50));
      
      final allMedia = await db.getAllMediaItemsLite();
      final allPeople = await db.getAllPeople();
      final allFaces = await db.getAllFaces();

      final currentGen = await MediaPriorityManager.incrementGeneration();
      final multipliers = await MediaPriorityManager.getMultipliers(currentGen);

      final generatedGroups = <RecommendGroup>[];

      // 1. Birthday Special
      await db.setGenerationStatus('generating', 0.25, 'Checking birthday specials...');
      await Future.delayed(const Duration(milliseconds: 50));
      for (final person in allPeople) {
        final dobStr = person['dob'] as String?;
        if (dobStr == null || dobStr.isEmpty) continue;
        final dob = DateTime.tryParse(dobStr);
        if (dob == null) continue;

        final birthdayThisYear = DateTime(now.year, dob.month, dob.day);
        final diffDays = birthdayThisYear.difference(DateTime(now.year, now.month, now.day)).inDays;

        // Trigger today or tomorrow (pre-birthday alert)
        if (diffDays == 0 || diffDays == 1) {
          final group = await _generateBirthdayGroup(person, allMedia, allFaces, now, multipliers, currentGen, isPreBirthday: diffDays == 1);
          if (group != null) {
            generatedGroups.add(group);
            // Schedule notification
            final notifService = RecommendsNotificationService.instance;
            String? imagePath;
            for (final item in group.items) {
              if (!item.isVideo && item.displayPath != null && item.displayPath!.isNotEmpty) {
                imagePath = item.displayPath;
                break;
              }
            }
            await notifService.scheduleBirthdayReminder(
              personId: person['id'] as String,
              personName: person['name'] as String,
              dob: dob,
              imagePath: imagePath,
              groupName: group.title,
            );
            await notifService.scheduleBirthdayOnDay(
              personId: person['id'] as String,
              personName: person['name'] as String,
              dob: dob,
              imagePath: imagePath,
              groupName: group.title,
            );
          }
        }
      }
      await RecommendsPersistence.recordRun(RecommendType.birthdaySpecial);

      // 2. On This Day
      await db.setGenerationStatus('generating', 0.40, 'Curating "On This Day" memories...');
      await Future.delayed(const Duration(milliseconds: 50));
      final onThisDayGroup = await _generateOnThisDayGroup(allMedia, now, multipliers, currentGen);
      if (onThisDayGroup != null) generatedGroups.add(onThisDayGroup);
      await RecommendsPersistence.recordRun(RecommendType.onThisDay);

      // 3. Best Moment
      await db.setGenerationStatus('generating', 0.55, 'Finding best moment highlights...');
      await Future.delayed(const Duration(milliseconds: 50));
      final bestMomentGroup = await _generateBestMomentGroup(allMedia, now, multipliers, currentGen);
      if (bestMomentGroup != null) generatedGroups.add(bestMomentGroup);
      await RecommendsPersistence.recordRun(RecommendType.bestMoment);

      // 4. Highlight
      await db.setGenerationStatus('generating', 0.70, 'Assembling person highlights...');
      await Future.delayed(const Duration(milliseconds: 50));
      final highlightGroups = await _generateHighlightGroups(allPeople, allMedia, allFaces, now, multipliers, currentGen);
      generatedGroups.addAll(highlightGroups);
      await RecommendsPersistence.recordRun(RecommendType.highlight);

      // 5. Best Trip
      await db.setGenerationStatus('generating', 0.85, 'Grouping best trips...');
      await Future.delayed(const Duration(milliseconds: 50));
      final tripGroup = await _generateBestTripGroup(allMedia, now, multipliers, currentGen);
      if (tripGroup != null) generatedGroups.add(tripGroup);
      await RecommendsPersistence.recordRun(RecommendType.bestTrip);

      // 6. Recap Previous Year (January only, 4 times a month on days 1, 8, 15, 22)
      if ((now.month == 1 && (now.day == 1 || now.day == 8 || now.day == 15 || now.day == 22)) ) {
        await db.setGenerationStatus('generating', 0.95, 'Compiling yearly recap...');
        await Future.delayed(const Duration(milliseconds: 50));
        final recapGroup = await _generateYearRecapGroup(allMedia, now, multipliers, currentGen);
        if (recapGroup != null) generatedGroups.add(recapGroup);
        await RecommendsPersistence.recordRun(RecommendType.recapPreviousYear);
      }

      // 7. Fallback Generic Highlights (if force is true, or if no other groups were generated and we have media)
      if (generatedGroups.isEmpty && allMedia.isNotEmpty) {
        final fallbackGroup = await _generateGenericHighlightGroup(allMedia, now, multipliers, currentGen);
        if (fallbackGroup != null) {
          generatedGroups.add(fallbackGroup);
        }
      }

      if (generatedGroups.isNotEmpty) {
        await RecommendsPersistence.appendGroups(generatedGroups);
        debugPrint('RecommendsAlgorithm: Generated ${generatedGroups.length} new recommendation groups.');
        
        // Notify user about new memories
        final nonBirthdayGroups = generatedGroups.where((g) => g.type != RecommendType.birthdaySpecial).toList();
        if (nonBirthdayGroups.isNotEmpty) {
          final group = nonBirthdayGroups.first;
          String? imagePath;
          for (final item in group.items) {
            if (!item.isVideo && item.displayPath != null && item.displayPath!.isNotEmpty) {
              imagePath = item.displayPath;
              break;
            }
          }
          await RecommendsNotificationService.instance.showNewMemoryAlert(
            title: "✨ New Memories Await!",
            body: "We curated some beautiful highlights from your library. Check them out under Recommends!",
            imagePath: imagePath,
            groupName: group.title,
          );
        }
      }
      
      await prefs.setInt('last_recommends_daily_run', DateTime.now().millisecondsSinceEpoch);
      await db.setGenerationStatus('completed', 1.0, 'Generation completed!');
    } catch (e, stack) {
      debugPrint('RecommendsAlgorithm: runIfNeeded error: $e\n$stack');
      await db.setGenerationStatus('failed', 0.0, 'Failed: $e');
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> runSingleType(RecommendType type) async {
    if (_isProcessing) return;
    final prefs = await SharedPreferences.getInstance();
    final isEnabled = prefs.getBool('enable_recommendations') ?? true;
    if (!isEnabled) {
      debugPrint('RecommendsAlgorithm: Skipped. Recommendation generation is disabled in settings.');
      return;
    }
    _isProcessing = true;
    final db = DatabaseHelper.instance;
    try {
      final now = DateTime.now();
      debugPrint('RecommendsAlgorithm: Starting manual single type run for ${type.name}...');
      await db.setGenerationStatus('generating', 0.05, 'Scanning library for new media...');
      await Future.delayed(const Duration(milliseconds: 50));
      
      try {
        await DeviceMediaScanner.instance.scanAndSyncDeviceMedia(force: true);
      } catch (e) {
        debugPrint('RecommendsAlgorithm: Media scan failed: $e');
      }
      
      await db.setGenerationStatus('generating', 0.15, 'Analyzing library media...');
      await Future.delayed(const Duration(milliseconds: 50));
      
      final allMedia = await db.getAllMediaItemsLite();
      final allPeople = await db.getAllPeople();
      final allFaces = await db.getAllFaces();

      final currentGen = await MediaPriorityManager.incrementGeneration();
      final multipliers = await MediaPriorityManager.getMultipliers(currentGen);

      final generatedGroups = <RecommendGroup>[];

      switch (type) {
        case RecommendType.birthdaySpecial:
          await db.setGenerationStatus('generating', 0.40, 'Checking birthday specials...');
          Map<String, dynamic>? targetPerson;
          for (final p in allPeople) {
            final pid = p['id'] as String;
            final faceCount = allFaces.where((f) => f['person_id'] == pid).length;
            if (faceCount >= 3) {
              targetPerson = p;
              break;
            }
          }
          if (targetPerson != null) {
            final group = await _generateBirthdayGroup(targetPerson, allMedia, allFaces, now, multipliers, currentGen, isPreBirthday: false);
            if (group != null) {
              generatedGroups.add(group);
            }
          }
          break;
        case RecommendType.onThisDay:
          await db.setGenerationStatus('generating', 0.40, 'Curating "On This Day" memories...');
          final group = await _generateOnThisDayGroup(allMedia, now, multipliers, currentGen);
          if (group != null) generatedGroups.add(group);
          break;
        case RecommendType.bestMoment:
          await db.setGenerationStatus('generating', 0.40, 'Finding best moment highlights...');
          final group = await _generateBestMomentGroup(allMedia, now, multipliers, currentGen);
          if (group != null) generatedGroups.add(group);
          break;
        case RecommendType.highlight:
          await db.setGenerationStatus('generating', 0.40, 'Assembling person highlights...');
          final groups = await _generateHighlightGroups(allPeople, allMedia, allFaces, now, multipliers, currentGen);
          generatedGroups.addAll(groups);
          break;
        case RecommendType.bestTrip:
          await db.setGenerationStatus('generating', 0.40, 'Grouping best trips...');
          final group = await _generateBestTripGroup(allMedia, now, multipliers, currentGen);
          if (group != null) generatedGroups.add(group);
          break;
        case RecommendType.recapPreviousYear:
          await db.setGenerationStatus('generating', 0.40, 'Compiling yearly recap...');
          final group = await _generateYearRecapGroup(allMedia, now, multipliers, currentGen);
          if (group != null) generatedGroups.add(group);
          break;
      }

      // Fallback in case there is not enough matching data, so we can preview the layout:
      if (generatedGroups.isEmpty && allMedia.isNotEmpty) {
        await db.setGenerationStatus('generating', 0.80, 'Creating preview for ${type.name}...');
        final sortedMedia = List<Map<String, dynamic>>.from(allMedia);
        sortedMedia.sort((a, b) => calculateWeightedScore(b, now, multipliers).compareTo(calculateWeightedScore(a, now, multipliers)));
        final selectedMedia = sortedMedia.take(6).toList();
        final groupId = 'demo_${type.name}_${now.millisecondsSinceEpoch}';

        // Mark preview items as selected
        final selectedIds = selectedMedia.map((m) => m['id'] as String).toList();
        await MediaPriorityManager.markSelected(selectedIds, currentGen);
        
        String title = '';
        String subtitle = '';
        switch (type) {
          case RecommendType.birthdaySpecial:
            title = "🎂 Happy Birthday (Demo)";
            subtitle = "Demo birthday special memory collection";
            break;
          case RecommendType.onThisDay:
            title = "📅 On This Day (Demo)";
            subtitle = "Demo on this day memory collection";
            break;
          case RecommendType.bestMoment:
            title = "✨ Best Moment (Demo)";
            subtitle = "Demo best moment memory collection";
            break;
          case RecommendType.highlight:
            title = "Highlight (Demo)";
            subtitle = "Demo person highlight memory collection";
            break;
          case RecommendType.bestTrip:
            title = "✈️ Trip to Paradise (Demo)";
            subtitle = "Demo travel highlights memory collection";
            break;
          case RecommendType.recapPreviousYear:
            final prevYear = now.year - 1;
            title = "🎉 Year Recap: $prevYear (Demo)";
            subtitle = "Demo previous year recap memory collection";
            break;
        }

        final items = await _createRecommendItems(
          selectedMedia,
          groupId,
          textOverlayTemplate: "$title ✨",
          type: type,
        );
        if (items.isNotEmpty) {
          generatedGroups.add(RecommendGroup(
            id: groupId,
            type: type,
            title: title,
            subtitle: subtitle,
            generatedAt: now,
            expiresAt: now.add(const Duration(hours: 48)),
            items: items,
          ));
        }
      }

      if (generatedGroups.isNotEmpty) {
        await RecommendsPersistence.appendGroups(generatedGroups);
        await RecommendsPersistence.recordRun(type);
        debugPrint('RecommendsAlgorithm: Generated ${generatedGroups.length} group(s) manually.');
      }
      
      await db.setGenerationStatus('completed', 1.0, 'Generation completed!');
    } catch (e, stack) {
      debugPrint('RecommendsAlgorithm: runSingleType error: $e\n$stack');
      await db.setGenerationStatus('failed', 0.0, 'Failed: $e');
    } finally {
      _isProcessing = false;
    }
  }

  // ── Specific Trigger Generation ──────────────────────────────────────────

  Future<RecommendGroup?> _generateBirthdayGroup(
    Map<String, dynamic> person,
    List<Map<String, dynamic>> allMedia,
    List<Map<String, dynamic>> allFaces,
    DateTime now,
    Map<String, double> multipliers,
    int currentGen, {
    required bool isPreBirthday,
  }) async {
    final personId = person['id'] as String;
    final name = person['name'] as String;

    // Filter media containing person face
    final mediaIds = allFaces
        .where((f) => f['person_id'] == personId)
        .map((f) => f['media_id'] as String)
        .toSet();

    final matches = allMedia.where((m) => mediaIds.contains(m['id'])).toList();
    if (matches.length < 3) return null; // need at least some photos

    // Sort by quality
    matches.sort((a, b) => calculateWeightedScore(b, now, multipliers).compareTo(calculateWeightedScore(a, now, multipliers)));
    final selectedMedia = matches.take(8).toList();

    // Mark items as selected
    final selectedIds = selectedMedia.map((m) => m['id'] as String).toList();
    await MediaPriorityManager.markSelected(selectedIds, currentGen);

    final groupId = 'birthday_${personId}_${now.year}';
    final items = await _createRecommendItems(
      selectedMedia,
      groupId,
      textOverlayTemplate: "Happy Birthday $name! 🎂",
      type: RecommendType.birthdaySpecial,
    );

    final title = isPreBirthday ? "🎂 Birthday is Coming!" : "🎉 Happy Birthday $name!";
    final subtitle = isPreBirthday ? "Tomorrow is $name's special day" : "Here's a memory slideshow we made for $name";

    return RecommendGroup(
      id: groupId,
      type: RecommendType.birthdaySpecial,
      title: title,
      subtitle: subtitle,
      generatedAt: now,
      expiresAt: isPreBirthday 
          ? DateTime(now.year, now.month, now.day, 23, 59, 59).add(const Duration(days: 1))
          : DateTime(now.year, now.month, now.day, 23, 59, 59),
      items: items,
    );
  }

  Future<RecommendGroup?> _generateOnThisDayGroup(
    List<Map<String, dynamic>> allMedia,
    DateTime now,
    Map<String, double> multipliers,
    int currentGen,
  ) async {
    List<Map<String, dynamic>> matches = [];
    int windowDays = 0;

    // Media matching close to today's day, either in past years (any month) or previous months of the current year.
    // Loop through windows of +/- 0 up to +/- 3 days.
    for (int window = 0; window <= 3; window++) {
      matches = allMedia.where((m) {
        final ts = m['date_timestamp'] as int?;
        if (ts == null) return false;
        final dt = DateTime.fromMillisecondsSinceEpoch(ts);

        // Day difference check (e.g. if dt.day is close to now.day)
        final dayDiff = (dt.day - now.day).abs();
        if (dayDiff > window) return false;

        // Must be either:
        // A) A past year (any month)
        // B) The current year, but a previous month
        if (dt.year < now.year) {
          return true;
        } else if (dt.year == now.year) {
          return dt.month < now.month;
        }
        return false;
      }).toList();

      if (matches.length >= 3) {
        windowDays = window;
        break;
      }
    }

    if (matches.length < 3) return null;

    // Group by year to get variety
    final Map<int, List<Map<String, dynamic>>> byYear = {};
    for (final m in matches) {
      final dt = DateTime.fromMillisecondsSinceEpoch(m['date_timestamp'] as int);
      byYear.putIfAbsent(dt.year, () => []).add(m);
    }

    final selectedMedia = <Map<String, dynamic>>[];
    final yearsSorted = byYear.keys.toList()..sort((a, b) => b.compareTo(a));

    for (final year in yearsSorted) {
      final yearMedia = byYear[year]!;
      yearMedia.sort((a, b) => calculateWeightedScore(b, now, multipliers).compareTo(calculateWeightedScore(a, now, multipliers)));
      selectedMedia.addAll(yearMedia.take(2)); // pick best 2 of each year
      if (selectedMedia.length >= 8) break;
    }

    if (selectedMedia.isEmpty) return null;

    // Mark items as selected
    final selectedIds = selectedMedia.map((m) => m['id'] as String).toList();
    await MediaPriorityManager.markSelected(selectedIds, currentGen);

    final groupId = 'on_this_day_${now.month}_${now.day}_${now.year}';
    final items = await _createRecommendItems(
      selectedMedia,
      groupId,
      textOverlayTemplate: "On This Day 📅",
      type: RecommendType.onThisDay,
    );

    final yearsDiffs = selectedMedia.map((m) {
      final ts = m['date_timestamp'] as int;
      final dt = DateTime.fromMillisecondsSinceEpoch(ts);
      return now.year - dt.year;
    }).toSet().toList()..sort();

    String title = "📅 On This Day";
    String subtitle = "Relive memories from today in past years";

    if (yearsDiffs.isNotEmpty) {
      final nonZeroDiffs = yearsDiffs.where((diff) => diff > 0).toList();
      if (nonZeroDiffs.isEmpty) {
        title = "📅 Memories from Months Ago";
        subtitle = "Relive moments from previous months on this day";
      } else if (nonZeroDiffs.length == 1) {
        final x = nonZeroDiffs.first;
        title = "On this day $x ${x == 1 ? 'year' : 'years'} ago";
        subtitle = "Relive memories from ${now.year - x}";
      } else {
        final last = nonZeroDiffs.last;
        final others = nonZeroDiffs.sublist(0, nonZeroDiffs.length - 1);
        title = "On this day ${others.join(', ')} & $last years ago";
        
        final yearsList = nonZeroDiffs.map((diff) => (now.year - diff).toString()).toList();
        final lastYear = yearsList.last;
        final otherYears = yearsList.sublist(0, yearsList.length - 1);
        subtitle = "Relive memories from ${otherYears.join(', ')} and $lastYear";
      }
    }

    return RecommendGroup(
      id: groupId,
      type: RecommendType.onThisDay,
      title: title,
      subtitle: subtitle,
      generatedAt: now,
      expiresAt: DateTime(now.year, now.month, now.day, 23, 59, 59),
      items: items,
    );
  }

  Future<RecommendGroup?> _generateBestMomentGroup(
    List<Map<String, dynamic>> allMedia,
    DateTime now,
    Map<String, double> multipliers,
    int currentGen,
  ) async {
    if (allMedia.isEmpty) return null;

    // Pick a random media item and get its date as target
    final randomItem = allMedia[_random.nextInt(allMedia.length)];
    final ts = randomItem['date_timestamp'] as int?;
    if (ts == null) return null;
    final targetDate = DateTime.fromMillisecondsSinceEpoch(ts);

    List<Map<String, dynamic>> matches = [];
    int foundDelta = 0;
    
    // Scan outward ±0, ±1, ..., ±7 days
    for (int delta = 0; delta <= 7; delta++) {
      final start = DateTime(targetDate.year, targetDate.month, targetDate.day).subtract(Duration(days: delta));
      final end = DateTime(targetDate.year, targetDate.month, targetDate.day).add(Duration(days: delta, hours: 23, minutes: 59, seconds: 59));
      
      matches = allMedia.where((m) {
        final t = m['date_timestamp'] as int?;
        if (t == null) return false;
        final dt = DateTime.fromMillisecondsSinceEpoch(t);
        return dt.isAfter(start.subtract(const Duration(seconds: 1))) &&
               dt.isBefore(end.add(const Duration(seconds: 1)));
      }).toList();
      
      if (matches.length >= 4) {
        foundDelta = delta;
        break;
      }
    }

    if (matches.length < 4) return null;

    matches.sort((a, b) => calculateWeightedScore(b, now, multipliers).compareTo(calculateWeightedScore(a, now, multipliers)));
    final selectedMedia = matches.take(8).toList();

    // Mark items as selected
    final selectedIds = selectedMedia.map((m) => m['id'] as String).toList();
    await MediaPriorityManager.markSelected(selectedIds, currentGen);

    final dateFormatted = "${_getMonthName(targetDate.month)} ${targetDate.day}, ${targetDate.year}";
    final displayTitle = foundDelta == 0 
        ? "✨ Best Moment on $dateFormatted"
        : "✨ Best Moment around $dateFormatted";
    final textOverlay = foundDelta == 0 
        ? "Best Moment on $dateFormatted ✨"
        : "Best Moment around $dateFormatted ✨";

    final groupId = 'best_moment_${targetDate.year}_${targetDate.month}_${targetDate.day}_$currentGen';
    final items = await _createRecommendItems(
      selectedMedia,
      groupId,
      textOverlayTemplate: textOverlay,
      type: RecommendType.bestMoment,
    );

    return RecommendGroup(
      id: groupId,
      type: RecommendType.bestMoment,
      title: displayTitle,
      subtitle: foundDelta == 0 
          ? "Looking back at a special day" 
          : "Looking back at a special few days",
      generatedAt: now,
      expiresAt: DateTime(now.year, now.month, now.day, 23, 59, 59),
      items: items,
    );
  }

  Future<List<RecommendGroup>> _generateHighlightGroups(
    List<Map<String, dynamic>> allPeople,
    List<Map<String, dynamic>> allMedia,
    List<Map<String, dynamic>> allFaces,
    DateTime now,
    Map<String, double> multipliers,
    int currentGen,
  ) async {
    final groups = <RecommendGroup>[];

    // Pick top people with >= configured face eligibility threshold
    final prefs = await SharedPreferences.getInstance();
    final threshold = prefs.getInt('face_eligible_threshold') ?? 10;

    final Map<String, int> faceCounts = {};
    for (final f in allFaces) {
      final pid = f['person_id'] as String?;
      if (pid != null) {
        faceCounts[pid] = (faceCounts[pid] ?? 0) + 1;
      }
    }

    final eligiblePeople = allPeople
        .where((p) => (faceCounts[p['id']] ?? 0) >= threshold)
        .toList();

    // Limit to max 2 highlight groups per run to not spam
    eligiblePeople.shuffle(_random);
    final selectedPeople = eligiblePeople.take(2);

    for (final person in selectedPeople) {
      final personId = person['id'] as String;
      final name = person['name'] as String;

      final mediaIds = allFaces
          .where((f) => f['person_id'] == personId)
          .map((f) => f['media_id'] as String)
          .toSet();

      final matches = allMedia.where((m) => mediaIds.contains(m['id'])).toList();
      if (matches.length < 5) continue;

      matches.sort((a, b) => calculateWeightedScore(b, now, multipliers).compareTo(calculateWeightedScore(a, now, multipliers)));
      final selectedMedia = matches.take(8).toList();

      // Resolve person profile picture and face bounding box
      String? profilePath = person['cover_image'] as String?;
      final coverX = person['cover_x'] as int? ?? 0;
      final coverY = person['cover_y'] as int? ?? 0;
      final coverW = person['cover_w'] as int? ?? 0;
      final coverH = person['cover_h'] as int? ?? 0;
      Rect? profileFaceRect;

      if (profilePath != null && profilePath.isNotEmpty && File(profilePath).existsSync()) {
        if (coverW > 0 && coverH > 0) {
          profileFaceRect = Rect.fromLTWH(coverX.toDouble(), coverY.toDouble(), coverW.toDouble(), coverH.toDouble());
        }
      } else {
        profilePath = null;
      }

      if (profilePath == null || profileFaceRect == null) {
        final personFaces = allFaces.where((f) => f['person_id'] == personId).toList();
        for (final pf in personFaces) {
          final mId = pf['media_id'] as String?;
          final bboxStr = pf['bounding_box'] as String? ?? '';
          final parts = bboxStr.split(',');
          if (mId != null && parts.length >= 4) {
            final bx = double.tryParse(parts[0]) ?? 0;
            final by = double.tryParse(parts[1]) ?? 0;
            final bw = double.tryParse(parts[2]) ?? 0;
            final bh = double.tryParse(parts[3]) ?? 0;
            if (bw > 0 && bh > 0) {
              final mItem = allMedia.firstWhere(
                (m) => m['id'] == mId,
                orElse: () => <String, dynamic>{},
              );
              final p = mItem['path'] as String?;
              if (p != null && p.isNotEmpty && File(p).existsSync()) {
                profilePath = p;
                profileFaceRect = Rect.fromLTWH(bx, by, bw, bh);
                break;
              }
            }
          }
        }
      }

      // Ensure profile picture is at index 0 for highlight recommendation
      if (profilePath != null) {
        final existingIdx = selectedMedia.indexWhere((m) => m['path'] == profilePath);
        if (existingIdx >= 0) {
          final item = selectedMedia.removeAt(existingIdx);
          selectedMedia.insert(0, item);
        } else {
          final mItem = allMedia.firstWhere(
            (m) => m['path'] == profilePath,
            orElse: () => <String, dynamic>{
              'id': 'profile_$personId',
              'path': profilePath,
              'media_type': 'image',
              'width': coverW > 0 ? coverW : 300,
              'height': coverH > 0 ? coverH : 300,
            },
          );
          selectedMedia.insert(0, mItem);
          if (selectedMedia.length > 8) {
            selectedMedia.removeLast();
          }
        }
      }

      // Mark items as selected
      final selectedIds = selectedMedia.map((m) => m['id'] as String).toList();
      await MediaPriorityManager.markSelected(selectedIds, currentGen);

      final groupId = 'highlight_${personId}_${now.year}';
      final items = await _createRecommendItems(
        selectedMedia,
        groupId,
        textOverlayTemplate: "Highlight: $name 👤",
        type: RecommendType.highlight,
        profileFaceRect: profileFaceRect,
      );

      groups.add(RecommendGroup(
        id: groupId,
        type: RecommendType.highlight,
        title: "Highlight: $name",
        subtitle: "Celebrating sweet memories with $name",
        generatedAt: now,
        expiresAt: now.add(const Duration(hours: 48)),
        items: items,
      ));
    }

    return groups;
  }

  Future<RecommendGroup?> _generateBestTripGroup(
    List<Map<String, dynamic>> allMedia,
    DateTime now,
    Map<String, double> multipliers,
    int currentGen,
  ) async {
    // Find items in the last 12 months with a locality tag
    final twelveMonthsAgo = now.subtract(const Duration(days: 365));
    final locItems = allMedia.where((m) {
      final ts = m['date_timestamp'] as int?;
      if (ts == null) return false;
      final dt = DateTime.fromMillisecondsSinceEpoch(ts);
      final hasLoc = m['locality'] != null && (m['locality'] as String).isNotEmpty;
      return hasLoc && dt.isAfter(twelveMonthsAgo);
    }).toList();

    if (locItems.length < 5) return null;

    // Cluster by locality name
    final Map<String, List<Map<String, dynamic>>> clusters = {};
    for (final m in locItems) {
      final loc = m['locality'] as String;
      clusters.putIfAbsent(loc, () => []).add(m);
    }

    // Pick largest cluster
    final sortedLocs = clusters.keys.toList()
      ..sort((a, b) => clusters[b]!.length.compareTo(clusters[a]!.length));

    final bestLoc = sortedLocs.first;
    final tripMedia = clusters[bestLoc]!;

    if (tripMedia.length < 4) return null;

    tripMedia.sort((a, b) => calculateWeightedScore(b, now, multipliers).compareTo(calculateWeightedScore(a, now, multipliers)));
    final selectedMedia = tripMedia.take(10).toList();

    // Mark items as selected
    final selectedIds = selectedMedia.map((m) => m['id'] as String).toList();
    await MediaPriorityManager.markSelected(selectedIds, currentGen);

    final groupId = 'trip_${bestLoc.replaceAll(' ', '_')}_${now.year}';
    final items = await _createRecommendItems(
      selectedMedia,
      groupId,
      textOverlayTemplate: "Best Trip to $bestLoc ✈️",
      type: RecommendType.bestTrip,
    );

    return RecommendGroup(
      id: groupId,
      type: RecommendType.bestTrip,
      title: "✈️ Trip to $bestLoc",
      subtitle: "Remembering your adventures in $bestLoc",
      generatedAt: now,
      expiresAt: now.add(const Duration(hours: 48)),
      items: items,
    );
  }

  Future<RecommendGroup?> _generateYearRecapGroup(
    List<Map<String, dynamic>> allMedia,
    DateTime now,
    Map<String, double> multipliers,
    int currentGen,
  ) async {
    // Find all years in the library
    final Map<int, List<Map<String, dynamic>>> byYear = {};
    for (final m in allMedia) {
      final ts = m['date_timestamp'] as int?;
      if (ts == null) continue;
      final dt = DateTime.fromMillisecondsSinceEpoch(ts);
      if (dt.year <= now.year) {
        byYear.putIfAbsent(dt.year, () => []).add(m);
      }
    }

    if (byYear.isEmpty) return null;

    // Find the best year to recap (most recent year that has at least 4 items)
    int? targetYear;
    final sortedYears = byYear.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final yr in sortedYears) {
      if (byYear[yr]!.length >= 4) {
        targetYear = yr;
        break;
      }
    }

    if (targetYear == null) return null;
    final recapItems = byYear[targetYear]!;

    // Group by month
    final Map<int, List<Map<String, dynamic>>> byMonth = {};
    for (final m in recapItems) {
      final dt = DateTime.fromMillisecondsSinceEpoch(m['date_timestamp'] as int);
      byMonth.putIfAbsent(dt.month, () => []).add(m);
    }

    final selectedMedia = <Map<String, dynamic>>[];
    for (int month = 1; month <= 12; month++) {
      final monthMedia = byMonth[month];
      if (monthMedia != null && monthMedia.isNotEmpty) {
        monthMedia.sort((a, b) => calculateWeightedScore(b, now, multipliers).compareTo(calculateWeightedScore(a, now, multipliers)));
        selectedMedia.add(monthMedia.first); // best photo from this month
      }
    }

    // If we have fewer than 4 months, let's just pick the top scoring items from the target year
    if (selectedMedia.length < 4) {
      selectedMedia.clear();
      final sortedItems = List<Map<String, dynamic>>.from(recapItems);
      sortedItems.sort((a, b) => calculateWeightedScore(b, now, multipliers).compareTo(calculateWeightedScore(a, now, multipliers)));
      selectedMedia.addAll(sortedItems.take(8));
    }

    if (selectedMedia.isEmpty) return null;

    // Mark items as selected
    final selectedIds = selectedMedia.map((m) => m['id'] as String).toList();
    await MediaPriorityManager.markSelected(selectedIds, currentGen);

    final groupId = 'year_recap_$targetYear';
    final items = await _createRecommendItems(
      selectedMedia,
      groupId,
      textOverlayTemplate: "Recap: $targetYear 🎉",
      type: RecommendType.recapPreviousYear,
    );

    return RecommendGroup(
      id: groupId,
      type: RecommendType.recapPreviousYear,
      title: "🎉 Year Recap: $targetYear",
      subtitle: "A journey through the highlights of the year $targetYear",
      generatedAt: now,
      expiresAt: now.add(const Duration(hours: 48)),
      items: items,
    );
  }

  Future<RecommendGroup?> _generateGenericHighlightGroup(
    List<Map<String, dynamic>> allMedia,
    DateTime now,
    Map<String, double> multipliers,
    int currentGen,
  ) async {
    if (allMedia.isEmpty) return null;

    // Sort by quality score
    final sortedMedia = List<Map<String, dynamic>>.from(allMedia);
    sortedMedia.sort((a, b) => calculateWeightedScore(b, now, multipliers).compareTo(calculateWeightedScore(a, now, multipliers)));

    // Take up to 8 best photos
    final selectedMedia = sortedMedia.take(8).toList();
    if (selectedMedia.isEmpty) return null;

    // Mark items as selected
    final selectedIds = selectedMedia.map((m) => m['id'] as String).toList();
    await MediaPriorityManager.markSelected(selectedIds, currentGen);

    final groupId = 'generic_highlights_${now.millisecondsSinceEpoch}';
    final items = await _createRecommendItems(
      selectedMedia,
      groupId,
      textOverlayTemplate: "Sweet Memories ✨",
      type: RecommendType.highlight,
    );

    if (items.isEmpty) return null;

    return RecommendGroup(
      id: groupId,
      type: RecommendType.highlight,
      title: "✨ Highlight Collection",
      subtitle: "A collection of beautiful moments from your library",
      generatedAt: now,
      expiresAt: now.add(const Duration(hours: 48)),
      items: items,
    );
  }

  String _getMonthName(int month) {
    const names = [
      '', 'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return names[month];
  }

  String _formatOnThisDayText(int timestamp, DateTime now) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final yearsDiff = now.year - dt.year;
    final monthsDiff = (now.year - dt.year) * 12 + now.month - dt.month;
    
    if (yearsDiff == 0) {
      if (monthsDiff == 1) {
        return "On This Day, 1 Month Ago 📅";
      } else if (monthsDiff > 1) {
        return "On This Day, $monthsDiff Months Ago 📅";
      } else {
        return "On This Day 📅";
      }
    } else {
      if (dt.month == now.month) {
        if (yearsDiff == 1) {
          return "On This Day, 1 Year Ago 📅";
        } else {
          return "On This Day, $yearsDiff Years Ago 📅";
        }
      } else {
        if (monthsDiff == 12) {
          return "On This Day, 1 Year Ago 📅";
        } else {
          if (monthsDiff < 24) {
            return "On This Day, $monthsDiff Months Ago 📅";
          } else {
            final y = monthsDiff ~/ 12;
            final m = monthsDiff % 12;
            if (m == 0) {
              return "On This Day, $y Years Ago 📅";
            } else {
              return "On This Day, $y ${y == 1 ? 'Year' : 'Years'} & $m ${m == 1 ? 'Month' : 'Months'} Ago 📅";
            }
          }
        }
      }
    }
  }

  // ── Media Generation & Sequencing ──────────────────────────────────────────

  Future<List<RecommendItem>> _createRecommendItems(
    List<Map<String, dynamic>> mediaList,
    String groupId, {
    required String textOverlayTemplate,
    required RecommendType type,
    Rect? profileFaceRect,
  }) async {
    final items = <RecommendItem>[];
    final appDocs = await getApplicationDocumentsDirectory();
    final outDir = Directory('${appDocs.path}/ghost_recommends/$groupId');
    if (!outDir.existsSync()) {
      outDir.createSync(recursive: true);
    }

    // Filter only valid image items from library for generation input
    final imageItems = mediaList.where((m) {
      final path = m['path'] as String? ?? '';
      final isImg = m['media_type'] == 'image' ||
          path.toLowerCase().endsWith('.jpg') == true ||
          path.toLowerCase().endsWith('.jpeg') == true ||
          path.toLowerCase().endsWith('.png') == true;
      return isImg && File(path).existsSync();
    }).toList();

    if (imageItems.isEmpty) return [];

    // 1. Generate Collage Image if images count > 5
    String? collagePath;
    if (imageItems.length > 5) {
      final headingText = textOverlayTemplate.replaceFirst('{years}', 'Some');
      collagePath = await _generateCollage(imageItems, outDir.path, headingText);
    }

    // 2. Prepare slideshow inputs (source images + collage as final slide)
    final slidePaths = imageItems.map((m) => m['path'] as String).toList();
    if (collagePath != null) {
      slidePaths.add(collagePath);
    }

    // 3. Generate Slideshow Video
    final videoPath = await _generateSlideshow(
      slidePaths,
      outDir.path,
      type,
      profileFaceRect: profileFaceRect,
      groupId: groupId,
    );
    if (videoPath != null) {
      items.add(RecommendItem(
        id: '${groupId}_video',
        itemType: RecommendItemType.generatedVideo,
        generatedFilePath: videoPath,
      ));
    }

    // 4. Generate 1-2 Text + Photo Cards
    final textCardPhotos = List<Map<String, dynamic>>.from(imageItems)..shuffle(_random);
    final count = min(textCardPhotos.length, 2);
    for (int i = 0; i < count; i++) {
      final photo = textCardPhotos[i];
      String text;
      if (type == RecommendType.onThisDay && photo['date_timestamp'] != null) {
        text = _formatOnThisDayText(photo['date_timestamp'] as int, DateTime.now());
      } else {
        final yearsDiff = photo['date_timestamp'] != null
            ? DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(photo['date_timestamp'] as int)).inDays ~/ 365
            : 0;
        text = textOverlayTemplate.replaceFirst('{years}', yearsDiff > 0 ? '$yearsDiff' : 'Few');
      }
      
      final textCardPath = await _generateTextOverlayCard(
        photo['path'] as String,
        outDir.path,
        text,
        i,
      );

      if (textCardPath != null) {
        items.add(RecommendItem(
          id: '${groupId}_text_$i',
          itemType: RecommendItemType.textPhoto,
          sourceItemId: photo['id'] as String?,
          sourceItemPath: photo['path'] as String?,
          originAlbumName: photo['album_name'] as String?,
          generatedFilePath: textCardPath,
          textOverlay: text,
        ));
      }
    }

    // 5. Add Collage as standalone final card for viewing/saving if generated
    if (collagePath != null) {
      items.add(RecommendItem(
        id: '${groupId}_collage',
        itemType: RecommendItemType.collagePhoto,
        generatedFilePath: collagePath,
      ));
    }

    // 6. ALWAYS add the original library media items to the group's items list
    for (final media in mediaList) {
      final path = media['path'] as String? ?? '';
      if (path.isEmpty || !File(path).existsSync()) continue;
      final itemId = '${groupId}_lib_${media['id']}';
      items.add(RecommendItem(
        id: itemId,
        itemType: RecommendItemType.libraryMedia,
        sourceItemId: media['id'] as String?,
        sourceItemPath: media['path'] as String?,
        originAlbumName: media['album_name'] as String?,
      ));
    }

    return items;
  }

  // ── Canvas-based Collage Composer ───────────────────────────────────────

  Future<String?> _generateCollage(
    List<Map<String, dynamic>> items,
    String outDir,
    String headingText,
  ) async {
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 720, 1280));

      // 1. Draw elegant dark gradient background
      final paintBg = Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          const Offset(0, 1280),
          [const Color(0xFF0D0D12), const Color(0xFF161520)],
        );
      canvas.drawRect(const Rect.fromLTWH(0, 0, 720, 1280), paintBg);

      // 2. Lay out top 5 images in grid slots
      final count = min(items.length, 5);
      final uiImages = <ui.Image>[];
      for (int i = 0; i < count; i++) {
        final img = await _loadUiImage(items[i]['path'] as String);
        if (img != null) uiImages.add(img);
      }

      if (uiImages.isNotEmpty) {
        // Simple grid offsets for 5 images:
        // Slot 0 (Featured): top half (720x600)
        // Slot 1,2,3,4: bottom 2x2 (360x300 each, from Y=600 to 1200)
        final double topHeight = 600.0;
        final double gridY = 620.0;
        final double cellW = 345.0;
        final double cellH = 280.0;

        // Draw Slot 0
        _drawCenterCrop(canvas, uiImages[0],  Rect.fromLTWH(20, 150, 680, topHeight - 130));

        // Draw Slots 1-4
        final offsets = [
          Offset(20, gridY),
          Offset(375, gridY),
          Offset(20, gridY + cellH + 20),
          Offset(375, gridY + cellH + 20),
        ];

        for (int i = 1; i < uiImages.length; i++) {
          if (i - 1 < offsets.length) {
            _drawCenterCrop(
              canvas,
              uiImages[i],
              Rect.fromLTWH(offsets[i - 1].dx, offsets[i - 1].dy, cellW, cellH),
            );
          }
        }
      }

      // 3. Draw heading with a random system font
      final fontFamilies = ['sans-serif', 'serif', 'monospace', 'sans-serif-condensed'];
      final selectedFont = fontFamilies[_random.nextInt(fontFamilies.length)];

      final textPainter = TextPainter(
        text: TextSpan(
          text: headingText,
          style: TextStyle(
            color: Colors.white,
            fontSize: 34,
            fontWeight: FontWeight.w900,
            fontFamily: selectedFont,
            letterSpacing: 1.2,
            shadows: [
              Shadow(
                color: Colors.black.withValues(alpha: 0.8),
                offset: const Offset(2, 2),
                blurRadius: 8,
              ),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      );

      textPainter.layout(maxWidth: 680);
      textPainter.paint(canvas, Offset(360 - textPainter.width / 2, 70));

      // Save to file
      final picture = recorder.endRecording();
      final image = await picture.toImage(720, 1280);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData != null) {
        final collageFile = File('$outDir/collage.png');
        await collageFile.writeAsBytes(byteData.buffer.asUint8List());
        return collageFile.path;
      }
    } catch (e, stack) {
      debugPrint("RecommendsAlgorithm: _generateCollage failed: $e\n$stack");
    }
    return null;
  }

  // ── Canvas-based Text + Photo Composer ───────────────────────────────────

  Future<String?> _generateTextOverlayCard(
    String photoPath,
    String outDir,
    String text,
    int index,
  ) async {
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 720, 1280));

      final img = await _loadUiImage(photoPath);
      if (img == null) return null;

      // Draw main image filled
      _drawCenterCrop(canvas, img, const Rect.fromLTWH(0, 0, 720, 1280));

      // Draw subtle gradient overlay at bottom to read text better
      final gradientPaint = Paint()
        ..shader = ui.Gradient.linear(
          const Offset(0, 800),
          const Offset(0, 1280),
          [Colors.transparent, Colors.black.withValues(alpha: 0.85)],
        );
      canvas.drawRect(const Rect.fromLTWH(0, 800, 720, 480), gradientPaint);

      // Random text styles
      final alignment = _random.nextBool() ? Alignment.bottomCenter : Alignment.center;
      final fontFamilies = ['sans-serif', 'serif', 'monospace', 'sans-serif-medium'];
      final selectedFont = fontFamilies[_random.nextInt(fontFamilies.length)];
      final fontSize = 28.0 + _random.nextInt(10);

      final textPainter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: Colors.white,
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
            fontFamily: selectedFont,
            shadows: [
              Shadow(
                color: Colors.black.withValues(alpha: 0.6),
                offset: const Offset(1, 1),
                blurRadius: 4,
              ),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      );

      textPainter.layout(maxWidth: 640);

      // Render text inside a beautiful rounded card box
      final boxW = textPainter.width + 40;
      final boxH = textPainter.height + 30;
      final double boxY = alignment == Alignment.center ? 640 - boxH / 2 : 1100 - boxH / 2;
      final double boxX = 360 - boxW / 2;

      final cardPaint = Paint()
        ..color = Colors.black.withValues(alpha: 0.6)
        ..style = PaintingStyle.fill;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(boxX, boxY, boxW, boxH), const Radius.circular(16)),
        cardPaint,
      );

      // Draw border accent
      final borderPaint = Paint()
        ..color = const Color(0xFFB388FF).withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(boxX, boxY, boxW, boxH), const Radius.circular(16)),
        borderPaint,
      );

      textPainter.paint(canvas, Offset(boxX + 20, boxY + 15));

      final picture = recorder.endRecording();
      final resultImage = await picture.toImage(720, 1280);
      final byteData = await resultImage.toByteData(format: ui.ImageByteFormat.png);
      if (byteData != null) {
        final cardFile = File('$outDir/text_card_$index.png');
        await cardFile.writeAsBytes(byteData.buffer.asUint8List());
        return cardFile.path;
      }
    } catch (e, stack) {
      debugPrint("RecommendsAlgorithm: _generateTextOverlayCard failed: $e\n$stack");
    }
    return null;
  }

  Future<List<double>> _detectBeats(String audioPath) async {
    final tempDir = await getTemporaryDirectory();
    final wavPath = '${tempDir.path}/temp_audio_${DateTime.now().millisecondsSinceEpoch}.wav';
    try {
      // Convert MP3/AAC/etc. to 16kHz mono 16-bit WAV
      final ffmpegCmd = '-y -i "$audioPath" -ar 16000 -ac 1 -c:a pcm_s16le "$wavPath"';
      debugPrint("RecommendsAlgorithm: Converting audio to WAV for beat detection...");
      final session = await FFmpegKit.execute(ffmpegCmd);
      final returnCode = await session.getReturnCode();
      
      if (!ReturnCode.isSuccess(returnCode)) {
        debugPrint("RecommendsAlgorithm: Audio WAV conversion failed: $returnCode");
        return [];
      }
      
      final wavFile = File(wavPath);
      if (!wavFile.existsSync()) return [];
      
      final bytes = await wavFile.readAsBytes();
      
      // Parse WAV format (PCM 16-bit mono 16000Hz)
      int dataIdx = -1;
      for (int i = 0; i < bytes.length - 4; i++) {
        if (bytes[i] == 0x64 && // 'd'
            bytes[i + 1] == 0x61 && // 'a'
            bytes[i + 2] == 0x74 && // 't'
            bytes[i + 3] == 0x61) { // 'a'
          dataIdx = i;
          break;
        }
      }
      if (dataIdx == -1) {
        dataIdx = 40; // Fallback RIFF offset
      }
      
      final int pcmStart = dataIdx + 8;
      if (pcmStart >= bytes.length) return [];
      
      final samples = <int>[];
      final byteData = ByteData.sublistView(bytes, pcmStart);
      for (int i = 0; i < byteData.lengthInBytes - 1; i += 2) {
        samples.add(byteData.getInt16(i, Endian.little));
      }
      
      final sampleRate = 16000;
      final double windowDuration = 0.1; // 100ms
      final int windowSize = (sampleRate * windowDuration).round();
      final List<double> energies = [];
      
      for (int i = 0; i < samples.length - windowSize; i += windowSize) {
        double sum = 0.0;
        for (int j = 0; j < windowSize; j++) {
          final double s = samples[i + j].toDouble() / 32768.0;
          sum += s * s;
        }
        energies.add(sum / windowSize);
      }
      
      final List<double> beatTimes = [];
      final int localWindow = 15; // 1.5 seconds local window
      
      for (int i = 0; i < energies.length; i++) {
        int start = max(0, i - localWindow);
        int end = min(energies.length, i + localWindow + 1);
        double localSum = 0.0;
        for (int j = start; j < end; j++) {
          localSum += energies[j];
        }
        double localMean = localSum / (end - start);
        
        final e = energies[i];
        final prev = i > 0 ? energies[i - 1] : 0.0;
        final next = i < energies.length - 1 ? energies[i + 1] : 0.0;
        
        if (e > localMean * 1.3 && e >= prev && e >= next) {
          final double beatTime = i * windowDuration;
          if (beatTimes.isEmpty || (beatTime - beatTimes.last) >= 1.5) {
            beatTimes.add(beatTime);
          }
        }
      }
      
      debugPrint("RecommendsAlgorithm: Detected ${beatTimes.length} beats.");
      return beatTimes;
    } catch (e, stack) {
      debugPrint("RecommendsAlgorithm: _detectBeats failed: $e\n$stack");
      return [];
    } finally {
      try {
        final f = File(wavPath);
        if (f.existsSync()) {
          f.deleteSync();
        }
      } catch (_) {}
    }
  }

  // ── FFmpeg Slideshow Video compiler ──────────────────────────────────────

  Future<String?> _generateSlideshow(
    List<String> imagePaths,
    String outDir,
    RecommendType type, {
    String? customAudioPath,
    Rect? profileFaceRect,
    String? groupId,
  }) async {
    try {
      final tempDir = await getTemporaryDirectory();
      
      // Load all images into memory as ui.Image to avoid disk reads during frame rendering loop
      final loadedImages = <ui.Image>[];
      final isOldList = <bool>[];
      for (final path in imagePaths) {
        final img = await _loadUiImage(path);
        if (img != null) {
          loadedImages.add(img);
          bool isOld = false;
          try {
            final file = File(path);
            final mTime = file.lastModifiedSync();
            final yearsAgo = DateTime.now().difference(mTime).inDays / 365.0;
            isOld = yearsAgo > 3.0;
          } catch (_) {}
          isOldList.add(isOld);
        }
      }
      
      if (loadedImages.isEmpty) {
        debugPrint("RecommendsAlgorithm: No valid images loaded for slideshow.");
        return null;
      }

      // Pre-generate Ken Burns params and transition styles
      final rand = Random();
      Rect? faceRect = profileFaceRect;
      if (faceRect == null && type == RecommendType.highlight && groupId != null) {
        faceRect = await _resolveHighlightFaceRect(groupId);
      }

      final kbParams = <KenBurnsParams>[];
      for (int i = 0; i < loadedImages.length; i++) {
        final img = loadedImages[i];
        if (i == 0 && type == RecommendType.highlight && faceRect != null) {
          kbParams.add(KenBurnsParams.faceZoomInOut(
            faceRect: faceRect,
            imageWidth: img.width.toDouble(),
            imageHeight: img.height.toDouble(),
          ));
        } else {
          kbParams.add(KenBurnsParams.random(rand));
        }
      }
      final transTypes = List<int>.generate(loadedImages.length, (_) => rand.nextInt(4));

      String? tempAudioPath;
      if (customAudioPath != null) {
        tempAudioPath = customAudioPath;
      } else {
        // Find appropriate audio track based on RecommendType
        String? audioAsset;
        switch (type) {
          case RecommendType.birthdaySpecial:
            audioAsset = 'assets/audio/ambient_nostalgic.mp3';
            break;
          case RecommendType.highlight:
            audioAsset = 'assets/audio/ambient_nostalgic_2.mp3';
            break;
          case RecommendType.onThisDay:
          case RecommendType.recapPreviousYear:
            audioAsset = 'assets/audio/ambient_soft.mp3';
            break;
          case RecommendType.bestMoment:
          case RecommendType.bestTrip:
            audioAsset = 'assets/audio/ambient_upbeat.mp3';
            break;
        }

        tempAudioPath = await _copyAssetToTemp(audioAsset);
      }

      // Detect beat timestamps
      List<double> beatTimes = [];
      if (tempAudioPath != null && File(tempAudioPath).existsSync()) {
        beatTimes = await _detectBeats(tempAudioPath);
      }

      // Fallback/synthetic beats if none detected
      if (beatTimes.length < loadedImages.length + 1) {
        beatTimes.clear();
        for (int i = 0; i <= loadedImages.length + 5; i++) {
          beatTimes.add((i + 1) * 2.5);
        }
      }

      // Calculate slide timings matching detected beats
      final slideDurations = <double>[];
      final slideStarts = <double>[];
      final slideEnds = <double>[];
      
      double currentStart = 0.0;
      for (int i = 0; i < loadedImages.length; i++) {
        final duration = beatTimes[i] - currentStart;
        slideStarts.add(currentStart);
        slideDurations.add(duration);
        slideEnds.add(beatTimes[i]);
        currentStart = beatTimes[i];
      }
      
      final totalDuration = currentStart;
      double ss = 0.0;
      if (tempAudioPath != null && File(tempAudioPath).existsSync()) {
        final audioDuration = await _getAudioDuration(tempAudioPath);
        if (audioDuration > totalDuration) {
          final maxStart = audioDuration - totalDuration;
          ss = Random().nextDouble() * maxStart;
        }
      }
      final fps = 15;
      final totalFrames = (totalDuration * fps).round();
      final transitionDuration = 0.6; // 600ms transitions

      final rawVideoFile = File('${tempDir.path}/raw_video_${DateTime.now().millisecondsSinceEpoch}.rgba');
      final sink = rawVideoFile.openWrite();

      String? outVideoPath;
      bool success = false;
      try {
        debugPrint("RecommendsAlgorithm: Rendering $totalFrames frames at $fps FPS (optimized RAW format to single stream)...");

        // Render frame sequence frame-by-frame on Canvas (540x960 resolution)
        for (int frameIndex = 0; frameIndex < totalFrames; frameIndex++) {
          final double t = frameIndex / fps;
          
          // Find which slide we are currently on
          int slideIdx = 0;
          for (int i = 0; i < loadedImages.length; i++) {
            if (t >= slideStarts[i] && t <= slideEnds[i]) {
              slideIdx = i;
              break;
            }
          }
          if (t > slideEnds.last) {
            slideIdx = loadedImages.length - 1;
          }

          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 540, 960));
          canvas.clipRect(const Rect.fromLTWH(0, 0, 540, 960));

          // Check if transition is active
          final double timeIntoSlide = t - slideStarts[slideIdx];
          final double curSlideDur = slideDurations[slideIdx];
          final double transDur = min(transitionDuration, curSlideDur / 2);
          final bool isTransition = slideIdx > 0 && timeIntoSlide <= transDur;

          final paint = Paint()
            ..isAntiAlias = true
            ..filterQuality = ui.FilterQuality.medium;

          if (isTransition) {
            final double p = timeIntoSlide / transDur;
            final prevSlideIdx = slideIdx - 1;
            final double prevProgress = (t - slideStarts[prevSlideIdx]) / slideDurations[prevSlideIdx];
            final double destProgress = timeIntoSlide / curSlideDur;
            final transType = transTypes[slideIdx] % 4;

            if (transType == 0) {
              // 1. Cross-fade
              final paintPrev = Paint()
                ..isAntiAlias = true
                ..filterQuality = ui.FilterQuality.medium
                ..color = Colors.white.withValues(alpha: 1.0 - p);
              _drawSlideFrame(canvas, loadedImages[prevSlideIdx], prevProgress, kbParams[prevSlideIdx], paintPrev);

              final paintDest = Paint()
                ..isAntiAlias = true
                ..filterQuality = ui.FilterQuality.medium
                ..color = Colors.white.withValues(alpha: p);
              _drawSlideFrame(canvas, loadedImages[slideIdx], destProgress, kbParams[slideIdx], paintDest);

            } else if (transType == 1) {
              // 2. Slide (Push)
              canvas.save();
              canvas.translate(-p * 540.0, 0.0);
              _drawSlideFrame(canvas, loadedImages[prevSlideIdx], prevProgress, kbParams[prevSlideIdx], paint);
              canvas.restore();

              canvas.save();
              canvas.translate((1.0 - p) * 540.0, 0.0);
              _drawSlideFrame(canvas, loadedImages[slideIdx], destProgress, kbParams[slideIdx], paint);
              canvas.restore();

            } else if (transType == 2) {
              // 3. Zoom-In Dissolve
              final paintPrev = Paint()
                ..isAntiAlias = true
                ..filterQuality = ui.FilterQuality.medium
                ..color = Colors.white.withValues(alpha: 1.0 - p);
              canvas.save();
              canvas.translate(270.0, 480.0);
              canvas.scale(1.0 + p * 0.15);
              canvas.translate(-270.0, -480.0);
              _drawSlideFrame(canvas, loadedImages[prevSlideIdx], prevProgress, kbParams[prevSlideIdx], paintPrev);
              canvas.restore();

              final paintDest = Paint()
                ..isAntiAlias = true
                ..filterQuality = ui.FilterQuality.medium
                ..color = Colors.white.withValues(alpha: p);
              canvas.save();
              canvas.translate(270.0, 480.0);
              canvas.scale(0.85 + p * 0.15);
              canvas.translate(-270.0, -480.0);
              _drawSlideFrame(canvas, loadedImages[slideIdx], destProgress, kbParams[slideIdx], paintDest);
              canvas.restore();

            } else {
              // 4. Swipe (Slide-over)
              _drawSlideFrame(canvas, loadedImages[prevSlideIdx], prevProgress, kbParams[prevSlideIdx], paint);

              canvas.save();
              canvas.translate((1.0 - p) * 540.0, 0.0);
              _drawSlideFrame(canvas, loadedImages[slideIdx], destProgress, kbParams[slideIdx], paint);
              canvas.restore();
            }
          } else {
            // No transition, draw current slide fully with Ken Burns pan-zoom
            final double slideProgress = timeIntoSlide / curSlideDur;
            _drawSlideFrame(canvas, loadedImages[slideIdx], slideProgress, kbParams[slideIdx], paint);
          }

          // Draw animated text / emoji title overlay
          String textMessage = "Sweet Memories";
          switch (type) {
            case RecommendType.birthdaySpecial:
              textMessage = "Happy Birthday! 🎂";
              break;
            case RecommendType.highlight:
              textMessage = "Sweet Memories ✨";
              break;
            case RecommendType.onThisDay:
              textMessage = "On This Day 📅";
              break;
            case RecommendType.recapPreviousYear:
              textMessage = "Year in Review 🎉";
              break;
            case RecommendType.bestMoment:
              textMessage = "Best Moment ✨";
              break;
            case RecommendType.bestTrip:
              textMessage = "Travel Diaries ✈️";
              break;
          }
          _drawTextOverlay(canvas, textMessage, t, totalDuration);

          final pic = recorder.endRecording();
          final uiImg = await pic.toImage(540, 960);
          final bytes = await uiImg.toByteData(format: ui.ImageByteFormat.rawRgba);
          if (bytes != null) {
            sink.add(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
          }
        }

        await sink.flush();
        await sink.close();

        final outPath = '$outDir/slideshow.mp4';
        final fileOut = File(outPath);
        if (fileOut.existsSync()) {
          fileOut.deleteSync();
        }

        // Compile raw RGBA video sequence file and audio track into final MP4 using FFmpeg
        String ffmpegCmd;
        if (tempAudioPath != null && File(tempAudioPath).existsSync()) {
          ffmpegCmd = "-y -f rawvideo -pix_fmt rgba -s 540x960 -r 15 -i \"${rawVideoFile.path}\" -stream_loop -1 -ss $ss -i \"$tempAudioPath\" -map 0:v:0 -map 1:a:0 -c:v libx264 -pix_fmt yuv420p -c:a aac -t $totalDuration \"$outPath\"";
        } else {
          ffmpegCmd = "-y -f rawvideo -pix_fmt rgba -s 540x960 -r 15 -i \"${rawVideoFile.path}\" -c:v libx264 -pix_fmt yuv420p -t $totalDuration \"$outPath\"";
        }

        debugPrint("RecommendsAlgorithm: Compiling video using FFmpeg: $ffmpegCmd");
        final session = await FFmpegKit.execute(ffmpegCmd);
        final returnCode = await session.getReturnCode();

        if (ReturnCode.isSuccess(returnCode)) {
          debugPrint("RecommendsAlgorithm: Video slideshow compiled successfully: $outPath");
          outVideoPath = outPath;
          success = true;
        } else {
          final failLog = await session.getAllLogsAsString();
          debugPrint("RecommendsAlgorithm: FFmpeg slideshow compilation failed with return code $returnCode. Log: $failLog");
        }
      } finally {
        try {
          await sink.close();
        } catch (_) {}
        try {
          if (rawVideoFile.existsSync()) {
            rawVideoFile.deleteSync();
          }
        } catch (_) {}

        if (tempAudioPath != null && customAudioPath == null) {
          try {
            final f = File(tempAudioPath);
            if (f.existsSync()) {
              f.deleteSync();
            }
          } catch (_) {}
        }
      }

      if (success) {
        return outVideoPath;
      }
    } catch (e, stack) {
      debugPrint("RecommendsAlgorithm: _generateSlideshow failed: $e\n$stack");
    }
    return null;
  }

  void _drawSlideFrame(Canvas canvas, ui.Image img, double slideProgress, KenBurnsParams kb, Paint paint) {
    final double srcW = img.width.toDouble();
    final double srcH = img.height.toDouble();
    final double destW = 540.0;
    final double destH = 960.0;

    final double scaleX = destW / srcW;
    final double scaleY = destH / srcH;
    final double baseScale = max(scaleX, scaleY);

    final double s = kb.scaleAt(slideProgress);
    final Offset pan = kb.panAt(slideProgress);

    final double finalScale = baseScale * s;
    final double wRender = srcW * finalScale;
    final double hRender = srcH * finalScale;

    final double dx = (destW - wRender) / 2 + pan.dx;
    final double dy = (destH - hRender) / 2 + pan.dy;

    final src = Rect.fromLTWH(0, 0, srcW, srcH);
    final dst = Rect.fromLTWH(dx, dy, wRender, hRender);

    canvas.drawImageRect(img, src, dst, paint);
  }

  void _drawTextOverlay(Canvas canvas, String text, double t, double totalDuration) {
    double opacity = 0.0;
    double yOffset = 0.0;
    double scale = 1.0;
    
    if (t < 4.0) {
      if (t < 1.5) {
        final progress = t / 1.5;
        final ease = 1.0 - pow(1.0 - progress, 3);
        opacity = ease;
        yOffset = (1.0 - ease) * 30.0;
      } else if (t < 3.0) {
        opacity = 1.0;
        yOffset = 0.0;
      } else {
        final progress = (t - 3.0);
        opacity = (1.0 - progress).clamp(0.0, 1.0);
      }
    } else if (t > totalDuration - 4.0) {
      final tFinal = t - (totalDuration - 4.0);
      if (tFinal < 1.5) {
        final progress = tFinal / 1.5;
        final ease = 1.0 - pow(1.0 - progress, 3);
        opacity = ease;
        yOffset = (1.0 - ease) * 30.0;
      } else {
        opacity = 1.0;
        yOffset = 0.0;
        scale = 1.0 + sin((t - (totalDuration - 4.0)) * pi * 2) * 0.03;
      }
    } else {
      final watermarkPainter = TextPainter(
        text: TextSpan(
          text: "Ghost Gallery",
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.4),
            fontSize: 14,
            fontWeight: FontWeight.w300,
            letterSpacing: 2.0,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      watermarkPainter.layout();
      watermarkPainter.paint(canvas, Offset(270.0 - watermarkPainter.width / 2, 910.0));
      return;
    }
    
    if (opacity <= 0.0) return;
    
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: opacity),
          fontSize: 32,
          fontWeight: FontWeight.w900,
          fontFamily: 'sans-serif',
          letterSpacing: 1.5,
          shadows: [
            Shadow(
              color: Colors.black.withValues(alpha: 0.8 * opacity),
              offset: const Offset(2.0, 2.0),
              blurRadius: 8.0,
            ),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );
    
    textPainter.layout(maxWidth: 480.0);
    final x = 270.0;
    final y = 780.0 + yOffset;
    
    canvas.save();
    canvas.translate(x, y);
    canvas.scale(scale);
    textPainter.paint(canvas, Offset(-textPainter.width / 2, -textPainter.height / 2));
    canvas.restore();
  }

  // ── Rendering & Asset Helpers ───────────────────────────────────────────

  Future<ui.Image?> _loadUiImage(String path) async {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _copyAssetToTemp(String assetPath) async {
    try {
      final byteData = await rootBundle.load(assetPath);
      final tempDir = await getTemporaryDirectory();
      final filename = assetPath.split('/').last;
      final file = File('${tempDir.path}/$filename');
      await file.writeAsBytes(byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      ));
      return file.path;
    } catch (e) {
      debugPrint("RecommendsAlgorithm: copyAssetToTemp failed for $assetPath (using silent fallback): $e");
      return null;
    }
  }

  void _drawCenterCrop(Canvas canvas, ui.Image img, Rect dest, {Paint? customPaint}) {
    final paint = customPaint ?? (Paint()..isAntiAlias = true..filterQuality = ui.FilterQuality.high);
    final double srcW = img.width.toDouble();
    final double srcH = img.height.toDouble();
    final double destW = dest.width;
    final double destH = dest.height;

    final double srcAspect = srcW / srcH;
    final double destAspect = destW / destH;

    Rect srcRect;
    if (srcAspect > destAspect) {
      final double width = srcH * destAspect;
      srcRect = Rect.fromLTWH((srcW - width) / 2, 0, width, srcH);
    } else {
      final double height = srcW / destAspect;
      srcRect = Rect.fromLTWH(0, (srcH - height) / 2, srcW, height);
    }

    canvas.drawImageRect(img, srcRect, dest, paint);
  }

  Future<double> _getAudioDuration(String path) async {
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      if (info != null) {
        final durationStr = info.getDuration();
        if (durationStr != null) {
          final duration = double.tryParse(durationStr);
          if (duration != null) {
            return duration;
          }
        }
      }
    } catch (e) {
      debugPrint("RecommendsAlgorithm: Failed to get audio duration via FFprobeKit: $e");
    }
    // Fallbacks
    if (path.contains('ambient_nostalgic_2')) return 840.0;
    if (path.contains('ambient_nostalgic')) return 360.0;
    if (path.contains('ambient_soft')) return 180.0;
    if (path.contains('ambient_upbeat')) return 200.0;
    return 180.0; // generic fallback
  }

  Future<Rect?> _resolveHighlightFaceRect(String groupId) async {
    try {
      final personId = getPersonIdFromGroupId(groupId);
      if (personId == null) return null;
      final person = await DatabaseHelper.instance.getPersonById(personId);
      if (person != null) {
        final w = person['cover_w'] as int? ?? 0;
        final h = person['cover_h'] as int? ?? 0;
        final x = person['cover_x'] as int? ?? 0;
        final y = person['cover_y'] as int? ?? 0;
        if (w > 0 && h > 0) {
          return Rect.fromLTWH(x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble());
        }
      }
      final allFaces = await DatabaseHelper.instance.getAllFaces();
      final personFaces = allFaces.where((f) => f['person_id'] == personId).toList();
      for (final pf in personFaces) {
        final bboxStr = pf['bounding_box'] as String? ?? '';
        final parts = bboxStr.split(',');
        if (parts.length >= 4) {
          final bx = double.tryParse(parts[0]) ?? 0;
          final by = double.tryParse(parts[1]) ?? 0;
          final bw = double.tryParse(parts[2]) ?? 0;
          final bh = double.tryParse(parts[3]) ?? 0;
          if (bw > 0 && bh > 0) {
            return Rect.fromLTWH(bx, by, bw, bh);
          }
        }
      }
    } catch (e) {
      debugPrint("RecommendsAlgorithm: _resolveHighlightFaceRect error: $e");
    }
    return null;
  }

  Future<String?> regenerateSlideshow({
    required String groupId,
    required List<String> imagePaths,
    required RecommendType type,
    required String customAudioPath,
  }) async {
    final appDocs = await getApplicationDocumentsDirectory();
    final outDir = '${appDocs.path}/ghost_recommends/$groupId';
    return _generateSlideshow(
      imagePaths,
      outDir,
      type,
      customAudioPath: customAudioPath,
      groupId: groupId,
    );
  }
}

class MediaPriorityManager {
  static const _kCurrentGenKey = 'recommends_current_generation';
  static const _kHistoryKey = 'recommends_media_selection_history';

  static Future<int> incrementGeneration() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = prefs.getInt(_kCurrentGenKey) ?? 0;
      final next = current + 1;
      await prefs.setInt(_kCurrentGenKey, next);
      await _pruneHistory(next);
      return next;
    } catch (e) {
      debugPrint("MediaPriorityManager: incrementGeneration failed: $e");
      return 0;
    }
  }

  static Future<int> getCurrentGeneration() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_kCurrentGenKey) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> markSelected(List<String> mediaIds, int generation) async {
    if (mediaIds.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kHistoryKey);
      final Map<String, dynamic> history = raw != null ? jsonDecode(raw) : {};
      for (final id in mediaIds) {
        history[id] = generation;
      }
      await prefs.setString(_kHistoryKey, jsonEncode(history));
    } catch (e) {
      debugPrint("MediaPriorityManager: markSelected failed: $e");
    }
  }

  static Future<Map<String, double>> getMultipliers(int currentGen) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kHistoryKey);
      if (raw == null) return {};
      final Map<String, dynamic> history = jsonDecode(raw);
      final Map<String, double> multipliers = {};
      for (final entry in history.entries) {
        final lastGen = entry.value as int;
        final diff = currentGen - lastGen;
        multipliers[entry.key] = (diff * 0.2).clamp(0.0, 1.0);
      }
      return multipliers;
    } catch (e) {
      debugPrint("MediaPriorityManager: getMultipliers failed: $e");
      return {};
    }
  }

  static Future<void> _pruneHistory(int currentGen) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kHistoryKey);
      if (raw == null) return;
      final Map<String, dynamic> history = jsonDecode(raw);
      history.removeWhere((key, value) => (currentGen - (value as int)) >= 5);
      await prefs.setString(_kHistoryKey, jsonEncode(history));
    } catch (_) {}
  }
}

class KenBurnsParams {
  final double startScale;
  final double endScale;
  final Offset startPan;
  final Offset endPan;
  final bool isFaceZoomInOut;
  final double faceZoomScale;
  final Offset facePan;
  final Offset basePan;
  final double srcWidth;
  final double srcHeight;

  KenBurnsParams({
    required this.startScale,
    required this.endScale,
    required this.startPan,
    required this.endPan,
    this.isFaceZoomInOut = false,
    this.faceZoomScale = 1.0,
    this.facePan = Offset.zero,
    this.basePan = Offset.zero,
    this.srcWidth = 0.0,
    this.srcHeight = 0.0,
  });

  static KenBurnsParams random(Random rand) {
    final zoomIn = rand.nextBool();
    final startS = zoomIn ? 1.0 : 1.15;
    final endS = zoomIn ? 1.15 : 1.0;

    final double maxPan = 25.0;
    final startX = (rand.nextDouble() * 2 - 1) * maxPan;
    final startY = (rand.nextDouble() * 2 - 1) * maxPan;
    final endX = (rand.nextDouble() * 2 - 1) * maxPan;
    final endY = (rand.nextDouble() * 2 - 1) * maxPan;

    return KenBurnsParams(
      startScale: startS,
      endScale: endS,
      startPan: Offset(startX, startY),
      endPan: Offset(endX, endY),
    );
  }

  static KenBurnsParams faceZoomInOut({
    required Rect faceRect,
    required double imageWidth,
    required double imageHeight,
    double canvasWidth = 540.0,
    double canvasHeight = 960.0,
  }) {
    final double srcW = imageWidth <= 0 ? canvasWidth : imageWidth;
    final double srcH = imageHeight <= 0 ? canvasHeight : imageHeight;
    final double baseScale = max(canvasWidth / srcW, canvasHeight / srcH);

    final double faceW = faceRect.width <= 0 ? srcW * 0.3 : faceRect.width;
    final double faceCenterX = faceRect.left + (faceRect.width <= 0 ? srcW * 0.5 : faceRect.width / 2.0);
    final double faceCenterY = faceRect.top + (faceRect.height <= 0 ? srcH * 0.4 : faceRect.height / 2.0);

    // Zoom scale targeted so face occupies ~36% width of frame
    final double targetFaceZoom = (canvasWidth * 0.36) / (faceW * baseScale);
    final double zoomScale = targetFaceZoom.clamp(1.3, 2.2);

    final double targetScreenX = canvasWidth / 2.0;
    final double targetScreenY = canvasHeight * 0.42;

    final double faceScreenXNoPan = canvasWidth / 2.0 + (faceCenterX - srcW / 2.0) * baseScale * zoomScale;
    final double faceScreenYNoPan = canvasHeight / 2.0 + (faceCenterY - srcH / 2.0) * baseScale * zoomScale;

    final double rawTargetPanX = targetScreenX - faceScreenXNoPan;
    final double rawTargetPanY = targetScreenY - faceScreenYNoPan;

    final double maxPanXZoom = max(0.0, (srcW * baseScale * zoomScale - canvasWidth) / 2.0);
    final double maxPanYZoom = max(0.0, (srcH * baseScale * zoomScale - canvasHeight) / 2.0);

    final double clampedFacePanX = rawTargetPanX.clamp(-maxPanXZoom, maxPanXZoom);
    final double clampedFacePanY = rawTargetPanY.clamp(-maxPanYZoom, maxPanYZoom);

    final double maxPanXBase = max(0.0, (srcW * baseScale - canvasWidth) / 2.0);
    final double maxPanYBase = max(0.0, (srcH * baseScale - canvasHeight) / 2.0);
    final double basePanX = (targetScreenX - (canvasWidth / 2.0 + (faceCenterX - srcW / 2.0) * baseScale)).clamp(-maxPanXBase, maxPanXBase);
    final double basePanY = (targetScreenY - (canvasHeight / 2.0 + (faceCenterY - srcH / 2.0) * baseScale)).clamp(-maxPanYBase, maxPanYBase);

    return KenBurnsParams(
      startScale: 1.0,
      endScale: 1.0,
      startPan: Offset(basePanX, basePanY),
      endPan: Offset(basePanX, basePanY),
      isFaceZoomInOut: true,
      faceZoomScale: zoomScale,
      facePan: Offset(clampedFacePanX, clampedFacePanY),
      basePan: Offset(basePanX, basePanY),
      srcWidth: srcW,
      srcHeight: srcH,
    );
  }

  double scaleAt(double s) {
    if (isFaceZoomInOut) {
      final double raw = sin(s.clamp(0.0, 1.0) * pi);
      final double factor = raw * raw * (3.0 - 2.0 * raw);
      return 1.0 + (faceZoomScale - 1.0) * factor;
    }
    return startScale + (endScale - startScale) * s;
  }

  Offset panAt(double s) {
    if (isFaceZoomInOut) {
      final double raw = sin(s.clamp(0.0, 1.0) * pi);
      final double factor = raw * raw * (3.0 - 2.0 * raw);
      final double panX = basePan.dx + (facePan.dx - basePan.dx) * factor;
      final double panY = basePan.dy + (facePan.dy - basePan.dy) * factor;

      if (srcWidth > 0 && srcHeight > 0) {
        final double curScale = scaleAt(s);
        final double baseScale = max(540.0 / srcWidth, 960.0 / srcHeight);
        final double maxPX = max(0.0, (srcWidth * baseScale * curScale - 540.0) / 2.0);
        final double maxPY = max(0.0, (srcHeight * baseScale * curScale - 960.0) / 2.0);
        return Offset(panX.clamp(-maxPX, maxPX), panY.clamp(-maxPY, maxPY));
      }
      return Offset(panX, panY);
    }
    return Offset(
      startPan.dx + (endPan.dx - startPan.dx) * s,
      startPan.dy + (endPan.dy - startPan.dy) * s,
    );
  }
}


