import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:image/image.dart' as img;
import 'package:flutter/services.dart';
import 'package:workmanager/workmanager.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'collection_source.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'database_helper.dart';
import 'face_cache_helper.dart';
import 'system_notification_service.dart';
import 'optional_features.dart';
import 'device_media_scanner.dart';
import 'objectbox_service.dart';
import '../models/media_vector.dart';
import '../objectbox.g.dart';
import 'recommends_algorithm.dart';
import 'package:exif/exif.dart';
import '../models/media_flags.dart';
import 'geocoding_service.dart';
import 'media_metadata_service.dart';
import 'entitlement_service.dart';
import 'trash_persistence.dart';
import 'cache_cleanup_service.dart';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

// ═══════════════════════════════════════════════════════════════════════════
// ML PROCESSING SERVICE — AVES-STYLE TIERED ARCHITECTURE
//
// Tier 2 (Foreground): EXIF + GPS + geocoding — fast (~50ms/item), runs on
//   main isolate while app is visible. Called from DeviceMediaScanner via
//   OptionalFeatures.enrichMetadataTier2.
//
// Tier 3: MLKit labels + OCR + face detection + face embedding + preview
//   thumbnail + search vector embedding. Runs in background (via WorkManager
//   on Android) or in-app (on Windows).
//
// Continuous Processing: Tier 3 processing runs continuously and is not
//   stopped when the app transitions between foreground and background. It
//   uses the shared 'ghost_bg_running' concurrency mutex to prevent multiple
//   instances from executing simultaneously and causing OOM or DB lock contention.
// ═══════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════════
// BACKGROUND TASK ENTRY POINT
// ═══════════════════════════════════════════════════════════════════════════

@pragma('vm:entry-point')
void foregroundTaskEntry() {
  FlutterForegroundTask.setTaskHandler(MLForegroundTaskHandler());
}

class MLForegroundTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final prefs = await SharedPreferences.getInstance();
    final taskName =
        prefs.getString('fg_active_task_name') ??
        'ghost_gallery_processing_task';
    final inputJson = prefs.getString('fg_active_task_input');
    final Map<String, dynamic>? inputData = inputJson != null
        ? jsonDecode(inputJson) as Map<String, dynamic>?
        : null;

    MLProcessingService._isBackgroundIsolate = true;
    MLProcessingService._isForegroundServiceIsolate = true;

    try {
      debugPrint('Foreground Service background task triggered: $taskName');
      await executeForegroundTask(taskName, inputData, prefs);
    } catch (e) {
      debugPrint('Foreground Service task execution error: $e');
    } finally {
      await FlutterForegroundTask.stopService();
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

Future<bool> executeForegroundTask(
  String taskName,
  Map<String, dynamic>? inputData,
  SharedPreferences prefs,
) async {
  debugPrint('Foreground task $taskName: Subscription checks bypassed.');

  debugPrint('Foreground task executing: $taskName');

  if (taskName == "ghost_gallery_faces_task") {
    try {
      await MLProcessingService.runFaceClusteringInline(prefs);
    } finally {}
    return true;
  }

  if (taskName == "ghost_gallery_recommends_task") {
    try {
      debugPrint('Recommends task: Running recommends curation algorithm.');
      await RecommendsAlgorithm.instance.runIfNeeded(force: true);
    } catch (e) {
      debugPrint('Recommends task error: $e');
    }
    return true;
  }

  if (taskName == "ghost_gallery_sync_task") {
    try {
      await DeviceMediaScanner.instance.scanAndSyncDeviceMedia();
      await MLProcessingService._bumpRefreshSeq(prefs);
    } catch (e) {
      debugPrint('Sync Task Error: $e');
    }
    return true;
  }

  if (taskName == "ghost_gallery_embedding_task") {
    final String? mediaId = inputData?['mediaId'] as String?;
    if (mediaId != null) {
      try {
        await MLProcessingService.instance.generateAndStoreMediaEmbedding(
          mediaId,
        );
        await MLProcessingService._bumpRefreshSeq(prefs);
      } catch (e) {
        debugPrint('Embedding Task Error: $e');
      }
    }
    return true;
  }

  // Tier 3 ML processing for Foreground Service
  try {
    await DatabaseHelper.instance.resetStuckProcessingItems();
  } catch (_) {}

  await SystemNotificationService.instance.showIndexingNotification();

  await MLProcessingService._clearStaleHeartbeatAndResetDb(prefs);
  await MLProcessingService._updateHeartbeat(prefs);

  Timer? heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
    try {
      await MLProcessingService._updateHeartbeat(prefs);
    } catch (_) {}
  });

  bool success = false;
  try {
    final db = DatabaseHelper.instance;

    // 1. Scan and Sync
    final bool foundNew = await DeviceMediaScanner.instance
        .scanAndSyncDeviceMedia();
    await MLProcessingService._bumpRefreshSeq(prefs);

    // 2. Metadata Enrichment
    final bool hasTier2 = await db.hasTier2PendingWork();
    if (foundNew || hasTier2) {
      await MLProcessingService.instance.runMetadataEnrichmentTier2();
      await MLProcessingService._bumpRefreshSeq(prefs);
    }

    final int pendingTotal = await db.countTier3PendingItems();
    if (pendingTotal == 0) {
      await prefs.setInt('ghost_bg_done', 0);
      await prefs.setInt('ghost_bg_total', 0);
      await prefs.setString('ghost_bg_message', "All done! 👻");

      // Release the mutex before running recommends
      await MLProcessingService._releaseMutex(prefs);

      // Run recommends curation
      final bool isFirstOpenProcessingCompleted =
          prefs.getBool('first_open_tier3_completed') ?? false;
      if (!isFirstOpenProcessingCompleted) {
        debugPrint(
          'First App Open ML Task (FG Early Exit): Tier 3 completed. Scheduling Midnight Background Scan nightly task...',
        );
        await MLProcessingService.instance.scheduleMidnightScanTask();

        debugPrint(
          'First App Open ML Task (FG Early Exit): Midnight Background Scan scheduled. Starting Recommends Algorithm curation...',
        );
        try {
          await RecommendsAlgorithm.instance.runIfNeeded(force: true);
        } catch (e) {
          debugPrint('Foreground Recommends Run Error (Early Exit): $e');
        }
        await prefs.setBool('first_open_tier3_completed', true);
      } else {
        try {
          await RecommendsAlgorithm.instance.runIfNeeded();
        } catch (e) {
          debugPrint('Foreground Recommends Run Error (Early Exit): $e');
        }
      }

      // Check if there are pending Tier 4 items (face clustering/detection) and trigger the faces task
      final int pendingFaces = await db.countTier4PendingItems();
      if (pendingFaces > 0) {
        debugPrint(
          'Foreground ML Task (Early Exit): Found $pendingFaces pending faces items. Triggering face clustering task.',
        );
        await MLProcessingService.instance.triggerFacesTaskNow();
      }

      success = true;
      return true;
    }

    final mlService = MLProcessingService.instance;
    int done = 0;

    while (true) {
      final pending = await db.getAndLockUnprocessedItems(20);
      if (pending.isEmpty) {
        break;
      }

      final int totalPendingInDb = await db.countTier3PendingItems();
      final int remainingLeft = (totalPendingInDb - pending.length).clamp(
        0,
        totalPendingInDb,
      );

      for (final item in pending) {
        try {
          await mlService.processMediaItemTier3(
            item['id'] as String,
            item['path'] as String,
            item['media_type'] as String,
            item['duration'] as double?,
            originalStatus: item['original_is_processed'] as int?,
          );
          await Future.delayed(const Duration(milliseconds: 300));
        } catch (e) {
          debugPrint("Foreground ML Task: Failed item ${item['id']} → $e");
        }
        done++;

        await prefs.setInt('ghost_bg_done', done);
        await prefs.setInt('ghost_bg_total', pendingTotal);
        await prefs.setString(
          'ghost_bg_message',
          "AI processing: $done of $pendingTotal",
        );

        SystemNotificationService.instance.showProgressNotification(
          done,
          pendingTotal,
          remainingLeft: remainingLeft,
        );
      }

      await mlService.reclusterAllFaces();

      await MLProcessingService._bumpRefreshSeq(prefs);
      await Future.delayed(const Duration(milliseconds: 200));
    }
    
    // Release the mutex and cancel the heartbeat timer before running recommends
    heartbeatTimer.cancel();
    await MLProcessingService._releaseMutex(prefs);

    // Run recommends curation
    final bool isFirstOpenProcessingCompleted =
        prefs.getBool('first_open_tier3_completed') ?? false;
    if (!isFirstOpenProcessingCompleted) {
      debugPrint(
        'First App Open ML Task (FG Normal Exit): Tier 3 completed. Scheduling Midnight Background Scan nightly task...',
      );
      await MLProcessingService.instance.scheduleMidnightScanTask();

      debugPrint(
        'First App Open ML Task (FG Normal Exit): Midnight Background Scan scheduled. Starting Recommends Algorithm curation...',
      );
      try {
        await RecommendsAlgorithm.instance.runIfNeeded(force: true);
      } catch (e) {
        debugPrint('Foreground Recommends Run Error (Normal Exit): $e');
      }
      await prefs.setBool('first_open_tier3_completed', true);
    } else {
      try {
        await RecommendsAlgorithm.instance.runIfNeeded();
      } catch (e) {
        debugPrint('Foreground Recommends Run Error (Normal Exit): $e');
      }
    }

    // Check if there are pending Tier 4 items (face clustering/detection) and trigger the faces task
    final int pendingFaces = await db.countTier4PendingItems();
    if (pendingFaces > 0) {
      debugPrint(
        'Foreground ML Task (Normal Exit): Found $pendingFaces pending faces items. Triggering face clustering task.',
      );
      await MLProcessingService.instance.triggerFacesTaskNow();
    }

    success = true;
  } catch (e) {
    debugPrint("Foreground ML Task Error: $e");
  } finally {
    heartbeatTimer.cancel();
    await MLProcessingService._releaseMutex(prefs);
    await SystemNotificationService.instance.dismissNotification();
    try {
      await DatabaseHelper.instance.resetStuckProcessingItems();
    } catch (_) {}
    try {
      await CacheCleanupService.instance.cleanUselessCacheFiles();
    } catch (_) {}
  }
  return success;
}

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();

    // Mark this Dart isolate as a WorkManager background worker.
    // This prevents UI-only side-effects (notifyChange, etc.) from firing
    // in a context where no widget tree or listeners exist.
    MLProcessingService._isBackgroundIsolate = true;

    debugPrint(
      'WorkManager background task $taskName: Subscription checks bypassed.',
    );

    final prefs = await SharedPreferences.getInstance();

    if (taskName == "ghost_gallery_processing_task") {
      final autoScanEnabled = prefs.getBool('auto_scan_enabled') ?? true;
      if (!autoScanEnabled) {
        debugPrint(
          'WorkManager background task $taskName: Auto-scanning is disabled in settings. Aborting.',
        );
        return true;
      }
    }

    debugPrint('WorkManager background task triggered: $taskName');

    if (taskName == "ghost_gallery_faces_task") {
      try {
        await MLProcessingService.runFaceClusteringInline(prefs);
        final db = DatabaseHelper.instance;
        final int remainingTotal = await db.countTier4PendingItems();
        if (remainingTotal == 0) {
          debugPrint(
            'Tier4 BG: Face clustering all finished! Triggering recommends task.',
          );
          await MLProcessingService.instance.triggerRecommendsTaskNow();
        }
      } finally {
        final scheduled = prefs.getBool('faces_task_scheduled') ?? true;
        if (scheduled) {
          await MLProcessingService.instance.scheduleMidnightScanTask(
            forceReplace: true,
          );
        }
      }
      return true;
    }

    if (taskName == "ghost_gallery_recommends_task") {
      try {
        final isFacesRunning = prefs.getBool('ghost_faces_running') ?? false;
        if (isFacesRunning) {
          debugPrint(
            'Recommends task: Face clustering is running. Deferring recommends.',
          );
          return false;
        }
        final forceRun = prefs.getBool('force_recommends_run') ?? false;
        if (forceRun) {
          await prefs.setBool('force_recommends_run', false);
        }
        debugPrint(
          'Recommends task: Running recommends curation algorithm (force=$forceRun).',
        );
        await RecommendsAlgorithm.instance.runIfNeeded(force: forceRun);
      } catch (e) {
        debugPrint('Recommends task background error: $e');
      } finally {
        await MLProcessingService.instance.scheduleRecommendsTask(
          forceReplace: true,
        );
      }
      return true;
    }

    if (taskName == "ghost_gallery_sync_task") {
      try {
        await prefs.setBool('ghost_sync_running', true);
        await DeviceMediaScanner.instance.scanAndSyncDeviceMedia();
        await MLProcessingService._bumpRefreshSeq(prefs);
      } catch (e) {
        debugPrint('Background Sync Task Error: $e');
      } finally {
        await prefs.setBool('ghost_sync_running', false);
      }
      return true;
    }

    if (taskName == "ghost_gallery_embedding_task") {
      final String? mediaId = inputData?['mediaId'] as String?;
      if (mediaId != null) {
        try {
          await MLProcessingService.instance.generateAndStoreMediaEmbedding(
            mediaId,
          );
          await MLProcessingService._bumpRefreshSeq(prefs);
        } catch (e) {
          debugPrint('Background Embedding Task Error: $e');
        }
      }
      return true;
    }

    // Try to trigger the native watchdog right away on start
    try {
      await MLProcessingService._mediaChannel.invokeMethod(
        'scheduleWatchdogAlarm',
        {'taskName': taskName},
      );
    } catch (_) {}

    // Unconditionally reset stuck processing items at start
    try {
      await DatabaseHelper.instance.resetStuckProcessingItems();
      debugPrint(
        'callbackDispatcher: Cleared any stuck items from previous kill.',
      );
    } catch (_) {}

    await SystemNotificationService.instance.showIndexingNotification();

    // ── Concurrency mutex (Heartbeat-based) ──────────────────────────────
    // WorkManager guarantees only one instance of a unique task runs at a time.
    // However, we still check the mutex to guard against the in-app
    // runInAppProcessingTier3() running simultaneously on the main isolate.
    //
    // On startup: always clear a potentially stale heartbeat left by a previous
    // run that was killed (e.g. app swiped from recents). This avoids the stale-lock
    // wait and releases any DB rows that were locked mid-batch.
    await MLProcessingService._clearStaleHeartbeatAndResetDb(prefs);

    final bool alreadyRunning = await MLProcessingService._isMutexLocked(prefs);
    if (alreadyRunning) {
      debugPrint(
        'Background ML Task: In-app instance is running (active heartbeat) — aborting.',
      );
      return true;
    }
    await MLProcessingService._updateHeartbeat(prefs);

    Timer? heartbeatTimer;
    bool success = false;
    try {
      int heartbeatCount = 0;
      // Periodic heartbeat update timer decoupled from item processing speed
      heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
        try {
          await MLProcessingService._updateHeartbeat(prefs);
          heartbeatCount++;
          if (heartbeatCount >= 6) {
            // Every 30 seconds
            heartbeatCount = 0;
            await MLProcessingService._mediaChannel.invokeMethod(
              'scheduleWatchdogAlarm',
              {'taskName': taskName},
            );
          }
        } catch (_) {}
      });

      final db = DatabaseHelper.instance;

      // Apply busy_timeout on the background isolate's DB connection.
      try {
        final dbClient = await db.database;
        await dbClient.rawQuery('PRAGMA busy_timeout=10000;');
      } catch (_) {}

      // 1. Run Tier 1: Scan and Sync device media in background isolate
      final bool foundNew = await DeviceMediaScanner.instance
          .scanAndSyncDeviceMedia();
      // Signal UI to refresh after Tier 1 scan completes
      await MLProcessingService._bumpRefreshSeq(prefs);

      // 2. Run Tier 2 metadata enrichment if new found or work pending
      final bool hasTier2 = await db.hasTier2PendingWork();
      if (foundNew || hasTier2) {
        await MLProcessingService.instance.runMetadataEnrichmentTier2();
        // Signal UI to refresh after Tier 2 enrichment completes
        await MLProcessingService._bumpRefreshSeq(prefs);
      }

      final int pendingTotal = await db.countTier3PendingItems();
      if (pendingTotal == 0) {
        // Clear progress stored values
        await prefs.setInt('ghost_bg_done', 0);
        await prefs.setInt('ghost_bg_total', 0);
        await prefs.setString('ghost_bg_message', "All done! 👻");

        // Release the mutex before running recommends
        await MLProcessingService._releaseMutex(prefs);

        // Run recommends curation
        final bool isFirstOpenProcessingCompleted =
            prefs.getBool('first_open_tier3_completed') ?? false;
        if (!isFirstOpenProcessingCompleted) {
          debugPrint(
            'First App Open ML Task (Early Exit): Tier 3 has no pending work. Scheduling Midnight Background Scan nightly task...',
          );
          await MLProcessingService.instance.scheduleMidnightScanTask();

          debugPrint(
            'First App Open ML Task (Early Exit): Midnight Background Scan scheduled. Starting Recommends Algorithm curation...',
          );
          try {
            await RecommendsAlgorithm.instance.runIfNeeded(force: true);
          } catch (e) {
            debugPrint('Background Recommends Run Error (Early Exit): $e');
          }
          await prefs.setBool('first_open_tier3_completed', true);
        } else {
          try {
            await RecommendsAlgorithm.instance.runIfNeeded();
          } catch (e) {
            debugPrint('Background Recommends Run Error (Early Exit): $e');
          }
        }

        // Check if there are pending Tier 4 items (face clustering/detection) and trigger the faces task
        final int pendingFaces = await db.countTier4PendingItems();
        if (pendingFaces > 0) {
          debugPrint(
            'Background ML Task (Early Exit): Found $pendingFaces pending faces items. Triggering face clustering task.',
          );
          await MLProcessingService.instance.triggerFacesTaskNow();
        }

        success = true;
        return true;
      }

      final mlService = MLProcessingService.instance;
      int done = 0;

      while (true) {
        final pending = await db.getAndLockUnprocessedItems(20);
        if (pending.isEmpty) {
          break;
        }

        final int totalPendingInDb = await db.countTier3PendingItems();
        final int remainingLeft = (totalPendingInDb - pending.length).clamp(
          0,
          totalPendingInDb,
        );

        int itemIndex = 0;
        for (final item in pending) {
          try {
            await mlService.processMediaItemTier3(
              item['id'] as String,
              item['path'] as String,
              item['media_type'] as String,
              item['duration'] as double?,
              originalStatus: item['original_is_processed'] as int?,
            );
            await Future.delayed(const Duration(milliseconds: 300));
          } catch (e) {
            debugPrint("Background ML Task: Failed item ${item['id']} → $e");
          }
          done++;
          itemIndex++;

          // Write current progress directly to SharedPreferences for UI sync
          await prefs.setInt('ghost_bg_done', done);
          await prefs.setInt('ghost_bg_total', pendingTotal);
          await prefs.setString(
            'ghost_bg_message',
            "AI processing: $done of $pendingTotal",
          );

          SystemNotificationService.instance.showProgressNotification(
            done,
            pendingTotal,
            remainingLeft: remainingLeft,
          );
        }

        // Run face clustering graph update after each batch
        await mlService.reclusterAllFaces();

        // Signal UI to refresh after each Tier 3 batch completes
        await MLProcessingService._bumpRefreshSeq(prefs);
        await Future.delayed(const Duration(milliseconds: 200));
      }
     
      // Release the mutex and cancel the heartbeat timer before running recommends
      // to avoid triggering the ML active safety check.
      heartbeatTimer.cancel();
      await MLProcessingService._releaseMutex(prefs);

      // Check if this is the first app open processing completion!
      final bool isFirstOpenProcessingCompleted =
          prefs.getBool('first_open_tier3_completed') ?? false;
      if (!isFirstOpenProcessingCompleted) {
        debugPrint(
          'First App Open ML Task: Tier 3 completed for the first time. Scheduling Midnight Background Scan nightly task...',
        );
        await MLProcessingService.instance.scheduleMidnightScanTask();

        debugPrint(
          'First App Open ML Task: Midnight Background Scan scheduled. Starting Recommends Algorithm curation...',
        );
        try {
          await RecommendsAlgorithm.instance.runIfNeeded(force: true);
        } catch (e) {
          debugPrint('Background Recommends Run Error: $e');
        }
        await prefs.setBool('first_open_tier3_completed', true);
      } else {
        try {
          await RecommendsAlgorithm.instance.runIfNeeded();
        } catch (e) {
          debugPrint('Background Recommends Run Error: $e');
        }
      }

      // Check if there are pending Tier 4 items (face clustering/detection) and trigger the faces task
      final int pendingFaces = await db.countTier4PendingItems();
      if (pendingFaces > 0) {
        debugPrint(
          'Background ML Task: Found $pendingFaces pending faces items. Triggering face clustering task.',
        );
        await MLProcessingService.instance.triggerFacesTaskNow();
      }

      success = true;
    } catch (e) {
      debugPrint("Background ML Task Error: $e");
      success = false;
    } finally {
      heartbeatTimer?.cancel();
      try {
        await MLProcessingService._mediaChannel.invokeMethod(
          'cancelWatchdogAlarm',
        );
      } catch (_) {}
      await MLProcessingService._releaseMutex(prefs);
      await SystemNotificationService.instance.dismissNotification();
      try {
        await DatabaseHelper.instance.resetStuckProcessingItems();
      } catch (e) {
        debugPrint(
          'MLProcessingService: resetStuckProcessingItems failed → $e',
        );
      }

      // Reschedule task if work remains
      try {
        final bool moreWork = await DatabaseHelper.instance
            .hasTier3PendingWork();
        if (moreWork) {
          await Workmanager().registerOneOffTask(
            MLProcessingService._wmUniqueTaskId,
            MLProcessingService.backgroundTaskName,
            initialDelay: const Duration(seconds: 30),
            existingWorkPolicy: ExistingWorkPolicy.replace,
            backoffPolicy: BackoffPolicy.linear,
            backoffPolicyDelay: const Duration(minutes: 1),
            constraints: Constraints(networkType: NetworkType.notRequired),
          );
        }
      } catch (_) {}

      try {
        await MLProcessingService._mediaChannel.invokeMethod(
          'scheduleMediaTriggerWork',
        );
      } catch (e) {
        debugPrint('Failed to reschedule media trigger work: $e');
      }

      try {
        final scheduled = prefs.getBool('faces_task_scheduled') ?? true;
        if (scheduled) {
          await MLProcessingService.instance.scheduleMidnightScanTask(
            forceReplace: true,
          );
        }
      } catch (e) {
        debugPrint('Failed to reschedule midnight scan task: $e');
      }
      try {
        await CacheCleanupService.instance.cleanUselessCacheFiles();
      } catch (_) {}
      debugPrint('MLProcessingService: final cleanup completed.');
    }
    return success;
  });
}

// ═══════════════════════════════════════════════════════════════════════════
// ML PROCESSING SERVICE
// ═══════════════════════════════════════════════════════════════════════════

const int kMaxPeopleShown = 10;

class MLProcessingService {
  static final MLProcessingService instance = MLProcessingService._init();
  bool _isNativeSupported = false;

  /// True when this singleton is running inside a WorkManager background isolate.
  /// Set by [callbackDispatcher] before any task logic runs.
  /// Used to skip UI-only side-effects (ValueNotifier updates to listeners,
  /// DeviceMediaScanner.notifyChange, etc.) that have no effect in a headless isolate.
  static bool _isBackgroundIsolate = false;
  static bool _isForegroundServiceIsolate = false;

  static bool get isBackgroundIsolate =>
      _isBackgroundIsolate || _isForegroundServiceIsolate;

  FaceDetector? _faceDetector;
  TextRecognizer? _textRecognizer;
  ImageLabeler? _imageLabeler;

  // ── Cancellation token (set by AppLifecycleObserver on resume) ───────────
  bool _tier3CancellationRequested = false;

  void requestTier3Cancellation() {
    _tier3CancellationRequested = true;
  }

  // ── Mutex Lock Heartbeats ───────────────────────────────────────────────

  /// Called at the very start of each WorkManager invocation to recover from
  /// a previous run that was killed mid-task (e.g. process killed by OEM when
  /// the user swiped the app from the recents list). This:
  ///   1. Clears the stale heartbeat so _isMutexLocked returns immediately.
  ///   2. Resets any DB rows that were locked mid-batch by the killed task.
  static Future<void> _clearStaleHeartbeatAndResetDb(
    SharedPreferences prefs,
  ) async {
    final int heartbeat = prefs.getInt('ghost_bg_heartbeat') ?? 0;
    if (heartbeat == 0) return; // Nothing stale — fresh start.

    final int now = DateTime.now().millisecondsSinceEpoch;
    final int ageMs = now - heartbeat;

    // Only clear if the heartbeat is older than 30s (i.e. the previous run is
    // truly dead). An active run updates every 5s so this is safe.
    if (ageMs >= 30000) {
      debugPrint(
        'MLProcessingService: Stale heartbeat detected (${ageMs}ms old) — clearing lock and resetting stuck DB items.',
      );
      await prefs.remove('ghost_bg_heartbeat');
      try {
        await DatabaseHelper.instance.resetStuckProcessingItems();
      } catch (e) {
        debugPrint(
          'MLProcessingService: resetStuckProcessingItems on startup failed → $e',
        );
      }
    }
  }

  static Future<bool> _isMutexLocked(SharedPreferences prefs) async {
    final int firstHeartbeat = prefs.getInt('ghost_bg_heartbeat') ?? 0;
    if (firstHeartbeat == 0) return false;

    final int now = DateTime.now().millisecondsSinceEpoch;
    // Heartbeat older than 30s → definitely stale (previous run is dead).
    if ((now - firstHeartbeat) >= 30000) {
      return false;
    }

    // Heartbeat is fresh — wait 6s and check again to see if it's still updating.
    // This guards against the in-app runInAppProcessingTier3() running on the
    // main isolate while WorkManager fires on a background isolate.
    await Future.delayed(const Duration(seconds: 6));
    await prefs.reload();
    final int secondHeartbeat = prefs.getInt('ghost_bg_heartbeat') ?? 0;
    if (secondHeartbeat == firstHeartbeat) {
      debugPrint(
        "MLProcessingService: Heartbeat did not update after 6s (stale lock). Taking over.",
      );
      return false;
    }

    return true;
  }

  static Future<void> _updateHeartbeat(SharedPreferences prefs) async {
    await prefs.setInt(
      'ghost_bg_heartbeat',
      DateTime.now().millisecondsSinceEpoch,
    );
    final String locker = _isForegroundServiceIsolate
        ? 'foreground_service'
        : (_isBackgroundIsolate ? 'workmanager' : 'main_app');
    await prefs.setString('ghost_bg_locker', locker);
  }

  static Future<void> _releaseMutex(SharedPreferences prefs) async {
    await prefs.remove('ghost_bg_heartbeat');
    await prefs.remove('ghost_bg_locker');
  }

  // ── UI Syncing between Isolates ─────────────────────────────────────────
  Timer? _uiSyncTimer;
  int _lastSeenRefreshSeq = 0;

  /// Increments [ghost_bg_refresh_seq] in SharedPreferences so the
  /// main-isolate [startUiSync] timer can detect a milestone completion
  /// (Tier 1, Tier 2, or Tier 3 batch) and fire [refreshTriggerNotifier].
  static Future<void> _bumpRefreshSeq(SharedPreferences prefs) async {
    final int seq = (prefs.getInt('ghost_bg_refresh_seq') ?? 0) + 1;
    await prefs.setInt('ghost_bg_refresh_seq', seq);
    debugPrint('MLProcessingService [BG]: refresh_seq → $seq');
  }

  void startUiSync() {
    if (kIsWeb || !Platform.isAndroid) return;
    _uiSyncTimer?.cancel();
    _uiSyncTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      // ── Tier milestone refresh detection ──────────────────────────────
      // The background isolate bumps ghost_bg_refresh_seq after Tier 1,
      // Tier 2, and each Tier 3 batch. When we detect a new value here
      // we increment refreshTriggerNotifier, which the home screen listens
      // to and responds to with _refreshFromDB().
      final int currentSeq = prefs.getInt('ghost_bg_refresh_seq') ?? 0;
      if (currentSeq != _lastSeenRefreshSeq) {
        _lastSeenRefreshSeq = currentSeq;
        refreshTriggerNotifier.value++;
        debugPrint(
          'MLProcessingService [UI]: refresh_seq=$currentSeq → triggering DB refresh.',
        );
      }

      final bool isLocked = await _isMutexLocked(prefs);
      if (isLocked) {
        isProcessingNotifier.value = true;
        final int done = prefs.getInt('ghost_bg_done') ?? 0;
        final int total = prefs.getInt('ghost_bg_total') ?? 0;
        final String log =
            prefs.getString('ghost_bg_message') ?? "AI processing…";

        progressNotifier.value = total > 0 ? done / total : 0.0;
        logNotifier.value = log;
      } else {
        isProcessingNotifier.value = false;
      }

      final bool isSyncing = prefs.getBool('ghost_sync_running') ?? false;
      isSyncingNotifier.value = isSyncing;

      final bool isFacesRunning = prefs.getBool('ghost_faces_running') ?? false;
      isFacesProcessingNotifier.value = isFacesRunning;
    });
  }

  void stopUiSync() {
    _uiSyncTimer?.cancel();
    _uiSyncTimer = null;
  }

  // ── UI notifiers ─────────────────────────────────────────────────────────
  final ValueNotifier<String> logNotifier = ValueNotifier("Scanner idle…");
  final ValueNotifier<double> progressNotifier = ValueNotifier(0.0);
  final ValueNotifier<bool> isProcessingNotifier = ValueNotifier(false);
  final ValueNotifier<bool> isSyncingNotifier = ValueNotifier(false);
  final ValueNotifier<bool> isFacesProcessingNotifier = ValueNotifier(false);

  /// Incremented by [startUiSync] each time the background isolate signals
  /// that a Tier 1, Tier 2, or Tier 3 batch milestone has completed.
  /// Listeners (e.g. home_screen.dart) should call _refreshFromDB() on change.
  final ValueNotifier<int> refreshTriggerNotifier = ValueNotifier(0);

  MLProcessingService._init() {
    _isNativeSupported = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    SystemNotificationService.instance.initialize(requestPermissions: false);

    // Bind state to OptionalFeatures
    OptionalFeatures.isMlProcessing.value = isProcessingNotifier.value;
    OptionalFeatures.mlProgress.value = progressNotifier.value;
    OptionalFeatures.mlLog.value = logNotifier.value;

    isProcessingNotifier.addListener(() {
      OptionalFeatures.isMlProcessing.value = isProcessingNotifier.value;
    });
    progressNotifier.addListener(() {
      OptionalFeatures.mlProgress.value = progressNotifier.value;
    });
    logNotifier.addListener(() {
      OptionalFeatures.mlLog.value = logNotifier.value;
    });

    OptionalFeatures.updateEmbeddingsForPerson = updateEmbeddingsForPerson;
    OptionalFeatures.scheduleBackgroundTask = scheduleBackgroundTask;
    OptionalFeatures.scheduleSyncBackgroundTask = scheduleSyncBackgroundTask;
    OptionalFeatures.scheduleEmbeddingBackgroundTask =
        scheduleEmbeddingBackgroundTask;
    // Vectorization is handled by pure-Dart MediaVectorizer (256-D hash projection).
    OptionalFeatures.vectorize = (String text) async =>
        MediaVectorizer.vectorize(text);
    OptionalFeatures.cosineSimilarity = MediaVectorizer.cosineSimilarity;
  }

  void _initClients() {}

  static const String backgroundTaskName = "ghost_gallery_processing_task";
  static const String chargingTaskName = "ghost_gallery_charging_task";
  static const String facesTaskName = "ghost_gallery_faces_task";
  static const String recommendsTaskName = "ghost_gallery_recommends_task";

  // Fixed unique task name — MUST be a constant so WorkManager can deduplicate.
  static const String _wmUniqueTaskId = "ghost_gallery_ml_worker";
  static const String _wmChargingTaskId = "ghost_gallery_charging_worker";
  static const String _wmFacesTaskId = "ghost_gallery_faces_worker";
  static const String _wmRecommendsTaskId = "ghost_gallery_recommends_worker";
  static const String _wmMidnightTaskId = "ghost_gallery_midnight_worker";

  Duration _calculateDelayToMidnight() {
    final now = DateTime.now();
    final midnight = DateTime(now.year, now.month, now.day + 1, 0, 0, 0);
    return midnight.difference(now);
  }

  static Future<void> runFaceClusteringInline(SharedPreferences prefs) async {
    await prefs.setBool('ghost_faces_running', true);
    await SystemNotificationService.instance.ensureInitialized();
    try {
      await _mediaChannel.invokeMethod('scheduleWatchdogAlarm', {
        'taskName': 'ghost_gallery_faces_task',
      });
    } catch (_) {}

    Timer? faceWatchdogTimer;
    try {
      faceWatchdogTimer = Timer.periodic(const Duration(seconds: 30), (
        _,
      ) async {
        try {
          await _mediaChannel.invokeMethod('scheduleWatchdogAlarm', {
            'taskName': 'ghost_gallery_faces_task',
          });
        } catch (_) {}
      });

      final db = DatabaseHelper.instance;
      // Reset any stuck items from a previous crash/run first
      await db.resetStuckFacesProcessingItems();

      final int pendingTotal = await db.countTier4PendingItems();
      // ── DIAGNOSTIC: log queue state so we can tell if the task exits early ──
      debugPrint('Tier4 BG: pendingTotal=$pendingTotal');
      if (pendingTotal == 0) {
        debugPrint(
          'Tier4 BG: Nothing to process — all items already have is_faces_processed=1. Task exiting.',
        );
      }

      int done = 0;

      while (true) {
        final pending = await db.getAndLockUnprocessedFacesItems(20);
        debugPrint(
          'Tier4 BG: batch fetched ${pending.length} items (done=$done / total=$pendingTotal)',
        );
        if (pending.isEmpty) {
          break;
        }
        final int remainingLeft = (pendingTotal - done - pending.length).clamp(
          0,
          pendingTotal,
        );
        int itemIndex = 0;
        for (final item in pending) {
          final String id = item['id'] as String;
          final String path = item['path'] as String;
          try {
            final file = File(path);
            if (!file.existsSync()) {
              debugPrint('Tier4 BG: File missing, skipping: $path');
              await db.updateMediaItemFacesProcessedStatus(id, 1);
              continue;
            }
            await MLProcessingService.instance.processMediaItemTier4(
              id,
              path,
              db,
              mediaType: item['media_type'] as String?,
              duration: item['duration'] as double?,
            );
            await db.updateMediaItemFacesProcessedStatus(id, 1);
          } catch (e) {
            debugPrint("Tier 4 background item $id failed: $e");
            await db.updateMediaItemFacesProcessedStatus(id, 1);
          }
          done++;
          itemIndex++;
          await SystemNotificationService.instance
              .showFacesProgressNotification(
                done,
                pendingTotal,
                remainingLeft: (pendingTotal - done).clamp(0, pendingTotal),
              );
        }

        // Run face clustering graph update after each batch
        await MLProcessingService.instance.reclusterAllFaces();
      }
      debugPrint('Tier4 BG: Loop complete. Processed $done item(s).');
      if (done > 0) {
        await SystemNotificationService.instance.showFacesFinishNotification();
      }
    } catch (e) {
      debugPrint("Tier 4 background task error: $e");
    } finally {
      faceWatchdogTimer?.cancel();
      try {
        await _mediaChannel.invokeMethod('cancelWatchdogAlarm');
      } catch (_) {}
      await prefs.setBool('ghost_faces_running', false);
      await SystemNotificationService.instance.dismissFacesNotification();
      try {
        await DatabaseHelper.instance.resetStuckFacesProcessingItems();
      } catch (_) {}
    }
  }

  Future<void> scheduleMidnightScanTask({bool forceReplace = false}) async {
    if (kIsWeb) return;
    debugPrint(
      'MLProcessingService: Subscription checks bypassed for scheduleMidnightScanTask.',
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('faces_task_scheduled', true);

    if (Platform.isAndroid) {
      try {
        final delay = _calculateDelayToMidnight();
        await Workmanager().registerOneOffTask(
          _wmMidnightTaskId,
          backgroundTaskName,
          initialDelay: delay,
          existingWorkPolicy: forceReplace
              ? ExistingWorkPolicy.replace
              : ExistingWorkPolicy.keep,
          backoffPolicy: BackoffPolicy.linear,
          backoffPolicyDelay: const Duration(minutes: 5),
          constraints: Constraints(
            networkType: NetworkType.notRequired,
            requiresBatteryNotLow: false,
            requiresCharging: false,
            requiresDeviceIdle: false,
          ),
        );
        debugPrint(
          'Midnight Background Scan task scheduled (one-off). Run in ${delay.inHours}h ${delay.inMinutes % 60}m (midnight).',
        );
      } catch (e) {
        debugPrint('Failed to schedule Midnight Background Scan task: $e');
      }
    }
  }

  /// Schedules an immediate one-off WorkManager task for face processing.
  /// Use this when you need faces processed right away (e.g. after re-clustering).
  Future<void> triggerFacesTaskNow() async {
    if (kIsWeb || !Platform.isAndroid) return;
    debugPrint(
      'MLProcessingService: Subscription checks bypassed for triggerFacesTaskNow.',
    );

    if (!_isBackgroundIsolate) {
      try {
        await Workmanager().cancelByUniqueName(_wmFacesTaskId);
      } catch (_) {}
      await scheduleForegroundMLTask(facesTaskName);
    } else {
      try {
        await Workmanager().registerOneOffTask(
          _wmFacesTaskId,
          facesTaskName,
          initialDelay: const Duration(seconds: 5),
          existingWorkPolicy: ExistingWorkPolicy.replace,
          backoffPolicy: BackoffPolicy.linear,
          backoffPolicyDelay: const Duration(minutes: 5),
          constraints: Constraints(
            networkType: NetworkType.notRequired,
            requiresBatteryNotLow: false,
            requiresCharging: false,
            requiresDeviceIdle: false,
          ),
        );
        debugPrint('Face task (one-off) scheduled to run in 5 s.');
      } catch (e) {
        debugPrint('Failed to schedule one-off face task: $e');
      }
    }
  }

  Future<void> scheduleRecommendsTask({bool forceReplace = false}) async {
    if (kIsWeb) return;
    debugPrint(
      'MLProcessingService: Subscription checks bypassed for scheduleRecommendsTask.',
    );
    if (Platform.isAndroid) {
      try {
        final delay = _calculateDelayToMidnight();
        await Workmanager().registerOneOffTask(
          _wmRecommendsTaskId,
          recommendsTaskName,
          initialDelay: delay,
          existingWorkPolicy: forceReplace
              ? ExistingWorkPolicy.replace
              : ExistingWorkPolicy.keep,
          backoffPolicy: BackoffPolicy.linear,
          backoffPolicyDelay: const Duration(minutes: 5),
          constraints: Constraints(
            networkType: NetworkType.notRequired,
            requiresBatteryNotLow: false,
            requiresCharging: false,
            requiresDeviceIdle: false,
          ),
        );
        debugPrint(
          'Recommends task scheduled (one-off). Run in ${delay.inHours}h ${delay.inMinutes % 60}m (midnight).',
        );
      } catch (e) {
        debugPrint('Failed to schedule Recommends task: $e');
      }
    }
  }

  Future<void> triggerRecommendsTaskNow() async {
    if (kIsWeb || !Platform.isAndroid) return;
    debugPrint(
      'MLProcessingService: Subscription checks bypassed for triggerRecommendsTaskNow.',
    );

    if (!_isBackgroundIsolate) {
      final prefs = await SharedPreferences.getInstance();
      final bool firstOpenCompleted =
          prefs.getBool('first_open_tier3_completed') ?? false;

      if (!firstOpenCompleted) {
        try {
          await Workmanager().cancelByUniqueName("${_wmRecommendsTaskId}_now");
        } catch (_) {}
        await scheduleForegroundMLTask(recommendsTaskName);
      } else {
        try {
          await prefs.setBool('force_recommends_run', true);
          await Workmanager().registerOneOffTask(
            "${_wmRecommendsTaskId}_now",
            recommendsTaskName,
            existingWorkPolicy: ExistingWorkPolicy.replace,
            constraints: Constraints(
              networkType: NetworkType.notRequired,
              requiresBatteryNotLow: false,
              requiresCharging: false,
              requiresDeviceIdle: false,
            ),
          );
          debugPrint(
            'MLProcessingService: Recommends task triggered immediately via WorkManager.',
          );
        } catch (e) {
          debugPrint('Failed to trigger recommends task via WorkManager: $e');
        }
      }
    } else {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('force_recommends_run', true);

        await Workmanager().registerOneOffTask(
          "${_wmRecommendsTaskId}_now",
          recommendsTaskName,
          existingWorkPolicy: ExistingWorkPolicy.replace,
          constraints: Constraints(
            networkType: NetworkType.notRequired,
            requiresBatteryNotLow: false,
            requiresCharging: false,
            requiresDeviceIdle: false,
          ),
        );
        debugPrint('Recommends task (one-off) triggered immediately.');
      } catch (e) {
        debugPrint('Failed to trigger recommends task immediately: $e');
      }
    }
  }

  Future<void> scheduleRecommendsTaskWithDelay(
    Duration delay, {
    bool forceReplace = false,
  }) async {
    if (kIsWeb) return;
    debugPrint(
      'MLProcessingService: Subscription checks bypassed for scheduleRecommendsTaskWithDelay.',
    );
    if (Platform.isAndroid) {
      try {
        await Workmanager().registerOneOffTask(
          "${_wmRecommendsTaskId}_delayed",
          recommendsTaskName,
          initialDelay: delay,
          existingWorkPolicy: forceReplace
              ? ExistingWorkPolicy.replace
              : ExistingWorkPolicy.keep,
          backoffPolicy: BackoffPolicy.linear,
          backoffPolicyDelay: const Duration(minutes: 5),
          constraints: Constraints(
            networkType: NetworkType.notRequired,
            requiresBatteryNotLow: false,
            requiresCharging: false,
            requiresDeviceIdle: false,
          ),
        );
        debugPrint(
          'Recommends task scheduled with delay of ${delay.inMinutes} minutes.',
        );
      } catch (e) {
        debugPrint('Failed to schedule delayed Recommends task: $e');
      }
    } else {
      Timer(delay, () async {
        try {
          await RecommendsAlgorithm.instance.runIfNeeded();
        } catch (e) {
          debugPrint('Delayed recommends run failed: $e');
        }
      });
      debugPrint(
        'Recommends task scheduled with delay of ${delay.inMinutes} minutes in-app.',
      );
    }
  }

  Future<void> checkAndScheduleRecommendsAppOpen() async {
    final prefs = await SharedPreferences.getInstance();

    // Condition 1: Must not running any ML_process like Tier 3 and 4
    final isAnyMlActive = await isAnyMlProcessingRunning();

    // Condition 2: Once run in a day
    final lastRunMs = prefs.getInt('last_recommends_daily_run') ?? 0;
    final lastRun = DateTime.fromMillisecondsSinceEpoch(lastRunMs);
    final now = DateTime.now();
    final isAlreadyRunToday = now.difference(lastRun).inHours < 24;

    debugPrint(
      'MLProcessingService: [AppOpen] Checking recommends run conditions: '
      'isAnyMlActive=$isAnyMlActive, isAlreadyRunToday=$isAlreadyRunToday (lastRun=$lastRun)',
    );

    if (!isAnyMlActive && !isAlreadyRunToday) {
      debugPrint(
        'MLProcessingService: [AppOpen] Conditions met. Scheduling recommends run in 1.5 hours.',
      );
      await scheduleRecommendsTaskWithDelay(
        const Duration(minutes: 90),
        forceReplace: true,
      );
    } else {
      debugPrint(
        'MLProcessingService: [AppOpen] Conditions NOT met for scheduling recommends.',
      );
    }
  }

  Future<void> cancelMidnightScanTask() async {
    if (kIsWeb) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('faces_task_scheduled', false);

    if (Platform.isAndroid) {
      try {
        await Workmanager().cancelByUniqueName(_wmMidnightTaskId);
        debugPrint('Midnight Background Scan task cancelled.');
      } catch (e) {
        debugPrint('Failed to cancel Midnight Background Scan task: $e');
      }
    }
  }

  Future<void> cancelAllBackgroundTasks() async {
    if (kIsWeb) return;
    if (Platform.isAndroid) {
      try {
        await Workmanager().cancelAll();
        debugPrint('All background tasks cancelled.');
      } catch (e) {
        debugPrint('Failed to cancel all background tasks: $e');
      }
    }
  }

  Future<void> triggerFacesReclustering() async {
    final db = DatabaseHelper.instance;
    await db.clearAllFacesAndPeopleData();
    await triggerFacesTaskNow();
  }

  void initializeWorkmanager() {
    if (kIsWeb) return;

    // Clear stuck background lock and start UI syncing on startup
    SharedPreferences.getInstance()
        .then((prefs) {
          prefs.remove('ghost_bg_heartbeat');
          startUiSync();

          final scheduled = prefs.getBool('faces_task_scheduled') ?? true;
          if (scheduled) {
            scheduleMidnightScanTask();
          }

          PackageInfo.fromPlatform()
              .then((packageInfo) {
                final version = packageInfo.version;
                if (version == '2.0.0') {
                  final reclusterDone =
                      prefs.getBool('reclustered_v2_0_0') ?? false;
                  if (!reclusterDone) {
                    triggerFacesReclustering()
                        .then((_) {
                          prefs.setBool('reclustered_v2_0_0', true);
                          debugPrint(
                            'Successfully scheduled face re-clustering for version 2.0.0',
                          );
                        })
                        .catchError((e) {
                          debugPrint(
                            'Failed to schedule face re-clustering: $e',
                          );
                        });
                  }
                }
              })
              .catchError((e) {
                debugPrint('Failed to read package info for version check: $e');
              });
        })
        .catchError((_) {});

    if (!kIsWeb && Platform.isAndroid) {
      try {
        Workmanager().initialize(callbackDispatcher, isInDebugMode: false);

        // Register the charging periodic task (checks for new media, processes Tier 2 & Tier 3 when charging)
        Workmanager().registerPeriodicTask(
          _wmChargingTaskId,
          chargingTaskName,
          frequency: const Duration(hours: 1), // run once an hour when charging
          existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
          constraints: Constraints(
            networkType: NetworkType.connected,
            requiresBatteryNotLow: true,
            requiresCharging: true, // MUST be charging
            requiresDeviceIdle: false,
            requiresStorageNotLow: true,
          ),
        );

        FlutterForegroundTask.init(
          androidNotificationOptions: AndroidNotificationOptions(
            channelId: 'ai_processing_channel',
            channelName: 'AI Image Processing',
            channelDescription: 'Shows progress bar for AI image scans',
            channelImportance: NotificationChannelImportance.LOW,
            priority: NotificationPriority.LOW,
            playSound: false,
            enableVibration: false,
          ),
          iosNotificationOptions: const IOSNotificationOptions(),
          foregroundTaskOptions: ForegroundTaskOptions(
            eventAction: ForegroundTaskEventAction.nothing(),
            autoRunOnBoot: false,
            allowWakeLock: true,
          ),
        );

        // Schedule the nightly recommends task
        scheduleRecommendsTask();

        debugPrint(
          'MLProcessingService: Workmanager & Foreground task service initialized.',
        );
      } catch (e) {
        debugPrint('Workmanager & ForegroundTask init error: $e');
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // APP OPEN CONSOLIDATED SYNC SEQUENCE (Checks only once on app open)
  // ══════════════════════════════════════════════════════════════════════════

  bool _isAppOpenSyncRunning = false;
  Timer? _monitoringTimer;
  final int _lastKnownItemCount = 0;

  Future<void> promoteToForegroundServiceIfPending() async {
    if (kIsWeb || !Platform.isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final locker = prefs.getString('ghost_bg_locker');
    if (locker == 'workmanager') {
      debugPrint(
        'MLProcessingService: Promoting WorkManager task to Foreground Service.',
      );
      try {
        await Workmanager().cancelByUniqueName(_wmUniqueTaskId);
        await Workmanager().cancelByUniqueName(_wmFacesTaskId);
        await Workmanager().cancelByUniqueName(
          "ghost_gallery_sync_task_unique",
        );
      } catch (_) {}
      await _releaseMutex(prefs);
    }
  }

  Future<void> performAppOpenSyncSequence() async {
    if (_isAppOpenSyncRunning) {
      debugPrint(
        'MLProcessingService: [AppOpenSync] Already running — skipping redundant trigger.',
      );
      return;
    }
    _isAppOpenSyncRunning = true;

    try {
      debugPrint(
        'MLProcessingService: [AppOpenSync] Starting foreground sync sequence...',
      );

      await promoteToForegroundServiceIfPending();

      // 2. Schedule/Start Tier 3 background task (schedules/runs WorkManager on Android, in-app on non-Android)
      await scheduleBackgroundTask(force: true);

      // Check and schedule recommends 1.5 hours later if conditions are met
      await checkAndScheduleRecommendsAppOpen();

      debugPrint(
        'MLProcessingService: [AppOpenSync] Foreground sync sequence finished successfully.',
      );
      await CollectionSource.instance.refresh();
    } catch (e) {
      debugPrint(
        'MLProcessingService: [AppOpenSync] Foreground check/enrichment failed → $e',
      );
    } finally {
      _isAppOpenSyncRunning = false;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // SCHEDULE BACKGROUND TASK
  //
  // Uses a FIXED unique task ID with ExistingWorkPolicy.keep so that if a
  // task is already queued/running, WorkManager silently ignores the duplicate
  // instead of queuing another engine-booting worker.
  //
  // Minimum initial delay is 1 minute — prevents the task from firing
  // immediately when the user quickly backgrounds and re-foregrounds the app.
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> scheduleForegroundMLTask(
    String taskName, {
    Map<String, dynamic>? inputData,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fg_active_task_name', taskName);
      if (inputData != null) {
        await prefs.setString('fg_active_task_input', jsonEncode(inputData));
      } else {
        await prefs.remove('fg_active_task_input');
      }

      if (await FlutterForegroundTask.isRunningService) {
        debugPrint('Foreground Service is already running.');
        return;
      }

      await FlutterForegroundTask.startService(
        serviceId: SystemNotificationService.progressNotificationId,
        notificationTitle: 'Ghost Gallery AI',
        notificationText: 'AI processing active...',
        notificationIcon: const NotificationIcon(
          metaDataName: 'com.pravera.flutter_foreground_task.notification_icon',
        ),
        callback: foregroundTaskEntry,
      );
      debugPrint('Foreground service started for task: $taskName');
    } catch (e) {
      debugPrint('Failed to start Foreground Service: $e');
    }
  }

  Future<void> scheduleBackgroundTask({bool force = false}) async {
    debugPrint(
      'MLProcessingService: Subscription checks bypassed for scheduleBackgroundTask.',
    );

    if (!_isBackgroundIsolate) {
      if (!force) {
        try {
          final bool anyPending = await DatabaseHelper.instance
              .hasTier3PendingWork();
          if (!anyPending) {
            debugPrint(
              'MLProcessingService: All items processed — Tier 3 skipped.',
            );
            return;
          }
        } catch (_) {}
      }

      if (!kIsWeb && Platform.isAndroid) {
        try {
          await Workmanager().cancelByUniqueName(_wmUniqueTaskId);
        } catch (_) {}
        await scheduleForegroundMLTask(backgroundTaskName);
        debugPrint(
          'MLProcessingService: Triggered Foreground Service for scanning/processing on app open.',
        );
      }
    } else {
      if (!kIsWeb && Platform.isAndroid) {
        if (!force) {
          try {
            final bool anyPending = await DatabaseHelper.instance
                .hasTier3PendingWork();
            if (!anyPending) {
              debugPrint(
                'MLProcessingService: All items processed — Tier 3 skipped.',
              );
              return;
            }
          } catch (_) {}
        }

        try {
          await Workmanager().registerOneOffTask(
            _wmUniqueTaskId,
            backgroundTaskName,
            initialDelay: const Duration(seconds: 5),
            existingWorkPolicy: ExistingWorkPolicy.replace,
            backoffPolicy: BackoffPolicy.linear,
            backoffPolicyDelay: const Duration(minutes: 1),
            constraints: Constraints(
              networkType: NetworkType.notRequired,
              requiresBatteryNotLow: false,
              requiresCharging: false,
              requiresDeviceIdle: false,
              requiresStorageNotLow: false,
            ),
          );
          debugPrint(
            'MLProcessingService: WorkManager background task scheduled immediately.',
          );
          try {
            await _mediaChannel.invokeMethod('scheduleMediaTriggerWork');
          } catch (e) {
            debugPrint(
              'Failed to schedule native media trigger WorkManager task: $e',
            );
          }
        } catch (e) {
          debugPrint('Workmanager register error: $e');
        }
      } 
    }
  }

  static Future<void> scheduleSyncBackgroundTask() async {
    debugPrint(
      'MLProcessingService: Subscription checks bypassed for scheduleSyncBackgroundTask.',
    );

    if (!MLProcessingService._isBackgroundIsolate) {
      if (!kIsWeb && Platform.isAndroid) {
        final prefs = await SharedPreferences.getInstance();
        final bool firstOpenCompleted =
            prefs.getBool('first_open_tier3_completed') ?? false;

        if (!firstOpenCompleted) {
          try {
            await Workmanager().cancelByUniqueName(
              "ghost_gallery_sync_task_unique",
            );
          } catch (_) {}
          await instance.scheduleForegroundMLTask("ghost_gallery_sync_task");
        } else {
          try {
            await Workmanager().registerOneOffTask(
              "ghost_gallery_sync_task_unique",
              "ghost_gallery_sync_task",
              initialDelay: const Duration(seconds: 0),
              existingWorkPolicy: ExistingWorkPolicy.replace,
              constraints: Constraints(
                networkType: NetworkType.notRequired,
                requiresBatteryNotLow: false,
                requiresCharging: false,
                requiresDeviceIdle: false,
                requiresStorageNotLow: false,
              ),
            );
            debugPrint(
              'MLProcessingService: Sync task scheduled directly via WorkManager.',
            );
          } catch (e) {
            debugPrint('Failed to schedule Sync task via WorkManager: $e');
          }
        }
      } else {
        try {
          await DeviceMediaScanner.instance.scanAndSyncDeviceMedia();
        } catch (_) {}
      }
    } else {
      if (!kIsWeb && Platform.isAndroid) {
        try {
          await Workmanager().registerOneOffTask(
            "ghost_gallery_sync_task_unique",
            "ghost_gallery_sync_task",
            initialDelay: const Duration(seconds: 0),
            existingWorkPolicy: ExistingWorkPolicy.keep,
            constraints: Constraints(
              networkType: NetworkType.notRequired,
              requiresBatteryNotLow: false,
              requiresCharging: false,
              requiresDeviceIdle: false,
              requiresStorageNotLow: false,
            ),
          );
          debugPrint(
            'MLProcessingService: WorkManager background sync task scheduled.',
          );
        } catch (e) {
          debugPrint('Workmanager sync register error: $e');
        }
      } else {
        try {
          await DeviceMediaScanner.instance.scanAndSyncDeviceMedia();
        } catch (e) {
          debugPrint('Sync inline fallback error: $e');
        }
      }
    }
  }

  static Future<void> scheduleEmbeddingBackgroundTask(String mediaId) async {
    debugPrint(
      'MLProcessingService: Subscription checks bypassed for scheduleEmbeddingBackgroundTask.',
    );

    if (!MLProcessingService._isBackgroundIsolate) {
      if (!kIsWeb && Platform.isAndroid) {
        final prefs = await SharedPreferences.getInstance();
        final bool firstOpenCompleted =
            prefs.getBool('first_open_tier3_completed') ?? false;

        if (!firstOpenCompleted) {
          try {
            await Workmanager().cancelByUniqueName(
              "ghost_gallery_embedding_task_$mediaId",
            );
          } catch (_) {}
          await instance.scheduleForegroundMLTask(
            "ghost_gallery_embedding_task",
            inputData: {"mediaId": mediaId},
          );
        } else {
          try {
            await Workmanager().registerOneOffTask(
              "ghost_gallery_embedding_task_$mediaId",
              "ghost_gallery_embedding_task",
              inputData: {"mediaId": mediaId},
              initialDelay: const Duration(seconds: 0),
              existingWorkPolicy: ExistingWorkPolicy.replace,
              constraints: Constraints(
                networkType: NetworkType.notRequired,
                requiresBatteryNotLow: false,
                requiresCharging: false,
                requiresDeviceIdle: false,
                requiresStorageNotLow: false,
              ),
            );
            debugPrint(
              'MLProcessingService: Embedding task scheduled directly via WorkManager.',
            );
          } catch (e) {
            debugPrint('Failed to schedule Embedding task via WorkManager: $e');
          }
        }
      } else {
        try {
          await instance.generateAndStoreMediaEmbedding(mediaId);
        } catch (_) {}
      }
    } else {
      if (!kIsWeb && Platform.isAndroid) {
        try {
          await Workmanager().registerOneOffTask(
            "ghost_gallery_embedding_task_$mediaId",
            "ghost_gallery_embedding_task",
            inputData: {"mediaId": mediaId},
            initialDelay: const Duration(seconds: 0),
            existingWorkPolicy: ExistingWorkPolicy.keep,
            constraints: Constraints(
              networkType: NetworkType.notRequired,
              requiresBatteryNotLow: false,
              requiresCharging: false,
              requiresDeviceIdle: false,
              requiresStorageNotLow: false,
            ),
          );
          debugPrint(
            'MLProcessingService: WorkManager background embedding task scheduled for $mediaId.',
          );
        } catch (e) {
          debugPrint('Workmanager embedding register error: $e');
        }
      } else {
        try {
          await instance.generateAndStoreMediaEmbedding(mediaId);
        } catch (e) {
          debugPrint('Embedding inline fallback error: $e');
        }
      }
    }
  }

  static const MethodChannel _mediaChannel = MethodChannel(
    'in.sddev.ghost_gallery/media_manager',
  );

  static Future<bool> isAnyMlProcessingRunning() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final int heartbeat = prefs.getInt('ghost_bg_heartbeat') ?? 0;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final bool isTier3Running = heartbeat != 0 && (now - heartbeat) < 30000;
    final bool isTier4Running = prefs.getBool('ghost_faces_running') ?? false;
    return isTier3Running || isTier4Running;
  }

  static Future<bool> isDeviceCharging() async {
    if (!Platform.isAndroid) {
      return true; // non-Android: bypass or default to true
    }
    try {
      final bool? isCharging = await _mediaChannel.invokeMethod<bool>(
        'isDeviceCharging',
      );
      return isCharging ?? false;
    } catch (_) {
      return false;
    }
  }

  // ── Battery Optimization Exemption ──────────────────────────────────────────
  // On most OEM Android devices (Xiaomi, Huawei, Samsung …) aggressive battery
  // management kills WorkManager tasks when the app is swiped from recents.
  // Requesting exemption from battery optimization is the standard Android API
  // to prevent this — it whitelists the app in the system's Doze/App Standby
  // bucket, ensuring background tasks continue uninterrupted.

  /// Returns true if the app is already exempt from battery optimization.
  /// Always returns true on non-Android platforms.
  static Future<bool> isBatteryOptimizationExempt() async {
    if (!Platform.isAndroid) return true;
    try {
      final bool? exempt = await _mediaChannel.invokeMethod<bool>(
        'isBatteryOptimizationExempt',
      );
      return exempt ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system dialog asking the user to disable battery optimization
  /// for this app. Falls back to the general battery optimization settings
  /// page if the direct intent is not available (some OEMs).
  static Future<void> requestBatteryOptimizationExemption() async {
    if (!Platform.isAndroid) return;
    try {
      await _mediaChannel.invokeMethod<void>(
        'requestBatteryOptimizationExemption',
      );
    } catch (_) {}
  }


  // ══════════════════════════════════════════════════════════════════════════
  // TIER 2 — METADATA ENRICHMENT (foreground, fast)
  //
  // Only runs EXIF/GPS/geocoding. No MLKit, no previews, no embeddings.
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> runMetadataEnrichmentTier2() async {
    try {
      final db = DatabaseHelper.instance;

      // ── Early-exit guard ─────────────────────────────────────────────────
      // Skip the entire loop if all items already have metadata_ready = 1.
      final bool anyPending = await db.hasTier2PendingWork();
      if (!anyPending) {
        debugPrint(
          'MLProcessingService: All items have EXIF metadata — Tier 2 skipped.',
        );
        return;
      }

      debugPrint(
        'MLProcessingService: Starting EXIF metadata enrichment queue...',
      );

      int processedCount = 0;
      while (true) {
        final pending = await db.getMetadataPendingItems(50);
        if (pending.isEmpty) {
          debugPrint(
            'MLProcessingService: No pending EXIF metadata items found.',
          );
          break;
        }

        debugPrint(
          'MLProcessingService: Processing batch of ${pending.length} pending metadata items...',
        );

        for (final item in pending) {
          try {
            debugPrint(
              'MLProcessingService: Extracting EXIF for item: ${item['id']} (${item['path']})',
            );
            await processMediaItemTier2(
              item['id'] as String,
              item['path'] as String,
              item['media_type'] as String,
            );
            await db.updateMetadataReady(item['id'] as String);
            processedCount++;
          } catch (e) {
            debugPrint(
              'MLProcessingService: Tier2 error for ${item['id']} → $e',
            );
            // Mark done even on error so we don't retry forever
            await db.updateMetadataReady(item['id'] as String);
          }
        }

        if (!MLProcessingService._isBackgroundIsolate) {
          DeviceMediaScanner.instance.notifyChange(); // progressive UI update
        }
      }
      debugPrint(
        'MLProcessingService: EXIF metadata enrichment finished. Processed $processedCount items.',
      );
      // Decoupled: reclusterAllFaces() is reserved for user-initiated actions
      // to avoid runaway merges on background metadata sync.
    } catch (e) {
      debugPrint('MLProcessingService: runMetadataEnrichmentTier2 error → $e');
    }
  }

  // ─── ADD NEW PUBLIC METHOD: reclusterAllFaces() ───────────────────────────────
  // This is the "Google Photos periodic re-cluster" equivalent.
  //
  // WHEN TO CALL IT:
  //   • After DeviceMediaScanner finishes a full scan batch.
  //   • After the user manually merges or renames a person.
  //   • Optionally on app launch (if >N new faces were added since last run).
  //
  // WHAT IT DOES:
  //   1. Loads all stored face embeddings and their current person assignments.
  //   2. Runs a single-linkage agglomerative pass:
  //      - builds a similarity graph where edges exist between faces that
  //        are above the cosine threshold
  //      - uses Union-Find to assign connected components to the same person
  //   3. Merges DB person records that ended up in the same component
  //      (preserving named/manually-labelled persons wherever possible).
  //   4. Splits any person whose internal faces have poor cohesion.
  //      (detects "merged strangers" — same problem Google Photos asks you
  //       to confirm manually)
  //
  // COMPLEXITY: O(n²) where n = number of stored faces.
  // For 10 000 photos with avg 1.2 faces each → 12 000 faces → ~144M ops.
  // Running in compute() keeps UI smooth. Should finish in < 5 s on a mid-range
  // Android device.
  Future<void> reclusterAllFaces() async {
    try {
      debugPrint('reclusterAllFaces: Starting global face re-clustering…');
      final db = DatabaseHelper.instance;

      final allFaces = await db.getAllFaces();
      if (allFaces.length < 2) return;

      // Filter to faces that have valid 192-D embeddings only
      final List<_FaceRecord> records = [];
      for (final f in allFaces) {
        final pid = f['person_id'] as String?;
        final embStr = f['embedding'] as String?;
        if (embStr == null ||
            embStr == 'null' ||
            embStr.isEmpty ||
            pid == null) {
          continue;
        }
        final parts = embStr.split(',');
        if (parts.length != _embeddingDims) continue;
        final vec = parts
            .map((s) => double.tryParse(s) ?? 0.0)
            .toList(growable: false);
        records.add(
          _FaceRecord(faceId: f['id'] as String, personId: pid, embedding: vec),
        );
      }

      if (records.length < 2) return;

      // Run the agglomerative single-linkage pass in a compute() isolate so the
      // UI stays smooth even with thousands of faces.
      final List<List<String>> components = await compute(
        _agglomerativeClusterIsolate,
        records,
      );

      if (components.isEmpty) {
        debugPrint('reclusterAllFaces: No merges needed — clusters look good.');
        return;
      }

      int mergedCount = 0;
      for (final component in components) {
        // Query database to get name for each person in component
        final List<Map<String, dynamic>> peopleDetails = [];
        for (final pid in component) {
          final p = await db.getPersonById(pid);
          if (p != null) {
            peopleDetails.add(p);
          }
        }

        // Separate named vs unnamed
        final List<String> namedIds = [];
        final List<String> unnamedIds = [];

        for (final p in peopleDetails) {
          final id = p['id'] as String;
          final name = p['name'] as String? ?? '';
          if (name.isNotEmpty &&
              name != 'Unknown Person' &&
              !RegExp(r'^Person \d+$').hasMatch(name)) {
            namedIds.add(id);
          } else {
            unnamedIds.add(id);
          }
        }

        String? targetId;
        List<String> sourcesToMerge = [];

        if (namedIds.isNotEmpty) {
          // Target is the first named person
          targetId = namedIds.first;
          // Merge all unnamed persons into this target
          sourcesToMerge.addAll(unnamedIds);
          // If there are other named persons, we do NOT merge them to prevent false merges of different named people.
        } else if (unnamedIds.isNotEmpty) {
          // No named persons: pick lexicographically smallest ID
          final sortedUnnamed = List<String>.from(unnamedIds)..sort();
          targetId = sortedUnnamed.first;
          sourcesToMerge.addAll(sortedUnnamed.skip(1));
        }

        if (targetId != null && sourcesToMerge.isNotEmpty) {
          debugPrint(
            'reclusterAllFaces: Merging ${sourcesToMerge.length} person(s) into $targetId',
          );
          await db.mergePeople(targetId, sourcesToMerge);
          mergedCount += sourcesToMerge.length;
        }
      }

      debugPrint(
        'reclusterAllFaces: Done. Merged $mergedCount person(s) total.',
      );
      if (!MLProcessingService._isBackgroundIsolate) {
        DeviceMediaScanner.instance.notifyChange();
      }
    } catch (e) {
      debugPrint('reclusterAllFaces error: $e');
    }
  }

  /// Isolate entry point for agglomerative clustering.
  /// Uses UPGMA (Average-Linkage) hierarchical clustering to prevent runaway merges.
  /// Returns components as lists of connected personIds.
  static List<List<String>> _agglomerativeClusterIsolate(
    List<_FaceRecord> records,
  ) {
    // 1. Group records by person ID
    final Map<String, List<_FaceRecord>> personFaces = {};
    for (final r in records) {
      personFaces.putIfAbsent(r.personId, () => []).add(r);
    }

    final List<String> pids = personFaces.keys.toList();
    final int numPeople = pids.length;
    if (numPeople < 2) return [];

    // Union-Find on person indices (0 to numPeople - 1)
    final List<int> parent = List.generate(numPeople, (i) => i);

    int find(int i) {
      while (parent[i] != i) {
        parent[i] = parent[parent[i]]; // path compression
        i = parent[i];
      }
      return i;
    }

    void union(int a, int b) {
      a = find(a);
      b = find(b);
      if (a != b) parent[a] = b;
    }

    // 2. Precompute the average similarity matrix elements.
    // sumSim[i][j] is the sum of similarities between faces of person i and person j.
    // countSim[i][j] is the count of comparisons.
    // Using a threshold of 0.50 for UPGMA to be conservative and prevent false merges.
    const double mergeThreshold = 0.50;

    final List<List<double>> sumSim = List.generate(
      numPeople,
      (_) => List.filled(numPeople, 0.0),
    );
    final List<List<int>> countSim = List.generate(
      numPeople,
      (_) => List.filled(numPeople, 0),
    );

    for (int i = 0; i < numPeople; i++) {
      final facesI = personFaces[pids[i]]!;
      for (int j = i + 1; j < numPeople; j++) {
        final facesJ = personFaces[pids[j]]!;
        double sum = 0.0;
        for (final fI in facesI) {
          for (final fJ in facesJ) {
            sum += _cosineSimilarity(fI.embedding, fJ.embedding);
          }
        }
        sumSim[i][j] = sum;
        sumSim[j][i] = sum;
        final count = facesI.length * facesJ.length;
        countSim[i][j] = count;
        countSim[j][i] = count;
      }
    }

    // activeClusters is a list of sets of original person indices.
    final List<Set<int>> activeClusters = List.generate(numPeople, (i) => {i});

    while (activeClusters.length > 1) {
      int bestI = -1;
      int bestJ = -1;
      double bestSim = -1.0;

      for (int i = 0; i < activeClusters.length; i++) {
        for (int j = i + 1; j < activeClusters.length; j++) {
          double sum = 0.0;
          int count = 0;
          for (final idxA in activeClusters[i]) {
            for (final idxB in activeClusters[j]) {
              sum += sumSim[idxA][idxB];
              count += countSim[idxA][idxB];
            }
          }
          final double avg = count > 0 ? sum / count : -1.0;
          if (avg > bestSim) {
            bestSim = avg;
            bestI = i;
            bestJ = j;
          }
        }
      }

      if (bestSim >= mergeThreshold) {
        // Merge cluster J into cluster I
        activeClusters[bestI].addAll(activeClusters[bestJ]);

        // Record the union in Union-Find
        final int firstA = activeClusters[bestI].first;
        for (final idxB in activeClusters[bestJ]) {
          union(firstA, idxB);
        }

        activeClusters.removeAt(bestJ);
      } else {
        break;
      }
    }

    // 3. Build component -> list of original personIds
    final Map<int, Set<String>> componentPersons = {};
    for (int i = 0; i < numPeople; i++) {
      final int root = find(i);
      componentPersons.putIfAbsent(root, () => {}).add(pids[i]);
    }

    return componentPersons.values
        .where((s) => s.length > 1)
        .map((s) => s.toList())
        .toList();
  }

  Future<void> processMediaItemTier2(
    String mediaId,
    String path,
    String mediaType,
  ) async {
    final db = DatabaseHelper.instance;
    final file = File(path);

    if (!file.existsSync() || file.lengthSync() == 0) return;

    try {
      Map<String, IfdTag> exifTags = {};
      if (mediaType == 'image') {
        try {
          Uint8List? bytes;
          if (Platform.isAndroid) {
            bytes = await TrashPersistence.getMediaBytes(
              mediaId: mediaId,
              filePath: path,
            );
          }
          bytes ??= await file.readAsBytes();
          exifTags = await readExifFromBytes(bytes);
        } catch (e) {
          print("[Ml_Process_exit_1629] ERROR: $e");
        }
      }

      final DateTime dateTaken =
          ExifExtractor.parseDateTaken(exifTags) ?? file.lastModifiedSync();

      final int width = exifTags.containsKey('EXIF ExifImageWidth')
          ? (int.tryParse(exifTags['EXIF ExifImageWidth']!.printable) ?? 800)
          : 800;
      final int height = exifTags.containsKey('EXIF ExifImageLength')
          ? (int.tryParse(exifTags['EXIF ExifImageLength']!.printable) ?? 600)
          : 600;

      final double? lat = ExifExtractor.parseGpsLatitude(exifTags);
      final double? lng = ExifExtractor.parseGpsLongitude(exifTags);

      print("[Ml_Process_GEOCODE_1648] $exifTags");

      final AddressInfo addr = await GhostGeocodingService.instance
          .reverseGeocode(lat ?? 0.0, lng ?? 0.0);
      final String folderName = basename(dirname(path));
      final String locationStr = addr.longString != 'Unknown Location'
          ? addr.longString
          : _locationFromFolderName(folderName);

      final String cameraInfo = ExifExtractor.parseCameraInfo(exifTags);
      final int sizeBytes = await file.length();
      final CameraSettings settings = ExifExtractor.parseCameraSettings(
        exifTags,
      );
      final String? mimeType = ExifExtractor.parseMimeType(exifTags, path);
      final int rotationDegrees = ExifExtractor.parseRotationDegrees(exifTags);
      final bool isFlipped = ExifExtractor.parseIsFlipped(exifTags);

      final bool isAnimated = ExifExtractor.detectIsAnimated(path);
      final bool isHdr = ExifExtractor.detectHdr(exifTags, path);
      final bool is360 = ExifExtractor.detectIs360(exifTags, width, height);
      final bool isPano = ExifExtractor.detectIsPanorama(
        exifTags,
        width,
        height,
      );
      final bool isBurst = ExifExtractor.detectIsBurst(exifTags, path);
      final bool isMotion = ExifExtractor.detectIsMotionPhoto(
        exifTags,
        mimeType,
      );
      final bool isPortrait = ExifExtractor.detectIsPortrait(exifTags, path);

      final int flags = MediaFlags.compute(
        animated: isAnimated,
        flipped: false,
        hdr: isHdr,
        is360: is360,
        panorama: isPano,
        burst: isBurst,
        motionPhoto: isMotion,
        portrait: isPortrait,
      );

      final List<String> subjects = ExifExtractor.parseXmpSubjects(exifTags);
      final String? xmpSubjects = subjects.isNotEmpty
          ? subjects.join(';')
          : null;
      final String? xmpTitle = ExifExtractor.parseXmpTitle(exifTags);
      final int rating = ExifExtractor.parseRating(exifTags);

      print(
        "[ML_PROSSING] : ${{'location': locationStr, 'latitude': lat ?? 0.0, 'longitude': lng ?? 0.0, 'width': width, 'height': height, 'size': _formatBytes(sizeBytes), 'camera_info': cameraInfo, 'flags': flags, 'rotation_degrees': rotationDegrees, 'is_flipped': isFlipped ? 1 : 0, 'mime_type': mimeType, 'aperture': settings.aperture, 'iso': settings.iso, 'focal_length': settings.focalLength, 'exposure_time': settings.exposureTime, 'flash': settings.flash, 'xmp_subjects': xmpSubjects, 'xmp_title': xmpTitle, 'rating': rating, 'country_code': addr.countryCode, 'country_name': addr.countryName, 'admin_area': addr.adminArea, 'locality': addr.locality, 'sub_locality': addr.subLocality, 'feature_name': addr.featureName}} ",
      );

      await db.updateMediaRichMetadata(mediaId, {
        'location': locationStr,
        'latitude': lat ?? 0.0,
        'longitude': lng ?? 0.0,
        'width': width,
        'height': height,
        'size': _formatBytes(sizeBytes),
        'camera_info': cameraInfo,
        'flags': flags,
        'mime_type': mimeType,
        'aperture': settings.aperture,
        'iso': settings.iso,
        'focal_length': settings.focalLength,
        'exposure_time': settings.exposureTime,
        'flash': settings.flash,
        'xmp_subjects': xmpSubjects,
        'xmp_title': xmpTitle,
        'rating': rating,
        'country_code': addr.countryCode,
        'country_name': addr.countryName,
        'admin_area': addr.adminArea,
        'locality': addr.locality,
        'sub_locality': addr.subLocality,
        'feature_name': addr.featureName,
      });
    } catch (e) {
      debugPrint("processMediaItemTier2 error for $path → $e");
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // TIER 3 — HEAVY PROCESSING (background only)
  //
  // MLKit (labels + OCR + face detection) + face embedding + preview
  // thumbnail + search vector embedding. Called ONLY from:
  //   • _runFallbackInAppProcessingTier3 (when isAppInForeground == false)
  //   • callbackDispatcher (Workmanager, when SharedPrefs says not open)
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> processMediaItemTier3(
    String mediaId,
    String path,
    String mediaType,
    double? duration, {
    int? originalStatus,
  }) async {
    final db = DatabaseHelper.instance;
    final file = File(path);

    if (!file.existsSync() || file.lengthSync() == 0) {
      await db.updateMediaItemProcessedStatus(mediaId, 1);
      await db.updateMediaItemFacesProcessedStatus(mediaId, 1);
      return;
    }

    logNotifier.value = "Processing: ${basename(path)}";

    try {
      await Future(() async {
        // Step 1: ML processing (tags, OCR, faces)
        if (mediaType == 'video') {
          await _processVideo(mediaId, path, duration ?? 0.0, db);
        } else {
          await _processImage(mediaId, path, db);
        }

        // Step 2: Face clustering/processing (Tier 4) inline
        try {
          await processMediaItemTier4(
            mediaId,
            path,
            db,
            mediaType: mediaType,
            duration: duration,
          );
        } catch (ex) {
          debugPrint("Tier 4 inline face processing error: $ex");
        }

        // Step 3: Generate search embedding (vector-based)
        try {
          await generateAndStoreMediaEmbedding(mediaId);
        } catch (ex) {
          debugPrint("Embedding generation error: $ex");
        }
      }).timeout(const Duration(seconds: 60));

      await db.updateMediaItemProcessedStatus(mediaId, 1);
      await db.updateMediaItemFacesProcessedStatus(mediaId, 1);
      await Future.delayed(const Duration(milliseconds: 50));
    } catch (e) {
      debugPrint("processMediaItemTier3 error/timeout for $path → $e");
      try {
        if (originalStatus == 4) {
          // Already failed once. Mark as completed (1) to skip it permanently.
          await db.updateMediaItemProcessedStatus(mediaId, 1);
          await db.updateMediaItemFacesProcessedStatus(mediaId, 1);
        } else {
          // First failure. Mark as status 4 to schedule for a retry.
          await db.updateMediaItemProcessedStatus(mediaId, 4);
          await db.updateMediaItemFacesProcessedStatus(mediaId, 4);
        }
      } catch (_) {}
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // LEGACY ENTRY POINT — kept for any callers that used processMediaItem().
  // Now routes to Tier2 (metadata) + Tier3 (ML) in sequence.
  // Only call this from contexts where you know both tiers are appropriate
  // (e.g. manual "re-process" action from UI).
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> processMediaItem(
    String mediaId,
    String path,
    String mediaType,
    double? duration,
  ) async {
    await processMediaItemTier2(mediaId, path, mediaType);
    await processMediaItemTier3(mediaId, path, mediaType, duration);
  }

  Future<void> prioritizeItem(
    String mediaId,
    String path,
    String mediaType,
    double? duration,
  ) async {
    try {
      final db = DatabaseHelper.instance;
      final dbItem = await db.getMediaItemById(mediaId);
      if (dbItem == null) return;

      // 1. Prioritize Tier 2
      final bool needsTier2 = (dbItem['metadata_ready'] as int? ?? 0) == 0;
      if (needsTier2) {
        debugPrint(
          'MLProcessingService: Priority Tier 2 processing for $mediaId',
        );
        await processMediaItemTier2(mediaId, path, mediaType);
        await db.updateMetadataReady(mediaId);
      }

      // 2. Prioritize Tier 3
      final bool needsTier3 = (dbItem['is_processed'] as int? ?? 0) != 1;
      if (needsTier3) {
        debugPrint(
          'MLProcessingService: Priority Tier 3 processing for $mediaId',
        );
        // Temporarily lock it as processing
        await db.updateMediaItemProcessedStatus(mediaId, 2);
        await processMediaItemTier3(mediaId, path, mediaType, duration);
      }

      DeviceMediaScanner.instance.notifyChange();
    } catch (e) {
      debugPrint('MLProcessingService: Error prioritizing item $mediaId: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 128-D FACE EMBEDDING (runs in isolate)
  // ══════════════════════════════════════════════════════════════════════════

  Future<List<double>?> extract128DFaceEmbedding(
    String imagePath,
    int x,
    int y,
    int w,
    int h,
  ) async {
    if (w < 20 || h < 20) {
      return null;
    }
    try {
      return await _computeEmbedding(imagePath, x, y, w, h);
    } catch (e) {
      debugPrint("Embedding extraction error → $e");
      return null;
    }
  }

  static Interpreter? _faceNetInterpreter;

  static Future<Interpreter> _getInterpreter() async {
    if (_faceNetInterpreter != null) return _faceNetInterpreter!;
    _faceNetInterpreter = await Interpreter.fromAsset(
      'assets/models/mobile_face_net.tflite',
    );
    return _faceNetInterpreter!;
  }

  static Future<List<double>?> _computeEmbedding(
    String imagePath,
    int x,
    int y,
    int w,
    int h,
  ) async {
    try {
      final file = File(imagePath);
      if (!file.existsSync()) return null;

      Uint8List? rgbBytes;
      if (Platform.isAndroid) {
        try {
          rgbBytes = await _mediaChannel.invokeMethod<Uint8List>(
            'cropAndResizeFace',
            {
              'path': imagePath,
              'x': x,
              'y': y,
              'w': w,
              'h': h,
              'padding': _cropPadding,
            },
          );
        } catch (e) {
          debugPrint("Native face crop failed, falling back to pure-Dart: $e");
        }
      }

      final List<List<List<List<double>>>> input;
      const int targetSize = 112;

      if (rgbBytes != null && rgbBytes.length == targetSize * targetSize * 3) {
        // Construct input tensor directly from native RGB bytes
        input = List.generate(
          1,
          (_) => List.generate(
            targetSize,
            (row) => List.generate(targetSize, (col) {
              final idx = (row * targetSize + col) * 3;
              final r = rgbBytes![idx];
              final g = rgbBytes[idx + 1];
              final b = rgbBytes[idx + 2];
              return [
                (r.toDouble() - 128.0) / 128.0,
                (g.toDouble() - 128.0) / 128.0,
                (b.toDouble() - 128.0) / 128.0,
              ];
            }),
          ),
        );
      } else {
        // Pure-Dart fallback
        final Uint8List bytes = await file.readAsBytes();
        final img.Image? decoded = img.decodeImage(bytes);
        if (decoded == null) return null;

        final int padX = (w * _cropPadding).round();
        final int padY = (h * _cropPadding).round();

        final int cropX = (x - padX).clamp(0, decoded.width - 1);
        final int cropY = (y - padY).clamp(0, decoded.height - 1);
        final int cropW = (w + padX * 2).clamp(1, decoded.width - cropX);
        final int cropH = (h + padY * 2).clamp(1, decoded.height - cropY);

        final img.Image cropped = img.copyCrop(
          decoded,
          x: cropX,
          y: cropY,
          width: cropW,
          height: cropH,
        );
        final img.Image resizedFace = img.copyResize(
          cropped,
          width: targetSize,
          height: targetSize,
          interpolation: img.Interpolation.linear,
        );

        input = List.generate(
          1,
          (_) => List.generate(
            targetSize,
            (row) => List.generate(targetSize, (col) {
              final pixel = resizedFace.getPixel(col, row);
              return [
                (pixel.r.toDouble() - 128.0) / 128.0,
                (pixel.g.toDouble() - 128.0) / 128.0,
                (pixel.b.toDouble() - 128.0) / 128.0,
              ];
            }),
          ),
        );
      }

      final interpreter = await _getInterpreter();
      final output = List.generate(1, (_) => List.filled(_embeddingDims, 0.0));
      interpreter.run(input, output);

      return _l2Normalize(List<double>.from(output[0]));
    } catch (e) {
      debugPrint("FaceNet embedding extraction error: $e");
      return null;
    }
  }

  static List<double>? _l2Normalize(List<double> v) {
    double sum = 0;
    for (final x in v) {
      sum += x * x;
    }
    final double norm = sqrt(sum);
    if (norm < 1e-6) {
      return null;
    }
    return v.map((x) => x / norm).toList();
  }

  static List<double> _fallbackEmbedding(String seed) {
    final rand = Random(seed.hashCode);
    return _l2Normalize(
      List<double>.generate(
        _embeddingDims,
        (_) => rand.nextDouble() * 2.0 - 1.0,
      ),
    )!;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // COSINE SIMILARITY
  // ══════════════════════════════════════════════════════════════════════════

  /// Cosine similarity for two L2-normalised vectors.
  /// Returns value in [-1, 1]. Higher = more similar.
  /// For L2-normalised vectors: cosSim(a,b) = dot(a,b) = 1 - (euclidean²/2).
  static double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return -1.0;
    double dot = 0.0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
    }
    // Clamp to [-1, 1] to guard against floating-point drift
    return dot.clamp(-1.0, 1.0);
  }

  // EUCLIDEAN DISTANCE
  // ══════════════════════════════════════════════════════════════════════════

  double euclideanDistance(List<double> a, List<double> b) {
    if (a.length != b.length) return double.maxFinite;
    double sum = 0.0;
    for (int i = 0; i < a.length; i++) {
      final double diff = a[i] - b[i];
      sum += diff * diff;
    }
    return sqrt(sum);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // CENTROID-BASED FACE CLUSTERING
  // ══════════════════════════════════════════════════════════════════════════

  // Threshold on L2-normalised 192-D FaceNet Euclidean distance.
  // For standard MobileFaceNet, intra-cluster distances for the same person
  // are typically < 0.70; different people typically have distances > 1.00.
  // Replace the old constants block starting with:
  //   static const double _distanceThreshold = 0.70;
  //   static const int _minVotesSmallCluster = 1;
  //   static const int _minVotesLargeCluster = 2;

  /// Cosine similarity threshold.
  /// Same-person pairs from ArcFace/MobileFaceNet typically score > 0.50.
  /// Different-person pairs typically score < 0.30.
  /// 0.40 gives a good recall/precision balance for a personal gallery.
  /// Updated to 0.72 to match the face unlock threshold.
  static const double _cosineSimilarityThreshold = 0.72;

  /// When a cluster already has 5+ faces, require a slightly higher bar
  /// to prevent large clusters from "absorbing" nearby strangers.
  static const double _cosineSimilarityThresholdStrict = 0.75;

  /// Face embedding dimension (MobileFaceNet output = 192).
  static const int _embeddingDims = 192;

  /// Padding fraction applied around the MLKit bounding box before cropping.
  /// 0.20 = 20% on each side. Matches FaceNet training crop convention.
  static const double _cropPadding = 0.20;

  Future<String> clusterFaceAndGetPersonId(
    List<double> embedding,
    String imagePath,
    int x,
    int y,
    int w,
    int h, {
    List<String> excludePersonIds = const [],
  }) async {
    final db = DatabaseHelper.instance;
    final allFaces = await db.getAllFaces();

    // ── Build per-person score table ─────────────────────────────────────────
    // For each candidate person we collect ALL their face embeddings, compute
    // cosine similarity with the incoming embedding, and record the BEST match
    // (not centroid). This is equivalent to single-linkage matching, which is
    // far more robust than centroid-based matching for personal photo galleries.

    final Map<String, _PersonMatchStats> personStats = {};

    for (final face in allFaces) {
      final pid = face['person_id'] as String?;
      if (pid == null || excludePersonIds.contains(pid)) continue;

      final embStr = face['embedding'] as String?;
      if (embStr == null || embStr == 'null' || embStr.isEmpty) continue;

      final parts = embStr.split(',');
      if (parts.length != _embeddingDims) continue; // skip incompatible dims

      final vec = parts
          .map((s) => double.tryParse(s) ?? 0.0)
          .toList(growable: false);
      final double sim = _cosineSimilarity(embedding, vec);

      personStats.putIfAbsent(pid, () => _PersonMatchStats()).update(sim);
    }

    // ── Pick best matching person ─────────────────────────────────────────────
    String? bestPid;
    double bestSim = -1.0;

    for (final entry in personStats.entries) {
      final pid = entry.key;
      final stats = entry.value;

      // Use stricter threshold for well-established clusters (5+ faces) to
      // prevent a large "Mum" cluster from absorbing an aunt who visited once.
      final double threshold = stats.count >= 5
          ? _cosineSimilarityThresholdStrict
          : _cosineSimilarityThreshold;

      if (stats.bestSim >= threshold && stats.bestSim > bestSim) {
        bestSim = stats.bestSim;
        bestPid = pid;
      }
    }

    if (bestPid != null) {
      await _maybeUpdatePersonCover(bestPid, imagePath, x, y, w, h);
      return bestPid;
    }

    // ── No match — create a new person cluster ────────────────────────────────
    final newPid =
        'person_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(9999)}';

    final people = await db.getAllPeople();
    int maxPersonNum = 0;
    final personRegex = RegExp(r'^Person (\d+)$');
    for (final p in people) {
      final name = p['name'] as String? ?? '';
      final match = personRegex.firstMatch(name);
      if (match != null) {
        final num = int.tryParse(match.group(1) ?? '0') ?? 0;
        if (num > maxPersonNum) {
          maxPersonNum = num;
        }
      }
    }
    final newName = 'Person ${maxPersonNum + 1}';

    await db.insertPerson({
      'id': newPid,
      'name': newName,
      'dob': '',
      'relation': '',
      'cover_image': imagePath,
      'cover_x': x,
      'cover_y': y,
      'cover_w': w,
      'cover_h': h,
    });
    return newPid;
  }

  Future<void> _maybeUpdatePersonCover(
    String personId,
    String imagePath,
    int x,
    int y,
    int w,
    int h,
  ) async {
    final db = DatabaseHelper.instance;
    final person = await db.getPersonById(personId);
    if (person == null) return;
    final bool isCustom = (person['is_custom_cover'] as int? ?? 0) == 1 ||
        ((person['cover_image'] as String?)?.contains('profile_pictures') ?? false);
    if (isCustom) return;
    final int storedArea =
        ((person['cover_w'] as int?) ?? 0) * ((person['cover_h'] as int?) ?? 0);
    final int area = w * h;
    if (area > storedArea) {
      await db.updatePersonCover(personId, imagePath, x, y, w, h);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BACKGROUND QUEUE (used by manual triggers / legacy paths)
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> startBackgroundQueue(
    List<Map<String, dynamic>> mediaItems,
  ) async {
    if (isProcessingNotifier.value) return;
    isProcessingNotifier.value = true;
    progressNotifier.value = 0.0;

    final pending = mediaItems.where((x) => x['is_processed'] != 1).toList();
    if (pending.isEmpty) {
      isProcessingNotifier.value = false;
      return;
    }

    logNotifier.value = "AI processing: 0 of ${pending.length}";

    const int batchSize = 20;
    int done = 0;
    bool finishedAll = false;

    for (int i = 0; i < pending.length; i += batchSize) {
      final batch = pending.skip(i).take(batchSize).toList();
      final int remainingLeft = (pending.length - (i + batch.length)).clamp(
        0,
        pending.length,
      );
      int itemIndex = 0;
      for (final item in batch) {
        try {
          await processMediaItemTier3(
            item['id'] as String,
            item['path'] as String,
            item['media_type'] as String,
            item['duration'] as double?,
          );
          await Future.delayed(const Duration(milliseconds: 300));
        } catch (e) {
          debugPrint("MLProcessingService: item error → $e");
        }
        done++;
        itemIndex++;
        progressNotifier.value = done / pending.length;
        logNotifier.value = "AI processing: $done of ${pending.length}";
        SystemNotificationService.instance.showProgressNotification(
          done,
          pending.length,
          remainingLeft: remainingLeft,
        );
      }

      // Run face clustering graph update after each batch
      await reclusterAllFaces();

      if (i + batchSize < pending.length) {
        await Future.delayed(const Duration(milliseconds: 500));
      } else {
        finishedAll = true;
      }
    }

    progressNotifier.value = 1.0;
    logNotifier.value = "All done! 👻";
    
    SystemNotificationService.instance.dismissNotification();
    isProcessingNotifier.value = false;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // IMAGE ML PIPELINE
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _processImage(
    String mediaId,
    String path,
    DatabaseHelper db,
  ) async {
    final existingTags = await db.getObjectsForMedia(mediaId);
    if (existingTags.isNotEmpty) {
      return; // fully done
    }

    // Clean up OCR and objects only, preserve any processed face records
    await db.clearOcrAndObjectsForMedia(mediaId);

    // Run ML without face detection (runFaces = false)
    final results = await _runML(path, runFaces: false);

    final expandedTags = _expandTags(results.tags);
    for (final tag in expandedTags) {
      await db.insertObject({
        'media_id': mediaId,
        'label': tag,
        'confidence': 0.90,
      });
    }

    if (results.ocrText.isNotEmpty) {
      await db.insertOcrText({
        'media_id': mediaId,
        'text': results.ocrText.join(' '),
        'confidence': 0.88,
      });
    }
  }

  Future<void> processMediaItemTier4(
    String mediaId,
    String path,
    DatabaseHelper db, {
    String? mediaType,
    double? duration,
  }) async {
    final file = File(path);
    if (!file.existsSync()) {
      debugPrint('processMediaItemTier4: skipping, file does not exist: $path');
      return;
    }

    final itemRecord = await db.getMediaItemById(mediaId);
    final String type =
        mediaType ?? (itemRecord?['media_type'] as String?) ?? 'image';
    final double dur = duration ?? (itemRecord?['duration'] as double?) ?? 0.0;

    if (type == 'image') {
      final fileSizeBytes = file.lengthSync();
      if (fileSizeBytes > 10 * 1024 * 1024) {
        // skip face detection on files > 10MB
        debugPrint(
          'processMediaItemTier4: skipping face detection for large file ($fileSizeBytes bytes): $path',
        );
        return;
      }
    } else if (type == 'video') {
      if (dur > 1800.0) {
        debugPrint(
          'processMediaItemTier4: skipping face detection for long video (${dur}s): $path',
        );
        return;
      }
    }

    final existingFaces = await db.getFacesForMedia(mediaId);

    // Check if the existing faces are actually valid FaceNet 192-D embeddings.
    bool hasIncompatibleEmbeddings = false;
    for (final face in existingFaces) {
      final embStr = face['embedding'] as String?;
      if (embStr == null || embStr == 'null' || embStr.isEmpty) {
        hasIncompatibleEmbeddings = true;
        break;
      }
      final length = embStr.split(',').length;
      if (length != _embeddingDims) {
        hasIncompatibleEmbeddings = true;
        break;
      }
    }

    if (existingFaces.isNotEmpty && !hasIncompatibleEmbeddings) {
      return; // fully done
    }

    // Clean up faces only for this media item
    await db.clearFacesForMedia(mediaId);

    final List<_FaceFrameResult> allDetectedFaces = [];
    final Set<String> tempFilesToDelete = {};

    try {
      if (type == 'video') {
        final tempDir = await getTemporaryDirectory();
        final stamps = [
          (dur * 1000 * 0.20).toInt(),
          (dur * 1000 * 0.50).toInt(),
          (dur * 1000 * 0.80).toInt(),
        ];
        for (final ms in stamps) {
          try {
            final thumb = await VideoThumbnail.thumbnailFile(
              video: path,
              thumbnailPath: tempDir.path,
              imageFormat: ImageFormat.JPEG,
              timeMs: ms,
              maxHeight: 720,
              quality: 85,
            );
            if (thumb != null && await File(thumb).exists()) {
              tempFilesToDelete.add(thumb);
              final results = await _runML(
                thumb,
                runOCR: false,
                runTags: false,
                runFaces: true,
              );
              for (final faceData in results.faces) {
                final int bw = faceData.w;
                final int bh = faceData.h;
                if (bw < 80 || bh < 80) {
                  continue; // Skip very small resolution faces to ignore dolls, emojis, toys
                }
                if (faceData.eulerY != null && faceData.eulerY!.abs() > 60)
                  continue;
                if (faceData.eulerX != null && faceData.eulerX!.abs() > 60)
                  continue;
                allDetectedFaces.add(
                  _FaceFrameResult(faceData: faceData, framePath: thumb),
                );
              }
            }
          } catch (e) {
            debugPrint("Tier 4 video frame extraction failed at $ms ms: $e");
          }
        }
      } else {
        // Image
        final results = await _runML(
          path,
          runOCR: false,
          runTags: false,
          runFaces: true,
        );
        for (final faceData in results.faces) {
          final int bw = faceData.w;
          final int bh = faceData.h;
          if (bw < 80 || bh < 80) {
            continue; // Skip very small resolution faces to ignore dolls, emojis, toys
          }
          if (faceData.eulerY != null && faceData.eulerY!.abs() > 60) continue;
          if (faceData.eulerX != null && faceData.eulerX!.abs() > 60) continue;
          allDetectedFaces.add(
            _FaceFrameResult(faceData: faceData, framePath: path),
          );
        }
      }

      // Helper to calculate Intersection over Union (IoU)
      double calculateIoU(
        int x1,
        int y1,
        int w1,
        int h1,
        int x2,
        int y2,
        int w2,
        int h2,
      ) {
        final int instX = max(x1, x2);
        final int instY = max(y1, y2);
        final int instW = min(x1 + w1, x2 + w2) - instX;
        final int instH = min(y1 + h1, y2 + h2) - instY;

        if (instW <= 0 || instH <= 0) return 0.0;

        final double intersection = (instW * instH).toDouble();
        final double union = (w1 * h1 + w2 * h2).toDouble() - intersection;
        return intersection / union;
      }

      // Extract embeddings and match with person IDs
      final List<String> personIds = [];
      final List<List<double>?> embeddings = [];
      for (final faceFrame in allDetectedFaces) {
        final faceData = faceFrame.faceData;
        final framePath = faceFrame.framePath;

        await Future.delayed(const Duration(milliseconds: 50));
        final List<double>? emb = await extract128DFaceEmbedding(
          framePath,
          faceData.x,
          faceData.y,
          faceData.w,
          faceData.h,
        );
        embeddings.add(emb);

        // Pre-cache video face frames permanently in cache so FacePreview loads instantly
        if (type == 'video') {
          await FaceCacheHelper.saveFaceToCache(
            targetPath: path,
            x: faceData.x,
            y: faceData.y,
            w: faceData.w,
            h: faceData.h,
            frameImagePath: framePath,
          );
        }

        String? reusedPersonId;
        double maxIoU = 0.3;
        for (final extFace in existingFaces) {
          final boxStr = extFace['bounding_box'] as String?;
          if (boxStr == null) continue;
          final parts = boxStr.split(',');
          if (parts.length != 4) continue;
          final ex = int.tryParse(parts[0]) ?? 0;
          final ey = int.tryParse(parts[1]) ?? 0;
          final ew = int.tryParse(parts[2]) ?? 0;
          final eh = int.tryParse(parts[3]) ?? 0;

          final iou = calculateIoU(
            faceData.x,
            faceData.y,
            faceData.w,
            faceData.h,
            ex,
            ey,
            ew,
            eh,
          );
          if (iou > maxIoU) {
            final pid = extFace['person_id'] as String?;
            if (pid != null && pid.isNotEmpty) {
              maxIoU = iou;
              reusedPersonId = pid;
            }
          }
        }

        final String personId;
        if (reusedPersonId != null) {
          personId = reusedPersonId;
        } else {
          if (emb != null) {
            personId = await clusterFaceAndGetPersonId(
              emb,
              path,
              faceData.x,
              faceData.y,
              faceData.w,
              faceData.h,
              excludePersonIds: personIds,
            );
          } else {
            personId =
                'person_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(9999)}';

            final people = await db.getAllPeople();
            int maxPersonNum = 0;
            final personRegex = RegExp(r'^Person (\d+)$');
            for (final p in people) {
              final name = p['name'] as String? ?? '';
              final match = personRegex.firstMatch(name);
              if (match != null) {
                final num = int.tryParse(match.group(1) ?? '0') ?? 0;
                if (num > maxPersonNum) {
                  maxPersonNum = num;
                }
              }
            }
            final newName = 'Person ${maxPersonNum + 1}';

            await db.insertPerson({
              'id': personId,
              'name': newName,
              'dob': '',
              'relation': '',
              'cover_image': path,
              'cover_x': faceData.x,
              'cover_y': faceData.y,
              'cover_w': faceData.w,
              'cover_h': faceData.h,
            });
          }
        }
        personIds.add(personId);
      }

      // Link the image/video to all person IDs
      for (int i = 0; i < allDetectedFaces.length; i++) {
        final faceData = allDetectedFaces[i].faceData;
        final personId = personIds[i];
        final emb = embeddings[i];
        final String embStr = emb != null ? emb.join(',') : 'null';

        await db.insertFace({
          'id': 'face_${mediaId}_${i + 1}_${Random().nextInt(9999)}',
          'media_id': mediaId,
          'bounding_box':
              '${faceData.x},${faceData.y},${faceData.w},${faceData.h}',
          'embedding': embStr,
          'person_id': personId,
        });
      }

      // Update preview/cover image if exactly one person found
      if (allDetectedFaces.length == 1 && personIds.isNotEmpty) {
        final faceData = allDetectedFaces[0].faceData;
        final personId = personIds[0];

        final person = await db.getPersonById(personId);
        final bool isCustom = (person?['is_custom_cover'] as int? ?? 0) == 1 ||
            ((person?['cover_image'] as String?)?.contains('profile_pictures') ?? false);

        if (!isCustom) {
          final mediaItem = await db.getMediaItemById(mediaId);
          final imgW =
              (mediaItem != null ? mediaItem['width'] as int? : null) ?? 2000;
          final imgH =
              (mediaItem != null ? mediaItem['height'] as int? : null) ?? 2000;

          int newX = (faceData.x).clamp(0, imgW);
          int newY = (faceData.y).clamp(0, imgH);
          int newW = (faceData.w).clamp(1, imgW - newX);
          int newH = (faceData.h).clamp(1, imgH - newY);

          await db.updatePersonCover(personId, path, newX, newY, newW, newH);
        }
      }
    } finally {
      // Clean up temporary video thumbnail files
      for (final thumbPath in tempFilesToDelete) {
        try {
          final f = File(thumbPath);
          if (f.existsSync()) {
            await f.delete();
          }
        } catch (e) {
          debugPrint("Tier 4 cleanup error for $thumbPath: $e");
        }
      }
    }
  }

  Future<void> _processVideo(
    String mediaId,
    String path,
    double duration,
    DatabaseHelper db,
  ) async {
    // Clear existing ML features (tags, OCR) for the video before processing to avoid duplicates
    await db.clearMLFeaturesForMedia(mediaId);

    if (duration > 1800.0) {
      final title = basename(path).replaceAll(RegExp(r'\.[^.]+$'), '');
      for (final word in title.split(RegExp(r'[-_\s]'))) {
        if (word.length > 2) {
          await db.insertObject({
            'media_id': mediaId,
            'label': _cap(word),
            'confidence': 0.95,
          });
        }
      }
      return;
    }

    final tempDir = await getTemporaryDirectory();
    final stamps = [
      (duration * 1000 * 0.20).toInt(),
      (duration * 1000 * 0.50).toInt(),
      (duration * 1000 * 0.80).toInt(),
    ];

    final Set<String> tagPool = {};
    final List<String> ocrPool = [];

    for (final ms in stamps) {
      String? thumb;
      try {
        thumb = await VideoThumbnail.thumbnailFile(
          video: path,
          thumbnailPath: tempDir.path,
          imageFormat: ImageFormat.JPEG,
          timeMs: ms,
          maxHeight: 480,
          quality: 75,
        );
        if (thumb != null && await File(thumb).exists()) {
          final r = await _runML(thumb);
          tagPool.addAll(r.tags);
          ocrPool.addAll(r.ocrText);
        }
      } catch (_) {
      } finally {
        if (thumb != null) {
          try {
            final f = File(thumb);
            if (f.existsSync()) {
              f.deleteSync();
            }
          } catch (_) {}
        }
      }
    }

    for (final tag in _expandTags(tagPool.toList())) {
      await db.insertObject({
        'media_id': mediaId,
        'label': tag,
        'confidence': 0.85,
      });
    }
    if (ocrPool.isNotEmpty) {
      await db.insertOcrText({
        'media_id': mediaId,
        'text': ocrPool.join(' '),
        'confidence': 0.80,
      });
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ML RUNNER
  // ══════════════════════════════════════════════════════════════════════════

  Future<_MLResults> _runML(
    String path, {
    bool runOCR = true,
    bool runTags = true,
    bool runFaces = true,
  }) async {
    if (_isNativeSupported) {
      return _nativeML(
        path,
        runOCR: runOCR,
        runTags: runTags,
        runFaces: runFaces,
      );
    }
    return const _MLResults([], [], []);
  }

  Future<_MLResults> _nativeML(
    String path, {
    required bool runOCR,
    required bool runTags,
    required bool runFaces,
  }) async {
    final input = InputImage.fromFilePath(path);
    final List<String> tags = [];
    final List<String> ocr = [];
    final List<_FaceData> faces = [];

    try {
      if (runOCR) {
        _textRecognizer ??= TextRecognizer(script: TextRecognitionScript.latin);
        final rt = await _textRecognizer!.processImage(input);
        for (final b in rt.blocks) {
          ocr.add(b.text);
        }
      }
    } catch (e) {
      debugPrint("MLKit OCR: $e");
    }

    try {
      if (runTags) {
        _imageLabeler ??= ImageLabeler(
          options: ImageLabelerOptions(confidenceThreshold: 0.55),
        );
        final labels = await _imageLabeler!.processImage(input);
        for (final l in labels) {
          tags.add(l.label);
        }
      }
    } catch (e) {
      debugPrint("MLKit Label: $e");
    }

    try {
      if (runFaces) {
        _faceDetector ??= FaceDetector(
          options: FaceDetectorOptions(
            minFaceSize: 0.05,
            enableClassification: false,
            enableContours: false,
            performanceMode: FaceDetectorMode.fast,
          ),
        );
        final result = await _downscaledInputImage(path, maxDim: 1024);
        final detected = await _faceDetector!.processImage(result.image);
        for (final f in detected) {
          final r = f.boundingBox;
          faces.add(
            _FaceData(
              x: (r.left / result.scaleX).round(),
              y: (r.top / result.scaleY).round(),
              w: (r.width / result.scaleX).round(),
              h: (r.height / result.scaleY).round(),
              eulerY: f.headEulerAngleY,
              eulerX: f.headEulerAngleX,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint("MLKit Face: $e");
    }

    return _MLResults(tags, ocr, faces);
  }

  List<String> _expandTags(List<String> originalTags) {
    final Set<String> expanded = {};
    for (final tag in originalTags) {
      final clean = tag.trim().toLowerCase();
      expanded.add(tag);
      if (clean.contains('ledger') || clean.contains('finance')) {
        expanded.addAll(['Ledger', 'Finance', 'Documents', 'Business']);
      }
      if (clean.contains('id') || clean.contains('card')) {
        expanded.addAll(['ID Card', 'Documents', 'Identity', 'Official']);
      }
      if (clean.contains('airport') || clean.contains('airplane')) {
        expanded.addAll(['Airport', 'Airplane', 'Travel', 'Flight']);
      }
      if (clean.contains('baby') || clean.contains('child')) {
        expanded.addAll(['Baby', 'People', 'Family', 'Child']);
      }
      if (clean.contains('selfie') || clean.contains('people')) {
        expanded.addAll(['Selfie', 'People', 'Portrait']);
      }
    }
    return expanded.toList();
  }

  String _cap(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();

  // ══════════════════════════════════════════════════════════════════════════
  // PREVIEW GENERATORS
  // ══════════════════════════════════════════════════════════════════════════

  static Future<String?> generateBase64Preview(String imagePath) async {
    try {
      final file = File(imagePath);
      if (!file.existsSync() || file.lengthSync() == 0) return null;

      final Uint8List bytes = await file.readAsBytes();

      // ── Pure-Dart decode + resize — works in any isolate (no GPU needed) ──
      final img.Image? decoded = img.decodeImage(bytes);
      if (decoded == null) return null;

      final img.Image resized = img.copyResize(decoded, width: 150);
      final Uint8List pngBytes = Uint8List.fromList(img.encodePng(resized));
      return base64Encode(pngBytes);
    } catch (e) {
      debugPrint("Preview generation error: $e");
      return null;
    }
  }

  static Future<String?> generateBase64VideoPreview(String videoPath) async {
    try {
      if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) return null;
      final Uint8List? bytes = await VideoThumbnail.thumbnailData(
        video: videoPath,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 150,
        quality: 30,
      );
      if (bytes != null && bytes.isNotEmpty) {
        return base64Encode(bytes);
      }
    } catch (e) {
      debugPrint("Video preview error: $e");
    }
    return null;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // MEDIA EMBEDDING GENERATION
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> generateAndStoreMediaEmbedding(String mediaId) async {
    try {
      final db = DatabaseHelper.instance;
      final item = await db.getMediaItemById(mediaId);
      if (item == null) return;

      final String path = item['path'] as String? ?? '';
      final String title = basename(path).replaceAll(RegExp(r'\.[^.]+$'), '');
      final String description = item['description'] as String? ?? '';

      final String albumName = item['album_name'] as String? ?? '';
      final String countryName = item['country_name'] as String? ?? '';
      final String adminArea = item['admin_area'] as String? ?? '';
      final String locality = item['locality'] as String? ?? '';
      final String subLocality = item['sub_locality'] as String? ?? '';
      final String featureName = item['feature_name'] as String? ?? '';

      final String geoText = [
        featureName,
        subLocality,
        locality,
        adminArea,
        countryName,
      ].where((s) => s.isNotEmpty).join(', ');

      final ocrRows = await db.getOcrTextsForMedia(mediaId);
      final String ocrText = ocrRows
          .map((r) => r['text'] as String? ?? '')
          .join(' ');

      final tagRows = await db.getObjectsForMedia(mediaId);
      final String tagsText = tagRows
          .map((r) => r['label'] as String? ?? '')
          .join(' ');

      final faceRows = await db.getFacesForMedia(mediaId);
      final List<String> personNames = [];
      final List<String> personDobs = [];
      final List<String> personRelations = [];

      for (final face in faceRows) {
        final pid = face['person_id'] as String?;
        if (pid != null) {
          final person = await db.getPersonById(pid);
          if (person != null) {
            final name = person['name'] as String? ?? '';
            final dob = person['dob'] as String? ?? '';
            final relation = person['relation'] as String? ?? '';

            if (name.isNotEmpty &&
                name != 'Unknown Person' &&
                !RegExp(r'^Person \d+$').hasMatch(name)) {
              personNames.add(name);
            }
            if (dob.isNotEmpty) {
              personDobs.add(dob);
              final match = RegExp(r'(\d{4})').firstMatch(dob);
              if (match != null) {
                personDobs.add(match.group(0)!);
                final int? yearVal = int.tryParse(match.group(0)!);
                if (yearVal != null &&
                    yearVal >= 1900 &&
                    yearVal <= DateTime.now().year) {
                  personDobs.add('${(yearVal / 10).floor() * 10}s');
                }
              }
            }
            if (relation.isNotEmpty) {
              personRelations.add(relation);
              _expandRelations(relation.toLowerCase().trim(), personRelations);
            }
          }
        }
      }

      final String consolidatedText = [
        title,
        description,
        ocrText,
        tagsText,
        personNames.join(' '),
        personDobs.join(' '),
        personRelations.join(' '),
        geoText,
        albumName,
      ].where((s) => s.isNotEmpty).join(' ');

      final List<double> vector = OptionalFeatures.vectorize != null
          ? await OptionalFeatures.vectorize!(consolidatedText)
          : MediaVectorizer.vectorize(consolidatedText);

      // Save to ObjectBox
      final box = await ObjectBoxService.getBox();
      if (box != null) {
        final query = box.query(MediaVector_.mediaId.equals(mediaId)).build();
        final existing = query.findFirst();
        query.close();

        if (existing != null) {
          existing.embedding = vector;
          box.put(existing);
        } else {
          box.put(MediaVector(mediaId: mediaId, embedding: vector));
        }
      }

      // Keep SQLite updated for compatibility / fallback
      // await db.updateMediaItemEmbedding(mediaId, vector.join(','));
    } catch (e) {
      debugPrint("Embedding generation error: $e");
    }
  }

  void _expandRelations(String lowerRel, List<String> relations) {
    if (lowerRel == 'mom' || lowerRel == 'mother' || lowerRel == 'mamma') {
      relations.addAll(['Mother', 'Family']);
    } else if (lowerRel == 'dad' ||
        lowerRel == 'father' ||
        lowerRel == 'papa') {
      relations.addAll(['Father', 'Family']);
    } else if (lowerRel == 'brother' || lowerRel == 'bro') {
      relations.addAll(['Brother', 'Family']);
    } else if (lowerRel == 'sister' || lowerRel == 'sis') {
      relations.addAll(['Sister', 'Family']);
    } else if (lowerRel == 'son') {
      relations.addAll(['Son', 'Family']);
    } else if (lowerRel == 'daughter') {
      relations.addAll(['Daughter', 'Family']);
    } else if (lowerRel == 'self' || lowerRel == 'me') {
      relations.addAll(['Self', 'Profile']);
    } else if (lowerRel == 'colleague' || lowerRel == 'coworker') {
      relations.addAll(['Colleague', 'Work']);
    }
  }

  Future<void> updateEmbeddingsForPerson(String personId) async {
    try {
      final db = DatabaseHelper.instance;
      final mediaItems = await db.getMediaItemsForPerson(personId);
      if (mediaItems.isEmpty) return;

      final allOcr = await db.getAllOcrTexts();
      final allTags = await db.getAllObjects();
      final allFaces = await db.getAllFaces();
      final allPeople = await db.getAllPeople();

      final args = _BatchEmbeddingArgs(
        mediaItems: mediaItems,
        ocr: allOcr,
        tags: allTags,
        faces: allFaces,
        people: allPeople,
      );

      final Map<String, String> results = await _batchVectorizationAsync(args);
      await db.updateMediaItemEmbeddingsBatch(results);

      // Save to ObjectBox
      final box = await ObjectBoxService.getBox();
      if (box != null) {
        final List<MediaVector> toPut = [];
        for (final entry in results.entries) {
          final mediaId = entry.key;
          final vecStr = entry.value;
          final vector = vecStr
              .split(',')
              .map((v) => double.tryParse(v) ?? 0.0)
              .toList();

          final query = box.query(MediaVector_.mediaId.equals(mediaId)).build();
          final existing = query.findFirst();
          query.close();

          if (existing != null) {
            existing.embedding = vector;
            toPut.add(existing);
          } else {
            toPut.add(MediaVector(mediaId: mediaId, embedding: vector));
          }
        }
        if (toPut.isNotEmpty) {
          box.putMany(toPut);
        }
      }
    } catch (e) {
      debugPrint("Batch embedding update error: $e");
    }
  }

  Future<Map<String, String>> _batchVectorizationAsync(
    _BatchEmbeddingArgs args,
  ) async {
    final Map<String, List<String>> ocrByMedia = {};
    final Map<String, List<String>> tagsByMedia = {};
    final Map<String, List<Map<String, dynamic>>> facesByMedia = {};
    final Map<String, Map<String, dynamic>> peopleMap = {
      for (final p in args.people) p['id'] as String: p,
    };

    for (final o in args.ocr) {
      ocrByMedia
          .putIfAbsent(o['media_id'] as String, () => [])
          .add(o['text'] as String? ?? '');
    }
    for (final t in args.tags) {
      tagsByMedia
          .putIfAbsent(t['media_id'] as String, () => [])
          .add(t['label'] as String? ?? '');
    }
    for (final f in args.faces) {
      facesByMedia.putIfAbsent(f['media_id'] as String, () => []).add(f);
    }

    final Map<String, String> resultMap = {};

    for (final item in args.mediaItems) {
      final String mediaId = item['id'] as String;
      final String path = item['path'] as String? ?? '';
      final String title = basename(path).replaceAll(RegExp(r'\.[^.]+$'), '');
      final String description = item['description'] as String? ?? '';

      final String albumName = item['album_name'] as String? ?? '';
      final String countryName = item['country_name'] as String? ?? '';
      final String adminArea = item['admin_area'] as String? ?? '';
      final String locality = item['locality'] as String? ?? '';
      final String subLocality = item['sub_locality'] as String? ?? '';
      final String featureName = item['feature_name'] as String? ?? '';

      final String geoText = [
        featureName,
        subLocality,
        locality,
        adminArea,
        countryName,
      ].where((s) => s.isNotEmpty).join(', ');

      final String ocrText = (ocrByMedia[mediaId] ?? []).join(' ');
      final String tagsText = (tagsByMedia[mediaId] ?? []).join(' ');

      final List<String> personNames = [];
      final List<String> personDobs = [];
      final List<String> personRelations = [];

      for (final face in facesByMedia[mediaId] ?? []) {
        final pid = face['person_id'] as String?;
        if (pid != null && peopleMap.containsKey(pid)) {
          final person = peopleMap[pid]!;
          final name = person['name'] as String? ?? '';
          final dob = person['dob'] as String? ?? '';
          final relation = person['relation'] as String? ?? '';

          if (name.isNotEmpty &&
              name != 'Unknown Person' &&
              !RegExp(r'^Person \d+$').hasMatch(name)) {
            personNames.add(name);
          }
          if (dob.isNotEmpty) {
            personDobs.add(dob);
            final match = RegExp(r'(\d{4})').firstMatch(dob);
            if (match != null) {
              personDobs.add(match.group(0)!);
              final int? yearVal = int.tryParse(match.group(0)!);
              if (yearVal != null &&
                  yearVal >= 1900 &&
                  yearVal <= DateTime.now().year) {
                personDobs.add('${(yearVal / 10).floor() * 10}s');
              }
            }
          }
          if (relation.isNotEmpty) personRelations.add(relation);
        }
      }

      final String consolidatedText = [
        title,
        description,
        ocrText,
        tagsText,
        personNames.join(' '),
        personDobs.join(' '),
        personRelations.join(' '),
        geoText,
        albumName,
      ].where((s) => s.isNotEmpty).join(' ');

      final List<double> vector = OptionalFeatures.vectorize != null
          ? await OptionalFeatures.vectorize!(consolidatedText)
          : MediaVectorizer.vectorize(consolidatedText);
      resultMap[mediaId] = vector.join(',');

      // Yield to let main isolate process UI framing/events
      await Future.delayed(const Duration(milliseconds: 5));
    }

    return resultMap;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // CATCH-UP — fix items missing previews or embeddings
  // Only runs when app is backgrounded (called from _runFallbackInAppProcessingTier3)
  // ══════════════════════════════════════════════════════════════════════════

  String _locationFromFolderName(String folderName) {
    final n = folderName.toLowerCase();
    if (n.contains('camera')) return 'Camera Roll';
    if (n.contains('screenshot')) return 'Screen Capture';
    if (n.contains('download')) return 'Downloads';
    if (n.contains('saved')) return 'Saved Pictures';
    return 'Unknown Location';
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    final i = (log(bytes) / log(1024)).floor();
    return '${(bytes / pow(1024, i)).toStringAsFixed(1)} ${suffixes[i]}';
  }

  static Future<_DownscaleResult> _downscaledInputImage(
    String path, {
    required int maxDim,
  }) async {
    if (!Platform.isAndroid) {
      return _DownscaleResult(
        image: InputImage.fromFilePath(path),
        scaleX: 1.0,
        scaleY: 1.0,
      );
    }
    final bytes = await File(path).readAsBytes();
    final original = img.decodeImage(bytes);
    if (original == null) {
      return _DownscaleResult(
        image: InputImage.fromFilePath(path),
        scaleX: 1.0,
        scaleY: 1.0,
      );
    }

    final longest = max(original.width, original.height);
    if (longest <= maxDim) {
      return _DownscaleResult(
        image: InputImage.fromFilePath(path),
        scaleX: 1.0,
        scaleY: 1.0,
      );
    }

    final double scale = maxDim / longest;
    // Ensure even dimensions for NV21/MLKit compatibility
    int newW = (original.width * scale).round();
    int newH = (original.height * scale).round();
    newW = (newW >> 1) << 1;
    newH = (newH >> 1) << 1;
    if (newW < 2) newW = 2;
    if (newH < 2) newH = 2;

    final double scaleX = newW / original.width;
    final double scaleY = newH / original.height;

    final resized = img.copyResize(
      original,
      width: newW,
      height: newH,
      interpolation: img.Interpolation.linear,
    );

    // Convert to NV21 bytes manually — no file write needed
    final int w = resized.width;
    final int h = resized.height;
    final int ySize = w * h;
    final int uvSize = (w * h) ~/ 2;
    final nv21 = Uint8List(ySize + uvSize);

    for (int row = 0; row < h; row++) {
      for (int col = 0; col < w; col++) {
        final pixel = resized.getPixel(col, row);
        final r = pixel.r.toInt();
        final g = pixel.g.toInt();
        final b = pixel.b.toInt();

        // RGB → Y
        final int y = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
        nv21[row * w + col] = y.clamp(0, 255);

        // UV plane (subsampled 2x2)
        if (row % 2 == 0 && col % 2 == 0) {
          final int v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
          final int u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
          final int uvIndex = ySize + (row ~/ 2) * w + col;
          if (uvIndex + 1 < nv21.length) {
            nv21[uvIndex] = v.clamp(0, 255);
            nv21[uvIndex + 1] = u.clamp(0, 255);
          }
        }
      }
    }

    final inputImage = InputImage.fromBytes(
      bytes: nv21,
      metadata: InputImageMetadata(
        size: Size(w.toDouble(), h.toDouble()),
        rotation: InputImageRotation.rotation0deg,
        format: InputImageFormat.nv21, // MLKit's native format on Android
        bytesPerRow: w,
      ),
    );

    return _DownscaleResult(image: inputImage, scaleX: scaleX, scaleY: scaleY);
  }
}

class _DownscaleResult {
  final InputImage image;
  final double scaleX;
  final double scaleY;
  const _DownscaleResult({
    required this.image,
    required this.scaleX,
    required this.scaleY,
  });
}

// ═══════════════════════════════════════════════════════════════════════════
// HELPER TYPES
// ═══════════════════════════════════════════════════════════════════════════

class _FaceData {
  final int x, y, w, h;
  final double? eulerY;
  final double? eulerX;
  const _FaceData({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.eulerY,
    this.eulerX,
  });
}

class _MLResults {
  final List<String> tags;
  final List<String> ocrText;
  final List<_FaceData> faces;
  const _MLResults(this.tags, this.ocrText, this.faces);
}

class _PersonMatchStats {
  double bestSim = -1.0;
  int count = 0;

  void update(double sim) {
    if (sim > bestSim) bestSim = sim;
    count++;
  }
}

class _FaceRecord {
  final String faceId;
  final String personId;
  final List<double> embedding;
  const _FaceRecord({
    required this.faceId,
    required this.personId,
    required this.embedding,
  });
}

class _BatchEmbeddingArgs {
  final List<Map<String, dynamic>> mediaItems;
  final List<Map<String, dynamic>> ocr;
  final List<Map<String, dynamic>> tags;
  final List<Map<String, dynamic>> faces;
  final List<Map<String, dynamic>> people;
  const _BatchEmbeddingArgs({
    required this.mediaItems,
    required this.ocr,
    required this.tags,
    required this.faces,
    required this.people,
  });
}

class _FaceFrameResult {
  final _FaceData faceData;
  final String framePath;
  _FaceFrameResult({required this.faceData, required this.framePath});
}
