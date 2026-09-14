package `in`.sddev.ghost_gallery

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import org.json.JSONArray
import java.io.File
import kotlin.random.Random

class GhostPhotoWidgetProvider : AppWidgetProvider() {

    companion object {
        const val ACTION_SHUFFLE_IMAGE   = "in.sddev.ghost_gallery.ACTION_SHUFFLE_IMAGE"
        const val ACTION_WIDGET_TAP      = "in.sddev.ghost_gallery.ACTION_WIDGET_TAP"
        const val EXTRA_WIDGET_ID        = "widget_id"
        const val EXTRA_WIDGET_ACTION    = "widget_action"
        const val EXTRA_IMAGE_PATH       = "image_path"
        const val EXTRA_ALBUM_NAME       = "album_name"

        // ── Per-widget key helpers ──────────────────────────────────────────────
        // All keys are stored in "FlutterSharedPreferences" with the "flutter." prefix
        // so the Flutter SharedPreferences plugin can access them too.
        //
        // Per-widget keys:  flutter.widget_album_name_<id>
        // Legacy global keys (backwards compat): flutter.widget_album_name
        private fun albumNameKey(id: Int)        = "flutter.widget_album_name_$id"
        private fun currentImageKey(id: Int)     = "flutter.widget_current_image_path_$id"
        private fun albumPathsKey(id: Int)       = "flutter.widget_album_paths_json_$id"
        private fun remainingPathsKey(id: Int)   = "flutter.widget_remaining_paths_json_$id"

        fun updateAppWidget(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int) {
            val views = RemoteViews(context.packageName, R.layout.ghost_photo_widget)

            // Read SharedPreferences — per-widget key first, fall back to legacy global key
            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

            val albumName = prefs.getString(albumNameKey(appWidgetId), null)
                ?: prefs.getString("flutter.widget_album_name", null)
            val currentImagePath = prefs.getString(currentImageKey(appWidgetId), null)
                ?: prefs.getString("flutter.widget_current_image_path", null)

            val hasAlbum = !albumName.isNullOrEmpty()
            val hasImage = !currentImagePath.isNullOrEmpty() && File(currentImagePath).exists()

            if (hasAlbum && hasImage) {
                // Show Image layout elements
                views.setViewVisibility(R.id.placeholder_container, View.GONE)
                views.setViewVisibility(R.id.widget_image, View.VISIBLE)
                views.setViewVisibility(R.id.gradient_overlay, View.VISIBLE)
                views.setViewVisibility(R.id.control_panel, View.VISIBLE)
                views.setViewVisibility(R.id.btn_refresh, View.VISIBLE)
                views.setViewVisibility(R.id.widget_album_title, View.VISIBLE)
                views.setViewVisibility(R.id.btn_settings, View.VISIBLE)

                // Set Album Title Text
                views.setTextViewText(R.id.widget_album_title, albumName)

                // Safely load and scale image to avoid memory issues (OOM)
                try {
                    var bitmap = decodeSampledBitmapFromFile(currentImagePath!!, 500, 500)
                    if (bitmap != null) {
                        bitmap = rotateBitmapIfRequired(bitmap, currentImagePath)
                        views.setImageViewBitmap(R.id.widget_image, bitmap)
                    } else {
                        // Fallback if decoding failed
                        views.setViewVisibility(R.id.placeholder_container, View.VISIBLE)
                        views.setViewVisibility(R.id.widget_image, View.GONE)
                        views.setViewVisibility(R.id.gradient_overlay, View.GONE)
                        views.setViewVisibility(R.id.control_panel, View.GONE)
                    }
                } catch (e: Exception) {
                    e.printStackTrace()
                }

                // ── Tap image → VIEW_IMAGE (routed via BroadcastReceiver trampoline) ──
                val viewIntent = Intent(context, GhostPhotoWidgetProvider::class.java).apply {
                    action = ACTION_WIDGET_TAP
                    putExtra(EXTRA_WIDGET_ID, appWidgetId)
                    putExtra(EXTRA_WIDGET_ACTION, "VIEW_IMAGE")
                    putExtra(EXTRA_IMAGE_PATH, currentImagePath)
                    putExtra(EXTRA_ALBUM_NAME, albumName)
                }
                val pendingViewIntent = PendingIntent.getBroadcast(
                    context,
                    appWidgetId * 10 + 1,
                    viewIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                )
                views.setOnClickPendingIntent(R.id.widget_image, pendingViewIntent)

                // ── Tap refresh → SHUFFLE_IMAGE ──
                val shuffleIntent = Intent(context, GhostPhotoWidgetProvider::class.java).apply {
                    action = ACTION_SHUFFLE_IMAGE
                    putExtra(EXTRA_WIDGET_ID, appWidgetId)
                }
                val pendingShuffleIntent = PendingIntent.getBroadcast(
                    context,
                    appWidgetId * 10 + 2,
                    shuffleIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                views.setOnClickPendingIntent(R.id.btn_refresh, pendingShuffleIntent)

                // ── Tap settings gear → CONFIGURE (routed via BroadcastReceiver trampoline) ──
                val settingsIntent = Intent(context, GhostPhotoWidgetProvider::class.java).apply {
                    action = ACTION_WIDGET_TAP
                    putExtra(EXTRA_WIDGET_ID, appWidgetId)
                    putExtra(EXTRA_WIDGET_ACTION, "CONFIGURE")
                }
                val pendingSettingsIntent = PendingIntent.getBroadcast(
                    context,
                    appWidgetId * 10 + 3,
                    settingsIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                )
                views.setOnClickPendingIntent(R.id.btn_settings, pendingSettingsIntent)

            } else {
                // Show placeholder state "Tap to select album"
                views.setViewVisibility(R.id.placeholder_container, View.VISIBLE)
                views.setViewVisibility(R.id.widget_image, View.GONE)
                views.setViewVisibility(R.id.gradient_overlay, View.GONE)
                views.setViewVisibility(R.id.control_panel, View.VISIBLE)
                views.setViewVisibility(R.id.btn_refresh, View.GONE)
                views.setViewVisibility(R.id.widget_album_title, View.GONE)
                views.setViewVisibility(R.id.btn_settings, View.GONE)

                // ── Tap placeholder → CONFIGURE (routed via BroadcastReceiver trampoline) ──
                val configIntent = Intent(context, GhostPhotoWidgetProvider::class.java).apply {
                    action = ACTION_WIDGET_TAP
                    putExtra(EXTRA_WIDGET_ID, appWidgetId)
                    putExtra(EXTRA_WIDGET_ACTION, "CONFIGURE")
                }
                val pendingConfigIntent = PendingIntent.getBroadcast(
                    context,
                    appWidgetId * 10 + 4,
                    configIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                )
                views.setOnClickPendingIntent(R.id.placeholder_container, pendingConfigIntent)

                // ── Tap settings gear → CONFIGURE (routed via BroadcastReceiver trampoline) ──
                val settingsIntent = Intent(context, GhostPhotoWidgetProvider::class.java).apply {
                    action = ACTION_WIDGET_TAP
                    putExtra(EXTRA_WIDGET_ID, appWidgetId)
                    putExtra(EXTRA_WIDGET_ACTION, "CONFIGURE")
                }
                val pendingSettingsIntent = PendingIntent.getBroadcast(
                    context,
                    appWidgetId * 10 + 3,
                    settingsIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                )
                views.setOnClickPendingIntent(R.id.btn_settings, pendingSettingsIntent)
            }

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }

        // Helper to load bitmap without OutOfMemoryError
        private fun decodeSampledBitmapFromFile(path: String, reqWidth: Int, reqHeight: Int): Bitmap? {
            val options = BitmapFactory.Options().apply {
                inJustDecodeBounds = true
            }
            BitmapFactory.decodeFile(path, options)

            options.inSampleSize = calculateInSampleSize(options, reqWidth, reqHeight)
            options.inJustDecodeBounds = false
            return BitmapFactory.decodeFile(path, options)
        }

        private fun calculateInSampleSize(options: BitmapFactory.Options, reqWidth: Int, reqHeight: Int): Int {
            val height = options.outHeight
            val width = options.outWidth
            var inSampleSize = 1

            if (height > reqHeight || width > reqWidth) {
                val halfHeight = height / 2
                val halfWidth = width / 2
                while (halfHeight / inSampleSize >= reqHeight && halfWidth / inSampleSize >= reqWidth) {
                    inSampleSize *= 2
                }
            }
            return inSampleSize
        }

        private fun rotateBitmapIfRequired(bitmap: Bitmap, path: String): Bitmap {
            try {
                val exif = ExifInterface(path)
                val orientation = exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
                val matrix = Matrix()
                when (orientation) {
                    ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
                    ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
                    ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
                    else -> return bitmap
                }
                val rotatedBitmap = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
                if (rotatedBitmap != bitmap) {
                    bitmap.recycle()
                }
                return rotatedBitmap
            } catch (e: Exception) {
                e.printStackTrace()
                return bitmap
            }
        }
    }

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        for (appWidgetId in appWidgetIds) {
            // Shuffle to show a fresh non-repeating image on periodic update
            shuffleImage(context, appWidgetId)
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        super.onDeleted(context, appWidgetIds)
        // Clean up per-widget keys when a widget is removed from the home screen
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val editor = prefs.edit()
        for (id in appWidgetIds) {
            editor.remove(albumNameKey(id))
            editor.remove(currentImageKey(id))
            editor.remove(albumPathsKey(id))
            editor.remove(remainingPathsKey(id))
        }
        editor.apply()
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)

        when (intent.action) {
            ACTION_SHUFFLE_IMAGE -> {
                val appWidgetId = intent.getIntExtra(EXTRA_WIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
                if (appWidgetId != AppWidgetManager.INVALID_APPWIDGET_ID) {
                    shuffleImage(context, appWidgetId)
                } else {
                    val appWidgetManager = AppWidgetManager.getInstance(context)
                    val cn = ComponentName(context.packageName, GhostPhotoWidgetProvider::class.java.name)
                    for (id in appWidgetManager.getAppWidgetIds(cn)) {
                        shuffleImage(context, id)
                    }
                }
            }

            ACTION_WIDGET_TAP -> {
                // ── Trampoline: write prefs FIRST, then start MainActivity ──
                // This guarantees WidgetLaunchPrefs is populated regardless of
                // how Android launches the activity (cold-start LAUNCHER intent
                // does not carry extras, so we cannot rely on Activity.intent).
                val widgetAction = intent.getStringExtra(EXTRA_WIDGET_ACTION) ?: "CONFIGURE"
                val imagePath    = intent.getStringExtra(EXTRA_IMAGE_PATH)
                val albumName    = intent.getStringExtra(EXTRA_ALBUM_NAME)
                val widgetId     = intent.getIntExtra(EXTRA_WIDGET_ID, -1)

                android.util.Log.d("GhostWidget", "ACTION_WIDGET_TAP: action=$widgetAction, id=$widgetId")

                // Write data to SharedPreferences before starting the activity
                context.getSharedPreferences("WidgetLaunchPrefs", Context.MODE_PRIVATE)
                    .edit()
                    .putBoolean("widgetClicked", true)
                    .putString("action", widgetAction)
                    .putString("imagePath", imagePath)
                    .putString("albumName", albumName)
                    .putInt("widgetId", widgetId)
                    .commit()

                // Now launch (or resume) MainActivity
                val launchIntent = context.packageManager
                    .getLaunchIntentForPackage(context.packageName)
                    ?.apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    }
                if (launchIntent != null) {
                    context.startActivity(launchIntent)
                }
            }
        }
    }

    private fun shuffleImage(context: Context, appWidgetId: Int) {
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

        // Per-widget paths key first; fall back to legacy global key
        val pathsJsonStr = prefs.getString(albumPathsKey(appWidgetId), null)
            ?: prefs.getString("flutter.widget_album_paths_json", null)

        if (!pathsJsonStr.isNullOrEmpty()) {
            try {
                val allPathsArray = JSONArray(pathsJsonStr)
                if (allPathsArray.length() == 0) return

                val allPaths = mutableListOf<String>()
                for (i in 0 until allPathsArray.length()) {
                    allPaths.add(allPathsArray.getString(i))
                }

                // Retrieve remaining paths for the current non-repeating shuffle cycle
                val remainingJsonStr = prefs.getString(remainingPathsKey(appWidgetId), null)
                    ?: prefs.getString("flutter.widget_remaining_paths_json", null)
                val remainingPaths = mutableListOf<String>()
                if (!remainingJsonStr.isNullOrEmpty()) {
                    val remainingArray = JSONArray(remainingJsonStr)
                    for (i in 0 until remainingArray.length()) {
                        remainingPaths.add(remainingArray.getString(i))
                    }
                }

                // If remaining paths list is empty, start a new non-repeating shuffle cycle
                if (remainingPaths.isEmpty()) {
                    remainingPaths.addAll(allPaths)
                    remainingPaths.shuffle()
                }

                // Take the first image path from our cycle list
                val nextImagePath = remainingPaths.removeAt(0)

                // Save changes back to SharedPreferences using per-widget keys
                val remainingJsonArray = JSONArray(remainingPaths)
                prefs.edit().apply {
                    putString(currentImageKey(appWidgetId), nextImagePath)
                    putString(remainingPathsKey(appWidgetId), remainingJsonArray.toString())
                    apply()
                }

                // Update widget UI
                val appWidgetManager = AppWidgetManager.getInstance(context)
                updateAppWidget(context, appWidgetManager, appWidgetId)
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }
}
