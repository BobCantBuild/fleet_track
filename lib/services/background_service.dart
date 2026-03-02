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

Future<void> initBackgroundService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onServiceStart,
      isForegroundMode: true,
      autoStart: false,
      notificationChannelId: AppConstants.locationChannelId,
      initialNotificationTitle: '🚛 Fleet Track Active',
      initialNotificationContent: 'GPS tracking running...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
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

  // ✅ Reload prefs fresh — avoid stale isolate cache
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();

  final techId = prefs.getString('tech_id') ?? '';
  final franchise = prefs.getString('franchise') ?? '';
  final name = prefs.getString('name') ?? '';
  final sessionId = prefs.getString('session_id') ?? '';

  if (techId.isEmpty || sessionId.isEmpty) {
    service.stopSelf();
    return;
  }

  // ✅ Resume km if service restarted mid-session (e.g. killed by OS)
  double totalKm = prefs.getDouble('total_km') ?? 0.0;
  Position? lastPosition;
  bool wasLocationOn = true;
  bool firstReading = true;

  // ── Silent notification channel ──────────────────────────────────────────
  final FlutterLocalNotificationsPlugin localPlugin =
      FlutterLocalNotificationsPlugin();
  await localPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(
        const AndroidNotificationChannel(
          AppConstants.locationChannelId,
          'Fleet Track GPS',
          description: 'Live GPS tracking — silent ongoing',
          importance: Importance.low,
          playSound: false,
          enableVibration: false,
          showBadge: false,
        ),
      );

  service.on('stopService').listen((_) => service.stopSelf());

  // ── Helper: sync km to prefs + UI + session doc ──────────────────────────
  Future<void> syncKm(double km) async {
    // ✅ Write to SharedPreferences so HomeScreen prefs.reload() gets it
    final p = await SharedPreferences.getInstance();
    await p.setDouble('total_km', km);

    // ✅ Update session doc so dashboard reads accurate km
    if (sessionId.isNotEmpty) {
      try {
        await FirebaseFirestore.instance
            .collection(AppConstants.sessionsCollection)
            .doc(sessionId)
            .update({'totalKm': km});
      } catch (_) {}
    }

    // ✅ Invoke update to HomeScreen listener
    service.invoke('update', {'totalKm': km});
  }

  // ── Main GPS tracking loop ────────────────────────────────────────────────
  Timer.periodic(
    Duration(seconds: AppConstants.gpsIntervalSeconds),
    (timer) async {
      // ✅ Always reload prefs — catches punch-out from main isolate
      final p = await SharedPreferences.getInstance();
      await p.reload();
      final punchedIn = p.getBool('is_punched_in') ?? false;

      if (!punchedIn) {
        timer.cancel();
        service.stopSelf();
        return;
      }

      // ── GPS on/off check ─────────────────────────────────────────────────
      final locEnabled = await Geolocator.isLocationServiceEnabled();
      if (!locEnabled) {
        if (wasLocationOn) {
          await NotificationService.showLocationOffWarning();
          wasLocationOn = false;
        }
        // Still sync current km so UI doesn't go blank
        await syncKm(totalKm);
        return;
      }
      if (!wasLocationOn) {
        await NotificationService.cancelLocationWarning();
        wasLocationOn = true;
      }

      // ── Get GPS position ──────────────────────────────────────────────────
      Position pos;
      try {
        pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 0, // ✅ 0 = always get position, we filter ourselves
          ),
        );
      } catch (_) {
        await syncKm(totalKm); // sync even on error
        return;
      }

      // ── Distance calculation ──────────────────────────────────────────────
      if (!firstReading && lastPosition != null) {
        final metres = Geolocator.distanceBetween(
          lastPosition!.latitude,
          lastPosition!.longitude,
          pos.latitude,
          pos.longitude,
        );

        // ✅ Accuracy < 35m AND moved >= 15m = real movement
        if (pos.accuracy < 35 && metres >= 15) {
          totalKm += metres / 1000.0;
          totalKm = double.parse(totalKm.toStringAsFixed(3));
        }
      }
      firstReading = false;
      lastPosition = pos;

      // ── Sync km everywhere ────────────────────────────────────────────────
      await syncKm(totalKm);

      // ── Update foreground notification ────────────────────────────────────
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: '🚛 $name — Tracking Active',
          content: '📍 Live  |  🛣️ ${totalKm.toStringAsFixed(2)} km covered',
        );
      }

      // ── Write to Firestore location doc ───────────────────────────────────
      final now = DateTime.now();
      final locRef = FirebaseFirestore.instance
          .collection(AppConstants.locationsCollection)
          .doc(techId);

      try {
        await locRef.set({
          'lat': pos.latitude,
          'lng': pos.longitude,
          'accuracy': pos.accuracy,
          'speed': pos.speed, // m/s — dashboard × 3.6 = km/h
          'totalKm': totalKm,
          'sessionId': sessionId,
          'franchise': franchise,
          'name': name,
          'status': 'active',
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        await locRef.collection('trail').add({
          'lat': pos.latitude,
          'lng': pos.longitude,
          'totalKm': totalKm,
          'sessionId': sessionId,
          'timestamp': FieldValue.serverTimestamp(),
          'dateStr': '${now.day}/${now.month}/${now.year}',
        });
      } catch (_) {}
    },
  );
}
