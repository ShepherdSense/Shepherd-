/// Map-meters <-> WGS84 projection via the map's GPS anchor.
///
/// The exact inverse of the equirectangular `latLonToMeters` in
/// gps_positioning.dart (110540 m/deg latitude; 111320*cos(lat0) m/deg
/// longitude). Accurate to centimeters over field-sized areas (a few
/// hundred meters); do not use it across kilometers.
///
/// Pure Dart — no Flutter dependencies.
library;

import 'dart:math' as math;

/// Meters per degree of latitude (matches gps_positioning.dart).
const double kMetersPerDegLat = 110540.0;

/// Meters per degree of longitude at the equator (matches
/// gps_positioning.dart); scaled by cos(origin latitude).
const double kMetersPerDegLonEquator = 111320.0;

/// Field-local X/Y (x east, y north, meters) <-> (lat, lon) degrees,
/// anchored on the map's GPS origin.
class GeoProjection {
  GeoProjection({required this.originLat, required this.originLon});

  final double originLat;
  final double originLon;

  double get metersPerDegLon =>
      kMetersPerDegLonEquator * math.cos(originLat * math.pi / 180.0);

  /// Map meters -> WGS84. Exact inverse of [latLonToMeters].
  ({double lat, double lon}) metersToLatLon(double xEast, double yNorth) {
    return (
      lat: originLat + yNorth / kMetersPerDegLat,
      lon: originLon + xEast / metersPerDegLon,
    );
  }

  /// WGS84 -> map meters. Mirrors gps_positioning.dart's
  /// `latLonToMeters` against this projection's origin.
  ({double x, double y}) latLonToMeters(double lat, double lon) {
    return (
      x: (lon - originLon) * metersPerDegLon,
      y: (lat - originLat) * kMetersPerDegLat,
    );
  }
}
