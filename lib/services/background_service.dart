import 'dart:async';
import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
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

  final prefs = await SharedPreferences.getInstance();
  final techId = prefs.getString('tech_id') ?? '';
  final franchise = prefs.getString('franchise') ?? '';
  final name = prefs.getString('name') ?? '';
  final sessionId = prefs.getString('session_id') ?? '';

  if (techId.isEmpty) {
    service.stopSelf();
    return;
  }

  // ✅ Silent channel — no popup, no sound
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

  // ✅ Start km from 0 — single source of truth
  double totalKm = 0.0;
  Position? lastPosition;
  bool wasLocationOn = true;
  bool firstReading = true; // skip distance on very first point

  Timer.periodic(
    Duration(seconds: AppConstants.gpsIntervalSeconds),
    (timer) async {
      final p = await SharedPreferences.getInstance();
      final punchedIn = p.getBool('is_punched_in') ?? false;

      if (!punchedIn) {
        timer.cancel();
        service.stopSelf();
        return;
      }

      // GPS ON/OFF
      final locEnabled = await Geolocator.isLocationServiceEnabled();
      if (!locEnabled) {
        if (wasLocationOn) {
          await NotificationService.showLocationOffWarning();
          wasLocationOn = false;
        }
        return;
      }
      if (!wasLocationOn) {
        await NotificationService.cancelLocationWarning();
        wasLocationOn = true;
      }

      // Get position
      Position pos;
      try {
        pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            // ✅ Increased from 5m to 20m — reduces GPS drift noise
            distanceFilter: 20,
          ),
        );
      } catch (_) {
        return;
      }

      // ✅ Only add distance if:
      // - Not the first reading (no jump from 0,0)
      // - Accuracy is good (< 30 metres)
      // - Moved more than 20m (real movement, not GPS wobble)
      if (!firstReading && lastPosition != null) {
        final metres = Geolocator.distanceBetween(
          lastPosition!.latitude,
          lastPosition!.longitude,
          pos.latitude,
          pos.longitude,
        );

        // ✅ Only count if accuracy is acceptable AND distance is real
        if (pos.accuracy < 30 && metres >= 20) {
          totalKm += metres / 1000;
        }
      }
      firstReading = false;
      lastPosition = pos;

      final km = double.parse(totalKm.toStringAsFixed(3));

      // ✅ Save to SharedPreferences — HomeScreen reads from here
      await p.setDouble('total_km', km);

      // Update silent foreground notification
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: '🚛 $name — Tracking Active',
          content: '📍 Live  |  🛣️ ${km.toStringAsFixed(2)} km covered',
        );
      }

      final now = DateTime.now();
      final locRef = FirebaseFirestore.instance
          .collection(AppConstants.locationsCollection)
          .doc(techId);

      await locRef.set({
        'lat': pos.latitude,
        'lng': pos.longitude,
        'accuracy': pos.accuracy,
        'speed': pos.speed,
        'totalKm': km,
        'sessionId': sessionId,
        'franchise': franchise,
        'name': name,
        'status': 'active',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await locRef.collection('trail').add({
        'lat': pos.latitude,
        'lng': pos.longitude,
        'totalKm': km,
        'sessionId': sessionId,
        'timestamp': FieldValue.serverTimestamp(),
        'dateStr': '${now.day}/${now.month}/${now.year}',
      });

      // ✅ Send km update to HomeScreen
      service.invoke('update', {
        'lat': pos.latitude,
        'lng': pos.longitude,
        'totalKm': km,
      });
    },
  );
}
