import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../utils/constants.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    // ANDROID ONLY
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initSettings = InitializationSettings(
      android: androidSettings,
    );

    // NEW API: requires the named parameter `settings`
    await _plugin.initialize(
      settings: initSettings,
      // Keep callback empty for now to avoid extra type issues
      // onDidReceiveNotificationResponse: (NotificationResponse response) {},
    );

    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    if (androidPlugin != null) {
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          AppConstants.locationChannelId,
          AppConstants.locationChannelName,
          description: 'Location tracking and work time alerts',
          importance: Importance.high,
        ),
      );
    }
  }

  static Future<void> showPunchInReminder() async {
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      AppConstants.locationChannelId,
      AppConstants.locationChannelName,
      channelDescription: 'Work start reminder',
      importance: Importance.high,
      priority: Priority.high,
      ongoing: false,
    );

    const NotificationDetails details =
        NotificationDetails(android: androidDetails);

    await _plugin.show(
      id: AppConstants.punchInNotifId,
      title: '⏰ Working Hours Started',
      body: 'It\'s 9:30 AM — Please Punch IN and enable location tracking.',
      notificationDetails: details,
    );
  }

  static Future<void> showLocationOffWarning() async {
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      AppConstants.locationChannelId,
      AppConstants.locationChannelName,
      channelDescription: 'Location turned off warning',
      importance: Importance.high,
      priority: Priority.high,
      ongoing: true,
    );

    const NotificationDetails details =
        NotificationDetails(android: androidDetails);

    await _plugin.show(
      id: AppConstants.locationOffNotifId,
      title: '📍 Location Turned Off',
      body: 'Please re-enable location tracking or Punch OUT if you\'re done.',
      notificationDetails: details,
    );
  }

  static Future<void> cancelLocationWarning() async {
    await _plugin.cancel(
      id: AppConstants.locationOffNotifId,
    );
  }
}
