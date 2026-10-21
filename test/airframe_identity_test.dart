/// Tests for the friendly registry + airframe classifier
/// (Skydio P1, lib/services/airframe_identity.dart).
///
/// The rules under test are the spec's promotion contract:
/// promote on evidence, never demote on silence; an RID whitelist
/// match is (claimed) until a cooperative feed corroborates; a
/// whitelist match never suppresses anything (there is nothing to
/// suppress WITH here — the classifier has no output but records).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/services/airframe_identity.dart';

const registryText = '''
# tail numbers
1581F5FHJ229R00N3K7P, VIPER-1
1581F6ABC123R00M4Q2W, VIPER-2, A

bad line without commas is a serial-only entry
''';

void main() {
  group('FriendlyRegistry.parse', () {
    test('parses serials, callsigns, hints; skips comments/blanks', () {
      final r = FriendlyRegistry.parse(registryText);
      expect(r.entries, hasLength(3));
      expect(r.entryForSerial('1581f5fhj229r00n3k7p')?.callsign, 'VIPER-1');
      expect(r.entryForCallsign('viper-2')?.classHint, AirframeClass.a);
      expect(r.entryForSerial('BAD LINE WITHOUT COMMAS IS A SERIAL-ONLY ENTRY'),
          isNotNull);
    });

    test('matching is case-insensitive and trims', () {
      final r = FriendlyRegistry.parse(' abc123 , Wingman ');
      expect(r.entryForSerial(' ABC123 ')?.callsign, 'Wingman');
      expect(r.entryForCallsign('WINGMAN'), isNotNull);
      expect(r.entryForSerial(''), isNull);
      expect(r.entryForSerial(null), isNull);
    });

    test('uid match: exact or full serial suffix only', () {
      final r = FriendlyRegistry.parse('1581F5FHJ229R00N3K7P, VIPER-1');
      expect(r.entryForUid('1581F5FHJ229R00N3K7P'), isNotNull);
      expect(r.entryForUid('SOMEUID-1581F5FHJ229R00N3K7P'), isNotNull);
      expect(r.entryForUid('OTHER'), isNull);
    });

    test('duplicate serials collapse to one entry', () {
      final r = FriendlyRegistry.parse('S1, A\nS1, B\n');
      expect(r.entries, hasLength(1));
    });
  });

  group('AirframeClassifier promotion', () {
    final t0 = DateTime.utc(2026, 10, 21, 12);

    AirframeClassifier withRegistry() =>
        AirframeClassifier(registry: FriendlyRegistry.parse(registryText));

    test('CoT platform for a registry callsign -> Class B FRIENDLY', () {
      final c = withRegistry();
      final r = c.observeCotPlatform(CotPlatformEvidence(
        uid: 'u-1',
        callsign: 'VIPER-1',
        cotType: 'a-f-A-M-F-Q',
        lat: 35.1,
        lon: -78.9,
        time: t0,
        batteryPct: 87,
      ));
      expect(r.klass, AirframeClass.b);
      expect(r.affiliationLabel, 'FRIENDLY');
      expect(r.serial, '1581F5FHJ229R00N3K7P');
      expect(r.batteryPct, 87);
      expect(r.hasTelemetryPosition, isTrue);
    });

    test('friendly CoT without registry -> FRIENDLY (FEED)', () {
      final c = AirframeClassifier();
      final r = c.observeCotPlatform(CotPlatformEvidence(
        uid: 'u-2',
        callsign: 'DART-7',
        cotType: 'a-f-A',
        lat: 35.0,
        lon: -78.0,
        time: t0,
      ));
      expect(r.klass, AirframeClass.b);
      expect(r.affiliationLabel, 'FRIENDLY (FEED)');
    });

    test('RID-only registry match -> Class C FRIENDLY (claimed)', () {
      final c = withRegistry();
      final r = c.observeRid(RidEvidence(
        serial: '1581F5FHJ229R00N3K7P',
        time: t0,
        lat: 35.2,
        lon: -78.8,
      ))!;
      expect(r.klass, AirframeClass.c);
      expect(r.affiliationLabel, 'FRIENDLY (claimed)');
      expect(r.ridClaimed, isTrue);
    });

    test('RID claim corroborated by CoT -> same record, FRIENDLY, B', () {
      final c = withRegistry();
      c.observeRid(RidEvidence(
        serial: '1581F5FHJ229R00N3K7P',
        time: t0,
        lat: 35.2,
        lon: -78.8,
      ));
      final r2 = c.observeCotPlatform(CotPlatformEvidence(
        uid: 'u-1',
        callsign: 'VIPER-1',
        cotType: 'a-f-A',
        lat: 35.21,
        lon: -78.81,
        time: t0.add(const Duration(minutes: 1)),
      ));
      expect(c.records, hasLength(1));
      expect(r2.klass, AirframeClass.b);
      expect(r2.affiliationLabel, 'FRIENDLY');
      expect(r2.ridClaimed, isFalse);
      // Cooperative position outranks the broadcast claim.
      expect(r2.lat, 35.21);
    });

    test('unknown RID -> Class C UNKNOWN; never pruned while fresh', () {
      final c = withRegistry();
      final r = c.observeRid(RidEvidence(
        serial: '9999ZZZZZZZZZZZZZZZZ',
        time: t0,
        lat: 35.3,
        lon: -78.7,
      ))!;
      expect(r.klass, AirframeClass.c);
      expect(r.affiliationLabel, 'UNKNOWN');
    });

    test('never demote: B record hearing RID stays B', () {
      final c = withRegistry();
      c.observeCotPlatform(CotPlatformEvidence(
        uid: 'u-1',
        callsign: 'VIPER-1',
        cotType: 'a-f-A',
        lat: 35.1,
        lon: -78.9,
        time: t0,
      ));
      final r = c.observeRid(RidEvidence(
        serial: '1581F5FHJ229R00N3K7P',
        time: t0.add(const Duration(minutes: 2)),
      ))!;
      expect(r.klass, AirframeClass.b);
      expect(r.affiliationLabel, 'FRIENDLY');
    });

    test('mesh node with link metrics + motion -> Class A', () {
      final c = withRegistry();
      final r = c.observeMeshNode(
        nodeCallsign: 'VIPER-1',
        hasLinkMetrics: true,
        moving3d: true,
        time: t0,
        lat: 35.1,
        lon: -78.9,
      )!;
      expect(r.klass, AirframeClass.a);
      expect(r.affiliationLabel, 'FRIENDLY');
    });

    test('mesh node with metrics but no motion/hint -> stays B', () {
      final c = withRegistry();
      final r = c.observeMeshNode(
        nodeCallsign: 'VIPER-1',
        hasLinkMetrics: true,
        moving3d: false,
        time: t0,
      )!;
      expect(r.klass, AirframeClass.b);
    });

    test('registry A hint promotes a linked node without motion', () {
      final c = withRegistry();
      final r = c.observeMeshNode(
        nodeCallsign: 'VIPER-2', // hint A in the registry text
        hasLinkMetrics: true,
        moving3d: false,
        time: t0,
      )!;
      expect(r.klass, AirframeClass.a);
    });

    test('mesh node outside the registry is not an airframe', () {
      final c = withRegistry();
      expect(
          c.observeMeshNode(
            nodeCallsign: 'GROUND-1',
            hasLinkMetrics: true,
            moving3d: true,
            time: t0,
          ),
          isNull);
      expect(c.records, isEmpty);
    });

    test('prune drops stale Class C strangers only', () {
      final c = withRegistry();
      c.observeRid(RidEvidence(
          serial: '9999ZZZZZZZZZZZZZZZZ', time: t0, lat: 1, lon: 1));
      c.observeRid(RidEvidence(
          serial: '1581F5FHJ229R00N3K7P', time: t0, lat: 1, lon: 1));
      c.observeCotPlatform(CotPlatformEvidence(
        uid: 'u-9',
        callsign: 'DART-7',
        cotType: 'a-f-A',
        lat: 1,
        lon: 1,
        time: t0,
      ));
      c.prune(t0.add(const Duration(hours: 2)));
      final serials = c.records.map((r) => r.serial).toList();
      expect(serials, isNot(contains('9999ZZZZZZZZZZZZZZZZ')));
      // (claimed) friendly and feed-friendly B records survive.
      expect(serials, contains('1581F5FHJ229R00N3K7P'));
      expect(c.records.any((r) => r.callsign == 'DART-7'), isTrue);
    });

    test('rematchAll: a serial typed later claims an existing contact', () {
      final c = AirframeClassifier();
      c.observeRid(RidEvidence(
          serial: '1581F5FHJ229R00N3K7P', time: t0, lat: 1, lon: 1));
      expect(c.records.single.affiliationLabel, 'UNKNOWN');
      c.registry = FriendlyRegistry.parse(registryText);
      c.rematchAll();
      expect(c.records.single.affiliationLabel, 'FRIENDLY (claimed)');
      expect(c.records.single.callsign, 'VIPER-1');
    });
  });
}
