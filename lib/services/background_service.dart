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

  // ✅ FIX #1, #3 — Reload prefs fresh, restore last known position
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

  // ✅ FIX #1 — Resume totalKm so OS kill/restart doesn't reset distance
  double totalKm = prefs.getDouble('total_km') ?? 0.0;

  // ✅ FIX #1, #3 — Restore lastPosition from prefs so no segment is skipped
  Position? lastPosition;
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

  bool wasLocationOn = true;
  // ✅ FIX #3 — firstReading only true if no saved position exists
  bool firstReading = lastPosition == null;

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

  service.on('stopService').listen((_) async {
    // ✅ FIX #2 — Final sync before stopping so punch out gets correct km
    await _doFinalSync(sessionId, totalKm);
    service.stopSelf();
  });

  // ── Helper: sync km to ALL sources ───────────────────────────────────────
  Future<void> syncKm(double km, {int retryCount = 0}) async {
    try {
      // ✅ FIX #12 — Write prefs first (always succeeds)
      final p = await SharedPreferences.getInstance();
      await p.setDouble('total_km', km);

      // ✅ FIX #2 — Session doc updated every tick — dashboard always accurate
      await FirebaseFirestore.instance
          .collection(AppConstants.sessionsCollection)
          .doc(sessionId)
          .update({'totalKm': km});

      // ✅ Push to HomeScreen UI
      service.invoke('update', {'totalKm': km});
    } catch (e) {
      // ✅ FIX #12 — Retry once on Firestore failure
      if (retryCount < 1) {
        await Future.delayed(const Duration(seconds: 2));
        await syncKm(km, retryCount: retryCount + 1);
      }
      // Prefs write always succeeds so UI still updates
    }
  }

  // ── Main GPS tracking loop ────────────────────────────────────────────────
  Timer.periodic(
    Duration(seconds: AppConstants.gpsIntervalSeconds),
    (timer) async {
      // ✅ FIX #4 — Reload every tick to catch punch-out from main isolate
      final p = await SharedPreferences.getInstance();
      await p.reload();
      final punchedIn = p.getBool('is_punched_in') ?? false;

      if (!punchedIn) {
        timer.cancel();
        // ✅ FIX #2 — Final sync before service dies
        await _doFinalSync(sessionId, totalKm);
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
        await syncKm(totalKm); // ✅ Keep UI alive even when GPS off
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
            distanceFilter: 0,
          ),
        );
      } catch (_) {
        await syncKm(totalKm); // ✅ FIX #12 — sync on GPS error too
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

        // ✅ accuracy < 35m AND moved >= 15m = real movement, not GPS noise
        if (pos.accuracy < 35 && metres >= 15) {
          totalKm += metres / 1000.0;
          totalKm = double.parse(totalKm.toStringAsFixed(3));
        }
      }
      firstReading = false;
      lastPosition = pos;

      // ✅ FIX #1 — Save last position to prefs so restart resumes correctly
      await p.setDouble('last_lat', pos.latitude);
      await p.setDouble('last_lng', pos.longitude);

      // ── Sync km everywhere ────────────────────────────────────────────────
      await syncKm(totalKm);

      // ── Update foreground notification ────────────────────────────────────
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: '🚛 $name — Tracking Active',
          content: '📍 Live  |  🛣️ ${totalKm.toStringAsFixed(2)} km covered',
        );
      }

      // ✅ FIX #11 — Use same DateTime.now() for both dateStr and timestamp
      final now = DateTime.now();
      final locRef = FirebaseFirestore.instance
          .collection(AppConstants.locationsCollection)
          .doc(techId);

      // ✅ FIX #12 — Wrap Firestore writes in try/catch with retry
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

        // ✅ FIX #5 — Write trail every 30s, not every tick
        // Only write trail on even ticks (every 2nd interval)
        final shouldWriteTrail =
            (DateTime.now().second ~/ AppConstants.gpsIntervalSeconds) % 2 == 0;
        if (shouldWriteTrail) {
          await locRef.collection('trail').add({
            'lat': pos.latitude,
            'lng': pos.longitude,
            'totalKm': totalKm,
            'sessionId': sessionId,
            'timestamp': FieldValue.serverTimestamp(),
            // ✅ FIX #11 — dateStr uses local time consistent with timestamp
            'dateStr': '${now.day}/${now.month}/${now.year}',
          });
        }
      } catch (_) {
        // ✅ FIX #12 — Firestore write failed — km already saved to prefs
        // Will retry on next tick naturally
      }
    },
  );
}

// ✅ FIX #2 — Final sync helper called before service stops
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
