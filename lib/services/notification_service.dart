import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const String _channelId = 'fleet_track_channel';
  static const String _channelName = 'Fleet Track Alerts';
  static const int _punchRemId = 1001;
  static const int _locationId = 1002;

  // ── INIT ──────────────────────────────────────────────────────────────────
  static Future<void> init() async {
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Kolkata'));

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      settings: const InitializationSettings(android: android),
      onDidReceiveNotificationResponse: _onTap,
    );

    // Create notification channel
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: 'Fleet Track work reminders',
            importance: Importance.high,
            playSound: true,
            enableVibration: true,
          ),
        );

    // ✅ Request notification permission (Android 13+)
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    // ✅ Request exact alarm permission (Android 12+)
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestExactAlarmsPermission();
  }

  static void _onTap(NotificationResponse response) {}

  // ── SCHEDULE DAILY 10 AM REMINDER ────────────────────────────────────────
  static Future<void> scheduleDailyPunchReminder() async {
    await _plugin.cancel(id: _punchRemId);

    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Daily 10 AM punch IN reminder',
      importance: Importance.high,
      priority: Priority.high,
      autoCancel: true,
      fullScreenIntent: true, // ✅ shows even on locked screen
      actions: [
        AndroidNotificationAction(
          'punch_in',
          '▶ Punch IN for Work',
          showsUserInterface: true,
          cancelNotification: true,
        ),
        AndroidNotificationAction(
          'apply_leave',
          '🏖 Apply Leave',
          showsUserInterface: true,
          cancelNotification: true,
        ),
      ],
    );

    await _plugin.zonedSchedule(
      id: _punchRemId,
      title: '⏰ Time to Punch IN!',
      body: 'It\'s 10:00 AM — Punch IN for work or Apply Leave.',
      scheduledDate: _next10AM(),
      notificationDetails: const NotificationDetails(android: androidDetails),
      matchDateTimeComponents: DateTimeComponents.time, // repeat daily
      // ✅ alarmClock works on ALL Android versions including 13/14
      androidScheduleMode: AndroidScheduleMode.alarmClock,
    );

    print('✅ Notification scheduled for: ${_next10AM()}');
  }

  // ── CANCEL TODAY ONLY (reschedules tomorrow automatically) ───────────────
  static Future<void> cancelTodayReminderOnly() async =>
      _plugin.cancel(id: _punchRemId);

  // ── CANCEL PERMANENTLY (on logout) ───────────────────────────────────────
  static Future<void> cancelPunchReminder() async =>
      _plugin.cancel(id: _punchRemId);

  // ── LOCATION WARNING ──────────────────────────────────────────────────────
  static Future<void> showLocationOffWarning() async {
    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'GPS warning',
      importance: Importance.high,
      priority: Priority.high,
      ongoing: true,
      autoCancel: false,
    );
    await _plugin.show(
      id: _locationId,
      title: '📍 Location Turned OFF',
      body: 'Please turn on GPS to continue tracking.',
      notificationDetails: const NotificationDetails(android: androidDetails),
    );
  }

  static Future<void> cancelLocationWarning() async =>
      _plugin.cancel(id: _locationId);

  // ── LAUNCH ACTION ─────────────────────────────────────────────────────────
  static Future<String?> getLaunchAction() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    return details?.notificationResponse?.actionId;
  }

  // ── NEXT 10 AM (or 2 min for testing) ────────────────────────────────────
  static tz.TZDateTime _next10AM() {
    final now = tz.TZDateTime.now(tz.local);
    var scheduled =
        tz.TZDateTime(tz.local, now.year, now.month, now.day, 10, 0, 0);
    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }
}
