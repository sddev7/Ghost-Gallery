#
# Generated file, do not edit.
#

list(APPEND FLUTTER_PLUGIN_LIST
  awesome_notifications
  ffmpeg_kit_flutter_new
  file_selector_windows
  flutter_tts
  geolocator_windows
  local_auth_windows
  objectbox_flutter_libs
  printing
  pro_video_editor
  share_plus
  url_launcher_windows
)

list(APPEND FLUTTER_FFI_PLUGIN_LIST
  jni
  tflite_flutter
)

set(PLUGIN_BUNDLED_LIBRARIES)

foreach(plugin ${FLUTTER_PLUGIN_LIST})
  add_subdirectory(flutter/ephemeral/.plugin_symlinks/${plugin}/windows plugins/${plugin})
  target_link_libraries(${BINARY_NAME} PRIVATE ${plugin}_plugin)
  list(APPEND PLUGIN_BUNDLED_LIBRARIES $<TARGET_FILE:${plugin}_plugin>)
  list(APPEND PLUGIN_BUNDLED_LIBRARIES ${${plugin}_bundled_libraries})
endforeach(plugin)

foreach(ffi_plugin ${FLUTTER_FFI_PLUGIN_LIST})
  add_subdirectory(flutter/ephemeral/.plugin_symlinks/${ffi_plugin}/windows plugins/${ffi_plugin})
  list(APPEND PLUGIN_BUNDLED_LIBRARIES ${${ffi_plugin}_bundled_libraries})
endforeach(ffi_plugin)
