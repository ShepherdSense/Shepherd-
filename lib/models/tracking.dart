/// Tracking models for the multi-node RF sensing engine.
///
/// Honest-geometry note: position, heading and speed come from the *sequence*
/// of disturbed links across the mesh, so they need 3+ nodes. Altitude needs
/// nodes at *different heights* (a mast, roof, or hill) — with all nodes on
/// the ground it is unobservable and reported as unknown, never faked.
/// Everything here is an estimate; type guesses are low-confidence heuristics.
library;

/// A mesh node's position in field-local meters (x east, y north)
/// plus its height above ground in meters and its antenna type
/// ('whip' = omnidirectional donut, 'panel' = directional lobe).
class NodePosition {
  NodePosition({
    required this.nodeId,
    required this.x,
    required this.y,
    this.height = 0.0,
    this.antenna = 'whip',
    this.lat,
    this.lon,
    this.callsign,
  });

  final String nodeId;
  double x;
  double y;
  double height;

  /// 'whip' or 'panel'. Used by the 3D beam view; idealized patterns.
  String antenna;

  /// WGS84 coordinates from the last GPS capture, if any.
  /// Display/persistence only — the tracker uses x/y.
  double? lat;
  double? lon;

  /// True once the operator has dragged this node on the map. Auto
  /// placement (spiral, or Meshtastic GPS) must not overwrite it.
  bool userPlaced = false;

  /// Operator callsign ("RAPTOR-1") shown over the node on the map.
  /// Set by the user in the app, or broadcast by the node in its beacon.
  /// Null = show the hardware node id.
  String? callsign;

  /// True when the callsign was typed by the operator; beacon callsigns
  /// never overwrite a user-set one.
  bool callsignByUser = false;

  /// Map label: callsign when set, else the hardware id.
  String get displayName =>
      (callsign != null && callsign!.isNotEmpty) ? callsign! : nodeId;

  Map<String, dynamic> toJson() => {
        'nodeId': nodeId,
        'x': x,
        'y': y,
        'height': height,
        'antenna': antenna,
        if (lat != null) 'lat': lat,
        if (lon != null) 'lon': lon,
        if (userPlaced) 'userPlaced': true,
        if (callsign != null && callsign!.isNotEmpty) 'callsign': callsign,
        if (callsignByUser) 'callsignByUser': true,
      };

  factory NodePosition.fromJson(Map<String, dynamic> j) => NodePosition(
        nodeId: j['nodeId'] as String,
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        height: ((j['height'] ?? 0) as num).toDouble(),
        antenna: (j['antenna'] as String?) ?? 'whip',
        lat: (j['lat'] as num?)?.toDouble(),
        lon: (j['lon'] as num?)?.toDouble(),
        callsign: j['callsign'] as String?,
      )
        ..userPlaced = (j['userPlaced'] as bool?) ?? false
        ..callsignByUser = (j['callsignByUser'] as bool?) ?? false;

  String get gpsLabel => lat == null || lon == null
      ? '—'
      : '${lat!.toStringAsFixed(6)}, ${lon!.toStringAsFixed(6)}';
}

/// The defended point: inbound/outbound is judged relative to this.
/// Draggable on the tracking map.
class DefendedPoint {
  DefendedPoint({required this.x, required this.y});

  double x;
  double y;

  Map<String, dynamic> toJson() => {'x': x, 'y': y};

  factory DefendedPoint.fromJson(Map<String, dynamic> j) => DefendedPoint(
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
      );
}

/// One fused track estimate for the (single) target currently disturbing
/// the mesh. Null fields mean "not observable with current geometry" —
/// the UI must show that, not a made-up number.
class TrackEstimate {
  const TrackEstimate({
    required this.timestamp,
    required this.x,
    required this.y,
    this.altitudeM,
    this.altitudeConfidence = 0.0,
    this.speedMps,
    this.headingDeg,
    required this.sizeClass,
    required this.typeGuess,
    required this.typeConfidence,
    required this.linksUsed,
    required this.relation,
    this.stitchLabel,
    this.stitchConfidence,
  });

  final DateTime timestamp;

  /// Field-local meters (x east, y north). Estimate.
  final double x;
  final double y;

  /// Meters above ground. Null when unobservable (nodes coplanar).
  final double? altitudeM;

  /// 0..1 — how much to trust the altitude (vertical node spread).
  final double altitudeConfidence;

  /// Meters per second. Null until the target has moved between fixes.
  final double? speedMps;

  /// Degrees clockwise from north. Null when stationary / unknown.
  final double? headingDeg;

  /// 'S', 'M' or 'L' from dip depth. Estimate.
  final String sizeClass;

  /// Heuristic label, e.g. "Fast small object — possible small drone".
  final String typeGuess;

  /// 0..1, always low — this is a guess, not identification.
  final double typeConfidence;

  /// How many distinct mesh links contributed to this fix.
  final int linksUsed;

  /// INBOUND / OUTBOUND / TRANSITING / UNKNOWN, relative to defended point.
  final String relation;

  /// Cross-radio stitch verdict, e.g. 'SILVUS → SIM'. Null when the
  /// track sits on one driver or the stitcher abstained. Estimate.
  final String? stitchLabel;

  /// 0..1 P(same mover) from the stitching specialist. Estimate.
  final double? stitchConfidence;

  TrackEstimate copyWith({String? stitchLabel, double? stitchConfidence}) =>
      TrackEstimate(
        timestamp: timestamp,
        x: x,
        y: y,
        altitudeM: altitudeM,
        altitudeConfidence: altitudeConfidence,
        speedMps: speedMps,
        headingDeg: headingDeg,
        sizeClass: sizeClass,
        typeGuess: typeGuess,
        typeConfidence: typeConfidence,
        linksUsed: linksUsed,
        relation: relation,
        stitchLabel: stitchLabel ?? this.stitchLabel,
        stitchConfidence: stitchConfidence ?? this.stitchConfidence,
      );

  String get headingCompass =>
      headingDeg == null ? '—' : compass16(headingDeg!);

  String get positionLabel =>
      '≈ ${x.toStringAsFixed(0)}m E, ${y.toStringAsFixed(0)}m N of field origin (est.)';
}

/// 16-point compass label for a heading in degrees.
String compass16(double deg) {
  const pts = [
    'N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE',
    'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW',
  ];
  final i = (((deg + 11.25) / 22.5).floor()) % 16;
  return pts[i];
}
