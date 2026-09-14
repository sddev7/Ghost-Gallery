package `in`.sddev.ghost_gallery

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.work.*
import dev.fluttercommunity.workmanager.BackgroundWorker
import java.util.concurrent.TimeUnit

class WatchdogReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val taskName = intent.getStringExtra("taskName") ?: "ghost_gallery_processing_task"
        android.util.Log.d("GhostWatchdogReceiver", "WatchdogReceiver: Fired! Re-enqueuing WorkManager task: $taskName")
        
        try {
            val inputData = Data.Builder()
                .putString("dev.fluttercommunity.workmanager.DART_TASK", taskName)
                .build()

            val request = OneTimeWorkRequestBuilder<BackgroundWorker>()
                .setInitialDelay(0, TimeUnit.SECONDS)
                .setBackoffCriteria(BackoffPolicy.LINEAR, 1, TimeUnit.MINUTES)
                .setInputData(inputData)
                .build()

            val uniqueWorkName = if (taskName == "ghost_gallery_faces_task") {
                "ghost_gallery_faces_task"
            } else {
                "ghost_gallery_ml_worker"
            }

            WorkManager.getInstance(context)
                .enqueueUniqueWork(
                    uniqueWorkName,
                    ExistingWorkPolicy.REPLACE,
                    request
                )
            android.util.Log.d("GhostWatchdogReceiver", "Successfully re-enqueued worker task $uniqueWorkName via watchdog.")
        } catch (e: Exception) {
            android.util.Log.e("GhostWatchdogReceiver", "Failed to enqueue worker via watchdog: ${e.message}")
        }
    }
}
