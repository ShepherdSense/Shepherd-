import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/models/tracking.dart';
import 'package:shepherd/services/adaptive_baseline.dart';

NodePosition _n(String id, double x, double y) =>
    NodePosition(nodeId: id, x: x, y: y);

Map<String, NodePosition> _mesh() => {
      'A': _n('A', 0, 0),
      'B': _n('B', 60, 0),
      'C': _n('C', 30, 50),
    };

TrackEstimate _track(double x, double y, double speed) => TrackEstimate(
      timestamp: DateTime(2026, 1, 1, 12),
      x: x,
      y: y,
      speedMps: speed,
      sizeClass: 'M',
      typeGuess: 'test',
      typeConfidence: 0.3,
      linksUsed: 2,
      relation: 'TRANSITING',
    );

List<ArtiSample> _samples(
    List<String> links, double Function(String link) level) => [
      for (final l in links)
        for (final dir in const ['dip', 'rise'])
          ArtiSample(
            linkKey: l,
            channel: 'mesh',
            direction: dir,
            level: level(l),
            madThreshold: 3.0,
          ),
    ];

double _muOf(AdaptiveBaseline ab, String link, String dir) =>
    ab.entries['$link@mesh@$dir']!.mu;

void main() {
  group('BandWavelength', () {
    test('uses true physical wavelengths, never the paper 0.05 m', () {
      // λ = c/f: 0.125 m @ 2.4 GHz, 0.33 m @ 915 MHz, 0.69 m @ 433 MHz.
      expect(BandWavelength.meters(2400), closeTo(0.125, 0.002));
      expect(BandWavelength.meters(915), closeTo(0.328, 0.003));
      expect(BandWavelength.meters(433.92), closeTo(0.691, 0.003));
      expect(BandWavelength.meters(2400), isNot(closeTo(0.05, 0.01)));
    });

    test('band labels resolve to the right band', () {
      expect(BandWavelength.forBandLabel('433'), 433.92);
      expect(BandWavelength.forBandLabel('915'), 915.0);
      expect(BandWavelength.forBandLabel('2437'), 2437.0);
      expect(BandWavelength.forBandLabel('5780'), 5780.0);
    });
  });

  group('ARTI anti-blend', () {
    test('near-link mu ignores the target; far-link mu tracks drift',
        () {
      final ab = AdaptiveBaseline();
      final nodes = _mesh();
      const base = -70.0;
      const driftPerStep = 0.5 / 60; // 0.5 dB/min, 1 s steps
      var t = 0;

      double level(String link, double? dipDb) =>
          base + driftPerStep * t - (dipDb ?? 0);

      // Phase 1: vacant, 20 steps — both links learn the drifting level.
      for (var i = 0; i < 20; i++, t++) {
        ab.update(
          now: DateTime(2026, 1, 1, 12, 0, t),
          samples: _samples(['A → B', 'A → C'], (l) => level(l, null)),
          tracks: const [],
          nodes: nodes,
        );
      }
      final muNearVacant = _muOf(ab, 'A → B', 'dip');

      // Phase 2: crossing — target walks x=30 from y=-5 to y=5 at
      // 1 m/s. Link A→B is near for |y| ≲ 2.7 m (2λ = 0.25 m);
      // link A→C stays far throughout. The dip is injected only
      // while the link is geometrically near.
      for (var k = 0; k <= 20; k++, t++) {
        final y = -5.0 + k * 0.5;
        final near = y.abs() <= 2.5;
        ab.update(
          now: DateTime(2026, 1, 1, 12, 0, t),
          samples: _samples(['A → B', 'A → C'],
              (l) => level(l, l == 'A → B' && near ? 8.0 : null)),
          tracks: [_track(30, y, 1.0)],
          nodes: nodes,
        );
      }

      // The target never contaminates its own reference: near-link mu
      // tracks the TRUE drifting level, not the 8 dB dips.
      final trueLevel = base + driftPerStep * t;
      expect((_muOf(ab, 'A → B', 'dip') - trueLevel).abs(),
          lessThan(0.5));
      // …and it barely moved during the pass itself (no blending).
      expect((_muOf(ab, 'A → B', 'dip') - muNearVacant).abs(),
          lessThan(0.5));
      // Far-link mu tracks the injected drift within 0.3 dB.
      expect((_muOf(ab, 'A → C', 'dip') - trueLevel).abs(),
          lessThan(0.3));
      // The anti-blend rule fired: near samples updated phi, not mu.
      expect(ab.stats.gatedNear, greaterThan(0));
      expect(ab.stats.updated, greaterThan(0));
    });

    test('no-calibration startup: first sample becomes mu', () {
      final ab = AdaptiveBaseline();
      ab.update(
        now: DateTime(2026, 1, 1, 12),
        samples: const [
          ArtiSample(
              linkKey: 'A → B',
              channel: 'mesh',
              direction: 'dip',
              level: -72.5,
              madThreshold: 3.0),
        ],
        tracks: const [],
        nodes: _mesh(),
      );
      expect(ab.muFor('A → B', 'mesh', 'dip'), closeTo(-72.5, 1e-9));
    });
  });

  group('phi sign convergence', () {
    test('wrongly-signed phi self-corrects within one pass', () {
      final ab = AdaptiveBaseline();
      final nodes = _mesh();
      final links = [for (var i = 0; i < 10; i++) 'N$i → M$i'];
      for (var i = 0; i < 10; i++) {
        nodes['N$i'] = _n('N$i', i * 10.0, 0);
        nodes['M$i'] = _n('M$i', i * 10.0, 40);
      }
      // Learn the quiet level first (no-calibration startup: the
      // first sample becomes mu — the disturbance must come after).
      // Far links update mu only, so phi stays at phi0 = −1e-3: the
      // dip-side entries are correctly signed, the rise-side entries
      // start WRONGLY signed (the paper's ~1/3 observation).
      for (var i = 0; i < 5; i++) {
        ab.update(
          now: DateTime(2026, 1, 1, 11, 59, i),
          samples: _samples(links, (_) => -70.0),
          tracks: const [],
          nodes: nodes,
        );
      }
      for (final l in links) {
        expect(ab.phiSignFor(l, 'mesh', 'rise'), -1);
      }
      // One pass of consistent dips, target on each link midpoint.
      for (var step = 0; step < 12; step++) {
        ab.update(
          now: DateTime(2026, 1, 1, 12, 0, step),
          samples: _samples(links, (_) => -78.0), // 8 dB dip
          tracks: [
            for (var i = 0; i < 10; i++) _track(i * 10.0, 20.0, 2.0),
          ],
          nodes: nodes,
        );
      }
      var dipCorrect = 0;
      for (final l in links) {
        if (ab.phiSignFor(l, 'mesh', 'dip') == -1) dipCorrect++;
      }
      expect(dipCorrect / links.length, greaterThanOrEqualTo(0.9));
      // One pass of consistent rises: the wrongly-signed rise entries
      // self-correct.
      for (var step = 0; step < 12; step++) {
        ab.update(
          now: DateTime(2026, 1, 1, 12, 1, step),
          samples: _samples(links, (_) => -62.0), // 8 dB rise
          tracks: [
            for (var i = 0; i < 10; i++) _track(i * 10.0, 20.0, 2.0),
          ],
          nodes: nodes,
        );
      }
      var riseCorrect = 0;
      for (final l in links) {
        if (ab.phiSignFor(l, 'mesh', 'rise') == 1) riseCorrect++;
      }
      expect(riseCorrect / links.length, greaterThanOrEqualTo(0.9));
    });
  });

  group('loiter freeze', () {
    test('stationary target freezes all mu/phi updates', () {
      final ab = AdaptiveBaseline();
      final nodes = _mesh();
      // Learn a reference first (vacant).
      for (var i = 0; i < 10; i++) {
        ab.update(
          now: DateTime(2026, 1, 1, 12, 0, i),
          samples: _samples(['A → B'], (_) => -70.0),
          tracks: const [],
          nodes: nodes,
        );
      }
      final muBefore = _muOf(ab, 'A → B', 'dip');
      final phiBefore =
          ab.entries['A → B@mesh@dip']!.phi;
      // 5 min loiter at 0.1 m/s (below the 0.2 m/s gate) with injected
      // drift: the estimator must refuse to learn.
      for (var i = 0; i < 300; i++) {
        ab.update(
          now: DateTime(2026, 1, 1, 12, 1, i),
          samples: _samples(
              ['A → B'], (_) => -70.0 + 0.5 / 60 * i - 8.0),
          tracks: [_track(30, 0, 0.1)],
          nodes: nodes,
        );
      }
      expect(_muOf(ab, 'A → B', 'dip'), equals(muBefore));
      expect(ab.entries['A → B@mesh@dip']!.phi, equals(phiBefore));
      expect(ab.stats.gatedMotion, 600); // 300 steps × 2 directions
      // Post-loiter mu is the pre-loiter mu: the baseline never
      // absorbed the disturbance.
      expect((_muOf(ab, 'A → B', 'dip') - muBefore).abs(),
          lessThan(0.5));
    });
  });

  group('divergence safeguard', () {
    test('runaway mu is marked suspect and frozen', () {
      final ab = AdaptiveBaseline();
      final nodes = _mesh();
      ab.register(
          linkKey: 'A → B', channel: 'mesh', direction: 'dip', mu0: -70);
      // 10 dB step drift, vacant (gates open).
      var suspectAt = -1;
      double? muAtSuspect;
      for (var i = 0; i < 30; i++) {
        ab.update(
          now: DateTime(2026, 1, 1, 12, 0, i),
          samples: _samples(['A → B'], (_) => -60.0),
          tracks: const [],
          nodes: nodes,
        );
        if (ab.entries['A → B@mesh@dip']!.suspect && suspectAt < 0) {
          suspectAt = i;
          muAtSuspect = _muOf(ab, 'A → B', 'dip');
        }
      }
      expect(suspectAt, greaterThanOrEqualTo(0));
      expect(suspectAt, lessThan(30));
      expect(ab.suspectLinkKeys, contains('A → B'));
      expect(ab.stats.suspectLinks, contains('A → B'));
      // Frozen: further updates change nothing.
      for (var i = 30; i < 40; i++) {
        ab.update(
          now: DateTime(2026, 1, 1, 12, 0, i),
          samples: _samples(['A → B'], (_) => -60.0),
          tracks: const [],
          nodes: nodes,
        );
      }
      expect(_muOf(ab, 'A → B', 'dip'), equals(muAtSuspect));
      // muFor refuses suspect entries (callers must not trust them).
      expect(ab.muFor('A → B', 'mesh', 'dip'), isNull);
    });
  });

  group('mobility recompute', () {
    test('node motion > 1 m recomputes the far/near split', () {
      final ab = AdaptiveBaseline();
      final nodes = {
        'A': _n('A', 0, 0),
        'B': _n('B', 60, 0),
      };
      // Track sits where node B will move TO: far from the old link
      // (excess path 3.0 m), on the new link (excess path 0).
      final t = _track(61.5, 0, 5.0);
      ab.update(
        now: DateTime(2026, 1, 1, 12),
        samples: _samples(['A → B'], (_) => -70.0),
        tracks: [t],
        nodes: nodes,
      );
      expect(ab.stats.geomRecompute, 0);
      final updatedBefore = ab.stats.updated;
      final muBefore = _muOf(ab, 'A → B', 'dip');

      // Node B moves 3 m mid-track.
      nodes['B'] = _n('B', 63, 0);
      ab.update(
        now: DateTime(2026, 1, 1, 12, 0, 1),
        samples: _samples(['A → B'], (_) => -70.0),
        tracks: [t],
        nodes: nodes,
      );
      // Recompute triggered and logged…
      expect(ab.stats.geomRecompute, 1);
      // …and the split followed the NEW geometry: the link is near
      // now, so mu is untouched (anti-blend) instead of updated.
      expect(ab.stats.updated, updatedBefore);
      expect(ab.stats.gatedNear, greaterThan(0));
      expect(_muOf(ab, 'A → B', 'dip'), equals(muBefore));
    });
  });

  group('guided routine', () {
    test('names the worst node and anchors mu_calib', () {
      final ab = AdaptiveBaseline();
      final nodes = {
        'X': _n('X', 0, 0),
        'A': _n('A', 20, 0),
        'B': _n('B', 0, 20),
        'C': _n('C', 20, 20),
      };
      ab.beginGuidedCalibration();
      // One deliberately deep-fade node: X's links sit 30 dB below.
      final levels = {
        'X → A': -90.0,
        'X → B': -90.0,
        'X → C': -90.0,
        'A → B': -60.0,
        'A → C': -60.0,
        'B → C': -60.0,
      };
      for (var i = 0; i < 30; i++) {
        for (final e in levels.entries) {
          ab.observeCalibration(
              linkKey: e.key, channel: 'mesh', rssi: e.value);
        }
      }
      ab.nudgeRound();
      ab.nudgeRound();
      final rec = ab.finishGuidedCalibration(
          nodes: nodes, vacantSecs: 30);
      expect(rec, isNotNull);
      expect(rec!.rounds, 2);
      expect(rec.degraded, isFalse);
      // The routine names the right node: worst links first.
      final worst = rec.worstFirst.take(3).toList();
      expect(worst.every((l) => l.link.startsWith('X → ')), isTrue);
      // Anchors are set: mu_calib ≈ the static mean.
      expect(ab.entries['X → A@mesh@dip']!.muCalib,
          closeTo(-90.0, 0.5));
      expect(ab.suspectLinkKeys, isEmpty);
      // Schema check.
      final j = rec.toJson();
      expect(j['kind'], 'calibration');
      expect(j['vacant_s'], 30);
      expect((j['links'] as List).length, 6);
      expect((j['pathloss'] as Map)['rmse_db'], isNotNull);
    });

    test('degraded mode says so', () {
      final ab = AdaptiveBaseline();
      ab.beginGuidedCalibration(degraded: true);
      ab.observeCalibration(
          linkKey: 'A → B', channel: 'mesh', rssi: -70.0);
      final rec = ab.finishGuidedCalibration(
          nodes: _mesh(), vacantSecs: 5);
      expect(rec!.degraded, isTrue);
      expect(rec.toJson()['degraded'], isTrue);
    });

    test('empty routine returns null and anchors nothing', () {
      final ab = AdaptiveBaseline();
      ab.beginGuidedCalibration();
      expect(
          ab.finishGuidedCalibration(nodes: _mesh(), vacantSecs: 0),
          isNull);
    });

    test('anchors reset PRE-EXISTING drifted entries (B1 regression)',
        () {
      // Reviewer repro: 30 drifted updates learn mu = −60; then the
      // guided routine measures a fresh vacant mean of −72. Both mu
      // and muCalib must become −72 — not stay at the drifted −60.
      final ab = AdaptiveBaseline();
      final nodes = _mesh();
      const link = 'A → B';
      for (var i = 0; i < 30; i++) {
        ab.update(
          now: DateTime(2026, 1, 1, 11, 0, i),
          samples: _samples([link], (_) => -60.0),
          tracks: const [], // vacant: mu learns the drifted level
          nodes: nodes,
        );
      }
      expect(_muOf(ab, link, 'dip'), closeTo(-60.0, 0.5));
      expect(ab.entries['$link@mesh@dip']!.muCalib,
          closeTo(-60.0, 0.5));

      ab.beginGuidedCalibration();
      for (var i = 0; i < 20; i++) {
        ab.observeCalibration(
            linkKey: link, channel: 'mesh', rssi: -72.0);
      }
      final rec =
          ab.finishGuidedCalibration(nodes: nodes, vacantSecs: 30);
      expect(rec, isNotNull);

      // The anchor actually landed: mu follows the fresh vacant mean.
      expect(ab.muFor(link, 'mesh', 'dip'), closeTo(-72.0, 1e-9));
      expect(ab.muFor(link, 'mesh', 'rise'), closeTo(-72.0, 1e-9));
      expect(ab.entries['$link@mesh@dip']!.muCalib,
          closeTo(-72.0, 1e-9));
      expect(ab.entries['$link@mesh@rise']!.muCalib,
          closeTo(-72.0, 1e-9));
      expect(ab.suspectLinkKeys, isEmpty);
    });
  });

  group('batch refit export', () {
    test('exports buffered telemetry with the offline procedure', () {
      final ab = AdaptiveBaseline();
      ab.recordTelemetry = true;
      final nodes = _mesh();
      for (var i = 0; i < 5; i++) {
        ab.update(
          now: DateTime(2026, 1, 1, 12, 0, i),
          samples: _samples(['A → B'], (_) => -70.0),
          tracks: [_track(30, 0, 2.0)],
          nodes: nodes,
        );
      }
      final ex = ab.exportRefitTelemetry();
      expect(ex['kind'], 'refit_telemetry');
      expect((ex['points'] as List).length, 10); // 5 steps × 2 dirs
      expect(ex['procedure'], contains('Nelder'));
      expect(ex['procedure'], contains('Never run live'));
      ab.clearTelemetry();
      expect(
          (ab.exportRefitTelemetry()['points'] as List), isEmpty);
    });
  });

  group('expectedDirectionSign', () {
    test('unknown link abstains (0)', () {
      final ab = AdaptiveBaseline();
      expect(ab.expectedDirectionSign('NOPE → NOPE'), 0);
    });

    test('learned dip sign beats the static rule', () {
      final ab = AdaptiveBaseline();
      final nodes = _mesh();
      for (var i = 0; i < 5; i++) {
        ab.update(
          now: DateTime(2026, 1, 1, 11, 59, i),
          samples: _samples(['A → B'], (_) => -70.0),
          tracks: const [],
          nodes: nodes,
        );
      }
      for (var i = 0; i < 12; i++) {
        ab.update(
          now: DateTime(2026, 1, 1, 12, 0, i),
          samples: _samples(['A → B'], (_) => -78.0),
          tracks: [_track(30, 0, 2.0)],
          nodes: nodes,
        );
      }
      // Net phi is dip-side ⇒ expect dip (+1).
      expect(ab.expectedDirectionSign('A → B'), 1);
    });
  });

  group('ArtiStats schema', () {
    test('toJson carries the spec fields', () {
      final ab = AdaptiveBaseline();
      final j = ab.stats.toJson(DateTime(2026, 1, 1, 12));
      expect(j['v'], 1);
      expect(j['kind'], 'arti_stats');
      for (final k in [
        'gated_residual',
        'gated_motion',
        'gated_near',
        'updated',
        'suspect_links',
        'max_mu_drift_db',
        'geom_recompute'
      ]) {
        expect(j.containsKey(k), isTrue, reason: 'missing $k');
      }
    });
  });
}
