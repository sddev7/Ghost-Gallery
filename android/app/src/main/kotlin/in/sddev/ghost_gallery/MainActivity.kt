package `in`.sddev.ghost_gallery

import android.app.Activity
import android.app.WallpaperManager
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.work.*
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterFragmentActivity() {
    private val WALLPAPER_CHANNEL = "in.sddev.ghost_gallery/wallpaper"
    private val WIDGET_CHANNEL   = "in.sddev.ghost_gallery/widget_manager"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Security channel (prevent screenshot/screen recording) ────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "in.sddev.ghost_gallery/security")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "secureScreen" -> {
                        try {
                            val secure = call.argument<Boolean>("secure") ?: true
                            if (secure) {
                                window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
                            } else {
                                window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Widget channel ────────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WIDGET_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getWidgetLaunchData" -> {
                        val prefs = getSharedPreferences("WidgetLaunchPrefs", Context.MODE_PRIVATE)
                        if (prefs.getBoolean("widgetClicked", false)) {
                            val action = prefs.getString("action", null)
                            val imagePath = prefs.getString("imagePath", null)
                            val albumName = prefs.getString("albumName", null)
                            val widgetId = prefs.getInt("widgetId", -1)

                            val data = mapOf(
                                "widgetClicked" to true,
                                "action" to action,
                                "imagePath" to imagePath,
                                "albumName" to albumName,
                                "widgetId" to if (widgetId != -1) widgetId else null
                            )
                            result.success(data)

                            // Clear it immediately after retrieving
                            prefs.edit().clear().apply()
                        } else {
                            result.success(null)
                        }
                    }
                    "updateWidget" -> {
                        try {
                            val appWidgetManager = AppWidgetManager.getInstance(this)
                            val thisAppWidgetComponentName = ComponentName(this, GhostPhotoWidgetProvider::class.java)
                            val targetId = call.argument<Int>("widgetId")
                            if (targetId != null) {
                                // Update only the specific widget instance
                                GhostPhotoWidgetProvider.updateAppWidget(this, appWidgetManager, targetId)
                            } else {
                                // Update all widget instances
                                val appWidgetIds = appWidgetManager.getAppWidgetIds(thisAppWidgetComponentName)
                                for (id in appWidgetIds) {
                                    GhostPhotoWidgetProvider.updateAppWidget(this, appWidgetManager, id)
                                }
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("WIDGET_UPDATE_FAILED", e.message, null)
                        }
                    }
                    "getActiveWidgetIds" -> {
                        try {
                            val appWidgetManager = AppWidgetManager.getInstance(this)
                            val cn = ComponentName(this, GhostPhotoWidgetProvider::class.java)
                            val ids = appWidgetManager.getAppWidgetIds(cn).toList()
                            result.success(ids)
                        } catch (e: Exception) {
                            result.error("WIDGET_IDS_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Wallpaper + Volume channel ────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WALLPAPER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setWallpaper" -> {
                        val path = call.argument<String>("path")
                        val screen = call.argument<String>("screen")
                        if (path == null) { result.error("INVALID_ARGUMENT", "path is null", null); return@setMethodCallHandler }
                        Thread {
                            try {
                                val file = File(path)
                                if (!file.exists()) {
                                    this@MainActivity.runOnUiThread {
                                        result.error("FILE_NOT_FOUND", "File does not exist", null)
                                    }
                                    return@Thread
                                }
                                val bmp = BitmapFactory.decodeFile(file.absolutePath)
                                if (bmp == null) {
                                    this@MainActivity.runOnUiThread {
                                        result.error("DECODE_FAILED", "Failed to decode image bitmap", null)
                                    }   
                                    return@Thread
                                }
                                val wm = WallpaperManager.getInstance(this@MainActivity)
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                                    val which = when (screen) {
                                        "home" -> WallpaperManager.FLAG_SYSTEM
                                        "lock" -> WallpaperManager.FLAG_LOCK
                                        else -> WallpaperManager.FLAG_SYSTEM or WallpaperManager.FLAG_LOCK
                                    }
                                    wm.setBitmap(bmp, null, true, which)
                                } else {
                                    wm.setBitmap(bmp)
                                }
                                this@MainActivity.runOnUiThread {
                                    result.success(true)
                                }
                            } catch (e: Exception) {
                                e.printStackTrace()
                                this@MainActivity.runOnUiThread {
                                    result.error("ERROR", "${e.javaClass.simpleName}: ${e.message}", null)
                                }
                            }
                        }.start()
                    }
                    "getSystemVolume" -> {
                        try {
                            val audioManager = getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
                            val cur = audioManager.getStreamVolume(android.media.AudioManager.STREAM_MUSIC)
                            val max = audioManager.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)
                            result.success(cur.toDouble() / max.toDouble())
                        } catch (e: Exception) { result.error("ERROR", e.message, null) }
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Auto-Scan channel ─────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "in.sddev.ghost_gallery/auto_scan")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enableAutoScan" -> {
                        try {
                            MediaScanTriggerWorker.enqueueMediaTrigger(applicationContext)
                            MediaScanTriggerWorker.enqueuePeriodicFallback(applicationContext)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ERROR", e.message, null)
                        }
                    }
                    "disableAutoScan" -> {
                        try {
                            WorkManager.getInstance(applicationContext)
                                .cancelUniqueWork(MediaScanTriggerWorker.TRIGGER_WORK_NAME)
                            WorkManager.getInstance(applicationContext)
                                .cancelUniqueWork(MediaScanTriggerWorker.SCAN_WORK_NAME)
                            WorkManager.getInstance(applicationContext)
                                .cancelUniqueWork("ghost_gallery/PeriodicScanFallback")
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ERROR", e.message, null)
                        }
                    }
                    "getAutoScanStatus" -> {
                        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                        val active = prefs.getBoolean("flutter.auto_scan_enabled", true)
                        result.success(active)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleWidgetIntent(intent)
        
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val autoScanEnabled = prefs.getBoolean("flutter.auto_scan_enabled", true)
        if (autoScanEnabled) {
            // Seed the self-re-arming OS-level media trigger chain (survives process death)
            MediaScanTriggerWorker.enqueueMediaTrigger(this)
            // Register hourly fallback for Doze-mode / aggressive OEM battery-kill devices
            MediaScanTriggerWorker.enqueuePeriodicFallback(this)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleWidgetIntent(intent)
    }

    private fun handleWidgetIntent(intent: Intent?) {
        android.util.Log.d("GhostMainActivity", "handleWidgetIntent called: intent=$intent")
        if (intent != null) {
            val extras = intent.extras
            if (extras != null) {
                for (key in extras.keySet()) {
                    android.util.Log.d("GhostMainActivity", "  extra: $key = ${extras.get(key)}")
                }
            }
        }

        if (intent != null && intent.getBooleanExtra("widget_click", false)) {
            val action = intent.getStringExtra("widget_action")
            val imagePath = intent.getStringExtra("image_path")
            val albumName = intent.getStringExtra("album_name")
            val widgetId = intent.getIntExtra("widget_id", -1)

            android.util.Log.d("GhostMainActivity", "Widget click matched! action=$action, imagePath=$imagePath, albumName=$albumName, widgetId=$widgetId")

            val prefs = getSharedPreferences("WidgetLaunchPrefs", Context.MODE_PRIVATE)
            prefs.edit().apply {
                putBoolean("widgetClicked", true)
                putString("action", action)
                putString("imagePath", imagePath)
                putString("albumName", albumName)
                putInt("widgetId", widgetId)
                apply()
            }
        }
    }
}
