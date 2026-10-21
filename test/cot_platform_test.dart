/// Tests for the CoT listener's friendly-platform ingest path
/// (Skydio P1, lib/services/cot_listener.dart).
///
/// The contract under test: platform observations are a SEPARATE
/// collection from emitter observations. The emitter path
/// (PREDATOR- prefix, corroboration-only) must behave exactly as
/// before whether or not a platform matcher is installed.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/services/cot_listener.dart';

CotListenerConfig cfg() => const CotListenerConfig(
      enabled: true,
      multicastGroup: '239.2.3.1',
      multicastPort: 6969,
      windowSeconds: 60,
      emitterPrefix: 'PREDATOR-',
      coincidenceRadiusM: 50,
    );

List<int> datagram(String xml) => utf8.encode(xml);

/// Event timestamps anchor to the real clock: the listener's
/// getters prune against DateTime.now() (same pattern as the
/// existing cot_listener_test.dart).
String _iso(DateTime t) => t.toUtc().toIso8601String().replaceAll('.000Z', 'Z');

String event({
  required String uid,
  required String type,
  required String callsign,
  String? time,
  double lat = 35.1,
  double lon = -78.9,
  String detail = '',
}) {
  final t = time ?? _iso(DateTime.now().toUtc());
  return '<?xml version="1.0"?>'
      '<event version="2.0" uid="$uid" type="$type" time="$t" '
      'start="$t" stale="$t" how="m-g">'
      '<point lat="$lat" lon="$lon" hae="120.5" ce="10.0" le="5.0"/>'
      '<detail><contact callsign="$callsign"/>$detail</detail>'
      '</event>';
}

void main() {
  DateTime now() => DateTime.now().toUtc();

  group('platform ingest', () {
    test('friendly air event populates platform observations', () {
      final l =
          CotListener(config: cfg(), platformMatcher: (_, __, ___) => false);
      l.handleDatagram(
          datagram(event(
            uid: 'uas-1',
            type: 'a-f-A-M-F-Q',
            callsign: 'VIPER-1',
            detail: '<track course="271.0" speed="12.5"/>'
                '<status battery="87"/>',
          )),
          now());
      final ps = l.platformObservations;
      expect(ps, hasLength(1));
      final p = ps.single;
      expect(p.callsign, 'VIPER-1');
      expect(p.lat, 35.1);
      expect(p.haeM, 120.5);
      expect(p.courseDeg, 271.0);
      expect(p.speedMps, 12.5);
      expect(p.batteryPct, 87);
      // A friendly platform is NOT an emitter observation.
      expect(l.activeEmitterCount, 0);
    });

    test('matcher accepts a registry callsign of any air type', () {
      final l = CotListener(
        config: cfg(),
        platformMatcher: (callsign, uid, type) => callsign == 'VIPER-9',
      );
      l.handleDatagram(
          datagram(event(uid: 'uas-9', type: 'a-u-A', callsign: 'VIPER-9')),
          now());
      expect(l.platformObservations, hasLength(1));
    });

    test('unmatched non-friendly events are not platforms', () {
      final l = CotListener(
        config: cfg(),
        platformMatcher: (callsign, uid, type) => false,
      );
      l.handleDatagram(
          datagram(event(uid: 'g-1', type: 'a-u-G', callsign: 'SOMEONE')),
          now());
      expect(l.platformObservations, isEmpty);
    });

    test('no matcher installed -> platform ingest fully off', () {
      final l = CotListener(config: cfg());
      l.handleDatagram(
          datagram(event(uid: 'uas-1', type: 'a-f-A', callsign: 'VIPER-1')),
          now());
      expect(l.platformObservations, isEmpty);
    });

    test('battery fraction form (0..1 non-integer) reads as percent', () {
      final l =
          CotListener(config: cfg(), platformMatcher: (_, __, ___) => true);
      l.handleDatagram(
          datagram(event(
            uid: 'uas-2',
            type: 'a-f-A',
            callsign: 'VIPER-2',
            detail: '<status battery="0.5"/>',
          )),
          now());
      expect(l.platformObservations.single.batteryPct, 50);
    });

    test('sentinel hae and junk track fields stay null', () {
      final l =
          CotListener(config: cfg(), platformMatcher: (_, __, ___) => true);
      l.handleDatagram(
          datagram(event(
            uid: 'uas-3',
            type: 'a-f-A',
            callsign: 'VIPER-3',
            detail: '<track course="north" speed="-4"/>',
          ).replaceAll('hae="120.5"', 'hae="999999.0"')),
          now());
      final p = l.platformObservations.single;
      expect(p.haeM, isNull);
      expect(p.courseDeg, isNull);
      expect(p.speedMps, isNull);
    });
  });

  group('emitter path is unaffected', () {
    test('PREDATOR- event still lands as emitter, not platform', () {
      final l =
          CotListener(config: cfg(), platformMatcher: (_, __, ___) => false);
      l.handleDatagram(
          datagram(event(uid: 'e-1', type: 'a-u-G', callsign: 'PREDATOR-7')),
          now());
      expect(l.activeEmitterCount, 1);
      expect(l.platformObservations, isEmpty);
    });

    test('future-dated platform event is rejected like emitters', () {
      final l =
          CotListener(config: cfg(), platformMatcher: (_, __, ___) => true);
      l.handleDatagram(
          datagram(event(
            uid: 'uas-f',
            type: 'a-f-A',
            callsign: 'VIPER-1',
            time: '2027-01-01T00:00:00Z',
          )),
          now());
      expect(l.platformObservations, isEmpty);
    });
  });
}
