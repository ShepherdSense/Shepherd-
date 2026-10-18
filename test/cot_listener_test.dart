/// Tests for the Shepherd CoT ingest listener
/// (docs/predator_integration_spec.md — Shepherd side only).
///
/// Load-bearing invariants:
///  1. Sample Predator-style CoT -> emitter observation extracted.
///  2. Non-matching callsign prefixes ignored.
///  3. Malformed XML dropped silently (never throws out of handleDatagram).
///  4. Stale observations dropped -> no coincidence.
///  5. In-radius fresh emitter -> 1 coincidence, boost 0.10, freshness ~1.
///  6. Out-of-radius emitter -> empty.
///  7. Emitter with no tracks -> empty, and NO track is ever created here.
///  8. Never-subtractive is structural: every emitted coincidence has
///     boost >= 0 (the merger never sees a negative).
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/services/confidence_merger.dart';
import 'package:shepherd/services/cot_listener.dart';
import 'package:shepherd/services/geo_projection.dart';

final DateTime t0 = DateTime.utc(2026, 10, 18, 19, 35, 0);

String _event({
  String callsign = 'PREDATOR-FHSS2G4',
  String uid = 'PREDATOR-FHSS2G4',
  String type = 'a-u-S',
  DateTime? time,
  double lat = 35.052100,
  double lon = -78.878900,
  String? ce,
  String extraPoint = '',
}) {
  final ts = (time ?? DateTime.now().toUtc()).toIso8601String();
  final ceAttr = ce == null ? '' : ' ce="$ce"';
  return '<event version="2.0" uid="$uid" type="$type"'
      ' time="$ts" start="$ts" stale="$ts" how="m-g">'
      '<point lat="$lat" lon="$lon" hae="0.0"$ceAttr le="25.0"$extraPoint/>'
      '<detail>'
      '<contact callsign="$callsign"/>'
      '<remarks>FHSS emitter 2.4 GHz</remarks>'
      '</detail>'
      '</event>';
}

CotListener _listener() =>
    CotListener(config: const CotListenerConfig(enabled: true));

void main() {
  group('CoT parsing', () {
    // Event times are anchored to the real clock because activeEmitters
    // prunes against DateTime.now(); the 60 s window gives ample margin.
    DateTime now() => DateTime.now().toUtc();
    DateTime fresh(DateTime n) => n.subtract(const Duration(seconds: 5));

    test('sample Predator-style event -> observation extracted', () {
      final l = _listener();
      final n = now();
      l.handleDatagram(utf8.encode(_event(time: fresh(n))), n);
      final emitters = l.activeEmitters;
      expect(emitters.length, 1);
      final o = emitters.single;
      expect(o.callsign, 'PREDATOR-FHSS2G4');
      expect(o.lat, closeTo(35.052100, 1e-9));
      expect(o.lon, closeTo(-78.878900, 1e-9));
      expect(o.type, 'a-u-S');
      expect(o.ce, 25.0);
    });

    test('non-matching prefix (BEAST-X) ignored', () {
      final l = _listener();
      final n = now();
      l.handleDatagram(
          utf8.encode(_event(callsign: 'BEAST-X', uid: 'BEAST-X', time: fresh(n))),
          n);
      expect(l.activeEmitters, isEmpty);
    });

    test('malformed XML dropped without throwing', () {
      final l = _listener();
      final n = now();
      expect(() => l.handleDatagram(utf8.encode('<event version="'), n),
          returnsNormally);
      expect(() => l.handleDatagram([0xFF, 0xFE, 0x00, 0x41], n),
          returnsNormally);
      expect(
          () => l.handleDatagram(
              utf8.encode('<event><point lat="35" lon="-78"/></event>'), n),
          returnsNormally);
      expect(() => l.handleDatagram(utf8.encode(''), n), returnsNormally);
      expect(l.activeEmitters, isEmpty);
    });

    test('ce defaults to 25.0 when absent (documented default)', () {
      final l = _listener();
      final n = now();
      l.handleDatagram(utf8.encode(_event(ce: null, time: fresh(n))), n);
      expect(l.activeEmitters.single.ce, 25.0);
    });

    test('ce kept when present and parseable', () {
      final l = _listener();
      final n = now();
      l.handleDatagram(utf8.encode(_event(ce: '40.5', time: fresh(n))), n);
      expect(l.activeEmitters.single.ce, 40.5);
    });

    test('unparseable ce falls back to 25.0, not NaN', () {
      final l = _listener();
      final n = now();
      l.handleDatagram(utf8.encode(_event(ce: 'bogus', time: fresh(n))), n);
      expect(l.activeEmitters.single.ce, 25.0);
    });

    test('stale observation (> 60 s) dropped from activeEmitters', () {
      final l = _listener();
      final n = now();
      l.handleDatagram(
          utf8.encode(
              _event(time: n.subtract(const Duration(seconds: 61)))),
          n);
      expect(l.activeEmitters, isEmpty);
    });

    test('observation upserts on repeat events from the same emitter', () {
      final l = _listener();
      final n = now();
      l.handleDatagram(
          utf8.encode(_event(lat: 35.0, lon: -78.0, time: fresh(n))), n);
      l.handleDatagram(
          utf8.encode(_event(
              lat: 35.001,
              lon: -78.0,
              time: n.subtract(const Duration(seconds: 4)))),
          n);
      final emitters = l.activeEmitters;
      expect(emitters.length, 1);
      expect(emitters.single.lat, closeTo(35.001, 1e-9));
    });

    test('lat=999 (out of range) dropped', () {
      final l = _listener();
      final n = now();
      l.handleDatagram(
          utf8.encode(_event(lat: 999.0, time: fresh(n))), n);
      expect(l.activeEmitters, isEmpty);
    });

    test('lon=-999 (out of range) dropped', () {
      final l = _listener();
      final n = now();
      l.handleDatagram(
          utf8.encode(_event(lon: -999.0, time: fresh(n))), n);
      expect(l.activeEmitters, isEmpty);
    });

    test('prefix match is case-sensitive: predator-x ignored', () {
      final l = _listener();
      final n = now();
      // Default emitter prefix is 'PREDATOR-' (uppercase); a
      // lowercase callsign must not match.
      l.handleDatagram(
          utf8.encode(_event(
              callsign: 'predator-x', uid: 'predator-x', time: fresh(n))),
          n);
      expect(l.activeEmitters, isEmpty);
    });
  });

  group('coincidence', () {
    test('in-radius (30 m), fresh -> 1 coincidence, boost 0.10, freshness ~1',
        () {
      final l = _listener();
      final now = t0.add(const Duration(seconds: 2));
      l.handleDatagram(
          utf8.encode(_event(lat: 35.0, lon: -78.0, time: t0)), now);
      // Track 30 m north of the emitter.
      const track = TrackPosition(
          id: 'T1', lat: 35.0 + 30 / 110540.0, lon: -78.0);
      final coins = l.checkCoincidence([track], now);
      expect(coins.length, 1);
      final c = coins.single;
      expect(c.emitterCallsign, 'PREDATOR-FHSS2G4');
      expect(c.trackId, 'T1');
      expect(c.boost, 0.10);
      expect(c.freshness01, closeTo(1.0, 0.05));
      expect(c.distanceM, closeTo(30.0, 1.0));
    });

    test('out-of-radius (500 m) -> empty', () {
      final l = _listener();
      final now = t0.add(const Duration(seconds: 2));
      l.handleDatagram(
          utf8.encode(_event(lat: 35.0, lon: -78.0, time: t0)), now);
      const track = TrackPosition(
          id: 'T1', lat: 35.0 + 500 / 110540.0, lon: -78.0);
      expect(l.checkCoincidence([track], now), isEmpty);
    });

    test('stale emitter -> no coincidence', () {
      final l = _listener();
      // Observation arrives fresh, coincidence checked 2 minutes later.
      l.handleDatagram(
          utf8.encode(_event(lat: 35.0, lon: -78.0, time: t0)), t0);
      const track = TrackPosition(id: 'T1', lat: 35.0, lon: -78.0);
      expect(l.checkCoincidence([track], t0.add(const Duration(seconds: 120))),
          isEmpty);
    });

    test('emitter with zero tracks -> empty AND no track created', () {
      final l = _listener();
      // Anchored to the real clock: the observation must actually be
      // held (not pruned as stale) for the structural assertion below
      // to be meaningful.
      final n = DateTime.now().toUtc();
      l.handleDatagram(utf8.encode(_event(lat: 35.0, lon: -78.0, time: n)),
          n);
      // The observation IS held (the listener stores emitter evidence)
      // — but it must never become a track.
      expect(l.activeEmitters.length, 1);
      final tracks = <TrackPosition>[];
      final coins = l.checkCoincidence(tracks, n);
      expect(coins, isEmpty);
      expect(tracks, isEmpty,
          reason: 'the listener must never originate a track');
      // STRUCTURAL GUARANTEE (documented here; asserted behaviorally
      // above): the only thing CotListener stores is EmitterObservation
      // records keyed by callsign. Its public API surface —
      // handleDatagram, checkCoincidence, activeEmitters,
      // activeEmitterCount, start, stop, clear — exposes no
      // TrackEstimate-returning method and no mutable track list:
      // checkCoincidence only RETURNS EmitterCoincidence entries for
      // tracks the CALLER supplied. There is no code path in this
      // class that constructs a track.
      expect(l.activeEmitters.single.callsign, 'PREDATOR-FHSS2G4');
    });

    test('future-dated event -> no coincidence (age < 0 skipped)', () {
      final l = _listener();
      final n = DateTime.now().toUtc();
      // Event claims a time 60 s in the future: checkCoincidence must
      // never treat it as fresh corroboration.
      l.handleDatagram(
          utf8.encode(_event(
              lat: 35.0,
              lon: -78.0,
              time: n.add(const Duration(seconds: 60)))),
          n);
      const track = TrackPosition(id: 'T1', lat: 35.0, lon: -78.0);
      expect(l.checkCoincidence([track], n), isEmpty);
      // And the dashboard count must not include it either.
      expect(l.activeEmitterCount, 0);
    });

    test('disabled listener -> empty coincidence list', () {
      final l = CotListener(
          config: const CotListenerConfig(enabled: false));
      l.handleDatagram(
          utf8.encode(_event(lat: 35.0, lon: -78.0, time: t0)), t0);
      const track = TrackPosition(id: 'T1', lat: 35.0, lon: -78.0);
      expect(l.checkCoincidence([track], t0), isEmpty);
    });

    test('never-subtractive is structural: all boosts >= 0', () {
      final l = _listener();
      final now = t0.add(const Duration(seconds: 1));
      l.handleDatagram(
          utf8.encode(_event(lat: 35.0, lon: -78.0, time: t0)), now);
      const tracks = [
        TrackPosition(id: 'T1', lat: 35.0, lon: -78.0),
        TrackPosition(id: 'T2', lat: 35.0 + 10 / 110540.0, lon: -78.0),
      ];
      final coins = l.checkCoincidence(tracks, now);
      expect(coins, isNotEmpty);
      for (final c in coins) {
        expect(c.boost, greaterThanOrEqualTo(0.0),
            reason: 'corroboration must never subtract');
      }
    });

    test('freshness decays across the window', () {
      final l = _listener();
      l.handleDatagram(
          utf8.encode(_event(lat: 35.0, lon: -78.0, time: t0)),
          t0.add(const Duration(seconds: 30)));
      const track = TrackPosition(id: 'T1', lat: 35.0, lon: -78.0);
      final coins =
          l.checkCoincidence([track], t0.add(const Duration(seconds: 30)));
      expect(coins.length, 1);
      expect(coins.single.freshness01, closeTo(0.5, 0.01));
    });
  });

  group('listener + merger seam', () {
    // The app-layer helper (_emitterCoincidences) is private to
    // AppState, so this tests the seam it stands on: CotListener
    // coincidences -> GatedCorroboration -> mergeTrackConfidence.
    // The corroboration shape mirrors _emitterCoincidences exactly:
    // boost 0.10, gate weight = freshness.
    List<GatedCorroboration> toCorroborations(
            List<EmitterCoincidence> coins) =>
        [
          for (final c in coins)
            GatedCorroboration(
              sensorId: 'cot-emitter:${c.emitterCallsign}',
              boost: c.boost,
              gateWeight: c.freshness01,
            ),
        ];

    test('emitter disappears mid-track: merged confidence returns to '
        'base, never below', () {
      final l = _listener();
      final n = DateTime.now().toUtc();
      // Feed coincidence once: a fresh emitter exactly on the track.
      l.handleDatagram(
          utf8.encode(_event(lat: 35.0, lon: -78.0, time: n)), n);
      const track = TrackPosition(id: 'T1', lat: 35.0, lon: -78.0);
      const base = 0.55;

      var coins = l.checkCoincidence([track], n);
      expect(coins.length, 1);
      var merged = mergeTrackConfidence(
        baseConfidence: base,
        contributions: toCorroborations(coins),
        trackConsistent: true,
      );
      expect(merged.displayed, greaterThanOrEqualTo(base));
      expect(merged.upgrade, greaterThan(0.0),
          reason: 'the fresh coincidence must upgrade, never subtract');

      // The emitter goes quiet: 120 s later the observation is stale,
      // checkCoincidence yields nothing, and the displayed confidence
      // returns to base — never below it.
      final later = n.add(const Duration(seconds: 120));
      coins = l.checkCoincidence([track], later);
      expect(coins, isEmpty,
          reason: 'a stale emitter contributes zero corroboration');
      merged = mergeTrackConfidence(
        baseConfidence: base,
        contributions: toCorroborations(coins),
        trackConsistent: true,
      );
      expect(merged.displayed, base);
      expect(merged.displayed, greaterThanOrEqualTo(base),
          reason: 'the merger is never subtractive');
    });
  });

  group('haversineMeters', () {
    test('NYC -> LA within 1% of the known great-circle distance', () {
      // Known great-circle distance JFK-area to LAX-area ~ 3974 km;
      // city centers (40.7128,-74.0060) -> (34.0522,-118.2437) ~ 3935.7 km.
      final d = haversineMeters(40.7128, -74.0060, 34.0522, -118.2437);
      expect((d - 3935750).abs() / 3935750, lessThan(0.01));
    });

    test('zero distance and symmetry', () {
      expect(haversineMeters(35.0, -78.0, 35.0, -78.0), 0.0);
      final a = haversineMeters(35.0, -78.0, 36.0, -77.0);
      final b = haversineMeters(36.0, -77.0, 35.0, -78.0);
      expect(a, closeTo(b, 1e-9));
    });
  });

  group('GeoProjection inverse', () {
    test('metersToLatLon inverts latLonToMeters to centimeter precision',
        () {
      final p = GeoProjection(originLat: 35.0, originLon: -78.0);
      for (final xy in [
        (10.0, 20.0),
        (-150.5, 300.25),
        (0.0, 0.0),
        (499.9, -499.9),
      ]) {
        final geo = p.metersToLatLon(xy.$1, xy.$2);
        final back = p.latLonToMeters(geo.lat, geo.lon);
        expect(back.x, closeTo(xy.$1, 0.01));
        expect(back.y, closeTo(xy.$2, 0.01));
      }
    });
  });
}
