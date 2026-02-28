import 'package:geolocator/geolocator.dart';

class LocationService {
  /// Returns current position or throws
  static Future<Position> getCurrentPosition() async {
    return await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
      ),
    );
  }

  /// Stream of position updates
  static Stream<Position> positionStream() {
    return Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10, // metres — only emit if moved 10m
      ),
    );
  }

  /// Distance between two lat/lng points in kilometres
  static double distanceKm(
    double startLat,
    double startLng,
    double endLat,
    double endLng,
  ) {
    final metres =
        Geolocator.distanceBetween(startLat, startLng, endLat, endLng);
    return metres / 1000;
  }

  /// Request all necessary permissions (fine + always/background)
  static Future<bool> requestPermissions() async {
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    return perm == LocationPermission.always ||
        perm == LocationPermission.whileInUse;
  }
}
