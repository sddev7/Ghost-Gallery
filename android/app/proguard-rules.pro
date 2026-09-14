# ============================================================
# Ghost Gallery — proguard-rules.pro
# Covers every native / reflection-based dependency in pubspec.yaml
# Place at: android/app/proguard-rules.pro
# ============================================================

# ---------- General pigeon-codegen safety net ----------
# shared_preferences crashed because its pigeon-generated channel classes got
# stripped. Several other plugins here (geocoding, geolocator, local_auth,
# image_picker, video_player, camera) use the same dev.flutter.pigeon.*
# codegen pattern and are equally exposed — keep all of them broadly.
-keep class dev.flutter.pigeon.** { *; }
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keepclassmembers class dev.flutter.pigeon.** { *; }
-dontwarn dev.flutter.pigeon.**

# ---------- Flutter (baseline, keep always) ----------
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }
-dontwarn io.flutter.embedding.**

# ---------- google_mlkit_text_recognition ----------
-keep class com.google.mlkit.vision.text.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text_common.** { *; }
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# ---------- google_mlkit_face_detection ----------
-keep class com.google.mlkit.vision.face.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_face.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_face_bundled.** { *; }
-dontwarn com.google.mlkit.vision.face.**

# ---------- google_mlkit_image_labeling ----------
-keep class com.google.mlkit.vision.label.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_image_label.** { *; }
-dontwarn com.google.mlkit.vision.label.**

# ---------- MLKit common / vision-common (shared by all three above) ----------
-keep class com.google.mlkit.common.** { *; }
-keep class com.google.mlkit.vision.common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-dontwarn com.google.mlkit.common.**

# ---------- tflite_flutter / TensorFlow Lite ----------
-keep class org.tensorflow.lite.** { *; }
-keep class org.tensorflow.lite.gpu.** { *; }
-keep class org.tensorflow.lite.support.** { *; }
-dontwarn org.tensorflow.lite.**

# ---------- mediapipe_core / mediapipe_text ----------
# NOTE: these packages require the native-assets experiment + Flutter master
# channel to function at all. If you're on the stable channel, these are very
# likely the actual blank-screen cause and not a proguard issue — see chat.
-keep class com.google.mediapipe.** { *; }
-keep class com.google.mediapipe.framework.** { *; }
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.mediapipe.**
-dontwarn com.google.protobuf.**


# ---------- image_picker / camera ----------
-keep class io.flutter.plugins.imagepicker.** { *; }
-keep class io.flutter.plugins.camera.** { *; }

# ---------- sqflite ----------
-keep class com.tekartik.sqflite.** { *; }

# ---------- shared_preferences (pigeon-generated — confirmed crash source) ----------
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep class dev.flutter.pigeon.shared_preferences_android.** { *; }
-keepclassmembers class dev.flutter.pigeon.shared_preferences_android.** { *; }
-dontwarn io.flutter.plugins.sharedpreferences.**

# ---------- exif ----------
-keep class com.github.haibison.exiv2.** { *; }
-dontwarn com.github.haibison.exiv2.**

# ---------- geocoding / geolocator ----------
-keep class com.baseflow.geocoding.** { *; }
-keep class com.baseflow.geolocator.** { *; }
-keep class com.google.android.gms.location.** { *; }
-dontwarn com.baseflow.**

# ---------- workmanager ----------
-keep class androidx.work.** { *; }
-keep class be.tramckrijte.workmanager.** { *; }
-dontwarn androidx.work.**

# ---------- awesome_notifications ----------
-keep class me.carda.awesome_notifications.** { *; }
-dontwarn me.carda.awesome_notifications.**

# ---------- pro_image_editor / pro_video_editor ----------
-keep class com.cuachpro.** { *; }
-dontwarn com.cuachpro.**

# ---------- pdf / printing ----------
-keep class net.nfet.flutter.printing.** { *; }
-dontwarn net.nfet.flutter.printing.**

# ---------- flutter_tts ----------
-keep class com.tundralabs.fluttertts.** { *; }
-dontwarn com.tundralabs.fluttertts.**

# ---------- flutter_map / latlong2 (pure-Dart — minimal native surface, safe net) ----------
-dontwarn org.osmdroid.**

# ---------- flutter_media_delete ----------
-keep class com.example.flutter_media_delete.** { *; }
-dontwarn com.example.flutter_media_delete.**

# ---------- async_wallpaper ----------
-keep class com.bharat.asyncwallpaper.** { *; }
-dontwarn com.bharat.asyncwallpaper.**

# ---------- wakelock_plus ----------
-keep class dev.fluttercommunity.plus.wakelock.** { *; }

# ---------- local_auth ----------
-keep class io.flutter.plugins.localauth.** { *; }
-keep class androidx.biometric.** { *; }
-dontwarn androidx.biometric.**

# ---------- encrypt (pointycastle, pure Dart — usually no native surface) ----------
-dontwarn org.pointycastle.**

# ---------- ffmpeg_kit_flutter_new (Fixed Package Namespace) ----------
# Keep the original namespace if any legacy fallback modules use it
-keep class com.arthenica.ffmpegkit.** { *; }
-keep class com.arthenica.smartexception.** { *; }
-dontwarn com.arthenica.ffmpegkit.**

# Keep the active community fork package namespace from your Logcat
-keep class com.antonkarpenko.ffmpegkit.** { *; }
-keepclassmembers class com.antonkarpenko.ffmpegkit.** { *; }
-dontwarn com.antonkarpenko.ffmpegkit.**

# Broad safety net to preserve every JNI method map across your plugins
-keepclasseswithmembernames class * {
    native <methods>;
}


# ---------- receive_sharing_intent ----------
-keep class com.kasem.receivesharingintent.** { *; }
-dontwarn com.kasem.receivesharingintent.**

# ---------- video_player / video_thumbnail ----------
-keep class io.flutter.plugins.videoplayer.** { *; }
-keep class com.justsoft.videothumbnail.** { *; }

# ---------- General Android / Kotlin reflection safety net ----------
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keepattributes InnerClasses
-keep class kotlin.** { *; }
-keep class kotlin.Metadata { *; }
-dontwarn kotlin.**

# ---------- Gson / Moshi / JSON reflection (used internally by several plugins) ----------
-keepclassmembers,allowobfuscation class * {
  @com.google.gson.annotations.SerializedName <fields>;
}
-keep class com.google.gson.** { *; }
-dontwarn com.google.gson.**

# ---------- Suppress warnings on optional Play Core split-install classes ----------
-dontwarn com.google.android.play.core.**

