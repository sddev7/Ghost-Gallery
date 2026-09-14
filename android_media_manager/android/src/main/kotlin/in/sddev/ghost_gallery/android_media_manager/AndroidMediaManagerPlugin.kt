package `in`.sddev.ghost_gallery.android_media_manager

import android.app.Activity
import android.content.ContentResolver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.ContentObserver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Rect
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import android.util.LruCache
import android.util.Size
import androidx.work.*
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.io.File

class AndroidMediaManagerPlugin : FlutterPlugin, ActivityAware, MethodCallHandler, PluginRegistry.ActivityResultListener, PluginRegistry.RequestPermissionsResultListener {
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var activity: Activity? = null

    private val RENAME_REQUEST_CODE = 1002
    private val TRASH_REQUEST_CODE = 1003
    private val DELETE_REQUEST_CODE = 1004
    private val MEDIA_PERMISSION_REQUEST_CODE = 2001

    private var pendingResult: MethodChannel.Result? = null
    private var pendingUri: Uri? = null
    private var pendingFilePath: String? = null
    private var pendingNewName: String? = null
    private var pendingTrashUris: List<Uri>? = null
    private var pendingTrashIds: List<String>? = null
    private val trashedThumbnailCache = LruCache<Long, ByteArray>(100)
    private var mediaObserver: ContentObserver? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    private fun runOnMainThread(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            action()
        } else {
            mainHandler.post(action)
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "in.sddev.ghost_gallery/media_manager")
        channel?.setMethodCallHandler(this)
        registerMediaObserver()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        unregisterMediaObserver()
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val safeContext = context ?: run {
            result.error("NO_CONTEXT", "Application context is null", null)
            return
        }

        when (call.method) {
            "checkMediaPermission" -> {
                if (Build.VERSION.SDK_INT < 23) {
                    result.success(true)
                    return
                }
                val granted = if (Build.VERSION.SDK_INT >= 34) {
                    val hasImages = androidx.core.content.ContextCompat.checkSelfPermission(safeContext, android.Manifest.permission.READ_MEDIA_IMAGES) == android.content.pm.PackageManager.PERMISSION_GRANTED
                    val hasVideos = androidx.core.content.ContextCompat.checkSelfPermission(safeContext, android.Manifest.permission.READ_MEDIA_VIDEO) == android.content.pm.PackageManager.PERMISSION_GRANTED
                    val hasSelected = androidx.core.content.ContextCompat.checkSelfPermission(safeContext, "android.permission.READ_MEDIA_VISUAL_USER_SELECTED") == android.content.pm.PackageManager.PERMISSION_GRANTED
                    (hasImages && hasVideos) || hasSelected
                } else if (Build.VERSION.SDK_INT >= 33) {
                    val hasImages = androidx.core.content.ContextCompat.checkSelfPermission(safeContext, android.Manifest.permission.READ_MEDIA_IMAGES) == android.content.pm.PackageManager.PERMISSION_GRANTED
                    val hasVideos = androidx.core.content.ContextCompat.checkSelfPermission(safeContext, android.Manifest.permission.READ_MEDIA_VIDEO) == android.content.pm.PackageManager.PERMISSION_GRANTED
                    hasImages && hasVideos
                } else {
                    androidx.core.content.ContextCompat.checkSelfPermission(safeContext, android.Manifest.permission.READ_EXTERNAL_STORAGE) == android.content.pm.PackageManager.PERMISSION_GRANTED
                }
                result.success(granted)
            }

            "checkAudioPermission" -> {
                if (Build.VERSION.SDK_INT < 23) {
                    result.success(true)
                    return
                }
                val granted = if (Build.VERSION.SDK_INT >= 33) {
                    androidx.core.content.ContextCompat.checkSelfPermission(safeContext, android.Manifest.permission.READ_MEDIA_AUDIO) == android.content.pm.PackageManager.PERMISSION_GRANTED
                } else {
                    androidx.core.content.ContextCompat.checkSelfPermission(safeContext, android.Manifest.permission.READ_EXTERNAL_STORAGE) == android.content.pm.PackageManager.PERMISSION_GRANTED
                }
                result.success(granted)
            }

            "scanFile" -> {
                val path = call.argument<String>("path")
                if (path != null) {
                    android.media.MediaScannerConnection.scanFile(
                        safeContext,
                        arrayOf(path),
                        null
                    ) { scanPath, uri ->
                        android.util.Log.d("AndroidMediaManager", "Scanned $scanPath -> uri=$uri")
                        runOnMainThread {
                            result.success(uri?.toString())
                        }
                    }
                } else {
                    result.error("INVALID_ARGUMENT", "path is null", null)
                }
            }

            "canManageMedia" -> {
                val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    MediaStore.canManageMedia(safeContext)
                } else {
                    true
                }
                result.success(granted)
            }

            "requestManageMediaPermission" -> {
                val safeActivity = activity
                if (safeActivity == null) {
                    result.error("NO_ACTIVITY", "Cannot request manage media permission without an activity context", null)
                    return
                }
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        val intent = Intent(Settings.ACTION_REQUEST_MANAGE_MEDIA).apply {
                            data = Uri.parse("package:${safeActivity.packageName}")
                        }
                        safeActivity.startActivity(intent)
                    }
                    result.success(null)
                } catch (e: Exception) {
                    result.error("ERROR", e.message, null)
                }
            }

            "hasVaultStoragePermission" -> {
                val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    android.os.Environment.isExternalStorageManager()
                } else {
                    androidx.core.content.ContextCompat.checkSelfPermission(safeContext, android.Manifest.permission.WRITE_EXTERNAL_STORAGE) == android.content.pm.PackageManager.PERMISSION_GRANTED
                }
                result.success(granted)
            }

            "requestVaultStoragePermission" -> {
                val safeActivity = activity
                if (safeActivity == null) {
                    result.error("NO_ACTIVITY", "Cannot request vault storage permission without an activity context", null)
                    return
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    try {
                        val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                            data = Uri.parse("package:${safeActivity.packageName}")
                        }
                        safeActivity.startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        try {
                            val intent = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                            safeActivity.startActivity(intent)
                            result.success(true)
                        } catch (ex: Exception) {
                            result.error("ERROR", ex.message, null)
                        }
                    }
                } else {
                    pendingResult = result
                    safeActivity.requestPermissions(
                        arrayOf(
                            android.Manifest.permission.WRITE_EXTERNAL_STORAGE,
                            android.Manifest.permission.READ_EXTERNAL_STORAGE
                        ),
                        1005
                    )
                }
            }

            "cropAndResizeFace" -> {
                val path = call.argument<String>("path") ?: ""
                val x = call.argument<Int>("x") ?: 0
                val y = call.argument<Int>("y") ?: 0
                val w = call.argument<Int>("w") ?: 0
                val h = call.argument<Int>("h") ?: 0
                val padding = call.argument<Double>("padding") ?: 0.20
                cropAndResizeFace(path, x, y, w, h, padding, result)
            }

            "isDeviceCharging" -> {
                try {
                    val intent = safeContext.registerReceiver(null, android.content.IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                    val plugged = intent?.getIntExtra(android.os.BatteryManager.EXTRA_PLUGGED, -1) ?: -1
                    val isCharging = plugged == android.os.BatteryManager.BATTERY_PLUGGED_AC ||
                                     plugged == android.os.BatteryManager.BATTERY_PLUGGED_USB ||
                                     plugged == android.os.BatteryManager.BATTERY_PLUGGED_WIRELESS
                    result.success(isCharging)
                } catch (e: Exception) {
                    result.success(false)
                }
            }

            "isBatteryOptimizationExempt" -> {
                try {
                    val pm = safeContext.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
                    result.success(pm.isIgnoringBatteryOptimizations(safeContext.packageName))
                } catch (e: Exception) {
                    result.success(false)
                }
            }

            "requestBatteryOptimizationExemption" -> {
                val safeActivity = activity
                if (safeActivity == null) {
                    result.error("NO_ACTIVITY", "Cannot request battery exemption without an activity context", null)
                    return
                }
                try {
                    val intent = Intent(
                        Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        Uri.parse("package:${safeActivity.packageName}")
                    )
                    safeActivity.startActivity(intent)
                    result.success(null)
                } catch (e: Exception) {
                    try {
                        safeActivity.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                    } catch (_: Exception) {}
                    result.success(null)
                }
            }

            "requestMediaPermission" -> {
                val safeActivity = activity
                if (safeActivity == null) {
                    result.error("NO_ACTIVITY", "Cannot request media permission without an activity context", null)
                    return
                }
                if (Build.VERSION.SDK_INT < 23) {
                    result.success(true)
                    return
                }
                pendingResult = result
                if (Build.VERSION.SDK_INT >= 34) {
                    safeActivity.requestPermissions(
                        arrayOf(
                            android.Manifest.permission.READ_MEDIA_IMAGES,
                            android.Manifest.permission.READ_MEDIA_VIDEO,
                            "android.permission.READ_MEDIA_VISUAL_USER_SELECTED",
                            android.Manifest.permission.ACCESS_MEDIA_LOCATION
                        ),
                        MEDIA_PERMISSION_REQUEST_CODE
                    )
                } else if (Build.VERSION.SDK_INT >= 33) {
                    safeActivity.requestPermissions(
                        arrayOf(
                            android.Manifest.permission.READ_MEDIA_IMAGES,
                            android.Manifest.permission.READ_MEDIA_VIDEO,
                            android.Manifest.permission.ACCESS_MEDIA_LOCATION
                        ),
                        MEDIA_PERMISSION_REQUEST_CODE
                    )
                } else if (Build.VERSION.SDK_INT >= 29) {
                    safeActivity.requestPermissions(
                        arrayOf(
                            android.Manifest.permission.READ_EXTERNAL_STORAGE,
                            android.Manifest.permission.WRITE_EXTERNAL_STORAGE,
                            android.Manifest.permission.ACCESS_MEDIA_LOCATION
                        ),
                        MEDIA_PERMISSION_REQUEST_CODE
                    )
                } else {
                    safeActivity.requestPermissions(
                        arrayOf(
                            android.Manifest.permission.READ_EXTERNAL_STORAGE,
                            android.Manifest.permission.WRITE_EXTERNAL_STORAGE
                        ),
                        MEDIA_PERMISSION_REQUEST_CODE
                    )
                }
            }

            "saveImageToGallery" -> {
                val bytes = call.argument<ByteArray>("bytes")
                val title = call.argument<String>("title")
                val relativePath = call.argument<String>("relativePath") ?: "Pictures/Ghost Gallery"
                if (bytes == null || title == null) {
                    result.error("INVALID_ARGUMENT", "bytes and title are required", null)
                    return
                }
                
                Thread {
                    try {
                        val values = ContentValues().apply {
                            put(MediaStore.Images.Media.DISPLAY_NAME, title)
                            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                put(MediaStore.Images.Media.RELATIVE_PATH, relativePath)
                                put(MediaStore.Images.Media.IS_PENDING, 1)
                            }
                        }
                        
                        val uri = safeContext.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                        if (uri == null) {
                            runOnMainThread {
                                result.error("INSERT_FAILED", "Failed to insert MediaStore image record", null)
                            }
                            return@Thread
                        }
                        
                        safeContext.contentResolver.openOutputStream(uri)?.use { out ->
                            out.write(bytes)
                        }
                        
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            values.clear()
                            values.put(MediaStore.Images.Media.IS_PENDING, 0)
                            safeContext.contentResolver.update(uri, values, null, null)
                        }
                        
                        val finalPath = queryDataPath(uri) ?: ""
                        val id = getMediaIdFromUri(uri) ?: ""
                        
                        runOnMainThread {
                            result.success(mapOf("id" to id, "path" to finalPath))
                        }
                    } catch (e: Exception) {
                        runOnMainThread {
                            result.error("SAVE_FAILED", e.message, null)
                        }
                    }
                }.start()
            }
            
            "saveVideoToGallery" -> {
                val filePath = call.argument<String>("filePath")
                val title = call.argument<String>("title")
                val relativePath = call.argument<String>("relativePath") ?: "Movies/Ghost Gallery"
                if (filePath == null || title == null) {
                    result.error("INVALID_ARGUMENT", "filePath and title are required", null)
                    return
                }
                
                Thread {
                    try {
                        val sourceFile = File(filePath)
                        if (!sourceFile.exists()) {
                            runOnMainThread {
                                result.error("FILE_NOT_FOUND", "Source video file not found", null)
                            }
                            return@Thread
                        }
                        
                        val values = ContentValues().apply {
                            put(MediaStore.Video.Media.DISPLAY_NAME, title)
                            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                put(MediaStore.Video.Media.RELATIVE_PATH, relativePath)
                                put(MediaStore.Video.Media.IS_PENDING, 1)
                            }
                        }
                        
                        val uri = safeContext.contentResolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
                        if (uri == null) {
                            runOnMainThread {
                                result.error("INSERT_FAILED", "Failed to insert MediaStore video record", null)
                            }
                            return@Thread
                        }
                        
                        safeContext.contentResolver.openOutputStream(uri)?.use { out ->
                            sourceFile.inputStream().use { inp ->
                                inp.copyTo(out)
                            }
                        }
                        
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            values.clear()
                            values.put(MediaStore.Video.Media.IS_PENDING, 0)
                            safeContext.contentResolver.update(uri, values, null, null)
                        }
                        
                        val finalPath = queryDataPath(uri) ?: ""
                        val id = getMediaIdFromUri(uri) ?: ""
                        
                        runOnMainThread {
                            result.success(mapOf("id" to id, "path" to finalPath))
                        }
                    } catch (e: Exception) {
                        runOnMainThread {
                            result.error("SAVE_FAILED", e.message, null)
                        }
                    }
                }.start()
            }

            "getMediaList" -> {
                Thread {
                    try {
                        val list = mutableListOf<Map<String, Any?>>()
                        
                        val imgProjection = arrayOf(
                            MediaStore.Images.Media._ID,
                            MediaStore.Images.Media.DATA,
                            MediaStore.Images.Media.DATE_ADDED,
                            MediaStore.Images.Media.DATE_MODIFIED,
                            MediaStore.Images.Media.WIDTH,
                            MediaStore.Images.Media.HEIGHT,
                            MediaStore.Images.Media.SIZE,
                            MediaStore.Images.Media.MIME_TYPE,
                            MediaStore.Images.Media.ORIENTATION,
                            MediaStore.Images.Media.BUCKET_DISPLAY_NAME,
                            MediaStore.Images.Media.BUCKET_ID
                        )
                        
                        safeContext.contentResolver.query(
                            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                            imgProjection,
                            null, null, null
                        )?.use { cursor ->
                            val idCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
                            val dataCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATA)
                            val dateAddedCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_ADDED)
                            val dateModCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_MODIFIED)
                            val widthCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.WIDTH)
                            val heightCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.HEIGHT)
                            val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.SIZE)
                            val mimeCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.MIME_TYPE)
                            val orientCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.ORIENTATION)
                            val bucketNameCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.BUCKET_DISPLAY_NAME)
                            val bucketIdCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.BUCKET_ID)
                            
                            while (cursor.moveToNext()) {
                                val id = cursor.getLong(idCol).toString()
                                val path = cursor.getString(dataCol) ?: ""
                                if (path.isEmpty() || !File(path).exists()) continue
                                
                                val dateAdded = cursor.getLong(dateAddedCol) * 1000
                                val dateMod = cursor.getLong(dateModCol) * 1000
                                val width = cursor.getInt(widthCol)
                                val height = cursor.getInt(heightCol)
                                val size = cursor.getLong(sizeCol)
                                val mime = cursor.getString(mimeCol) ?: "image/jpeg"
                                val orient = cursor.getInt(orientCol)
                                val bucketName = cursor.getString(bucketNameCol) ?: "Camera"
                                val bucketId = cursor.getString(bucketIdCol) ?: ""
                                
                                list.add(mapOf(
                                    "id" to id,
                                    "path" to path,
                                    "media_type" to "image",
                                    "date_timestamp" to dateAdded,
                                    "modified_timestamp" to (if (dateMod > 0) dateMod else dateAdded),
                                    "width" to width,
                                    "height" to height,
                                    "size" to size,
                                    "mime_type" to mime,
                                    "rotation_degrees" to orient,
                                    "album_name" to bucketName,
                                    "album_id" to bucketId,
                                    "duration" to null
                                ))
                            }
                        }
                        
                        val vidProjection = arrayOf(
                            MediaStore.Video.Media._ID,
                            MediaStore.Video.Media.DATA,
                            MediaStore.Video.Media.DATE_ADDED,
                            MediaStore.Video.Media.DATE_MODIFIED,
                            MediaStore.Video.Media.WIDTH,
                            MediaStore.Video.Media.HEIGHT,
                            MediaStore.Video.Media.SIZE,
                            MediaStore.Video.Media.MIME_TYPE,
                            MediaStore.Video.Media.DURATION,
                            MediaStore.Video.Media.BUCKET_DISPLAY_NAME,
                            MediaStore.Video.Media.BUCKET_ID
                        )
                        
                        safeContext.contentResolver.query(
                            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                            vidProjection,
                            null, null, null
                        )?.use { cursor ->
                            val idCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media._ID)
                            val dataCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DATA)
                            val dateAddedCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DATE_ADDED)
                            val dateModCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DATE_MODIFIED)
                            val widthCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.WIDTH)
                            val heightCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.HEIGHT)
                            val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.SIZE)
                            val mimeCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.MIME_TYPE)
                            val durationCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DURATION)
                            val bucketNameCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.BUCKET_DISPLAY_NAME)
                            val bucketIdCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.BUCKET_ID)
                            
                            while (cursor.moveToNext()) {
                                val id = cursor.getLong(idCol).toString()
                                val path = cursor.getString(dataCol) ?: ""
                                if (path.isEmpty() || !File(path).exists()) continue
                                
                                val dateAdded = cursor.getLong(dateAddedCol) * 1000
                                val dateMod = cursor.getLong(dateModCol) * 1000
                                val width = cursor.getInt(widthCol)
                                val height = cursor.getInt(heightCol)
                                val size = cursor.getLong(sizeCol)
                                val mime = cursor.getString(mimeCol) ?: "video/mp4"
                                val durationMs = cursor.getLong(durationCol)
                                val durationSec = durationMs / 1000.0
                                val bucketName = cursor.getString(bucketNameCol) ?: "Camera"
                                val bucketId = cursor.getString(bucketIdCol) ?: ""
                                
                                list.add(mapOf(
                                    "id" to id,
                                    "path" to path,
                                    "media_type" to "video",
                                    "date_timestamp" to dateAdded,
                                    "modified_timestamp" to (if (dateMod > 0) dateMod else dateAdded),
                                    "width" to width,
                                    "height" to height,
                                    "size" to size,
                                    "mime_type" to mime,
                                    "rotation_degrees" to 0,
                                    "album_name" to bucketName,
                                    "album_id" to bucketId,
                                    "duration" to durationSec
                                ))
                            }
                        }
                        
                        list.sortByDescending { it["date_timestamp"] as Long }
                        
                        runOnMainThread {
                            result.success(list)
                        }
                    } catch (e: Exception) {
                        runOnMainThread {
                            result.error("QUERY_FAILED", e.message, null)
                        }
                    }
                }.start()
            }

            "getThumbnail" -> {
                val id = call.argument<String>("id")
                val isVideo = call.argument<Boolean>("isVideo") ?: false
                val width = call.argument<Int>("width") ?: 200
                val height = call.argument<Int>("height") ?: 200
                val quality = call.argument<Int>("quality") ?: 80
                
                if (id == null) {
                    result.error("INVALID_ARGUMENT", "id is required", null)
                    return
                }
                
                Thread {
                    try {
                        val mediaId = id.toLongOrNull()
                        if (mediaId == null) {
                            runOnMainThread {
                                result.error("INVALID_ID", "ID must be a numeric string", null)
                            }
                            return@Thread
                        }
                        
                        val uri = if (isVideo) {
                            ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, mediaId)
                        } else {
                            ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, mediaId)
                        }
                        
                        val bitmap = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            try {
                                safeContext.contentResolver.loadThumbnail(uri, Size(width, height), null)
                            } catch (e: Exception) {
                                null
                            }
                        } else {
                            null
                        }
                        
                        val finalBmp = bitmap ?: if (isVideo) {
                            @Suppress("DEPRECATION")
                            MediaStore.Video.Thumbnails.getThumbnail(
                                safeContext.contentResolver,
                                mediaId,
                                MediaStore.Video.Thumbnails.MINI_KIND,
                                null
                            )
                        } else {
                            @Suppress("DEPRECATION")
                            MediaStore.Images.Thumbnails.getThumbnail(
                                safeContext.contentResolver,
                                mediaId,
                                MediaStore.Images.Thumbnails.MINI_KIND,
                                null
                            )
                        }
                        
                        if (finalBmp == null) {
                            runOnMainThread {
                                result.success(null)
                            }
                            return@Thread
                        }
                        
                        val stream = ByteArrayOutputStream()
                        finalBmp.compress(Bitmap.CompressFormat.JPEG, quality, stream)
                        val byteArray = stream.toByteArray()
                        finalBmp.recycle()
                        
                        runOnMainThread {
                            result.success(byteArray)
                        }
                    } catch (e: Exception) {
                        runOnMainThread {
                            result.error("THUMBNAIL_FAILED", e.message, null)
                        }
                    }
                }.start()
            }

            "renameMediaFile" -> {
                val filePath = call.argument<String>("filePath")
                val newName  = call.argument<String>("newName")
                val mediaId  = call.argument<String>("mediaId")
                if (filePath == null || newName == null) {
                    result.error("INVALID_ARGUMENT", "filePath and newName required", null)
                    return
                }

                var contentUri = findContentUri(filePath)
                if (contentUri == null && mediaId != null) {
                    contentUri = findContentUriById(mediaId)
                }

                if (contentUri == null) {
                    val src  = File(filePath)
                    val dest = File(src.parent ?: "", newName)
                    if (src.renameTo(dest)) result.success(dest.absolutePath)
                    else result.error("RENAME_FAILED", "File.renameTo failed", null)
                    return
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    val safeActivity = activity
                    if (safeActivity == null) {
                        result.error("NO_ACTIVITY", "Cannot request rename write permission without an activity context", null)
                        return
                    }
                    try {
                        pendingResult = result
                        pendingUri = contentUri
                        pendingFilePath = filePath
                        pendingNewName = newName

                        val pendingIntent = MediaStore.createWriteRequest(safeContext.contentResolver, listOf(contentUri))
                        safeActivity.startIntentSenderForResult(
                            pendingIntent.intentSender,
                            RENAME_REQUEST_CODE,
                            null, 0, 0, 0
                        )
                    } catch (e: Exception) {
                        pendingResult = null
                        pendingUri = null
                        pendingFilePath = null
                        pendingNewName = null
                        result.error("ERROR", "Failed to create write request: ${e.message}", null)
                    }
                } else {
                    try {
                        val values = ContentValues().apply {
                            put(MediaStore.MediaColumns.DISPLAY_NAME, newName)
                        }
                        val rows = safeContext.contentResolver.update(contentUri, values, null, null)
                        if (rows > 0) {
                            val queriedPath = queryDataPath(contentUri)
                            val parentDir = File(filePath).parent ?: ""
                            val expectedPath = File(parentDir, newName).absolutePath
                            val newPath = if (queriedPath != null && File(queriedPath).name == newName) queriedPath else expectedPath
                            result.success(newPath)
                        } else {
                            result.error("RENAME_FAILED", "ContentResolver.update returned 0 rows", null)
                        }
                    } catch (e: Exception) {
                        result.error("ERROR", e.message, null)
                    }
                }
            }

            "trashMedia" -> {
                val filePaths = call.argument<List<String>>("filePaths")
                val mediaIds = call.argument<List<String>>("mediaIds")
                val trash = call.argument<Boolean>("trash") ?: true
                if (filePaths == null) {
                    result.error("INVALID_ARGUMENT", "filePaths required", null)
                    return
                }

                val uris = mutableListOf<Uri>()
                val ids = mutableListOf<String>()
                for (i in filePaths.indices) {
                    val path = filePaths[i]
                    val mediaId = mediaIds?.getOrNull(i)
                    var uri = findContentUri(path)
                    if (uri == null && mediaId != null) {
                        uri = findContentUriById(mediaId)
                    }
                    if (uri != null) {
                        uris.add(uri)
                        if (mediaId != null) {
                            ids.add(mediaId)
                        }
                    }
                }

                if (uris.isEmpty()) {
                    result.success(null)
                    return
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    val safeActivity = activity
                    if (safeActivity == null) {
                        result.error("NO_ACTIVITY", "Cannot request trash permission without an activity context", null)
                        return
                    }
                    try {
                        pendingResult = result
                        pendingTrashUris = uris
                        pendingTrashIds = ids
                        val pendingIntent = MediaStore.createTrashRequest(safeContext.contentResolver, uris, trash)
                        safeActivity.startIntentSenderForResult(
                            pendingIntent.intentSender,
                            TRASH_REQUEST_CODE,
                            null, 0, 0, 0
                        )
                    } catch (e: Exception) {
                        pendingResult = null
                        pendingTrashUris = null
                        pendingTrashIds = null
                        result.error("ERROR", "Failed to create trash request: ${e.message}", null)
                    }
                } else {
                    result.success(null)
                }
            }

            "deleteMedia" -> {
                val filePaths = call.argument<List<String>>("filePaths")
                val mediaIds = call.argument<List<String>>("mediaIds")
                if (filePaths == null) {
                    result.error("INVALID_ARGUMENT", "filePaths required", null)
                    return
                }

                val uris = mutableListOf<Uri>()
                for (i in filePaths.indices) {
                    val path = filePaths[i]
                    val mediaId = mediaIds?.getOrNull(i)
                    var uri = findContentUri(path)
                    if (uri == null && mediaId != null) {
                        uri = findContentUriById(mediaId)
                    }
                    if (uri != null) {
                        uris.add(uri)
                    }
                }

                if (uris.isEmpty()) {
                    result.success(null)
                    return
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    val safeActivity = activity
                    if (safeActivity == null) {
                        result.error("NO_ACTIVITY", "Cannot request delete permission without an activity context", null)
                        return
                    }
                    try {
                        pendingResult = result
                        val pendingIntent = MediaStore.createDeleteRequest(safeContext.contentResolver, uris)
                        safeActivity.startIntentSenderForResult(
                            pendingIntent.intentSender,
                            DELETE_REQUEST_CODE,
                            null, 0, 0, 0
                        )
                    } catch (e: Exception) {
                        pendingResult = null
                        result.error("ERROR", "Failed to create delete request: ${e.message}", null)
                    }
                } else {
                    var deletedCount = 0
                    for (uri in uris) {
                        try {
                            val rows = safeContext.contentResolver.delete(uri, null, null)
                            if (rows > 0) deletedCount++
                        } catch (e: Exception) {
                            android.util.Log.e("AndroidMediaManager", "Error deleting $uri: ${e.message}")
                        }
                    }
                    result.success(deletedCount == uris.size)
                }
            }

            "getAudioThumbnail" -> {
                val filePath = call.argument<String>("filePath")
                if (filePath == null) {
                    result.error("INVALID_ARGUMENT", "filePath required", null)
                    return
                }
                Thread {
                    var retriever: android.media.MediaMetadataRetriever? = null
                    try {
                        retriever = android.media.MediaMetadataRetriever()
                        retriever.setDataSource(filePath)
                        val art = retriever.embeddedPicture
                        runOnMainThread {
                            result.success(art)
                        }
                    } catch (e: Exception) {
                        runOnMainThread {
                            result.success(null)
                        }
                    } finally {
                        try {
                            retriever?.release()
                        } catch (_: Exception) {}
                    }
                }.start()
            }

            "getTrashedMedia" -> {
                result.success(getTrashedMedia())
            }

            "getTrashedThumbnail" -> {
                val id = call.argument<String>("id")!!
                result.success(getTrashedThumbnail(id.toLong()))
            }

            "getMediaContentUri" -> {
                val filePath = call.argument<String>("filePath")
                val mediaId  = call.argument<String>("mediaId")
                var contentUri: Uri? = null
                if (mediaId != null) {
                    contentUri = findContentUriById(mediaId)
                }
                if (contentUri == null && filePath != null) {
                    contentUri = findContentUri(filePath)
                }
                if (contentUri != null) {
                    result.success(contentUri.toString())
                } else {
                    result.success(null)
                }
            }

            "getMediaBytes" -> {
                val filePath = call.argument<String>("filePath")
                val mediaId  = call.argument<String>("mediaId")
                var contentUri: Uri? = null
                if (mediaId != null) {
                    contentUri = findContentUriById(mediaId)
                }
                if (contentUri == null && filePath != null) {
                    contentUri = findContentUri(filePath)
                }
                if (contentUri == null) {
                    result.error("INVALID_URI", "No content URI found", null)
                    return
                }
                var finalUri = contentUri
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    try {
                        finalUri = MediaStore.setRequireOriginal(contentUri)
                    } catch (e: Exception) {
                        android.util.Log.e("AndroidMediaManager", "setRequireOriginal failed: ${e.message}")
                    }
                }
                val readUri = finalUri
                Thread {
                    try {
                        safeContext.contentResolver.openInputStream(readUri)?.use { inputStream ->
                            val bytes = inputStream.readBytes()
                            runOnMainThread {
                                result.success(bytes)
                            }
                        } ?: run {
                            runOnMainThread {
                                result.error("OPEN_FAILED", "Failed to open input stream", null)
                            }
                        }
                    } catch (e: Exception) {
                        runOnMainThread {
                            result.error("ERROR", e.message, null)
                        }
                    }
                }.start()
            }

            "getTrashedMediaThumbnail" -> {
                val filePath = call.argument<String>("filePath")
                val mediaId  = call.argument<String>("mediaId")
                val isVideo  = call.argument<Boolean>("isVideo") ?: false
                if (filePath == null) {
                    result.error("INVALID_ARGUMENT", "filePath required", null)
                    return
                }

                var contentUri: Uri? = null
                if (mediaId != null) {
                    contentUri = findContentUriById(mediaId)
                }
                if (contentUri == null) {
                    contentUri = findContentUri(filePath)
                }

                try {
                    if (isVideo) {
                        val retriever = android.media.MediaMetadataRetriever()
                        try {
                            if (contentUri != null) {
                                retriever.setDataSource(safeContext, contentUri)
                            } else {
                                val file = File(filePath)
                                if (file.exists()) {
                                    retriever.setDataSource(file.absolutePath)
                                } else {
                                    result.error("NOT_FOUND", "Video file not found", null)
                                    return
                                }
                            }
                            val bitmap = retriever.getFrameAtTime(1000000, android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                            if (bitmap != null) {
                                val scaled = android.graphics.Bitmap.createScaledBitmap(bitmap, 512, 512, true)
                                val outputStream = java.io.ByteArrayOutputStream()
                                scaled.compress(android.graphics.Bitmap.CompressFormat.JPEG, 80, outputStream)
                                result.success(outputStream.toByteArray())
                            } else {
                                result.error("DECODE_FAILED", "Failed to extract frame from video", null)
                            }
                        } catch (e: Exception) {
                            result.error("ERROR", "Video metadata error: ${e.message}", null)
                        } finally {
                            try {
                                retriever.release()
                            } catch (_: Exception) {}
                        }
                    } else {
                        var bitmap: android.graphics.Bitmap? = null
                        val options = BitmapFactory.Options()

                        if (contentUri != null) {
                            safeContext.contentResolver.openInputStream(contentUri)?.use { inputStream ->
                                options.inJustDecodeBounds = true
                                BitmapFactory.decodeStream(inputStream, null, options)
                            }
                            
                            var inSampleSize = 1
                            if (options.outHeight > 512 || options.outWidth > 512) {
                                val halfHeight = options.outHeight / 2
                                val halfWidth = options.outWidth / 2
                                while (halfHeight / inSampleSize >= 512 && halfWidth / inSampleSize >= 512) {
                                    inSampleSize *= 2
                                }
                            }
                            options.inSampleSize = inSampleSize
                            options.inJustDecodeBounds = false

                            safeContext.contentResolver.openInputStream(contentUri)?.use { inputStream ->
                                bitmap = BitmapFactory.decodeStream(inputStream, null, options)
                            }
                        } else {
                            val file = File(filePath)
                            if (file.exists()) {
                                options.inJustDecodeBounds = true
                                BitmapFactory.decodeFile(file.absolutePath, options)
                                
                                var inSampleSize = 1
                                if (options.outHeight > 512 || options.outWidth > 512) {
                                    val halfHeight = options.outHeight / 2
                                    val halfWidth = options.outWidth / 2
                                    while (halfHeight / inSampleSize >= 512 && halfWidth / inSampleSize >= 512) {
                                        inSampleSize *= 2
                                    }
                                }
                                options.inSampleSize = inSampleSize
                                options.inJustDecodeBounds = false
                                
                                bitmap = BitmapFactory.decodeFile(file.absolutePath, options)
                            }
                        }

                        if (bitmap != null) {
                            val outputStream = java.io.ByteArrayOutputStream()
                            bitmap!!.compress(android.graphics.Bitmap.CompressFormat.JPEG, 80, outputStream)
                            result.success(outputStream.toByteArray())
                        } else {
                            result.error("DECODE_FAILED", "Failed to decode image", null)
                        }
                    }
                } catch (e: Exception) {
                    result.error("ERROR", "Thumbnail decoding error: ${e.message}", null)
                }
            }

            "scheduleMediaTriggerWork" -> {
                scheduleMediaTriggerWork(safeContext)
                result.success(true)
            }

            "scheduleWatchdogAlarm" -> {
                try {
                    val taskName = call.argument<String>("taskName") ?: "ghost_gallery_processing_task"
                    val alarmManager = safeContext.getSystemService(Context.ALARM_SERVICE) as android.app.AlarmManager
                    val intent = Intent().apply {
                        setClassName(safeContext.packageName, "in.sddev.ghost_gallery.WatchdogReceiver")
                        putExtra("taskName", taskName)
                    }
                    val pending = android.app.PendingIntent.getBroadcast(
                        safeContext, 0, intent,
                        android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
                    )
                    val triggerAt = System.currentTimeMillis() + (3 * 60 * 1000)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        alarmManager.setAndAllowWhileIdle(android.app.AlarmManager.RTC_WAKEUP, triggerAt, pending)
                    } else {
                        alarmManager.set(android.app.AlarmManager.RTC_WAKEUP, triggerAt, pending)
                    }
                    android.util.Log.d("AndroidMediaManager", "Watchdog alarm scheduled for $taskName to fire in 3 minutes.")
                    result.success(null)
                } catch (e: Exception) {
                    result.error("ERROR", "Failed to schedule watchdog: ${e.message}", null)
                }
            }

            "cancelWatchdogAlarm" -> {
                try {
                    val alarmManager = safeContext.getSystemService(Context.ALARM_SERVICE) as android.app.AlarmManager
                    val intent = Intent().apply {
                        setClassName(safeContext.packageName, "in.sddev.ghost_gallery.WatchdogReceiver")
                    }
                    val pending = android.app.PendingIntent.getBroadcast(
                        safeContext, 0, intent,
                        android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
                    )
                    alarmManager.cancel(pending)
                    android.util.Log.d("AndroidMediaManager", "Watchdog alarm cancelled.")
                    result.success(null)
                } catch (e: Exception) {
                    result.error("ERROR", "Failed to cancel watchdog: ${e.message}", null)
                }
            }

            "getStorageStats" -> {
                Thread {
                    try {
                        val extDir = android.os.Environment.getExternalStorageDirectory()
                        val stat = android.os.StatFs(extDir.path)
                        val blockSize = stat.blockSizeLong
                        val totalBytes = stat.blockCountLong * blockSize
                        val freeBytes  = stat.availableBlocksLong * blockSize

                        var imageBytes = 0L
                        safeContext.contentResolver.query(
                            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                            arrayOf(MediaStore.Images.Media.SIZE),
                            null, null, null
                        )?.use { cursor ->
                            val sizeCol = cursor.getColumnIndex(MediaStore.Images.Media.SIZE)
                            while (cursor.moveToNext()) {
                                if (sizeCol >= 0) imageBytes += cursor.getLong(sizeCol)
                            }
                        }

                        var videoBytes = 0L
                        safeContext.contentResolver.query(
                            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                            arrayOf(MediaStore.Video.Media.SIZE),
                            null, null, null
                        )?.use { cursor ->
                            val sizeCol = cursor.getColumnIndex(MediaStore.Video.Media.SIZE)
                            while (cursor.moveToNext()) {
                                if (sizeCol >= 0) videoBytes += cursor.getLong(sizeCol)
                            }
                        }

                        val data = mapOf(
                            "totalBytes"  to totalBytes,
                            "freeBytes"   to freeBytes,
                            "imageBytes"  to imageBytes,
                            "videoBytes"  to videoBytes
                        )
                        runOnMainThread { result.success(data) }
                    } catch (e: Exception) {
                        runOnMainThread {
                            result.error("STORAGE_STATS_ERROR", e.message, null)
                        }
                    }
                }.start()
            }

            else -> result.notImplemented()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val safeContext = context ?: return false
        if (requestCode == RENAME_REQUEST_CODE) {
            val resultCallback = pendingResult
            val uri = pendingUri
            val newName = pendingNewName
            val filePath = pendingFilePath

            pendingResult = null
            pendingUri = null
            pendingFilePath = null
            pendingNewName = null

            if (resultCallback == null || uri == null || newName == null || filePath == null) return true

            if (resultCode == Activity.RESULT_OK) {
                try {
                    val values = ContentValues().apply {
                        put(MediaStore.MediaColumns.DISPLAY_NAME, newName)
                    }
                    val rows = safeContext.contentResolver.update(uri, values, null, null)
                    if (rows > 0) {
                        val queriedPath = queryDataPath(uri)
                        val parentDir = File(filePath).parent ?: ""
                        val expectedPath = File(parentDir, newName).absolutePath
                        val newPath = if (queriedPath != null && File(queriedPath).name == newName) queriedPath else expectedPath
                        resultCallback.success(newPath)
                    } else {
                        resultCallback.error("RENAME_FAILED", "ContentResolver.update returned 0 rows after write permission granted", null)
                    }
                } catch (e: Exception) {
                    resultCallback.error("ERROR", "Failed to rename after write permission granted: ${e.message}", null)
                }
            } else {
                resultCallback.error("PERMISSION_DENIED", "Write permission denied for Uri", null)
            }
            return true
        } else if (requestCode == TRASH_REQUEST_CODE) {
            val resultCallback = pendingResult
            val uris = pendingTrashUris
            val ids = pendingTrashIds

            pendingResult = null
            pendingTrashUris = null
            pendingTrashIds = null

            if (resultCallback != null) {
                if (resultCode == Activity.RESULT_OK) {
                    val pathsMap = mutableMapOf<String, String>()
                    if (uris != null && ids != null) {
                        for (i in uris.indices) {
                            val uri = uris[i]
                            val id = ids.getOrNull(i) ?: continue
                            val newPath = queryDataPath(uri)
                            if (newPath != null) {
                                pathsMap[id] = newPath
                            }
                        }
                    }
                    resultCallback.success(pathsMap)
                } else {
                    resultCallback.success(null)
                }
            }
            return true
        } else if (requestCode == DELETE_REQUEST_CODE) {
            val resultCallback = pendingResult
            pendingResult = null
            if (resultCallback != null) {
                if (resultCode == Activity.RESULT_OK) {
                    resultCallback.success(true)
                } else {
                    resultCallback.success(false)
                }
            }
            return true
        }
        return false
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        val safeActivity = activity ?: return false
        if (requestCode == 1005) {
            val resultCallback = pendingResult
            pendingResult = null
            if (resultCallback != null) {
                val granted = grantResults.isNotEmpty() && grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
                resultCallback.success(granted)
            }
            return true
        } else if (requestCode == MEDIA_PERMISSION_REQUEST_CODE) {
            val resultCallback = pendingResult
            pendingResult = null
            if (resultCallback != null) {
                if (Build.VERSION.SDK_INT >= 34) {
                    val hasImages = androidx.core.content.ContextCompat.checkSelfPermission(safeActivity, android.Manifest.permission.READ_MEDIA_IMAGES) == android.content.pm.PackageManager.PERMISSION_GRANTED
                    val hasVideos = androidx.core.content.ContextCompat.checkSelfPermission(safeActivity, android.Manifest.permission.READ_MEDIA_VIDEO) == android.content.pm.PackageManager.PERMISSION_GRANTED
                    val hasSelected = androidx.core.content.ContextCompat.checkSelfPermission(safeActivity, "android.permission.READ_MEDIA_VISUAL_USER_SELECTED") == android.content.pm.PackageManager.PERMISSION_GRANTED
                    resultCallback.success((hasImages && hasVideos) || hasSelected)
                } else if (Build.VERSION.SDK_INT >= 33) {
                    val hasImages = androidx.core.content.ContextCompat.checkSelfPermission(safeActivity, android.Manifest.permission.READ_MEDIA_IMAGES) == android.content.pm.PackageManager.PERMISSION_GRANTED
                    val hasVideos = androidx.core.content.ContextCompat.checkSelfPermission(safeActivity, android.Manifest.permission.READ_MEDIA_VIDEO) == android.content.pm.PackageManager.PERMISSION_GRANTED
                    resultCallback.success(hasImages && hasVideos)
                } else {
                    val hasRead = androidx.core.content.ContextCompat.checkSelfPermission(safeActivity, android.Manifest.permission.READ_EXTERNAL_STORAGE) == android.content.pm.PackageManager.PERMISSION_GRANTED
                    resultCallback.success(hasRead)
                }
            }
            return true
        }
        return false
    }

    private fun findContentUri(filePath: String): Uri? {
        val safeContext = context ?: return null
        val collections = listOf(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        )
        for (collection in collections) {
            val uri = queryUriByPath(collection, filePath)
            if (uri != null) return uri
        }
        return null
    }

    private fun findContentUriById(mediaId: String): Uri? {
        val safeContext = context ?: return null
        val idLong = mediaId.toLongOrNull() ?: return null
        val collections = listOf(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        )
        for (collection in collections) {
            val uri = Uri.withAppendedPath(collection, idLong.toString())
            try {
                val queryResult = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    val bundle = android.os.Bundle().apply {
                        putInt(MediaStore.QUERY_ARG_MATCH_TRASHED, MediaStore.MATCH_INCLUDE)
                        putInt(MediaStore.QUERY_ARG_MATCH_PENDING, MediaStore.MATCH_INCLUDE)
                    }
                    safeContext.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns._ID), bundle, null)
                } else {
                    safeContext.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns._ID), null, null, null)
                }
                
                queryResult?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        return uri
                    }
                }
            } catch (_: Exception) {}
        }
        return null
    }

    private fun queryUriByPath(collection: Uri, filePath: String): Uri? {
        val safeContext = context ?: return null
        return try {
            val queryResult = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val bundle = android.os.Bundle().apply {
                    putString(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION, "${MediaStore.MediaColumns.DATA} = ?")
                    putStringArray(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, arrayOf(filePath))
                    putInt(MediaStore.QUERY_ARG_MATCH_TRASHED, MediaStore.MATCH_INCLUDE)
                    putInt(MediaStore.QUERY_ARG_MATCH_PENDING, MediaStore.MATCH_INCLUDE)
                }
                safeContext.contentResolver.query(collection, arrayOf(MediaStore.MediaColumns._ID), bundle, null)
            } else {
                safeContext.contentResolver.query(
                    collection,
                    arrayOf(MediaStore.MediaColumns._ID),
                    "${MediaStore.MediaColumns.DATA} = ?",
                    arrayOf(filePath),
                    null
                )
            }
            queryResult?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val id = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID))
                    Uri.withAppendedPath(collection, id.toString())
                } else null
            }
        } catch (_: Exception) { null }
    }

    private fun queryDataPath(uri: Uri): String? {
        val safeContext = context ?: return null
        return try {
            Thread.sleep(150)
            val queryResult = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val bundle = android.os.Bundle().apply {
                    putInt(MediaStore.QUERY_ARG_MATCH_TRASHED, MediaStore.MATCH_INCLUDE)
                    putInt(MediaStore.QUERY_ARG_MATCH_PENDING, MediaStore.MATCH_INCLUDE)
                }
                safeContext.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DATA), bundle, null)
            } else {
                safeContext.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)
            }
            queryResult?.use { cursor ->
                if (cursor.moveToFirst())
                    cursor.getString(cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATA))
                else null
            }
        } catch (_: Exception) { null }
    }

    private fun scheduleMediaTriggerWork(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                val constraints = Constraints.Builder()
                    .addContentUriTrigger(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true)
                    .addContentUriTrigger(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true)
                    .build()

                val inputData = Data.Builder()
                    .putString("dev.fluttercommunity.workmanager.DART_TASK", "ghost_gallery_processing_task")
                    .build()

                @Suppress("UNCHECKED_CAST")
                val workerClass = Class.forName("dev.fluttercommunity.workmanager.BackgroundWorker") as Class<out ListenableWorker>

                val workRequest = OneTimeWorkRequest.Builder(workerClass)
                    .setConstraints(constraints)
                    .setInputData(inputData)
                    .build()

                WorkManager.getInstance(context).enqueueUniqueWork(
                    "ghost_media_trigger_worker",
                    ExistingWorkPolicy.REPLACE,
                    workRequest
                )
                android.util.Log.d("AndroidMediaManager", "Successfully scheduled native media trigger WorkManager task")
            } catch (e: Exception) {
                android.util.Log.e("AndroidMediaManager", "Failed to schedule media trigger WorkManager task: ${e.message}")
            }
        }
    }

    private fun getTrashedMedia(): List<Map<String, Any?>> {
        val safeContext = context ?: return emptyList()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return emptyList()
        }
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.DATE_EXPIRES
        )

        val bundle = Bundle().apply {
            putInt("android:query-arg-match-trashed", 1)
            putString(
                ContentResolver.QUERY_ARG_SQL_SELECTION,
                "${MediaStore.MediaColumns.IS_TRASHED} = 1"
            )
        }

        val results = mutableListOf<Map<String, Any?>>()

        try {
            safeContext.contentResolver.query(
                MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL),
                projection, bundle, null
            )?.use { cursor ->
                val idCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                val nameCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                val mimeCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
                val expiresCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_EXPIRES)

                while (cursor.moveToNext()) {
                    val id = cursor.getLong(idCol)
                    val mime = cursor.getString(mimeCol) ?: ""

                    if (!mime.startsWith("image/") && !mime.startsWith("video/")) continue

                    val uri = ContentUris.withAppendedId(
                        MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL), id
                    )

                    results.add(mapOf(
                        "id" to id.toString(),
                        "uri" to uri.toString(),
                        "name" to cursor.getString(nameCol),
                        "mime" to mime,
                        "expires" to cursor.getLong(expiresCol)
                    ))
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("AndroidMediaManager", "Error querying trashed media: ${e.message}")
        }
        return results
    }

    private fun getTrashedThumbnail(id: Long): ByteArray? {
        val safeContext = context ?: return null
        val cached = trashedThumbnailCache.get(id)
        if (cached != null) {
            return cached
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return null
        }
        return try {
            val uri = ContentUris.withAppendedId(
                MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL), id
            )
            val bitmap = safeContext.contentResolver.loadThumbnail(uri, Size(512, 512), null)
            val stream = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, 85, stream)
            val bytes = stream.toByteArray()
            trashedThumbnailCache.put(id, bytes)
            bytes
        } catch (e: Exception) {
            android.util.Log.e("AndroidMediaManager", "Error loading trashed thumbnail for $id: ${e.message}")
            null
        }
    }

    private fun cropAndResizeFace(
        path: String,
        x: Int,
        y: Int,
        w: Int,
        h: Int,
        padding: Double,
        result: MethodChannel.Result
    ) {
        try {
            val file = java.io.File(path)
            if (!file.exists()) {
                result.error("FILE_NOT_FOUND", "File does not exist: $path", null)
                return
            }

            val options = BitmapFactory.Options().apply {
                inJustDecodeBounds = true
            }
            BitmapFactory.decodeFile(path, options)
            val imgWidth = options.outWidth
            val imgHeight = options.outHeight

            if (imgWidth <= 0 || imgHeight <= 0) {
                result.error("INVALID_IMAGE", "Could not read image dimensions", null)
                return
            }

            val padX = (w * padding).toInt()
            val padY = (h * padding).toInt()

            val cropLeft = (x - padX).coerceIn(0, imgWidth - 1)
            val cropTop = (y - padY).coerceIn(0, imgHeight - 1)
            val cropRight = (x + w + padX).coerceIn(1, imgWidth)
            val cropBottom = (y + h + padY).coerceIn(1, imgHeight)
            
            val cropWidth = cropRight - cropLeft
            val cropHeight = cropBottom - cropTop

            if (cropWidth <= 0 || cropHeight <= 0) {
                result.error("INVALID_CROP", "Crop width or height is zero or negative", null)
                return
            }

            val decoder = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
                BitmapRegionDecoder.newInstance(path)
            } else {
                @Suppress("DEPRECATION")
                BitmapRegionDecoder.newInstance(path, false)
            }

            if (decoder == null) {
                result.error("DECODER_FAILED", "Failed to create BitmapRegionDecoder", null)
                return
            }

            val rect = Rect(cropLeft, cropTop, cropRight, cropBottom)
            val rectOpts = BitmapFactory.Options().apply {
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
            
            var croppedBitmap = decoder.decodeRegion(rect, rectOpts)
            decoder.recycle()

            if (croppedBitmap == null) {
                result.error("CROP_FAILED", "Failed to decode region", null)
                return
            }

            try {
                val exif = ExifInterface(path)
                val orientation = exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
                val matrix = android.graphics.Matrix()
                var needsRotate = true
                when (orientation) {
                    ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
                    ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
                    ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
                    else -> needsRotate = false
                }
                if (needsRotate) {
                    val rotated = Bitmap.createBitmap(croppedBitmap, 0, 0, croppedBitmap.width, croppedBitmap.height, matrix, true)
                    if (rotated != croppedBitmap) {
                        croppedBitmap.recycle()
                        croppedBitmap = rotated
                    }
                }
            } catch (e: Exception) {}

            val resized = Bitmap.createScaledBitmap(croppedBitmap, 112, 112, true)
            if (resized != croppedBitmap) {
                croppedBitmap.recycle()
            }

            val rgbBytes = ByteArray(112 * 112 * 3)
            val pixels = IntArray(112 * 112)
            resized.getPixels(pixels, 0, 112, 0, 0, 112, 112)
            resized.recycle()

            var index = 0
            for (pixel in pixels) {
                val r = (pixel shr 16) and 0xFF
                val g = (pixel shr 8) and 0xFF
                val b = pixel and 0xFF
                rgbBytes[index++] = r.toByte()
                rgbBytes[index++] = g.toByte()
                rgbBytes[index++] = b.toByte()
            }

            result.success(rgbBytes)
        } catch (e: Exception) {
            result.error("ERROR", e.localizedMessage ?: "Unknown crop error", null)
        }
    }

    private fun getMediaIdFromUri(uri: Uri): String? {
        return try {
            ContentUris.parseId(uri).toString()
        } catch (e: Exception) {
            uri.lastPathSegment
        }
    }

    private fun registerMediaObserver() {
        val safeContext = context ?: return
        if (mediaObserver != null) return
        
        val handler = Handler(Looper.getMainLooper())
        mediaObserver = object : ContentObserver(handler) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                super.onChange(selfChange, uri)
                runOnMainThread {
                    channel?.invokeMethod("onMediaStoreChanged", null)
                }
            }
        }
        
        try {
            safeContext.contentResolver.registerContentObserver(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                true,
                mediaObserver!!
            )
            safeContext.contentResolver.registerContentObserver(
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                true,
                mediaObserver!!
            )
            android.util.Log.d("AndroidMediaManager", "Registered MediaStore ContentObservers successfully.")
        } catch (e: Exception) {
            android.util.Log.e("AndroidMediaManager", "Failed to register content observer", e)
        }
    }

    private fun unregisterMediaObserver() {
        val safeContext = context ?: return
        mediaObserver?.let {
            safeContext.contentResolver.unregisterContentObserver(it)
            mediaObserver = null
            android.util.Log.d("AndroidMediaManager", "Unregistered MediaStore ContentObservers.")
        }
    }
}
