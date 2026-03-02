import 'dart:async';
import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_service.dart';
import '../utils/constants.dart';

// ── Work hours ────────────────────────────────────────────────────────────────
const int kWorkStartHour = 9; // 9:00 AM
const int kWorkStartMinute = 0;
const int kWorkEndHour = 18; // 6:30 PM
const int kWorkEndMinute = 30;

bool _isWorkHours() {
  final now = DateTime.now();
  final start =
      now.copyWith(hour: kWorkStartHour, minute: kWorkStartMinute, second: 0);
  final end =
      now.copyWith(hour: kWorkEndHour, minute: kWorkEndMinute, second: 0);
  return now.isAfter(start) && now.isBefore(end);
}

// Minutes until next work start (for scheduling)
Duration _durationUntilWorkStart() {
  final now = DateTime.now();
  var start = now.copyWith(
      hour: kWorkStartHour,
      minute: kWorkStartMinute,
      second: 0,
      millisecond: 0);
  if (now.isAfter(start)) {
    start = start.add(const Duration(days: 1)); // tomorrow
  }
  return start.difference(now);
}

Future<void> initBackgroundService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onServiceStart,
      isForegroundMode: true,
      autoStart: true, // ✅ Start on boot/install
      notificationChannelId: AppConstants.locationChannelId,
      initialNotificationTitle: '🚛 Fleet Track',
      initialNotificationContent: 'Monitoring active...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onServiceStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async => true;

@pragma('vm:entry-point')
void onServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();

  final techId = prefs.getString('tech_id') ?? '';
  final franchise = prefs.getString('franchise') ?? '';
  final name = prefs.getString('name') ?? '';

  if (techId.isEmpty) {
    // Not logged in yet — check every 30s until login
    Timer.periodic(const Duration(seconds: 30), (t) async {
      final p = await SharedPreferences.getInstance();
      await p.reload();
      if ((p.getString('tech_id') ?? '').isNotEmpty) {
        t.cancel();
        onServiceStart(service); // restart with credentials
      }
    });
    return;
  }

  // ── Silent notification channel ───────────────────────────────────────────
  final FlutterLocalNotificationsPlugin localPlugin =
      FlutterLocalNotificationsPlugin();
  await localPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(
        const AndroidNotificationChannel(
          AppConstants.locationChannelId,
          'Fleet Track GPS',
          description: 'Work hours location monitoring',
          importance: Importance.low,
          playSound: false,
          enableVibration: false,
          showBadge: false,
        ),
      );

  service.on('stopService').listen((_) => service.stopSelf());

  // ── State ─────────────────────────────────────────────────────────────────
  double totalKm = 0.0;
  Position? lastPosition;
  bool wasTracking = false;
  String todayStr = ''; // tracks day rollover
  String sessionId = '';

  // ── Restore last position if service restarted ────────────────────────────
  final savedLat = prefs.getDouble('last_lat');
  final savedLng = prefs.getDouble('last_lng');
  if (savedLat != null && savedLng != null) {
    lastPosition = Position(
      latitude: savedLat,
      longitude: savedLng,
      timestamp: DateTime.now(),
      accuracy: 0,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );
  }

  // ── Helper: get location with GPS→WiFi→Cell fallback ─────────────────────
  Future<Position?> getPosition() async {
    // Try GPS first
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
          forceLocationManager: false,
        ),
      ).timeout(const Duration(seconds: 8));
    } catch (_) {}

    // Fallback: WiFi + Cell
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.medium,
          distanceFilter: 0,
          forceLocationManager: true,
        ),
      ).timeout(const Duration(seconds: 6));
    } catch (_) {}

    // Fallback: Cell only
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.low,
          distanceFilter: 0,
          forceLocationManager: true,
        ),
      ).timeout(const Duration(seconds: 5));
    } catch (_) {}

    // Last known
    return await Geolocator.getLastKnownPosition();
  }

  // ── Helper: start new day session ────────────────────────────────────────
  Future<void> startDaySession() async {
    final now = DateTime.now();
    todayStr = '${now.day}/${now.month}/${now.year}';
    sessionId = 'auto_${techId}_${now.millisecondsSinceEpoch}';
    totalKm = 0.0;
    lastPosition = null;

    final p = await SharedPreferences.getInstance();
    await p.setDouble('total_km', 0.0);
    await p.setString('session_id', sessionId);
    await p.remove('last_lat');
    await p.remove('last_lng');
    await p.setBool('is_punched_in', true); // ✅ Mark active for dashboard

    // Create session doc
    await FirebaseFirestore.instance
        .collection(AppConstants.sessionsCollection)
        .doc(sessionId)
        .set({
      'techId': techId,
      'name': name,
      'franchise': franchise,
      'punchIn': FieldValue.serverTimestamp(),
      'punchOut': null,
      'totalKm': 0.0,
      'status': 'active',
      'autoTracked': true,
    });

    // Update location doc status
    await FirebaseFirestore.instance
        .collection(AppConstants.locationsCollection)
        .doc(techId)
        .set({
      'status': 'active',
      'name': name,
      'franchise': franchise,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    wasTracking = true;
  }

  // ── Helper: end day session ───────────────────────────────────────────────
  Future<void> endDaySession() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('is_punched_in', false);
    await p.setDouble('total_km', totalKm);

    if (sessionId.isNotEmpty) {
      await FirebaseFirestore.instance
          .collection(AppConstants.sessionsCollection)
          .doc(sessionId)
          .update({
        'punchOut': FieldValue.serverTimestamp(),
        'totalKm': totalKm,
        'status': 'completed',
      });
    }

    await FirebaseFirestore.instance
        .collection(AppConstants.locationsCollection)
        .doc(techId)
        .set({'status': 'offline'}, SetOptions(merge: true));

    wasTracking = false;
    lastPosition = null;
    await p.remove('last_lat');
    await p.remove('last_lng');
  }

  // ── Helper: sync km ───────────────────────────────────────────────────────
  Future<void> syncKm(double km) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setDouble('total_km', km);
      if (sessionId.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection(AppConstants.sessionsCollection)
            .doc(sessionId)
            .update({'totalKm': km});
      }
      service.invoke('update', {'totalKm': km});
    } catch (_) {}
  }

  // ── Main loop — runs every 15 seconds always ──────────────────────────────
  Timer.periodic(const Duration(seconds: 15), (timer) async {
    final p = await SharedPreferences.getInstance();
    await p.reload();

    final now = DateTime.now();
    final isWork = _isWorkHours();
    final currentDay = '${now.day}/${now.month}/${now.year}';

    // ── Day rollover: new session at midnight if still in work hours ─────────
    if (wasTracking && currentDay != todayStr) {
      await endDaySession();
    }

    // ── Work hours started ────────────────────────────────────────────────────
    if (isWork && !wasTracking) {
      await startDaySession();
    }

    // ── Work hours ended ──────────────────────────────────────────────────────
    if (!isWork && wasTracking) {
      await endDaySession();

      // Update notification — off hours
      if (service is AndroidServiceInstance) {
        final until = _durationUntilWorkStart();
        final h = until.inHours;
        final m = until.inMinutes % 60;
        service.setForegroundNotificationInfo(
          title: '🚛 Fleet Track — Off Hours',
          content: 'Tracking resumes in ${h}h ${m}m',
        );
      }
      return;
    }

    // ── Not work hours — just wait ────────────────────────────────────────────
    if (!isWork) {
      if (service is AndroidServiceInstance) {
        final until = _durationUntilWorkStart();
        final h = until.inHours;
        final m = until.inMinutes % 60;
        service.setForegroundNotificationInfo(
          title: '🚛 Fleet Track',
          content: 'Tracking starts at 9:00 AM (in ${h}h ${m}m)',
        );
      }
      return;
    }

    // ── WORK HOURS — Track location ───────────────────────────────────────────
    final pos = await getPosition();
    if (pos == null) {
      await syncKm(totalKm);
      return;
    }

    // Distance calculation with accuracy-aware threshold
    if (lastPosition != null) {
      final metres = Geolocator.distanceBetween(
        lastPosition!.latitude,
        lastPosition!.longitude,
        pos.latitude,
        pos.longitude,
      );
      // ✅ Relax threshold based on accuracy source
      final minMove = pos.accuracy < 35 ? 15.0 : 50.0;
      if (pos.accuracy < 150 && metres >= minMove) {
        totalKm += metres / 1000.0;
        totalKm = double.parse(totalKm.toStringAsFixed(3));
      }
    }
    lastPosition = pos;

    // Save last position for restart recovery
    await p.setDouble('last_lat', pos.latitude);
    await p.setDouble('last_lng', pos.longitude);

    // Sync km
    await syncKm(totalKm);

    // Location source label
    String src = pos.accuracy < 35
        ? '📡 GPS'
        : pos.accuracy < 100
            ? '📶 WiFi'
            : '🗼 Cell';

    // Update notification
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: '🚛 $name — Work Hours Active',
        content: '$src  |  🛣️ ${totalKm.toStringAsFixed(2)} km',
      );
    }

    // Write to Firestore location doc
    final locRef = FirebaseFirestore.instance
        .collection(AppConstants.locationsCollection)
        .doc(techId);

    try {
      await locRef.set({
        'lat': pos.latitude,
        'lng': pos.longitude,
        'accuracy': pos.accuracy,
        'speed': pos.speed,
        'totalKm': totalKm,
        'sessionId': sessionId,
        'franchise': franchise,
        'name': name,
        'status': 'active',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // Trail — write every 30s (every 2nd tick)
      final shouldWriteTrail = (now.minute * 60 + now.second) % 30 < 15;
      if (shouldWriteTrail) {
        await locRef.collection('trail').add({
          'lat': pos.latitude,
          'lng': pos.longitude,
          'totalKm': totalKm,
          'sessionId': sessionId,
          'timestamp': FieldValue.serverTimestamp(),
          'dateStr': '${now.day}/${now.month}/${now.year}',
        });
      }
    } catch (_) {}
  });
}

// ── Final sync before stop ────────────────────────────────────────────────────
Future<void> _doFinalSync(String sessionId, double totalKm) async {
  try {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('total_km', totalKm);
    if (sessionId.isNotEmpty) {
      await FirebaseFirestore.instance
          .collection(AppConstants.sessionsCollection)
          .doc(sessionId)
          .update({'totalKm': totalKm});
    }
  } catch (_) {}
}
