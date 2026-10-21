import 'dart:math' as math;

import '../models/link_sample.dart';
import '../models/tracking.dart';
import 'geo_projection.dart';

/// Synthetic 4-node mesh for hardware-free testing of the tracking engine.
///
/// Three ground nodes plus one 15 m mast node. A single target wanders the
/// field at varying altitude; each link's dip is a Gaussian falloff of the
/// target's 3D distance to that link's segment. Output flows through the
/// same [Tripwire] + [Tracker] pipeline as real telemetry, so the UI
/// behaves identically in both modes.
class SimulatedSource {
  SimulatedSource({int seed = 7}) : _rng = math.Random(seed);

  final math.Random _rng;
  double _t = 0.0;

  /// Canonical demo layout. AppState uses this instead of auto-layout
  /// while simulated mode is on.
  Map<String, NodePosition> get nodeLayout => {
        'SIM-A': NodePosition(nodeId: 'SIM-A', x: -30, y: -30, height: 0),
        'SIM-B': NodePosition(nodeId: 'SIM-B', x: 30, y: -30, height: 0),
        'SIM-C': NodePosition(nodeId: 'SIM-C', x: 30, y: 30, height: 0),
        'SIM-D': NodePosition(nodeId: 'SIM-D', x: -30, y: 30, height: 15),
      };

  /// Advance the simulation by [dt] seconds and return raw link samples.
  List<LinkSample> tick({double dt = 0.5}) {
    _t += dt;
    final nodes = nodeLayout;
    final ids = nodes.keys.toList();

    // Wandering target, altitude varying 2..14 m.
    final tx = 42 * math.sin(_t / 16);
    final ty = 42 * math.sin(_t / 23 + 1.3);
    final tz = 8 + 6 * math.sin(_t / 31 + 0.5);

    final out = <LinkSample>[];
    for (var i = 0; i < ids.length; i++) {
      for (var j = 0; j < ids.length; j++) {
        if (i == j) continue;
        final a = nodes[ids[i]]!;
        final b = nodes[ids[j]]!;
        final d = _distToSegment3D(tx, ty, tz, a, b);
        final targetDip = 26 * math.exp(-math.pow(d / 11, 2));
        out.add(_sample(ids[i], ids[j], targetDip));
      }
    }
    return out;
  }

  LinkSample _sample(String from, String to, double targetDip) {
    final phase = (from.hashCode ^ to.hashCode) & 0xFF;
    final noise = (_rng.nextDouble() +
            _rng.nextDouble() +
            _rng.nextDouble() -
            1.5) *
        2.0;
    final base = 90 + 4 * math.sin(_t / 9 + phase);
    final jitter = (_rng.nextDouble() - 0.5) * 1.5;
    final snr = base + noise * 1.2 - targetDip + jitter;
    final now = DateTime.now();
    return LinkSample(
      timestamp: now,
      fromNode: from,
      toNode: to,
      snr: snr,
      mcs: 8 + _rng.nextInt(3),
      pcns: [snr - 70 + noise, snr - 71 - noise, -114.0, -114.0],
      noiseFrom: -72.0,
      noiseTo: -74.0,
    );
  }

  /// 3D distance from point P to segment AB (node heights included).
  static double _distToSegment3D(
      double px, double py, double pz, NodePosition a, NodePosition b) {
    final abx = b.x - a.x;
    final aby = b.y - a.y;
    final abz = b.height - a.height;
    final apx = px - a.x;
    final apy = py - a.y;
    final apz = pz - a.height;
    final len2 = abx * abx + aby * aby + abz * abz;
    var t = len2 == 0 ? 0.0 : (apx * abx + apy * aby + apz * abz) / len2;
    t = t.clamp(0.0, 1.0);
    final cx = a.x + abx * t - px;
    final cy = a.y + aby * t - py;
    final cz = a.height + abz * t - pz;
    return math.sqrt(cx * cx + cy * cy + cz * cz);
  }
}

/// One simulated dismount for [SimGroundFeed]: a parametric patrol
/// path in field-local meters (x east, y north) over sim time.
class _SimWalker {
  const _SimWalker({
    required this.uid,
    required this.callsign,
    required this.batteryStart,
    required this.path,
  });

  final String uid;
  final String callsign;

  /// Battery percent at sim start; drains slowly from here.
  final double batteryStart;

  /// Position (field meters) at sim-time [t] seconds.
  final ({double x, double y}) Function(double t) path;
}

/// Simulated friendly-ground PLI feed (v0.23.0): two dismounts
/// walking patrol paths at dismount pace (~1.4 m/s peak), emitting
/// ATAK-shaped CoT `a-f-G-U-C` events.
///
/// The point of the shape: AppState runs these datagrams through a
/// real CotListener, so the demo exercises the PRODUCTION parse →
/// platform → ground-classifier path end to end. Only the radio
/// is fake — and in simulated mode everything is labeled sim
/// anyway (callsigns carry the SIM- prefix, like the sim nodes).
class SimGroundFeed {
  SimGroundFeed();

  /// Demo anchor used ONLY when simulated mode has no GPS origin:
  /// an arbitrary point (Fort Liberty area) so sim lat/lon exist
  /// at all. Display-only — never persisted as the field origin,
  /// never a claim about anywhere real.
  static const double demoOriginLat = 35.05;
  static const double demoOriginLon = -78.97;

  double _t = 0;

  /// Patrol amplitudes/periods are sized for walking pace: peak
  /// speed of a sinusoid is amplitude × 2π / period ≈ 1.4 m/s.
  static final List<_SimWalker> _walkers = [
    _SimWalker(
      uid: 'SIM-163-A',
      callsign: 'SIM-163-A',
      batteryStart: 94,
      path: (t) => (
        x: 20 * math.sin(2 * math.pi * t / 90),
        y: 16 * math.sin(2 * math.pi * t / 127 + 1.3),
      ),
    ),
    _SimWalker(
      uid: 'SIM-163-B',
      callsign: 'SIM-163-B',
      batteryStart: 87,
      path: (t) => (
        x: 24 * math.sin(2 * math.pi * t / 111 + 2.0),
        y: 20 * math.cos(2 * math.pi * t / 97 + 0.4),
      ),
    ),
  ];

  /// Advance the feed by [dt] sim-seconds and return one CoT
  /// datagram per walker, timestamped [now] (real clock — the
  /// listener's pruning runs on it, exactly like the real feed).
  List<String> tick({
    required double dt,
    required double originLat,
    required double originLon,
    required DateTime now,
  }) {
    _t += dt;
    final geo = GeoProjection(originLat: originLat, originLon: originLon);
    final ts = now.toUtc().toIso8601String();
    final out = <String>[];
    for (final w in _walkers) {
      final p = w.path(_t);
      // Course/speed from a 1 s lookback difference — the same
      // finite difference a real PLI stream implies.
      final prev = w.path(_t - 1.0);
      final dx = p.x - prev.x;
      final dy = p.y - prev.y;
      final speed = math.sqrt(dx * dx + dy * dy); // meters per 1 s
      var course = math.atan2(dx, dy) * 180 / math.pi; // 0=N, 90=E
      if (course < 0) course += 360;
      final ll = geo.metersToLatLon(p.x, p.y);
      // Battery: ~1% per 4 minutes of sim time, floored at 5%.
      final batt = (w.batteryStart - _t / 240).clamp(5, 100).round();
      out.add('<event version="2.0" uid="${w.uid}" type="a-f-G-U-C" '
          'time="$ts" start="$ts" stale="$ts" how="m-g">'
          '<point lat="${ll.lat}" lon="${ll.lon}" hae="999999.0" '
          'ce="5.0" le="5.0"/>'
          '<detail><contact callsign="${w.callsign}"/>'
          '<track course="${course.toStringAsFixed(1)}" '
          'speed="${speed.toStringAsFixed(2)}"/>'
          '<status battery="$batt"/></detail></event>');
    }
    return out;
  }
}
