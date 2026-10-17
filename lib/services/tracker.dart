import 'dart:math' as math;

import '../models/link_sample.dart';
import '../models/tracking.dart';

/// Fuses disturbed mesh links into a single-target track estimate.
///
/// Method (deliberately simple and explainable):
/// - Position: 3D tomographic grid search — the point whose distances to
///   the disturbed links best explain the observed dip depths.
/// - Altitude: the grid search's z — but ONLY reported when the disturbed
///   nodes have real vertical spread (>= 1 m). All nodes on the ground
///   means altitude is unobservable, so it is null, never invented.
/// - Speed/heading: from the sequence of position fixes over time.
/// - Type: low-confidence heuristic from size + speed. Always labeled so.
///
/// No node-count limit anywhere: every link direction present in the
/// telemetry participates. Single target: if two objects cross at once,
/// the estimate is their blend (documented, not hidden).
class Tracker {
  /// Minimum seconds between position fixes used for velocity.
  final double fixMinIntervalSecs;

  /// Seconds without any disturbed link before velocity state resets.
  final double idleResetSecs;

  /// Dip falloff distance (m) of the forward model. Matches the
  /// simulator; real links vary, but the pattern-match degrades
  /// gracefully rather than collapsing.
  final double sigma;

  Tracker(
      {this.fixMinIntervalSecs = 1.5,
      this.idleResetSecs = 10.0,
      this.sigma = 11.0});

  final List<_Fix> _fixes = [];
  double? _vx;
  double? _vy;
  DateTime? _lastDetect;

  /// Fuse one poll of enriched samples into a track, or null when
  /// nothing is currently disturbed.
  TrackEstimate? update({
    required DateTime now,
    required List<LinkSample> samples,
    required Map<String, NodePosition> nodes,
    required double dipThreshold,
    required DefendedPoint defended,
  }) {
    // Link *pairs* (directions deduped, strongest dip kept) — ALL pairs,
    // not just disturbed ones: quiet links carry "the target is NOT near
    // me" information that sharpens the fix.
    final pairs = _dedupePairs(samples, nodes, dipThreshold);
    final disturbed = pairs.values.where((p) => p.isDisturbed).toList();
    if (disturbed.isEmpty) {
      if (_lastDetect != null &&
          now.difference(_lastDetect!).inMilliseconds / 1000 >
              idleResetSecs) {
        reset();
      }
      return null;
    }
    _lastDetect = now;

    // Geometry gate: one link (two nodes) only says "somewhere along this
    // line", and the grid search would pick an arbitrary point on it.
    // Without 3+ positioned nodes there is nothing honest to localize --
    // the disturbance is still reported by the tripwire / banner.
    final geometryIds = <String>{};
    for (final p in pairs.values) {
      geometryIds
        ..add(p.a.nodeId)
        ..add(p.b.nodeId);
    }
    if (geometryIds.length < 3) return null;

    // Position: coarse 3D tomographic grid search. Each candidate point is
    // scored by how well the disturbed links' dips match a Gaussian
    // falloff of the point's distance to each link. The argmax is the
    // estimate — far sharper than a link-midpoint average.
    final linkList = pairs.values.toList();
    final maxDip = linkList.map((p) => p.dip).reduce(math.max);

    // Normalized pattern match: the candidate point whose *relative*
    // dip pattern across all links best matches the observed one.
    // Score <= 0, best = 0 (exact match).
    double scoreAt(double x, double y, double z) {
      var maxM = 0.0;
      final ms = <double>[];
      for (final p in linkList) {
        final d = _distPtSeg3D(x, y, z, p.a, p.b);
        final m = math.exp(-math.pow(d / sigma, 2));
        ms.add(m);
        if (m > maxM) maxM = m;
      }
      if (maxM < 1e-6) return -1e9;
      var err = 0.0;
      for (var i = 0; i < linkList.length; i++) {
        final o = linkList[i].dip / maxDip;
        final m = ms[i] / maxM;
        final r = o - m;
        err += r * r;
      }
      return -err;
    }

    // Pass 1: coarse grid (2.5 m by default; coarser for big meshes).
    var best = -1e9, bx = 0.0, by = 0.0, bz = 0.0;
    var minX = double.infinity,
        maxX = -double.infinity,
        minY = double.infinity,
        maxY = -double.infinity,
        maxH = 0.0;
    for (final n in nodes.values) {
      if (n.x < minX) minX = n.x;
      if (n.x > maxX) maxX = n.x;
      if (n.y < minY) minY = n.y;
      if (n.y > maxY) maxY = n.y;
      if (n.height > maxH) maxH = n.height;
    }
    minX -= 15;
    maxX += 15;
    minY -= 15;
    maxY += 15;
    final zMax = maxH + 15;

    // The solve runs on the UI isolate every poll, so cap its cost: grow
    // the coarse step until the grid is at most ~20k points. The forward
    // model's falloff (sigma ~ 11 m) makes steps up to ~8 m harmless.
    var step = 2.5;
    double gridPoints(double st) =>
        ((maxX - minX) / st + 1) *
        ((maxY - minY) / st + 1) *
        (zMax / st + 1);
    while (gridPoints(step) > 20000 && step < 8.0) {
      step *= 1.25;
    }

    for (var x = minX; x <= maxX; x += step) {
      for (var y = minY; y <= maxY; y += step) {
        for (var z = 0.0; z <= zMax; z += step) {
          final s = scoreAt(x, y, z);
          if (s > best) {
            best = s;
            bx = x;
            by = y;
            bz = z;
          }
        }
      }
    }
    // Pass 2: refine around the coarse winner. The window covers one
    // coarse step each way (>= 3 m); fine step is a fifth of it (0.6 m
    // at the default grid).
    final win = math.max(3.0, step);
    final fine = win / 5.0;
    for (var x = bx - win; x <= bx + win + 1e-9; x += fine) {
      for (var y = by - win; y <= by + win + 1e-9; y += fine) {
        for (var z = math.max(0.0, bz - win);
            z <= bz + win + 1e-9;
            z += fine) {
          final s = scoreAt(x, y, z);
          if (s > best) {
            best = s;
            bx = x;
            by = y;
            bz = z;
          }
        }
      }
    }
    final x = bx, y = by, z = bz;

    // Altitude: only with real vertical spread among disturbed nodes.
    final heights = <double>{};
    for (final p in disturbed) {
      heights.add(p.a.height);
      heights.add(p.b.height);
    }
    final hList = heights.toList();
    final spread = hList.reduce(math.max) - hList.reduce(math.min);
    double? altitude;
    var altConf = 0.0;
    if (spread >= 1.0) {
      altitude = math.max(0.0, z);
      altConf = (spread / 12.0).clamp(0.2, 0.9);
    }

    // Velocity from fix history.
    if (_fixes.isEmpty ||
        now.difference(_fixes.last.t).inMilliseconds / 1000 >=
            fixMinIntervalSecs) {
      if (_fixes.isNotEmpty) {
        final last = _fixes.last;
        final dt = now.difference(last.t).inMilliseconds / 1000;
        if (dt >= 1.0 && dt <= 120.0) {
          final nvx = (x - last.x) / dt;
          final nvy = (y - last.y) / dt;
          _vx = _vx == null ? nvx : 0.5 * _vx! + 0.5 * nvx;
          _vy = _vy == null ? nvy : 0.5 * _vy! + 0.5 * nvy;
        }
      }
      _fixes.add(_Fix(t: now, x: x, y: y));
      if (_fixes.length > 40) _fixes.removeAt(0);
      // With 3+ recent fixes, fit a line through them: far less jumpy
      // than differencing two noisy grid positions.
      final fit = _fitVelocity(now);
      if (fit != null) {
        _vx = fit.vx;
        _vy = fit.vy;
      }
    }
    double? speed;
    double? heading;
    if (_vx != null && _vy != null) {
      speed = math.sqrt(_vx! * _vx! + _vy! * _vy!);
      if (speed >= 0.4) {
        // Clockwise from north, x east / y north.
        heading = (math.atan2(_vx!, _vy!) * 180 / math.pi + 360) % 360;
      }
    }

    final peakDip =
        disturbed.map((p) => p.dip).reduce(math.max);
    final size = peakDip < 10 ? 'S' : peakDip < 20 ? 'M' : 'L';
    final type = _guessType(size, speed);

    var relation = 'UNKNOWN';
    if (_vx != null && _vy != null && speed != null) {
      if (speed >= 0.5) {
        final dx = x - defended.x;
        final dy = y - defended.y;
        final dist = math.sqrt(dx * dx + dy * dy);
        if (dist > 1.0) {
          final closing = -(_vx! * dx + _vy! * dy) / dist;
          relation = closing > 0.5
              ? 'INBOUND'
              : closing < -0.5
                  ? 'OUTBOUND'
                  : 'TRANSITING';
        } else {
          relation = 'OVERHEAD';
        }
      } else {
        relation = 'HOLDING';
      }
    }

    return TrackEstimate(
      timestamp: now,
      x: x,
      y: y,
      altitudeM: altitude,
      altitudeConfidence: altConf,
      speedMps: speed,
      headingDeg: heading,
      sizeClass: size,
      typeGuess: type.label,
      typeConfidence: type.confidence,
      linksUsed: disturbed.length,
      relation: relation,
    );
  }

  /// Least-squares velocity over fixes from the last [window] seconds.
  /// Null with fewer than 3 fixes or no time spread.
  ({double vx, double vy})? _fitVelocity(DateTime now,
      {double window = 12.0}) {
    final pts = [
      for (final f in _fixes)
        if (now.difference(f.t).inMilliseconds / 1000.0 <= window) f,
    ];
    if (pts.length < 3) return null;
    final t0 = pts.first.t;
    final ts = [
      for (final f in pts) f.t.difference(t0).inMilliseconds / 1000.0
    ];
    final n = pts.length;
    final mt = ts.reduce((a, b) => a + b) / n;
    final mx = pts.map((f) => f.x).reduce((a, b) => a + b) / n;
    final my = pts.map((f) => f.y).reduce((a, b) => a + b) / n;
    var sxx = 0.0, sxt = 0.0, syt = 0.0;
    for (var i = 0; i < n; i++) {
      final dt = ts[i] - mt;
      sxx += dt * dt;
      sxt += dt * (pts[i].x - mx);
      syt += dt * (pts[i].y - my);
    }
    if (sxx < 1e-6) return null;
    return (vx: sxt / sxx, vy: syt / sxx);
  }

  void reset() {
    _fixes.clear();
    _vx = null;
    _vy = null;
    _lastDetect = null;
  }

  /// 2D shadow (attenuation) grid for the "what are the waves hitting"
  /// view. Each cell's value is the dip-weighted sum of Gaussian
  /// falloffs to every link segment: high values mark where the RF
  /// field is dimmed — the shadow the object casts in the waves.
  /// Quiet links contribute ~nothing, so empty field stays dark.
  /// Values are normalized 0..1 across the grid.
  List<ShadowCell> shadowGrid({
    required List<LinkSample> samples,
    required Map<String, NodePosition> nodes,
    required double dipThreshold,
    double cellM = 2.5,
  }) {
    final pairs = _dedupePairs(samples, nodes, dipThreshold);
    final out = <ShadowCell>[];
    if (pairs.isEmpty) return out;

    var minX = double.infinity,
        maxX = -double.infinity,
        minY = double.infinity,
        maxY = -double.infinity;
    for (final n in nodes.values) {
      if (n.x < minX) minX = n.x;
      if (n.x > maxX) maxX = n.x;
      if (n.y < minY) minY = n.y;
      if (n.y > maxY) maxY = n.y;
    }
    minX -= 12;
    maxX += 12;
    minY -= 12;
    maxY += 12;

    // Cap the cell count (~6k) so a large field doesn't mean thousands of
    // cells x every link, every poll.
    var cell = cellM;
    while (((maxX - minX) / cell + 1) * ((maxY - minY) / cell + 1) > 6000 &&
        cell < 20.0) {
      cell *= 1.25;
    }

    final linkList = pairs.values.toList();
    var peak = 0.0;
    final raws = <double>[];
    final xs = <double>[];
    final ys = <double>[];
    for (var x = minX; x <= maxX; x += cell) {
      for (var y = minY; y <= maxY; y += cell) {
        var v = 0.0;
        for (final p in linkList) {
          if (p.dip < p.threshold * 0.5) continue;
          final d = _distPtSeg2D(x, y, p.a, p.b);
          v += p.dip * math.exp(-math.pow(d / sigma, 2));
        }
        xs.add(x);
        ys.add(y);
        raws.add(v);
        if (v > peak) peak = v;
      }
    }
    if (peak < 1e-9) return out;
    for (var i = 0; i < raws.length; i++) {
      final v = (raws[i] / peak).clamp(0.0, 1.0);
      if (v > 0.03) out.add(ShadowCell(x: xs[i], y: ys[i], v: v));
    }
    return out;
  }

  /// Collapse link directions into undirected pairs. Of the two
  /// directions, keep the one that is furthest past ITS OWN threshold
  /// (each direction can have a different noise level, so raw dip depth
  /// is not comparable). [fallback] is used for samples that carry no
  /// threshold of their own.
  static Map<String, _PairDip> _dedupePairs(
    List<LinkSample> samples,
    Map<String, NodePosition> nodes,
    double fallback,
  ) {
    final pairs = <String, _PairDip>{};
    for (final s in samples) {
      final a = nodes[s.fromNode];
      final b = nodes[s.toNode];
      if (a == null || b == null) continue;
      final key = _pairKey(s.fromNode, s.toNode);
      final cand = _PairDip(
        a: a,
        b: b,
        dip: s.dip,
        threshold: s.effectiveThreshold(fallback),
      );
      final prev = pairs[key];
      if (prev == null || cand.margin > prev.margin) pairs[key] = cand;
    }
    return pairs;
  }

  static String _pairKey(String a, String b) {
    final ids = [a, b]..sort();
    return '${ids[0]}|${ids[1]}';
  }

  /// 2D (top-down) distance from point P to the segment A→B.
  /// Used by the shadow grid — the shadow is a ground-plane image.
  static double _distPtSeg2D(
      double px, double py, NodePosition a, NodePosition b) {
    final abx = b.x - a.x;
    final aby = b.y - a.y;
    final apx = px - a.x;
    final apy = py - a.y;
    final len2 = abx * abx + aby * aby;
    var t = len2 == 0 ? 0.0 : (apx * abx + apy * aby) / len2;
    t = t.clamp(0.0, 1.0);
    final cx = a.x + abx * t - px;
    final cy = a.y + aby * t - py;
    return math.sqrt(cx * cx + cy * cy);
  }

  /// 3D distance from point P to the segment A→B.
  static double _distPtSeg3D(
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

  /// Heuristic type guess. Confidence is ALWAYS low — this is a hint,
  /// not identification.
  static ({String label, double confidence}) _guessType(
      String size, double? speedMps) {
    final s = speedMps ?? 0;
    if (size == 'S' && s >= 3) {
      return (
        label: 'Fast small object — possible small drone',
        confidence: 0.35
      );
    }
    if (size == 'S') {
      return (
        label: 'Small slow mover — person / animal?',
        confidence: 0.30
      );
    }
    if (size == 'M' && s >= 5) {
      return (
        label: 'Medium fast object — possible drone / large bird',
        confidence: 0.30
      );
    }
    if (size == 'M') {
      return (label: 'Medium object — unknown', confidence: 0.25);
    }
    if (s >= 12) {
      return (
        label: 'Large fast object — possible vehicle / aircraft',
        confidence: 0.35
      );
    }
    return (label: 'Large object — unknown', confidence: 0.25);
  }
}

class _PairDip {
  _PairDip({
    required this.a,
    required this.b,
    required this.dip,
    required this.threshold,
  });

  final NodePosition a;
  final NodePosition b;
  final double dip;

  /// Dip depth at which this pair's link counts as disturbed.
  final double threshold;

  /// How far past (or short of) its own threshold the dip is.
  double get margin => dip - threshold;

  bool get isDisturbed => dip >= threshold;
}

/// One cell of the shadow (attenuation) grid: field-local meters and a
/// normalized 0..1 shadow intensity.
class ShadowCell {
  const ShadowCell({required this.x, required this.y, required this.v});

  final double x;
  final double y;
  final double v;
}

class _Fix {
  _Fix({required this.t, required this.x, required this.y});

  final DateTime t;
  final double x;
  final double y;
}
