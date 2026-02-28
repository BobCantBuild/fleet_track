import 'dart:async';
import 'dart:ui';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service/flutter_background_service.dart'
    show AndroidConfiguration, IosConfiguration;
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_service.dart';
import '../utils/constants.dart';

// ─── Called once at app start ───────────────────────────────────────────────
Future<void> initBackgroundService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onServiceStart,
      autoStart: false, // only starts after Punch IN
      isForegroundMode: true,
      notificationChannelId: AppConstants.locationChannelId,
      initialNotificationTitle: 'Fleet Track',
      initialNotificationContent: 'Location tracking active',
      foregroundServiceNotificationId: 888,
      foregroundServiceTypes: [AndroidForegroundType.location],
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
}

// ─── Entry point for background isolate ─────────────────────────────────────
@pragma('vm:entry-point')
void onServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final techId = prefs.getString('tech_id') ?? '';
  final franchise = prefs.getString('franchise') ?? '';
  final name = prefs.getString('name') ?? '';
  final sessionId = prefs.getString('session_id') ?? '';

  double totalKm = 0.0;
  Position? lastPosition;
  bool locationWasOn = true;

  // Update foreground notification text
  if (service is AndroidServiceInstance) {
    service.setForegroundNotificationInfo(
      title: 'Fleet Track — $name',
      content: 'Tracking active',
    );
  }

  // ── Periodic GPS push to Firestore ──────────────────────────────────────
  Timer.periodic(
    Duration(seconds: AppConstants.gpsIntervalSeconds),
    (timer) async {
      // Check if service should stop (punched out)
      final p = await SharedPreferences.getInstance();
      if (!(p.getBool('is_punched_in') ?? false)) {
        timer.cancel();
        service.stopSelf();
        return;
      }

      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (locationWasOn) {
          // Location just turned off — fire warning notification
          await NotificationService.showLocationOffWarning();
          locationWasOn = false;
        }
        return;
      }

      if (!locationWasOn) {
        await NotificationService.cancelLocationWarning();
        locationWasOn = true;
      }

      Position pos;
      try {
        pos = await Geolocator.getCurrentPosition(
          locationSettings:
              const LocationSettings(accuracy: LocationAccuracy.high),
        );
      } catch (_) {
        return;
      }

      // Accumulate km
      if (lastPosition != null) {
        totalKm += LocationService_distanceKm(
          lastPosition!.latitude,
          lastPosition!.longitude,
          pos.latitude,
          pos.longitude,
        );
      }
      lastPosition = pos;

      // Push to Firestore — locations/{techId}/trail/{auto-id}
      await FirebaseFirestore.instance
          .collection(AppConstants.locationsCollection)
          .doc(techId)
          .collection('trail')
          .add({
        'lat': pos.latitude,
        'lng': pos.longitude,
        'accuracy': pos.accuracy,
        'speed': pos.speed,
        'totalKm': double.parse(totalKm.toStringAsFixed(3)),
        'sessionId': sessionId,
        'timestamp': FieldValue.serverTimestamp(),
        'franchise': franchise,
        'name': name,
      });

      // Also update the live "last known" doc for the dashboard map pin
      await FirebaseFirestore.instance
          .collection(AppConstants.locationsCollection)
          .doc(techId)
          .set({
        'lat': pos.latitude,
        'lng': pos.longitude,
        'totalKm': double.parse(totalKm.toStringAsFixed(3)),
        'sessionId': sessionId,
        'updatedAt': FieldValue.serverTimestamp(),
        'franchise': franchise,
        'name': name,
        'status': 'active',
      }, SetOptions(merge: true));

      // Notify UI isolate
      service.invoke('locationUpdate', {
        'lat': pos.latitude,
        'lng': pos.longitude,
        'totalKm': totalKm,
      });
    },
  );

  // ── 9:30 AM punch-in reminder check (runs every minute) ─────────────────
  Timer.periodic(const Duration(minutes: 1), (timer) async {
    final now = DateTime.now();
    final p = await SharedPreferences.getInstance();
    final alreadyNotified = p.getBool('punch_notif_sent_today') ?? false;
    final isPunchedIn = p.getBool('is_punched_in') ?? false;

    if (now.hour == AppConstants.punchInHour &&
        now.minute == AppConstants.punchInMinute &&
        !alreadyNotified &&
        !isPunchedIn) {
      await NotificationService.showPunchInReminder();
      await p.setBool('punch_notif_sent_today', true);
    }
    // Reset flag at midnight
    if (now.hour == 0 && now.minute == 0) {
      await p.setBool('punch_notif_sent_today', false);
    }
  });
}

// Helper (can't import from isolate, so inline)
double LocationService_distanceKm(
    double sLat, double sLng, double eLat, double eLng) {
  final m = Geolocator.distanceBetween(sLat, sLng, eLat, eLng);
  return m / 1000;
}
