// ═══════════════════════════════════════════════════════════════════════════
// recommends_notification_service.dart
//
// Schedules birthday reminder notifications using awesome_notifications.
// Also sends "new memory" alerts when the algorithm generates groups.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:io';
import 'dart:ui';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:flutter/foundation.dart';

class RecommendsNotificationService {
  static final RecommendsNotificationService instance =
      RecommendsNotificationService._();
  RecommendsNotificationService._();

  static const _channelKey = 'recommends_channel';
  static const int _birthdayBaseId = 9000; // 9000–9099 reserved for birthdays
  static const int _memoryAlertId = 9100;

  bool get _isSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  // ── Initialize channel (called from SystemNotificationService.initialize) ─

  static Future<void> registerChannel() async {
    if (kIsWeb) return;
    try {
      await AwesomeNotifications().setChannel(
        NotificationChannel(
          channelKey: _channelKey,
          channelName: 'Memories & Recommendations',
          channelDescription:
              'Birthday reminders and new memory highlights',
          defaultColor: const Color(0xFFB388FF),
          ledColor: const Color(0xFFFFFFFF),
          importance: NotificationImportance.High,
          playSound: true,
          enableVibration: true,
        ),
      );
    } catch (e) {
      debugPrint('RecommendsNotificationService: registerChannel error: $e');
    }
  }

  // ── Birthday reminder — 1 day before ────────────────────────────────────

  /// Schedules a notification for the day before [dob] matches this year.
  /// [personId] is used to derive a unique notification id.
  Future<void> scheduleBirthdayReminder({
    required String personId,
    required String personName,
    required DateTime dob, // only month/day used
    String? imagePath,
    String? groupName,
  }) async {
    if (!_isSupported) return;
    try {
      final now = DateTime.now();
      // Compute birthday this year
      var birthdayThisYear = DateTime(now.year, dob.month, dob.day);
      if (birthdayThisYear.isBefore(now)) {
        birthdayThisYear = DateTime(now.year + 1, dob.month, dob.day);
      }
      final reminderDay = birthdayThisYear.subtract(const Duration(days: 1));
      if (reminderDay.isBefore(now)) return; // already past

      final notifId = _birthdayBaseId + personId.hashCode.abs() % 50;

      await AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: notifId,
          channelKey: _channelKey,
          title: "🎂 Tomorrow is $personName's Birthday!",
          body:
              "Don't forget to wish $personName! Ghost Gallery has prepared a special memory for you.",
          notificationLayout: imagePath != null
              ? NotificationLayout.BigPicture
              : NotificationLayout.Default,
          bigPicture: imagePath != null ? 'file://$imagePath' : null,
          summary: groupName,
          wakeUpScreen: false,
        ),
        schedule: NotificationCalendar(
          year: reminderDay.year,
          month: reminderDay.month,
          day: reminderDay.day,
          hour: 9,
          minute: 0,
          second: 0,
          millisecond: 0,
          repeats: false,
        ),
      );
      debugPrint(
          'RecommendsNotificationService: Scheduled birthday reminder for $personName on ${reminderDay.toIso8601String()}');
    } catch (e) {
      debugPrint(
          'RecommendsNotificationService: scheduleBirthdayReminder error: $e');
    }
  }

  // ── Birthday notification — on the day ──────────────────────────────────

  Future<void> scheduleBirthdayOnDay({
    required String personId,
    required String personName,
    required DateTime dob,
    String? imagePath,
    String? groupName,
  }) async {
    if (!_isSupported) return;
    try {
      final now = DateTime.now();
      var birthdayThisYear = DateTime(now.year, dob.month, dob.day);
      if (birthdayThisYear.isBefore(now)) {
        birthdayThisYear = DateTime(now.year + 1, dob.month, dob.day);
      }

      final notifId = _birthdayBaseId + 50 + personId.hashCode.abs() % 50;

      await AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: notifId,
          channelKey: _channelKey,
          title: "🎉 Happy Birthday, $personName!",
          body:
              "Open Ghost Gallery to see a special birthday memory we created just for them!",
          notificationLayout: imagePath != null
              ? NotificationLayout.BigPicture
              : NotificationLayout.Default,
          bigPicture: imagePath != null ? 'file://$imagePath' : null,
          summary: groupName,
          wakeUpScreen: true,
        ),
        schedule: NotificationCalendar(
          year: birthdayThisYear.year,
          month: birthdayThisYear.month,
          day: birthdayThisYear.day,
          hour: 9,
          minute: 0,
          second: 0,
          millisecond: 0,
          repeats: false,
        ),
      );
      debugPrint(
          'RecommendsNotificationService: Scheduled birthday on-day for $personName');
    } catch (e) {
      debugPrint(
          'RecommendsNotificationService: scheduleBirthdayOnDay error: $e');
    }
  }

  // ── New memory alert (immediate) ─────────────────────────────────────────

  Future<void> showNewMemoryAlert({
    required String title,
    required String body,
    String? imagePath,
    String? groupName,
  }) async {
    if (!_isSupported) return;
    try {
      await AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: _memoryAlertId,
          channelKey: _channelKey,
          title: title,
          body: body,
          notificationLayout: imagePath != null
              ? NotificationLayout.BigPicture
              : NotificationLayout.Default,
          bigPicture: imagePath != null ? 'file://$imagePath' : null,
          summary: groupName,
        ),
      );
    } catch (e) {
      debugPrint(
          'RecommendsNotificationService: showNewMemoryAlert error: $e');
    }
  }

  // ── Cancel birthday notifications for a person ───────────────────────────

  Future<void> cancelBirthdayNotifications(String personId) async {
    if (!_isSupported) return;
    try {
      final reminderId = _birthdayBaseId + personId.hashCode.abs() % 50;
      final onDayId = _birthdayBaseId + 50 + personId.hashCode.abs() % 50;
      await AwesomeNotifications().cancel(reminderId);
      await AwesomeNotifications().cancel(onDayId);
    } catch (e) {
      debugPrint(
          'RecommendsNotificationService: cancelBirthdayNotifications error: $e');
    }
  }
}
