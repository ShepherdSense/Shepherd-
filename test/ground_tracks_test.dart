/// Tests for PRC-163 friendly GROUND tracks (v0.23.0):
/// lib/services/cot_listener.dart (`a-f-G*` platform ingest),
/// lib/services/airframe_identity.dart (GroundTrackRecord),
/// lib/services/simulated.dart (SimGroundFeed).
///
/// The contract under test, per docs/prc163_ground_tracks_spec.md:
///  - ground events enter the platform path BY TYPE and carry
///    their domain off the type string;
///  - ground observations become ground records, NEVER airframe
///    records (a dismount is not a drone — the Drone tab reads
///    air records only, so it structurally cannot select one);
///  - labels: FRIENDLY (FEED) from the feed, FRIENDLY on a
///    registry match;
///  - pruning: feed-only records prune stale; registry-matched
///    records are retained like air friendlies;
///  - no-suppression: ground evidence has no path into the
///    merger/tracker (behavioral + source-structure assertions);
///  - the emitter (Predator) path behaves exactly as before.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/services/airframe_identity.dart';
import 'package:shepherd/services/cot_listener.dart';
import 'package:shepherd/services/simulated.dart';

CotListenerConfig cfg() => const CotListenerConfig(
      enabled: true,
      multicastGroup: '239.2.3.1',
      multicastPort: 6969,
      windowSeconds: 60,
      emitterPrefix: 'PREDATOR-',
      coincidenceRadiusM: 50,
    );

List<int> datagram(String xml) => utf8.encode(xml);

String _iso(DateTime t) => t.toUtc().toIso8601String().replaceAll('.000Z', 'Z');

String event({
  required String uid,
  required String type,
  required String callsign,
  String? time,
  double lat = 35.05,
  double lon = -78.97,
  String detail = '',
}) {
  final t = time ?? _iso(DateTime.now().toUtc());
  return '<?xml version="1.0"?>'
      '<event version="2.0" uid="$uid" type="$type" time="$t" '
      'start="$t" stale="$t" how="m-g">'
      '<point lat="$lat" lon="$lon" hae="999999.0" ce="10.0" le="5.0"/>'
      '<detail><contact callsign="$callsign"/>$detail</detail>'
      '</event>';
}

/// The app-level fold's routing, replicated: ground by domain,
/// air otherwise. If app_state's routing diverges from this, the
/// classifier-level pins below still hold — this helper exists so
/// the listener→classifier contract is tested end to end.
void fold(CotListener l, AirframeClassifier c) {
  for (final p in l.platformObservations) {
    if (p.isGround) {
      c.observeCotGround(CotGroundEvidence(
        uid: p.uid,
        callsign: p.callsign,
        cotType: p.type,
        lat: p.lat,
        lon: p.lon,
        time: p.time,
        courseDeg: p.courseDeg,
        speedMps: p.speedMps,
        batteryPct: p.batteryPct,
      ));
    } else {
      c.observeCotPlatform(CotPlatformEvidence(
        uid: p.uid,
        callsign: p.callsign,
        cotType: p.type,
        lat: p.lat,
        lon: p.lon,
        time: p.time,
        haeM: p.haeM,
        courseDeg: p.courseDeg,
        speedMps: p.speedMps,
        batteryPct: p.batteryPct,
      ));
    }
  }
}

void main() {
  DateTime now() => DateTime.now().toUtc();

  group('listener ground ingest', () {
    test('a-f-G event enters by type, domain ground, fields parsed', () {
      final l =
          CotListener(config: cfg(), platformMatcher: (_, __, ___) => false);
      l.handleDatagram(
          datagram(event(
            uid: 'eud-1',
            type: 'a-f-G-U-C',
            callsign: 'VIPER-6',
            detail: '<track course="90.0" speed="1.4"/>'
                '<status battery="82"/>',
          )),
          now());
      final ps = l.platformObservations;
      expect(ps, hasLength(1));
      final p = ps.single;
      expect(p.isGround, isTrue);
      expect(p.domain, PlatformDomain.ground);
      expect(p.callsign, 'VIPER-6');
      expect(p.courseDeg, 90.0);
      expect(p.speedMps, 1.4);
      expect(p.batteryPct, 82);
      // A ground friendly is NOT an emitter observation.
      expect(l.activeEmitterCount, 0);
    });

    test('a-f-A event still reports the air domain', () {
      final l =
          CotListener(config: cfg(), platformMatcher: (_, __, ___) => false);
      l.handleDatagram(
          datagram(event(uid: 'uas-1', type: 'a-f-A', callsign: 'VIPER-1')),
          now());
      expect(l.platformObservations.single.isGround, isFalse);
      expect(l.platformObservations.single.domain, PlatformDomain.air);
    });

    test('no matcher installed -> ground ingest off like air', () {
      final l = CotListener(config: cfg());
      l.handleDatagram(
          datagram(event(uid: 'eud-1', type: 'a-f-G-U-C', callsign: 'V-6')),
          now());
      expect(l.platformObservations, isEmpty);
    });

    test('unmatched a-u-G event is still not a platform', () {
      final l =
          CotListener(config: cfg(), platformMatcher: (_, __, ___) => false);
      l.handleDatagram(
          datagram(event(uid: 'g-1', type: 'a-u-G', callsign: 'SOMEONE')),
          now());
      expect(l.platformObservations, isEmpty);
    });

    test('PREDATOR- event is never a GROUND platform', () {
      final l =
          CotListener(config: cfg(), platformMatcher: (_, __, ___) => true);
      l.handleDatagram(
          datagram(event(uid: 'e-1', type: 'a-u-G', callsign: 'PREDATOR-7')),
          now());
      expect(l.activeEmitterCount, 1);
      // Ground domain derives from the a-f-G type prefix ONLY:
      // an unknown-affiliation a-u-G event can never be routed as
      // a friendly ground track, whatever the matcher says. (If a
      // matcher accepts it at all, it lands as an AIR-domain
      // platform — the v0.22.0 both-maps behavior, unchanged.)
      expect(l.platformObservations.where((p) => p.isGround), isEmpty);
    });
  });

  group('classifier ground records', () {
    final t0 = DateTime.utc(2026, 10, 21, 12);

    CotGroundEvidence ev({
      String uid = 'eud-1',
      String callsign = 'VIPER-6',
      DateTime? time,
      double? course,
      double? speed,
      double? battery,
    }) =>
        CotGroundEvidence(
          uid: uid,
          callsign: callsign,
          cotType: 'a-f-G-U-C',
          lat: 35.05,
          lon: -78.97,
          time: time ?? t0,
          courseDeg: course,
          speedMps: speed,
          batteryPct: battery,
        );

    test('feed-only ground track -> FRIENDLY (FEED), no air record', () {
      final c = AirframeClassifier();
      final g = c.observeCotGround(ev(course: 90, speed: 1.4, battery: 82));
      expect(g.affiliationLabel, 'FRIENDLY (FEED)');
      expect(g.courseDeg, 90);
      expect(g.speedMps, 1.4);
      expect(g.batteryPct, 82);
      expect(c.groundRecords, hasLength(1));
      // The Drone tab's selector reads `records`: a dismount must
      // structurally never appear there.
      expect(c.records, isEmpty);
    });

    test('registry callsign match -> FRIENDLY', () {
      final c = AirframeClassifier(
          registry: FriendlyRegistry.parse('RADIO12345, VIPER-6'));
      final g = c.observeCotGround(ev());
      expect(g.affiliationLabel, 'FRIENDLY');
      expect(g.registryEntry?.callsign, 'VIPER-6');
    });

    test('registry typed later upgrades the label on rematchAll', () {
      final c = AirframeClassifier();
      c.observeCotGround(ev());
      expect(c.groundRecords.single.affiliationLabel, 'FRIENDLY (FEED)');
      c.registry = FriendlyRegistry.parse('RADIO12345, VIPER-6');
      c.rematchAll();
      expect(c.groundRecords.single.affiliationLabel, 'FRIENDLY');
    });

    test('later event without <status> keeps the known battery', () {
      final c = AirframeClassifier();
      c.observeCotGround(ev(battery: 82));
      final g = c.observeCotGround(
          ev(time: t0.add(const Duration(seconds: 5))));
      expect(g.batteryPct, 82);
    });

    test('prune: feed-only stale record drops; registry record stays', () {
      final c = AirframeClassifier(
          registry: FriendlyRegistry.parse('RADIO12345, VIPER-6'));
      c.observeCotGround(ev(uid: 'eud-feed', callsign: 'ANON-1'));
      c.observeCotGround(ev(uid: 'eud-reg', callsign: 'VIPER-6'));
      expect(c.groundRecords, hasLength(2));
      c.prune(t0.add(const Duration(minutes: 11)));
      expect(c.groundRecords, hasLength(1));
      expect(c.groundRecords.single.callsign, 'VIPER-6');
    });

    test('fresh feed-only record survives prune', () {
      final c = AirframeClassifier();
      c.observeCotGround(ev());
      c.prune(t0.add(const Duration(minutes: 5)));
      expect(c.groundRecords, hasLength(1));
    });
  });

  group('end to end: listener -> classifier', () {
    test('ground datagram lands as a ground record, never an airframe',
        () {
      final l =
          CotListener(config: cfg(), platformMatcher: (_, __, ___) => false);
      final c = AirframeClassifier();
      l.handleDatagram(
          datagram(event(
            uid: 'eud-1',
            type: 'a-f-G-U-C',
            callsign: 'VIPER-6',
            detail: '<track course="45.0" speed="1.2"/>'
                '<status battery="77"/>',
          )),
          now());
      fold(l, c);
      expect(c.records, isEmpty);
      expect(c.groundRecords, hasLength(1));
      final g = c.groundRecords.single;
      expect(g.displayName, 'VIPER-6');
      expect(g.affiliationLabel, 'FRIENDLY (FEED)');
      expect(g.batteryPct, 77);
    });

    test('air and ground datagrams route to their own collections', () {
      final l =
          CotListener(config: cfg(), platformMatcher: (_, __, ___) => false);
      final c = AirframeClassifier();
      l.handleDatagram(
          datagram(event(uid: 'uas-1', type: 'a-f-A', callsign: 'VIPER-1')),
          now());
      l.handleDatagram(
          datagram(event(uid: 'eud-1', type: 'a-f-G-U-C', callsign: 'V-6')),
          now());
      fold(l, c);
      expect(c.records, hasLength(1));
      expect(c.records.single.callsign, 'VIPER-1');
      expect(c.groundRecords, hasLength(1));
      expect(c.groundRecords.single.callsign, 'V-6');
    });
  });

  group('sim ground feed', () {
    test('datagrams parse through a real listener as ground PLI', () {
      final feed = SimGroundFeed();
      final l =
          CotListener(config: cfg(), platformMatcher: (_, __, ___) => false);
      final t = DateTime.now().toUtc();
      for (final xml in feed.tick(
          dt: 30,
          originLat: SimGroundFeed.demoOriginLat,
          originLon: SimGroundFeed.demoOriginLon,
          now: t)) {
        l.handleDatagram(datagram(xml), t);
      }
      final ps = l.platformObservations;
      expect(ps, hasLength(2));
      expect(ps.every((p) => p.isGround), isTrue);
      expect(ps.map((p) => p.callsign),
          containsAll(['SIM-163-A', 'SIM-163-B']));
      expect(ps.every((p) => p.batteryPct != null), isTrue);
    });

    test('walkers move at dismount pace', () {
      final feed = SimGroundFeed();
      final l =
          CotListener(config: cfg(), platformMatcher: (_, __, ___) => false);
      final speeds = <double>[];
      final positions = <String, Set<String>>{};
      for (var i = 0; i < 6; i++) {
        final t = DateTime.now().toUtc();
        for (final xml in feed.tick(
            dt: 10,
            originLat: SimGroundFeed.demoOriginLat,
            originLon: SimGroundFeed.demoOriginLon,
            now: t)) {
          l.handleDatagram(datagram(xml), t);
        }
        for (final p in l.platformObservations) {
          if (p.speedMps != null) speeds.add(p.speedMps!);
          positions
              .putIfAbsent(p.callsign, () => <String>{})
              .add('${p.lat},${p.lon}');
        }
      }
      // Dismount pace: nobody sprints, nobody teleports.
      expect(speeds, isNotEmpty);
      expect(speeds.every((s) => s < 2.5), isTrue,
          reason: 'sim dismount faster than a walk: $speeds');
      expect(speeds.any((s) => s > 0.4), isTrue,
          reason: 'sim dismounts never actually move: $speeds');
      // And they actually change position over the ticks.
      expect(positions.values.every((s) => s.length > 1), isTrue);
    });
  });

  group('no-suppression structure', () {
    test('detection sources hold no ground/platform references', () {
      // The merger and the tracking pipeline must not be able to
      // see ground records at all — the invariant is structural,
      // so it is pinned structurally (mirrors imaging_weights).
      for (final f in [
        'lib/services/confidence_merger.dart',
        'lib/services/tracker.dart',
        'lib/services/tripwire.dart',
        'lib/services/track_stitcher.dart',
      ]) {
        final src = File(_libPath(f)).readAsStringSync();
        for (final banned in [
          'GroundTrack',
          'groundRecords',
          'observeCotGround',
          'PlatformObservation',
        ]) {
          expect(src.contains(banned), isFalse,
              reason: '$banned referenced from $f — platform evidence '
                  'must never reach detection');
        }
      }
    });
  });
}

/// Package root from the test file's location (mirrors
/// imaging_weights_test.dart's helper).
String _libPath(String rel) {
  final testFile = Platform.script.toFilePath();
  final testDir = File(testFile).parent.path;
  for (final base in ['$testDir/../', '$testDir/']) {
    final p = '$base$rel';
    if (File(p).existsSync()) return p;
  }
  return '$testDir/../$rel';
}
