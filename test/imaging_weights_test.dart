import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/models/link_sample.dart';
import 'package:shepherd/models/tracking.dart';
import 'package:shepherd/screens/tracking.dart' show rtiImageLabel;
import 'package:shepherd/services/tracker.dart';

NodePosition _n(String id, double x, double y) =>
    NodePosition(nodeId: id, x: x, y: y);

final _t0 = DateTime(2026, 1, 1, 12);

LinkSample _s(
  String from,
  String to,
  double deltaDown,
  double deltaUp,
  double fadeLevel, {
  int i = 0,
}) =>
    LinkSample(
      timestamp: _t0.add(Duration(milliseconds: 250 * i)),
      fromNode: from,
      toNode: to,
      snr: 90.0,
      dip: math.max(deltaDown, deltaUp),
      deltaDown: deltaDown,
      deltaUp: deltaUp,
      fadeLevel: fadeLevel,
      baseline: 90.0,
      threshold: 3.0,
    );

RtiCell _peak(List<RtiCell> cells) =>
    cells.reduce((a, b) => a.v >= b.v ? a : b);

/// Mass centroid of the significant region (cells with v ≥ half the
/// peak). More robust than argmax on a coarse grid: the per-link
/// mesas are flat, so the first max cell is an arbitrary plateau edge.
(math.Point<double>, double) _centroid(List<RtiCell> cells) {
  final peak = _peak(cells).v;
  var sx = 0.0, sy = 0.0, sm = 0.0;
  for (final c in cells) {
    if (c.v >= 0.5 * peak) {
      sx += c.x * c.v;
      sy += c.y * c.v;
      sm += c.v;
    }
  }
  return (math.Point(sx / sm, sy / sm), peak);
}

double _dist(double x1, double y1, double x2, double y2) =>
    math.sqrt((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2));

/// Peak-to-sidelobe ratio: peak v over the strongest cell farther
/// than [radiusM] from the truth point.
double _p2s(List<RtiCell> cells, double tx, double ty, double radiusM) {
  final peak = _peak(cells).v;
  var side = 0.0;
  for (final c in cells) {
    final d = math.sqrt(
        (c.x - tx) * (c.x - tx) + (c.y - ty) * (c.y - ty));
    if (d > radiusM && c.v > side) side = c.v;
  }
  if (side < 1e-9) return double.infinity;
  return peak / side;
}

void main() {
  group('direction split', () {
    test('dip + rise both contribute; no cancellation; control loses',
        () {
      final tracker = Tracker();
      final nodes = {
        'A': _n('A', 0, 0),
        'B': _n('B', 40, 0),
        'C': _n('C', 20, -20),
        'D': _n('D', 20, 20),
      };
      // Truth (20.5, 0.5): at the CROSSING of the two links, so the
      // direction-overlap region is symmetric about the truth.
      // Link A→B anti-fade (F=+6) DIPS; link C→D deep-fade (F=−6)
      // RISES.
      final samples = [
        _s('A', 'B', 10.0, 0.0, 6.0),
        _s('C', 'D', 0.0, 10.0, -6.0),
      ];
      final img = tracker.rtiImage(
          samples: samples, nodes: nodes, dipThreshold: 3.0);

      // Both directions contribute positive mass at the true pixel:
      // no cancellation.
      RtiCell? truth;
      for (final c in img) {
        if ((c.x - 20.5).abs() < 1e-9 && (c.y - 0.5).abs() < 1e-9) {
          truth = c;
        }
      }
      expect(truth, isNotNull);
      expect(truth!.vMinus, greaterThan(0),
          reason: 'anti-fade dip must feed p⁻ at truth');
      expect(truth.vPlus, greaterThan(0),
          reason: 'deep-fade rise must feed p⁺ at truth');

      // The fused location is where the two directions OVERLAP. The
      // per-link mesas are flat, so argmax is an arbitrary plateau
      // edge; the overlap centroid is the meaningful location.
      var sx = 0.0, sy = 0.0, sm = 0.0;
      for (final c in img) {
        if (c.vMinus > 0.25 && c.vPlus > 0.25) {
          sx += c.x * c.v;
          sy += c.y * c.v;
          sm += c.v;
        }
      }
      expect(sm, greaterThan(0), reason: 'directions must overlap');
      expect(_dist(sx / sm, sy / sm, 20.5, 0.5),
          lessThanOrEqualTo(3.75),
          reason: 'direction overlap localizes the truth');

      // Control: fold |Δr| first (magnitudes summed, direction and
      // fade info dropped — the old pipeline's information loss).
      // Raw (unnormalized) peak mass: the split must preserve
      // measurably more evidence.
      final folded = [
        _s('A', 'B', 10.0, 0.0, 0.0),
        _s('C', 'D', 10.0, 0.0, 0.0),
      ];
      final rawSplit = tracker.rtiImage(
          samples: samples,
          nodes: nodes,
          dipThreshold: 3.0,
          normalize: false);
      final rawControl = tracker.rtiImage(
          samples: folded,
          nodes: nodes,
          dipThreshold: 3.0,
          normalize: false);
      expect(_peak(rawSplit).v,
          greaterThan(_peak(rawControl).v * 1.1),
          reason:
              'direction split must preserve measurably more evidence');
    });

    test('measurement rows stack 2 per link (dip + rise)', () {
      final tracker = Tracker();
      final nodes = {'A': _n('A', 0, 0), 'B': _n('B', 40, 0)};
      final rows = tracker.imagingRows(
        samples: [_s('A', 'B', 10.0, 2.0, 4.0)],
        nodes: nodes,
        dipThreshold: 3.0,
      );
      expect(rows, hasLength(2));
      expect(rows.map((r) => r.direction).toSet(), {'dip', 'rise'});
      // p^δ = 1 − exp(−β^δ·|Δr^δ|).
      final dip = rows.firstWhere((r) => r.direction == 'dip');
      final rise = rows.firstWhere((r) => r.direction == 'rise');
      expect(dip.prob, closeTo(1 - math.exp(-0.12 * 10.0), 1e-9));
      final betaPlus = 0.18 * math.exp(4.0 / 13.0);
      expect(rise.prob, closeTo(1 - math.exp(-betaPlus * 2.0), 1e-9));
      expect(dip.lambdaM, lessThan(rise.lambdaM),
          reason:
              'anti-fade link: tight dip ellipse, diffuse rise ellipse');
    });
  });

  group('area normalization', () {
    test('beats 1/sqrt(d) by ≥2× peak-to-sidelobe', () {
      final tracker = Tracker();
      final nodes = {
        'A': _n('A', 15, 0),
        'B': _n('B', 25, 0),
        'C': _n('C', 20, -20),
        'D': _n('D', 20, 20),
      };
      // Truth (20.5, 0.5): on the SHORT anti-fade link A→B (10 m,
      // small dip ellipse) and on the deep-fade link C→D (40 m,
      // large diffuse dip ellipse).
      final samples = [
        _s('A', 'B', 10.0, 0.0, 8.0), // small ellipse
        _s('C', 'D', 10.0, 0.0, -16.0), // large ellipse
      ];
      const tx = 20.5, ty = -0.5;
      // Raw (unnormalized) masses: the comparison is about evidence
      // concentration, not the 0..1 display scaling.
      final area = tracker.rtiImage(
        samples: samples,
        nodes: nodes,
        dipThreshold: 3.0,
        scheme: WeightScheme.area,
        normalize: false,
      );
      final ctrl = tracker.rtiImage(
        samples: samples,
        nodes: nodes,
        dipThreshold: 3.0,
        scheme: WeightScheme.invSqrtDist,
        normalize: false,
      );
      final p2sArea = _p2s(area, tx, ty, 6.0);
      final p2sCtrl = _p2s(ctrl, tx, ty, 6.0);
      expect(p2sArea, greaterThanOrEqualTo(2 * p2sCtrl),
          reason: 'area normalization must sharpen ≥2× vs 1/√d '
              '(area $p2sArea vs control $p2sCtrl)');
      // The peak sits inside the small ellipse, not smeared across
      // the large one.
      final (centroid, _) = _centroid(area);
      expect(_dist(centroid.x, centroid.y, tx, ty),
          lessThanOrEqualTo(6.0),
          reason: 'small ellipse spans ±5 m; the 40 m diffuse ellipse '
              'spans ±19 m');
    });
  });

  group('channel diversity', () {
    test('diversity beats best-single-band selection', () {
      // The paper's CONFIRMED diversity result, relative form: each
      // band fades a different third of the links (independent
      // frequency-selective fading); combining bands recovers the
      // geometry no single band sees. 6 nodes / 15 links, truth
      // crossing at y=25.
      final tracker = Tracker();
      final nodes = {
        'A': _n('A', 0, 0),
        'B': _n('B', 30, 0),
        'C': _n('C', 45, 25),
        'D': _n('D', 30, 50),
        'E': _n('E', 0, 50),
        'F': _n('F', -15, 25),
      };
      final ids = nodes.keys.toList();
      final links = <(String, String)>[];
      for (var i = 0; i < ids.length; i++) {
        for (var j = i + 1; j < ids.length; j++) {
          links.add((ids[i], ids[j]));
        }
      }
      // Deterministic per-band fading + amplitude noise (seeded).
      double noise(int band, int link, int step) {
        var h = band * 7919 + link * 104729 + step * 1299709;
        h = (h ^ (h >> 13)) * 1274126177;
        h = h ^ (h >> 16);
        return ((h & 0xffffff) / 0xffffff - 0.5) * 0.6;
      }

      double distPtSeg(double px, double py, NodePosition a,
          NodePosition b) {
        final abx = b.x - a.x, aby = b.y - a.y;
        var t = ((px - a.x) * abx + (py - a.y) * aby) /
            (abx * abx + aby * aby);
        t = t.clamp(0.0, 1.0);
        final cx = a.x + abx * t - px, cy = a.y + aby * t - py;
        return math.sqrt(cx * cx + cy * cy);
      }

      double errFor(List<LinkSample> ss, double tx, double ty) {
        final img = tracker.rtiImage(
          samples: ss,
          nodes: nodes,
          dipThreshold: 3.0,
          cellM: 3.0,
          bandOf: (_) => 'mesh',
        );
        if (img.isEmpty) return double.infinity;
        final (c, _) = _centroid(img);
        return _dist(c.x, c.y, tx, ty);
      }

      const steps = 10;
      final bandErrs = [for (var b = 0; b < 4; b++) <double>[]];
      final divErrs = <double>[];
      for (var step = 0; step < steps; step++) {
        final tx = -10.0 + step * 5.0, ty = 25.0;
        List<LinkSample> bandSamples(int band) => [
              for (var li = 0; li < links.length; li++)
                _s(
                  links[li].$1,
                  links[li].$2,
                  math.max(
                      0.0,
                      12 *
                              math.exp(-math.pow(
                                  distPtSeg(tx, ty, nodes[links[li].$1]!,
                                      nodes[links[li].$2]!) /
                                  10,
                                  2)) *
                              // Band-selective fading: each band loses
                              // a different third of its links.
                              ((li + band) % 3 == 0 ? 0.02 : 1.0) *
                              (1 + noise(band, li, step))),
                  0.0,
                  5.0,
                  i: step * 10 + band,
                ),
            ];
        final divSamples = [
          for (var b = 0; b < 4; b++) ...bandSamples(b),
        ];
        divErrs.add(errFor(divSamples, tx, ty));
        for (var b = 0; b < 4; b++) {
          bandErrs[b].add(errFor(bandSamples(b), tx, ty));
        }
      }
      // Best-single-band selection, realistic form: the operator picks
      // ONE band (lowest mean error) and flies it for the whole track.
      var selBand = 0;
      var selMean = double.infinity;
      for (var b = 0; b < 4; b++) {
        final m =
            bandErrs[b].reduce((a, e) => a + e) / steps;
        if (m < selMean) {
          selMean = m;
          selBand = b;
        }
      }
      var diversityWins = 0;
      for (var step = 0; step < steps; step++) {
        if (divErrs[step] <= bandErrs[selBand][step]) diversityWins++;
      }
      expect(diversityWins / steps, greaterThanOrEqualTo(0.8),
          reason: 'diversity must win on ≥80% of track points '
              '(relative win only — mirrors the paper)');
    });
  });

  group('parameter refit', () {
    test('refitFromCalibration keeps the physical monotonicity', () {
      // Synthetic calibration crossings: deeper fade → larger
      // diffuse-direction (λ⁻-style) ellipses.
      final points = [
        for (final f in [-8.0, -4.0, 0.0, 4.0, 8.0])
          ImagingFitPoint(
            fadeDb: f,
            lambdaMinus: 5.0 * math.exp(f / -8.0),
            lambdaPlus: 0.5 * math.exp(f / 80.0),
            betaMinus: 0.12,
            betaPlus: 0.18 * math.exp(f / 13.0),
          ),
      ];
      final refit =
          ImagingBandParams.defaults().refitFrom(points);
      expect(refit.lambdaMinus(-8.0), greaterThan(refit.lambdaMinus(0)));
      expect(refit.lambdaMinus(0), greaterThan(refit.lambdaMinus(8.0)));
      // Values are fitted, not the paper's Table I numbers.
      expect(refit.bMinus, isNot(closeTo(0.2112, 1e-6)));
      expect(refit.kMinus, isNot(closeTo(-5.7874, 1e-6)));
    });

    test('refit with <3 points returns params unchanged', () {
      final d = ImagingBandParams.defaults();
      final r = d.refitFrom(const [
        ImagingFitPoint(
            fadeDb: 0,
            lambdaMinus: 1,
            lambdaPlus: 1,
            betaMinus: 0.1,
            betaPlus: 0.2),
      ]);
      expect(r.bMinus, d.bMinus);
      expect(r.kMinus, d.kMinus);
    });

    test('tracker stores per-band tables', () {
      final tracker = Tracker();
      final custom = ImagingBandParams.defaults()
          .refitFrom([
        for (final f in [-8.0, 0.0, 8.0])
          ImagingFitPoint(
              fadeDb: f,
              lambdaMinus: 5.0 * math.exp(f / -8.0),
              lambdaPlus: 0.5,
              betaMinus: 0.12,
              betaPlus: 0.18),
      ]);
      tracker.setImagingBand('433', custom);
      expect(tracker.imagingBands['433']!.bMinus,
          closeTo(custom.bMinus, 1e-12));
      expect(tracker.imagingBands['mesh']!.bMinus,
          closeTo(ImagingBandParams.defaults().bMinus, 1e-12));
    });
  });

  group('sparsity stress', () {
    test('6-node/15-link crossing localizes; ablation is robust', () {
      final tracker = Tracker();
      final nodes = {
        'A': _n('A', 0, 0),
        'B': _n('B', 30, 0),
        'C': _n('C', 45, 25),
        'D': _n('D', 30, 50),
        'E': _n('E', 0, 50),
        'F': _n('F', -15, 25),
      };
      final ids = nodes.keys.toList();
      final links = <(String, String)>[];
      for (var i = 0; i < ids.length; i++) {
        for (var j = i + 1; j < ids.length; j++) {
          links.add((ids[i], ids[j]));
        }
      }
      expect(links, hasLength(15));

      double distPtSeg(double px, double py, NodePosition a,
          NodePosition b) {
        final abx = b.x - a.x, aby = b.y - a.y;
        var t = ((px - a.x) * abx + (py - a.y) * aby) /
            (abx * abx + aby * aby);
        t = t.clamp(0.0, 1.0);
        final cx = a.x + abx * t - px, cy = a.y + aby * t - py;
        return math.sqrt(cx * cx + cy * cy);
      }

      List<LinkSample> samplesFor(double tx, double ty,
          {Set<(String, String)>? skip}) {
        final out = <LinkSample>[];
        for (final l in links) {
          if (skip != null && skip.contains(l)) continue;
          final d = distPtSeg(tx, ty, nodes[l.$1]!, nodes[l.$2]!);
          out.add(_s(l.$1, l.$2,
              12 * math.exp(-math.pow(d / 10, 2)), 0.0, 5.0));
        }
        return out;
      }

      var within3m = 0;
      const fixes = 10;
      final centroids = <(double, double)>[];
      for (var k = 0; k < fixes; k++) {
        final tx = -10.0 + k * 5.0, ty = 25.0;
        final img = tracker.rtiImage(
          samples: samplesFor(tx, ty),
          nodes: nodes,
          dipThreshold: 3.0,
          cellM: 3.0,
        );
        expect(img, isNotEmpty);
        final (c, _) = _centroid(img);
        centroids.add((c.x, c.y));
        if (_dist(c.x, c.y, tx, ty) <= 3.0) within3m++;
      }
      expect(within3m / fixes, greaterThanOrEqualTo(0.7),
          reason: 'centroid within 3 m of truth on ≥70% of fixes');

      // Ablation: remove the strongest link mid-crossing; the centroid
      // must not jump more than 3 m (robustness, not accuracy).
      const tx = 15.0, ty = 25.0;
      final full = samplesFor(tx, ty);
      var strongest = full.first;
      for (final s in full) {
        if (s.deltaDown > strongest.deltaDown) strongest = s;
      }
      final ablated = samplesFor(tx, ty,
          skip: {(strongest.fromNode, strongest.toNode)});
      final (cFull, _) = _centroid(tracker.rtiImage(
          samples: full, nodes: nodes, dipThreshold: 3.0, cellM: 3.0));
      final (cAbl, _) = _centroid(tracker.rtiImage(
          samples: ablated,
          nodes: nodes,
          dipThreshold: 3.0,
          cellM: 3.0));
      expect(_dist(cFull.x, cFull.y, cAbl.x, cAbl.y),
          lessThanOrEqualTo(3.0),
          reason: 'no single link may dominate the image');
    });
  });

  group('honesty contract', () {
    test('RTI label is estimated/disturbance language', () {
      expect(rtiImageLabel,
          'ESTIMATED DISTURBANCE LOCATION (GROUND PROJECTION)');
      expect(rtiImageLabel, contains('ESTIMATED'));
      for (final banned in ['LOCATED', 'IDENTIFIED', 'CONFIRMED']) {
        expect(rtiImageLabel.contains(banned), isFalse,
            reason: 'banned word $banned in RTI label');
      }
    });

    test('tracking screen has no located/identified/confirmed claims',
        () {
      final path = _libPath('lib/screens/tracking.dart');
      final lines = File(path).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final code = lines[i].split('//')[0]; // strip line comments
        for (final banned in ['LOCATED', 'IDENTIFIED', 'CONFIRMED']) {
          expect(code.contains(banned), isFalse,
              reason: '$banned on tracking.dart:${i + 1}');
        }
      }
    });
  });

  group('Fresnel release gate', () {
    test('no Fresnel-zone weighting code in the imaging path', () {
      // Scope: the RTI imaging path (tracker, tripwire, ARTI, the
      // tracking screen, app_state). beam.dart draws first-Fresnel
      // ellipsoids as a 3D *visualization* of the sensitive region —
      // that is display, not RTI link weighting, and out of scope.
      // Comments are stripped: documenting the open question is not
      // implementing it.
      var hits = 0;
      for (final f in [
        'lib/services/tracker.dart',
        'lib/services/tripwire.dart',
        'lib/services/adaptive_baseline.dart',
        'lib/screens/tracking.dart',
        'lib/state/app_state.dart',
      ]) {
        var inBlock = false;
        for (final line in File(_libPath(f)).readAsLinesSync()) {
          var code = line;
          if (inBlock) {
            final end = code.indexOf('*/');
            if (end < 0) continue;
            code = code.substring(end + 2);
            inBlock = false;
          }
          final start = code.indexOf('/*');
          if (start >= 0) {
            final end = code.indexOf('*/', start + 2);
            if (end >= 0) {
              code = code.substring(0, start) + code.substring(end + 2);
            } else {
              code = code.substring(0, start);
              inBlock = true;
            }
          }
          code = code.split('//')[0];
          if (code.toLowerCase().contains('fresnel')) hits++;
        }
      }
      expect(hits, 0,
          reason: 'Fresnel-zone weighting code found in the imaging '
              'path — the open question stays a question');
    });
  });
}

/// Package root from the test file's location. `Platform.script`
/// resolves differently under `flutter test` vs standalone dart, so
/// both layouts are tried.
String _libPath(String rel) {
  final testFile = Platform.script.toFilePath();
  final testDir = File(testFile).parent.path;
  for (final base in ['$testDir/../', '$testDir/']) {
    final p = '$base$rel';
    if (File(p).existsSync()) return p;
  }
  return '$testDir/../$rel';
}
