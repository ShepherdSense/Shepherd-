/// Never-override proof for Remote ID (Shepherd v0.26.0,
/// Fieldwatch-borrow item 1).
///
/// Rule: RID evidence is cooperative identification, display-only.
/// It must NEVER feed detection (tripwire), the tracker, or the
/// confidence merger, and must NEVER suppress or downgrade a mesh
/// track/alert. The sole in-app consumer is the display-only
/// airframe classifier fold in app_state.dart (`_foldAirframeEvidence`,
/// documented there as "Display-only: nothing here touches detection
/// state") — that fold is wiring, not detection, and is out of scope
/// for this service-level proof.
///
/// The proof is twofold, mirroring test/ground_tracks_test.dart:
///  1. STRUCTURAL: the detection/tracking/merger sources contain no
///     reference to any RID type or symbol, so no code path in them
///     can consume RID evidence. NOTE (v0.26.0 fix-pass, correcting
///     the old comment): the behavioral merger test below is NOT
///     itself proof of separation — it calls the merger with
///     mesh-only inputs in both arms, so it would pass even if a
///     hypothetical RID input path existed. The structural grep in
///     the first group IS the real proof for the merger: it shows
///     there is no RID symbol for any such path to be built on.
///     The behavioral tests prove the weaker, honest claim that a
///     live RID contact sitting alongside mesh inputs does not
///     change the outputs those mesh inputs produce.
///  2. BEHAVIORAL: a live RID contact sitting in a RemoteIdTracker
///     changes nothing about tripwire events, tracker estimates, or
///     merger output produced from mesh inputs.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/models/link_sample.dart';
import 'package:shepherd/models/tracking.dart';
import 'package:shepherd/services/confidence_merger.dart';
import 'package:shepherd/services/remote_id.dart';
import 'package:shepherd/services/tracker.dart';
import 'package:shepherd/services/tripwire.dart';

import 'remote_id_test.dart' as vec;

String _libPath(String rel) {
  final testFile = Platform.script.toFilePath();
  final testDir = File(testFile).parent.path;
  for (final base in ['$testDir/../', '$testDir/']) {
    final p = '$base$rel';
    if (File(p).existsSync()) return p;
  }
  return '$testDir/../$rel';
}

final _now = DateTime(2026, 1, 1, 12);

LinkSample _link(String a, String b, double dip) => LinkSample(
      timestamp: _now,
      fromNode: a,
      toNode: b,
      snr: 80,
      dip: dip,
      baseline: 90,
      threshold: 6,
    );

NodePosition _n(String id, double x, double y) =>
    NodePosition(nodeId: id, x: x, y: y);

/// A live RID contact, as if a compliant drone were broadcasting
/// next to the mesh right now.
RemoteIdTracker _liveRidTracker() {
  final tr = RemoteIdTracker();
  tr.ingestAppData([0x01, ...vec.basicIdBytes],
      sourceKey: 'ble:AA', sourceKind: 'BLE', at: _now);
  tr.ingestAppData(vec.locationBytes,
      sourceKey: 'ble:AA', sourceKind: 'BLE', at: _now);
  return tr;
}

void main() {
  group('never-override: structural separation', () {
    test('detection/tracker/merger sources reference no RID symbol', () {
      for (final f in [
        'lib/services/tripwire.dart',
        'lib/services/tracker.dart',
        'lib/services/confidence_merger.dart',
        'lib/services/track_stitcher.dart',
      ]) {
        final src = File(_libPath(f)).readAsStringSync();
        for (final banned in [
          'remote_id',
          'RidContact',
          'RidMessage',
          'RemoteIdTracker',
          'observeRid',
          'COOPERATIVE (RID)',
        ]) {
          expect(src.contains(banned), isFalse,
              reason: '$banned referenced from $f — RID evidence '
                  'must never reach detection, the tracker, or '
                  'the merger');
        }
      }
    });
  });

  group('never-override: behavioral', () {
    test('a live RID contact does not suppress a mesh track', () {
      final nodes = {
        't:a': _n('t:a', 0, 0),
        't:b': _n('t:b', 40, 0),
        't:c': _n('t:c', 20, 35),
      };
      final samples = [
        _link('t:a', 't:b', 20),
        _link('t:b', 't:c', 1),
        _link('t:c', 't:a', 1),
      ];
      // Baseline: mesh alone localizes.
      final before = Tracker().update(
        now: _now,
        samples: samples,
        nodes: nodes,
        dipThreshold: 6,
        defended: DefendedPoint(x: 0, y: 0),
      );
      expect(before, isNotNull);
      // Now a live RID contact exists alongside the mesh.
      final rid = _liveRidTracker();
      expect(rid.contacts(_now), hasLength(1));
      expect(rid.contacts(_now).single.serial, isNotNull);
      // Same mesh input still localizes — RID neither suppresses
      // nor replaces the mesh estimate.
      final after = Tracker().update(
        now: _now,
        samples: samples,
        nodes: nodes,
        dipThreshold: 6,
        defended: DefendedPoint(x: 0, y: 0),
      );
      expect(after, isNotNull);
      expect(after!.x, inInclusiveRange(5, 35));
      expect(after.linksUsed, before!.linksUsed);
    });

    test('RID alone never creates a mesh track', () {
      final rid = _liveRidTracker();
      expect(rid.contacts(_now), hasLength(1));
      final track = Tracker().update(
        now: _now,
        samples: const [],
        nodes: {
          't:a': _n('t:a', 0, 0),
          't:b': _n('t:b', 40, 0),
          't:c': _n('t:c', 20, 35),
        },
        dipThreshold: 6,
        defended: DefendedPoint(x: 0, y: 0),
      );
      expect(track, isNull);
    });

    test('a live RID contact does not change merger output', () {
      const base = 0.6;
      final before = mergeTrackConfidence(
        baseConfidence: base,
        contributions: const [],
        trackConsistent: true,
      );
      expect(before.displayed, base);
      expect(before.upgrade, 0.0);
      // RID exists, but the merger takes no RID input: there is no
      // GatedCorroboration a RID contact could become, so the
      // output for the same mesh-only inputs is identical.
      final rid = _liveRidTracker();
      expect(rid.contacts(_now), hasLength(1));
      final after = mergeTrackConfidence(
        baseConfidence: base,
        contributions: const [],
        trackConsistent: true,
      );
      expect(after.displayed, before.displayed);
      expect(after.upgrade, 0.0);
      expect(after.displayed, greaterThanOrEqualTo(base),
          reason: 'merger is never subtractive, with or without RID');
    });

    test('a live RID contact does not suppress a tripwire alert', () {
      final rid = _liveRidTracker();
      expect(rid.contacts(_now), hasLength(1));
      final tw = Tripwire(config: const TripwireConfig(confirmPolls: 2));
      var i = 0;
      for (; i < 20; i++) {
        tw.process(LinkSample(
          timestamp: _now.add(Duration(milliseconds: 250 * i)),
          fromNode: 'a',
          toNode: 'b',
          snr: i.isEven ? 90.0 : 90.2,
        ));
      }
      for (var k = 0; k < 5; k++) {
        tw.process(LinkSample(
          timestamp: _now.add(Duration(milliseconds: 250 * i)),
          fromNode: 'a',
          toNode: 'b',
          snr: 78.0,
        ));
        i++;
      }
      final events = tw.drainEvents();
      expect(events, hasLength(1));
      expect(events.first.dipDepth, greaterThan(10));
    });

    test('RID records carry the cooperative label, mesh tracks do not', () {
      final rid = _liveRidTracker();
      final c = rid.contacts(_now).single;
      expect(c.cooperativeLabel, 'COOPERATIVE (RID)');
      expect(c.cooperativeSourceLabel, 'COOPERATIVE (RID · BLE)');
      // A mesh track estimate carries no RID label at all.
      final track = Tracker().update(
        now: _now,
        samples: [
          _link('t:a', 't:b', 20),
          _link('t:b', 't:c', 1),
          _link('t:c', 't:a', 1),
        ],
        nodes: {
          't:a': _n('t:a', 0, 0),
          't:b': _n('t:b', 40, 0),
          't:c': _n('t:c', 20, 35),
        },
        dipThreshold: 6,
        defended: DefendedPoint(x: 0, y: 0),
      );
      expect(track, isNotNull);
      expect(track.toString(), isNot(contains('COOPERATIVE (RID)')));
    });
  });
}
