import 'dart:async';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

/// GPS-assisted node positioning.
///
/// Walk to each mesh node with the device running the app, tap capture,
/// and the node's field-local X/Y is set from the GPS fix — no more
/// hand-typing coordinates.
///
/// Honest-accuracy note: this is only as good as the device's fix.
/// A phone outdoors at the node gives meter-level accuracy; a Windows
/// desktop's location (Wi-Fi/IP based) is coarse — tens of meters.
/// The UI always shows the fix accuracy so you know what you got.
///
/// Positions are field-local meters (x east, y north) relative to a
/// stored GPS origin. The first capture sets the origin implicitly.

/// Field origin in WGS84. Persisted across restarts.
class GpsOrigin {
  GpsOrigin({required this.lat, required this.lon});

  final double lat;
  final double lon;

  Map<String, dynamic> toJson() => {'lat': lat, 'lon': lon};

  factory GpsOrigin.fromJson(Map<String, dynamic> j) => GpsOrigin(
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
      );

  String get label =>
      '${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}';
}

/// Equirectangular projection of (lat, lon) to meters east/north of
/// (lat0, lon0). Accurate to centimeters over field-sized areas
/// (a few hundred meters); do not use it across kilometers.
({double x, double y}) latLonToMeters(
    double lat, double lon, double lat0, double lon0) {
  const mPerDegLat = 110540.0;
  final mPerDegLon = 111320.0 * math.cos(lat0 * math.pi / 180.0);
  return (
    x: (lon - lon0) * mPerDegLon,
    y: (lat - lat0) * mPerDegLat,
  );
}

/// Human-readable failure from a GPS capture attempt.
class GpsException implements Exception {
  GpsException(this.message);
  final String message;
  @override
  String toString() => message;
}

class GpsPositioning {
  /// One-shot best-accuracy fix. Throws [GpsException] with a UI-ready
  /// message when location is unavailable, denied, or times out.
  ///
  /// `altitudeM` is the device-reported altitude in meters. Its
  /// reference frame is platform-dependent (Android documents WGS-84
  /// ellipsoid, iOS documents MSL) — never treat it as verified HAE.
  static Future<
      ({
        double lat,
        double lon,
        double accuracyM,
        double altitudeM,
      })> currentFix() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw GpsException(
          'LOCATION SERVICES ARE OFF — ENABLE THEM IN SYSTEM SETTINGS, THEN RETRY.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      throw GpsException('LOCATION PERMISSION DENIED.');
    }
    if (permission == LocationPermission.deniedForever) {
      throw GpsException(
          'LOCATION PERMISSION DENIED FOREVER — ENABLE IT IN SYSTEM SETTINGS.');
    }
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
        ),
      ).timeout(const Duration(seconds: 30));
      return (
        lat: pos.latitude,
        lon: pos.longitude,
        accuracyM: pos.accuracy,
        altitudeM: pos.altitude,
      );
    } on TimeoutException {
      throw GpsException(
          'GPS FIX TIMED OUT — TRY AGAIN OUTSIDE WITH A CLEAR VIEW OF THE SKY.');
    }
  }
}
