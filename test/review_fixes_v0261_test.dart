import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/models/link_sample.dart';
import 'package:shepherd/models/tracking.dart';
import 'package:shepherd/services/offline_map_source.dart';
import 'package:shepherd/services/tracker.dart';

void main() {
  test('tilesForBounds returns unique tiles, in a sane count', () {
    final tiles = tilesForBounds(40.1, 40.0, -105.1, -105.0, 12);
    expect(tiles.toSet().length, tiles.length);
    expect(tiles, isNotEmpty);
  });

  test('tilesForBounds antimeridian box has no duplicates', () {
    final tiles = tilesForBounds(10, 0, 170, -170, 4);
    expect(tiles.toSet().length, tiles.length);
  });

  test('flat zero-dip poll produces no track (maxDip guard)', () {
    // Zero dip threshold + flat poll: disturbed links exist but maxDip
    // is 0, so the old code divided by zero in scoreAt and picked an
    // arbitrary "best" point. The guard must report a missed poll.
    final now = DateTime(2026, 1, 1, 12);
    final nodes = {
      't:a': NodePosition(nodeId: 't:a', x: 0, y: 0),
      't:b': NodePosition(nodeId: 't:b', x: 40, y: 0),
      't:c': NodePosition(nodeId: 't:c', x: 20, y: 35),
    };
    final samples = [
      for (final pair in [('t:a', 't:b'), ('t:b', 't:c'), ('t:c', 't:a')])
        LinkSample(
          timestamp: now,
          fromNode: pair.$1,
          toNode: pair.$2,
          snr: 80,
          dip: 0,
          baseline: 90,
        ),
    ];
    final track = Tracker().update(
      now: now,
      samples: samples,
      nodes: nodes,
      dipThreshold: 0,
      defended: DefendedPoint(x: 0, y: 0),
    );
    expect(track, isNull);
  });
}
