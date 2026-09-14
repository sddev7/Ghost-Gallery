import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

class SystemNotificationService {
  static final SystemNotificationService instance =
      SystemNotificationService._init();
  SystemNotificationService._init();

  bool _isInitialized = false;
  static const int progressNotificationId = 8888;

  /// Helper to check if notifications are supported on the current platform.
  bool get _isSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  static const int facesProgressNotificationId = 8888;

  /// Initialize awesome notifications safely and request permissions if needed.
  Future<void> initialize({bool requestPermissions = true}) async {
    if (!_isSupported) return;

    if (!_isInitialized) {
      try {
        await AwesomeNotifications().initialize(
          'resource://drawable/res_app_icon',
          [
            NotificationChannel(
              channelKey: 'ai_processing_channel',
              channelName: 'AI Image Processing',
              channelDescription: 'Shows progress bar for AI image scans',
              defaultColor: const Color(0xFF9D50BB),
              ledColor: const Color(0xFFFFFFFF),
              importance: NotificationImportance.Low,
              playSound: true,
              enableVibration: true,
            ),
            NotificationChannel(
              channelKey: 'faces_processing_channel',
              channelName: 'Face Clustering',
              channelDescription: 'Shows progress bar for AI face clustering',
              defaultColor: const Color(0xFF7B61FF),
              ledColor: const Color(0xFFFFFFFF),
              importance: NotificationImportance.Low,
              playSound: false,
              enableVibration: false,
            ),
            NotificationChannel(
              channelKey: 'recommends_channel',
              channelName: 'Memories & Recommendations',
              channelDescription:
                  'Birthday reminders and new memory highlights',
              defaultColor: const Color(0xFFB388FF),
              ledColor: const Color(0xFFFFFFFF),
              importance: NotificationImportance.High,
              playSound: true,
              enableVibration: true,
            ),
          ],
          debug: false,
        );
        _isInitialized = true;
      } catch (e) {
        debugPrint("SystemNotificationService: Failed to initialize → $e");
      }
    }

    if (requestPermissions) {
      try {
        final bool isAllowed = await AwesomeNotifications()
            .isNotificationAllowed();
        if (!isAllowed) {
          await AwesomeNotifications().requestPermissionToSendNotifications();
        }
      } catch (e) {
        debugPrint("SystemNotificationService: Failed to request notification permission → $e");
      }
    }
  }

  Future<void> ensureInitialized() => initialize(requestPermissions: false);

  Future<void> showProgressNotification(
    int done,
    int total, {
    int? remainingLeft,
  }) async {
    if (!_isSupported) return;
    if (!_isInitialized) await initialize(requestPermissions: false);
    if (!_isInitialized) return;

    try {
      final double percent = total > 0 ? (done / total * 100) : 0;
      final String remainingStr = remainingLeft != null
          ? " ($remainingLeft left to process)"
          : "";
      final String title = 'AI is indexing media files.';
      final String body = '$done of $total completed$remainingStr';


      
      await AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: progressNotificationId,
          channelKey: 'ai_processing_channel',
          title: title,
          body: body,
          notificationLayout: NotificationLayout.ProgressBar,
          progress: percent.toDouble(),
          locked: true,
        ),
      );
    } catch (e) {
      debugPrint("SystemNotificationService: Error showing progress → $e");
    }
  }

  Future<void> showFacesProgressNotification(
    int done,
    int total, {
    int? remainingLeft,
  }) async {
    if (!_isSupported) return;
    if (!_isInitialized) await initialize(requestPermissions: false);
    if (!_isInitialized) return;

    try {
      final double percent = total > 0 ? (done / total * 100) : 0;
      final String remainingStr = remainingLeft != null
          ? " ($remainingLeft left to cluster)"
          : "";
      final String title = 'AI is clustering faces.';
      final String body = '$done of $total completed$remainingStr';


      
      await AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: facesProgressNotificationId,
          channelKey: 'faces_processing_channel',
          title: title,
          body: body,
          notificationLayout: NotificationLayout.ProgressBar,
          progress: percent.toDouble(),
          locked: true,
        ),
      );
    } catch (e) {
      debugPrint("SystemNotificationService: Error showing faces progress → $e");
    }
  }

  Future<void> showIndexingNotification() async {
    if (!_isSupported) return;
    if (!_isInitialized) await initialize(requestPermissions: false);
    if (!_isInitialized) return;

    try {
      final String title = 'Scanning for new media.';
      final String body = 'Scanning your device for new photos & videos... 👻';


      
      await AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: progressNotificationId,
          channelKey: 'ai_processing_channel',
          title: title,
          body: body,
          notificationLayout: NotificationLayout.ProgressBar,
          progress: null,
          locked: true,
        ),
      );
    } catch (e) {
      debugPrint(
        "SystemNotificationService: Error showing indexing notification → $e",
      );
    }
  }

  /// Publishes a separate finish notification.
  Future<void> showFinishNotification() async {
    if (!_isSupported) return;
    if (!_isInitialized) await initialize(requestPermissions: false);
    if (!_isInitialized) return;

    try {
      await AwesomeNotifications().createNotification(
        content: NotificationContent(
          id:
              progressNotificationId +
              1, // Separate ID so it is not dismissed by cancel(8888)
          channelKey: 'ai_processing_channel',
          title: 'AI Finished Indexing',
          body: 'All media has been successfully analyzed and indexed! 👻',
          notificationLayout: NotificationLayout.Default,
        ),
      );
      
    } catch (e) {
      debugPrint(
        "SystemNotificationService: Error showing finish notification → $e",
      );
    }
  }

  /// Publishes a separate finish notification for faces.
  Future<void> showFacesFinishNotification() async {
    if (!_isSupported) return;
    if (!_isInitialized) await initialize(requestPermissions: false);
    if (!_isInitialized) return;

    try {
      await AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: facesProgressNotificationId + 1,
          channelKey: 'faces_processing_channel',
          title: 'AI Finished Face Clustering',
          body: 'All faces have been successfully analyzed and grouped! 👻',
          notificationLayout: NotificationLayout.Default,
        ),
      );
    } catch (e) {
      debugPrint(
        "SystemNotificationService: Error showing faces finish notification → $e",
      );
    }
  }

  /// Cancels the progress notification from the system tray.
  Future<void> dismissNotification() async {
    if (!_isSupported) return;
    if (!_isInitialized) await initialize(requestPermissions: false);
    if (!_isInitialized) return;

    try {
      // Small initial delay to allow any pending progress notifications to finish rendering
      await Future.delayed(const Duration(milliseconds: 200));
      await AwesomeNotifications().cancel(progressNotificationId);
      // Double check cancel after a brief pause to handle any late incoming updates
      await Future.delayed(const Duration(milliseconds: 500));
      await AwesomeNotifications().cancel(progressNotificationId);
    } catch (e) {
      debugPrint(
        "SystemNotificationService: Error dismissing notification → $e",
      );
    }
  }

  /// Cancels the faces progress notification from the system tray.
  Future<void> dismissFacesNotification() async {
    if (!_isSupported) return;
    // Always attempt init — the background isolate may never have initialized.
    await initialize(requestPermissions: false);

    try {
      // Small initial delay to allow any pending progress notifications to finish rendering
      await Future.delayed(const Duration(milliseconds: 200));
      await AwesomeNotifications().cancel(facesProgressNotificationId);
      // Double check cancel after a brief pause to handle any late incoming updates
      await Future.delayed(const Duration(milliseconds: 500));
      await AwesomeNotifications().cancel(facesProgressNotificationId);
    } catch (e) {
      debugPrint(
        "SystemNotificationService: Error dismissing faces notification → $e",
      );
    }
  }
}
