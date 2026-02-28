class AppConstants {
  // Firestore collections
  static const String techniciansCollection = 'technicians';
  static const String locationsCollection = 'locations';
  static const String sessionsCollection = 'sessions';

  // Franchise list — add your 3 franchises here
  static const List<String> franchises = [
    'MFBS',
    'Krisma Tech',
    'PromptCare',
  ];

  // Work start hour and minute
  static const int punchInHour = 9;
  static const int punchInMinute = 30;

  // GPS update interval in seconds
  static const int gpsIntervalSeconds = 15;

  // Notification IDs
  static const int punchInNotifId = 1001;
  static const int locationOffNotifId = 1002;

  // Notification channel
  static const String locationChannelId = 'fleet_location_channel';
  static const String locationChannelName = 'Location Tracking';
}
