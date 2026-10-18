/// Tests for the Shepherd CoT emit publisher (docs/shepherd_cot_output_spec.md,
/// docs/predator_integration_spec.md — Shepherd side only).
///
/// Load-bearing invariants:
///  1. XML GOLDEN: fixed track + fixed timestamp -> byte-exact CoT event.
///  2. Callsign contract: `SHEPHERD-<trackId>` (hyphen, no space).
///  3. Type-code table: drone/fixed-wing/rotary @ >= 0.5 -> a-u-A.
///  4. Affiliation is ALWAYS 'u' (never h/f).
///  5. Throttle: 10 updates in 200 ms -> exactly 1 datagram.
///  6. Gates: disabled / no GPS anchor / below publish floor -> no datagram.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/services/cot_publisher.dart';
import 'package:shepherd/services/geo_projection.dart';

GeoProjection _proj() => GeoProjection(originLat: 35.0, originLon: -78.0);

CotTrackInput _track({
  String trackId = 'T0042',
  double xEast = 100.0,
  double yNorth = 50.0,
  double headingDeg = 94.0,
  double speedMps = 2.5,
  String sizeLabel = 'M',
  double sizeConfidence = 0.62,
  String typeGuess = 'Possible fixed-wing drone',
  double typeConfidence = 0.7,
  String inboundOutbound = 'INBOUND TO DEFENDED POINT',
  double confidence = 0.85,
  double positionUncertaintyM = 12.0,
}) =>
    CotTrackInput(
      trackId: trackId,
      xEast: xEast,
      yNorth: yNorth,
      headingDeg: headingDeg,
      speedMps: speedMps,
      sizeLabel: sizeLabel,
      sizeConfidence: sizeConfidence,
      typeGuess: typeGuess,
      typeConfidence: typeConfidence,
      inboundOutbound: inboundOutbound,
      confidence: confidence,
      positionUncertaintyM: positionUncertaintyM,
    );

/// Golden track: fixed everything, fixed timestamp.
String _goldenEvent() {
  const prefix = 'SHEPHERD-';
  return '<event version="2.0"'
      ' uid="${prefix}T0042"'
      ' type="a-u-A"'
      ' time="2026-10-18T19:35:00.123Z"'
      ' start="2026-10-18T19:35:00.123Z"'
      ' stale="2026-10-18T19:35:30.123Z"'
      ' how="m-g">'
      '<point lat="35.000452" lon="-77.998903" hae="0.0"'
      ' ce="12.0" le="12.0"/>'
      '<detail>'
      '<contact callsign="${prefix}T0042"/>'
      '<track course="94.0" speed="2.50"/>'
      '<remarks>M (conf 62%). Possible fixed-wing drone'
      ' — INBOUND TO DEFENDED POINT.</remarks>'
      '</detail>'
      '</event>';
}

String _typeAttr(String xml) {
  final m = RegExp(r'type="([^"]*)"').firstMatch(xml);
  return m!.group(1)!;
}

void main() {
  group('XML builder', () {
    test('golden test: fixed track + fixed timestamp -> byte-exact XML',
        () {
      final xml = buildEventXml(
        _track(),
        DateTime.utc(2026, 10, 18, 19, 35, 0, 123),
        projection: _proj(),
      );
      expect(xml, _goldenEvent());
    });

    test('callsign format: SHEPHERD-<trackId> (hyphen, no space)', () {
      final xml = buildEventXml(
        _track(trackId: 'T0042'),
        DateTime.utc(2026, 10, 18, 19, 35, 0, 123),
        projection: _proj(),
      );
      expect(xml, contains('uid="SHEPHERD-T0042"'));
      expect(xml, contains('callsign="SHEPHERD-T0042"'));
      expect(xml, isNot(contains('SHEPHERD T0042')));
      expect(xml, isNot(contains('SHEPHERD.T0042')));
    });

    test('type-code table', () {
      String typeFor(String guess, double conf) => _typeAttr(buildEventXml(
            _track(typeGuess: guess, typeConfidence: conf),
            DateTime.utc(2026, 10, 18, 19, 35, 0),
            projection: _proj(),
          ));
      expect(typeFor('drone', 0.6), 'a-u-A');
      expect(typeFor('drone', 0.4), 'a-u-G');
      expect(typeFor('person', 0.9), 'a-u-G');
      expect(typeFor('rotary', 0.5), 'a-u-A'); // boundary: >= threshold
      expect(typeFor('fixedwing quadcopter', 0.9), 'a-u-A');
      expect(typeFor('multirotor', 0.51), 'a-u-A');
      expect(typeFor('vehicle', 0.9), 'a-u-G');
    });

    test('affiliation is always u — never h/f', () {
      for (final type in [
        _typeAttr(buildEventXml(_track(typeGuess: 'drone', typeConfidence: 0.9),
            DateTime.utc(2026), projection: _proj())),
        _typeAttr(buildEventXml(_track(typeGuess: 'person', typeConfidence: 0.9),
            DateTime.utc(2026), projection: _proj())),
      ]) {
        expect(type, startsWith('a-u-'),
            reason: 'affiliation must stay unknown');
      }
    });

    test('remarks truncated to 200 chars', () {
      final xml = buildEventXml(
        _track(inboundOutbound: 'X' * 300),
        DateTime.utc(2026, 10, 18, 19, 35, 0),
        projection: _proj(),
      );
      final remarks = RegExp(r'<remarks>(.*)</remarks>')
          .firstMatch(xml)!
          .group(1)!;
      expect(remarks.length, lessThanOrEqualTo(200));
    });

    test('XML special chars are escaped', () {
      final xml = buildEventXml(
        _track(trackId: 'T&<1>', typeGuess: 'drone & "quad"'),
        DateTime.utc(2026, 10, 18, 19, 35, 0),
        projection: _proj(),
      );
      expect(xml, contains('uid="SHEPHERD-T&amp;&lt;1&gt;"'));
      expect(xml, contains('drone &amp; "quad"'));
    });

    test('stale = time + staleSeconds', () {
      final xml = buildEventXml(
        _track(),
        DateTime.utc(2026, 10, 18, 19, 35, 0, 500),
        projection: _proj(),
        config: const CotPublisherConfig(staleSeconds: 45),
      );
      expect(xml, contains('stale="2026-10-18T19:35:45.500Z"'));
    });
  });

  group('publish gates and throttle', () {
    test('throttle: 10 publishTrack calls in 200 ms -> exactly 1 datagram',
        () async {
      final sent = <List<int>>[];
      final pub = CotPublisher(
        config: const CotPublisherConfig(enabled: true),
        projection: _proj(),
        sender: (bytes) async {
          sent.add(bytes);
        },
      );
      final sw = Stopwatch()..start();
      for (var i = 0; i < 10; i++) {
        await pub.publishTrack(_track(xEast: 100.0 + i));
      }
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(5000));
      expect(sent.length, 1);
      expect(utf8.decode(sent.single), contains('uid="SHEPHERD-T0042"'));
      pub.dispose();
    });

    test('publish floor: confidence 0.2 < 0.3 -> no datagram', () async {
      final sent = <List<int>>[];
      final pub = CotPublisher(
        config: const CotPublisherConfig(enabled: true, publishFloor: 0.3),
        projection: _proj(),
        sender: (bytes) async {
          sent.add(bytes);
        },
      );
      await pub.publishTrack(_track(confidence: 0.2));
      expect(sent, isEmpty);
      pub.dispose();
    });

    test('disabled -> no datagram', () async {
      final sent = <List<int>>[];
      final pub = CotPublisher(
        config: const CotPublisherConfig(enabled: false),
        projection: _proj(),
        sender: (bytes) async {
          sent.add(bytes);
        },
      );
      await pub.publishTrack(_track());
      expect(sent, isEmpty);
      pub.dispose();
    });

    test('no projection (no GPS anchor) -> no datagram', () async {
      final sent = <List<int>>[];
      final pub = CotPublisher(
        config: const CotPublisherConfig(enabled: true),
        projection: null,
        sender: (bytes) async {
          sent.add(bytes);
        },
      );
      await pub.publishTrack(_track());
      expect(sent, isEmpty);
      pub.dispose();
    });

    test('stats reflect publishing state', () async {
      final sent = <List<int>>[];
      final pub = CotPublisher(
        config: const CotPublisherConfig(enabled: true),
        projection: _proj(),
        sender: (bytes) async {
          sent.add(bytes);
        },
      );
      expect(pub.stats.tracksPublishing, 0);
      expect(pub.stats.lastSentAt, isNull);
      await pub.publishTrack(_track());
      expect(pub.stats.tracksPublishing, 1);
      expect(pub.stats.lastSentAt, isNotNull);
      expect(pub.stats.lastError, isNull);
      pub.dispose();
    });

    test('transport error recorded, never thrown', () async {
      final pub = CotPublisher(
        config: const CotPublisherConfig(enabled: true),
        projection: _proj(),
        sender: (_) => throw SocketExceptionClosed(),
      );
      await pub.publishTrack(_track()); // must not throw
      expect(pub.stats.lastError, isNotNull);
      pub.dispose();
    });
  });
}

class SocketExceptionClosed implements Exception {
  @override
  String toString() => 'simulated transport failure';
}
