package `in`.sddev.ghost_gallery

import android.content.Context
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import androidx.work.*
import java.util.concurrent.TimeUnit

/**
 * A self-re-arming WorkManager Worker that uses OS-level ContentUri triggers.
 *
 * Inspired by Immich's MediaObserver.kt:
 * - addContentUriTrigger() registers with JobScheduler at the Android OS level.
 * - The OS wakes the app and runs doWork() whenever MediaStore changes, even when
 *   the app process is completely dead (unlike ContentObserver which is process-bound).
 * - Each run of doWork() re-arms itself via enqueueMediaTrigger(), forming a
 *   self-healing infinite chain that survives reboots and process kills.
 */
class MediaScanTriggerWorker(
    context: Context,
    params: WorkerParameters
) : Worker(context, params) {

    override fun doWork(): Result {
        val ctx = applicationContext

        // Check if any relevant URIs actually changed.
        // triggeredContentUris is populated by WorkManager when this Worker is
        // woken up due to a content-URI change constraint.
        val changedUris = triggeredContentUris
        Log.i(TAG, "doWork: fired, changedUris=${changedUris.size}")

        if (changedUris.isNotEmpty()) {
            // Real media changes detected → trigger the Dart-side scan
            enqueueDartScanTask(ctx)
        }

        // CRITICAL: Self-re-arm for the NEXT change.
        // Without this, after one fire the chain breaks permanently.
        enqueueMediaTrigger(ctx)

        return Result.success()
    }

    companion object {
        private const val TAG = "MediaScanTriggerWorker"
        const val TRIGGER_WORK_NAME = "ghost_gallery/MediaTriggerV2"
        const val SCAN_WORK_NAME = "ghost_gallery/BackgroundScanV2"

        /**
         * Enqueues this worker with OS-level ContentUri constraints.
         * Call once on app start to seed the chain.
         * The worker self-re-enqueues on every execution.
         */
        fun enqueueMediaTrigger(ctx: Context) {
            // addContentUriTrigger requires API 24+ (backed by JobScheduler triggerContentUri)
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
                Log.w(TAG, "addContentUriTrigger not available on API < 24, skipping")
                return
            }

            val constraints = Constraints.Builder()
                // These are OS / JobScheduler level URIs — they survive process death
                .addContentUriTrigger(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true)
                .addContentUriTrigger(MediaStore.Images.Media.INTERNAL_CONTENT_URI, true)
                .addContentUriTrigger(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true)
                .addContentUriTrigger(MediaStore.Video.Media.INTERNAL_CONTENT_URI, true)
                // Debounce: wait 3 s after last change to avoid burst triggers
                .setTriggerContentUpdateDelay(3, TimeUnit.SECONDS)
                // Safety cap: fire at most once per 30 s even if changes keep coming
                .setTriggerContentMaxDelay(30, TimeUnit.SECONDS)
                .build()

            val request = OneTimeWorkRequestBuilder<MediaScanTriggerWorker>()
                .setConstraints(constraints)
                .build()

            // REPLACE ensures the timer is reset whenever we re-arm
            WorkManager.getInstance(ctx)
                .enqueueUniqueWork(TRIGGER_WORK_NAME, ExistingWorkPolicy.REPLACE, request)

            Log.d(TAG, "Media trigger re-armed: $TRIGGER_WORK_NAME")
        }


        /**
         * Enqueues the actual Dart-side scan via flutter_workmanager's BackgroundWorker.
         * Uses KEEP so a scan already in flight is not duplicated.
         */
        fun enqueueDartScanTask(ctx: Context) {
            try {
                val inputData = Data.Builder()
                    .putString(
                        "dev.fluttercommunity.workmanager.DART_TASK",
                        "ghost_gallery_processing_task"
                    )
                    .build()

                val scanRequest =
                    OneTimeWorkRequestBuilder<dev.fluttercommunity.workmanager.BackgroundWorker>()
                        .setInputData(inputData)
                        .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 1, TimeUnit.MINUTES)
                        .build()

                WorkManager.getInstance(ctx).enqueueUniqueWork(
                    SCAN_WORK_NAME,
                    ExistingWorkPolicy.KEEP,
                    scanRequest
                )
                Log.i(TAG, "Dart scan task enqueued: $SCAN_WORK_NAME")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to enqueue Dart scan task: ${e.message}")
            }
        }

        /**
         * Registers a periodic fallback scan (1-hour interval) as a safety net.
         * Handles devices where Doze mode or aggressive OEM battery management
         * suppresses content-URI triggers.
         */
        fun enqueuePeriodicFallback(ctx: Context) {
            val inputData = Data.Builder()
                .putString(
                    "dev.fluttercommunity.workmanager.DART_TASK",
                    "ghost_gallery_processing_task"
                )
                .build()

            val periodicRequest =
                PeriodicWorkRequestBuilder<dev.fluttercommunity.workmanager.BackgroundWorker>(
                    1, TimeUnit.HOURS,
                    15, TimeUnit.MINUTES   // flex window
                )
                    .setInputData(inputData)
                    .build()

            WorkManager.getInstance(ctx).enqueueUniquePeriodicWork(
                "ghost_gallery/PeriodicScanFallback",
                ExistingPeriodicWorkPolicy.KEEP,
                periodicRequest
            )
            Log.d(TAG, "Periodic fallback scan registered (1-hour interval)")
        }
    }
}
