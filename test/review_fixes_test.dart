import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/models/link_sample.dart';
import 'package:shepherd/services/cot_listener.dart';
import 'package:shepherd/services/esp32_driver.dart';
import 'package:shepherd/services/node_udp_hub.dart';
import 'package:shepherd/services/tripwire.dart';

final _t0 = DateTime(2026, 1, 1, 12);

LinkSample _s(double snr, int i) => LinkSample(
      timestamp: _t0.add(Duration(milliseconds: 250 * i)),
      fromNode: 'a',
      toNode: 'b',
      snr: snr,
    );

int _warm(Tripwire tw, int n) {
  for (var i = 0; i < n; i++) {
    tw.process(_s(i.isEven ? 90.0 : 90.2, i));
  }
  return n;
}

void main() {
  group('Tripwire review fixes', () {
    test('confirmPolls of 0 is clamped and still emits', () {
      final tw = Tripwire(config: const TripwireConfig(confirmPolls: 0));
      var i = _warm(tw, 20);
      for (var k = 0; k < 4; k++) {
        tw.process(_s(70.0, i++));
      }
      expect(tw.drainEvents(), hasLength(1));
    });

    test('episode summary carries the true duration and peak', () {
      final tw = Tripwire(config: const TripwireConfig(confirmPolls: 2));
      var i = _warm(tw, 20);
      for (var k = 0; k < 12; k++) {
        tw.process(_s(k < 6 ? 78.0 : 70.0, i++)); // deepens mid-episode
      }
      final events = tw.drainEvents();
      expect(events, hasLength(1));
      expect(tw.drainClosedEpisodes(), isEmpty); // still in progress
      for (var k = 0; k < 3; k++) {
        tw.process(_s(90.1, i++)); // back to normal: episode ends
      }
      final closed = tw.drainClosedEpisodes();
      expect(closed, hasLength(1));
      expect(closed.single.confirmedAt, events.single.timestamp);
      expect(closed.single.durationSecs,
          greaterThan(events.single.durationSecs));
      expect(closed.single.peak, greaterThan(events.single.dipDepth));
    });

    test('a link swept as stale still closes its open episode', () {
      final tw = Tripwire(config: const TripwireConfig(confirmPolls: 2));
      var i = _warm(tw, 20);
      for (var k = 0; k < 6; k++) {
        tw.process(_s(70.0, i++)); // confirmed episode, still ongoing
      }
      expect(tw.drainEvents(), hasLength(1));
      // Another link's traffic 11 minutes later trips the stale sweep
      // (every 512 samples). The vanished link's episode must close,
      // not be silently discarded with its state.
      final later = _t0.add(const Duration(minutes: 11));
      for (var k = 0; k < 512; k++) {
        tw.process(LinkSample(
          timestamp: later.add(Duration(milliseconds: 250 * k)),
          fromNode: 'c',
          toNode: 'd',
          snr: 90.0,
        ));
      }
      final closed = tw.drainClosedEpisodes();
      expect(closed, hasLength(1));
      expect(closed.single.linkKey, 'a → b');
    });

    test('a lasting noise increase does not re-alarm after re-baselining',
        () {
      final tw = Tripwire(
          config: const TripwireConfig(maxHoldPolls: 20, confirmPolls: 2));
      var i = _warm(tw, 20);
      var events = 0;
      for (var k = 0; k < 140; k++) {
        tw.process(_s(k.isEven ? 88.0 : 92.0, i++));
        events += tw.drainEvents().length;
      }
      expect(events, lessThanOrEqualTo(1));
    });
  });

  group('ESP32 driver hardening', () {
    test('ids containing ":" are rejected (no key corruption)', () async {
      final d = Esp32Driver();
      d.datagramForTest(jsonEncode({
        'type': 'beacon',
        'node': 'a:b',
        'sensors': ['wifi'],
      }));
      d.datagramForTest(jsonEncode({
        'type': 'beacon',
        'node': 'GOOD-1',
        'sensors': ['wi:fi', 'wifi'],
        'lat': 0,
        'lon': 10.5,
      }));
      expect(d.meshPositions().containsKey('a:b'), isFalse);
      // lat == 0 is a valid coordinate and must be kept.
      expect(d.meshPositions()['GOOD-1']?.lat, 0.0);
    });

    test('out-of-range and non-numeric positions are ignored', () {
      final d = Esp32Driver();
      d.datagramForTest(
          jsonEncode({'type': 'beacon', 'node': 'N1', 'lat': 95, 'lon': 10}));
      d.datagramForTest(jsonEncode(
          {'type': 'beacon', 'node': 'N2', 'lat': 'x', 'lon': 'y'}));
      expect(d.meshPositions(), isEmpty);
    });

    test('non-object JSON is dropped without throwing', () {
      final d = Esp32Driver();
      d.datagramForTest('[1,2,3]');
      d.datagramForTest('"str"');
      expect(d.meshPositions(), isEmpty);
    });

    test('calib flag arrives as integer 1 from the firmware', () {
      // shepherd_node.ino formats the beacon with %d: "calib":1, not
      // a JSON bool. Dart's 1 == true is false, so the driver must
      // accept the integer form or guided calibration never engages.
      final d = Esp32Driver();
      d.datagramForTest(jsonEncode(
          {'type': 'beacon', 'node': 'N1', 'sensors': ['wifi'], 'calib': 1}));
      expect(d.calibNodes, contains('N1'));
      d.datagramForTest(jsonEncode(
          {'type': 'beacon', 'node': 'N1', 'sensors': ['wifi'], 'calib': 0}));
      expect(d.calibNodes, isNot(contains('N1')));
    });
  });

  group('NodeUdpHub source allowlist', () {
    tearDown(() => NodeUdpHub.allowedSources = null);

    test('parses comma/space separated lists; blank clears', () {
      NodeUdpHub.setAllowedSourcesFromText('10.0.0.1, 10.0.0.2  10.0.0.3');
      expect(NodeUdpHub.allowedSources, {'10.0.0.1', '10.0.0.2', '10.0.0.3'});
      NodeUdpHub.setAllowedSourcesFromText('  ');
      expect(NodeUdpHub.allowedSources, isNull);
    });
  });

  group('CoT listener hardening', () {
    String ev({required DateTime time, String callsign = 'PREDATOR-1'}) =>
        '<event version="2.0" uid="u" type="a-u-S" '
        'time="${time.toUtc().toIso8601String()}" '
        'start="${time.toUtc().toIso8601String()}" '
        'stale="${time.toUtc().add(const Duration(minutes: 1)).toIso8601String()}">'
        '<point lat="35.0" lon="-78.0" hae="0" ce="25" le="9999999"/>'
        '<detail><contact callsign="$callsign"/></detail></event>';

    test('far-future events are rejected; small skew is tolerated', () {
      final l = CotListener(
          config: const CotListenerConfig(enabled: true));
      final n = DateTime.now().toUtc();
      l.handleDatagram(
          utf8.encode(ev(time: n.add(const Duration(days: 365)))), n);
      expect(l.activeEmitters, isEmpty);
      l.handleDatagram(
          utf8.encode(ev(time: n.add(const Duration(seconds: 5)))), n);
      expect(l.activeEmitters, hasLength(1));
    });

    test('single-quoted attributes parse', () {
      final l = CotListener(
          config: const CotListenerConfig(enabled: true));
      final n = DateTime.now().toUtc();
      final xml = ev(time: n).replaceAll('"', "'");
      l.handleDatagram(utf8.encode(xml), n);
      expect(l.activeEmitters, hasLength(1));
    });

    test('observation map is capped', () {
      final l = CotListener(
          config: const CotListenerConfig(enabled: true));
      final n = DateTime.now().toUtc();
      for (var k = 0; k < CotListener.maxObservations + 50; k++) {
        l.handleDatagram(
            utf8.encode(ev(time: n, callsign: 'PREDATOR-$k')), n);
      }
      expect(l.activeEmitters.length, CotListener.maxObservations);
    });

    test('parseSources', () {
      expect(CotListenerConfig.parseSources('b, a  c'), ['a', 'b', 'c']);
    });
  });
}
