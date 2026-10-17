import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/models/link_sample.dart';
import 'package:shepherd/models/tracking.dart';
import 'package:shepherd/services/tracker.dart';

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

void main() {
  final defended = DefendedPoint(x: 0, y: 0);

  test('two nodes (one link) never produce a position fix', () {
    final nodes = {'t:a': _n('t:a', 0, 0), 't:b': _n('t:b', 40, 0)};
    final track = Tracker().update(
      now: _now,
      samples: [_link('t:a', 't:b', 20)],
      nodes: nodes,
      dipThreshold: 6,
      defended: defended,
    );
    expect(track, isNull);
  });

  test('three nodes localize near the disturbed link', () {
    final nodes = {
      't:a': _n('t:a', 0, 0),
      't:b': _n('t:b', 40, 0),
      't:c': _n('t:c', 20, 35),
    };
    final track = Tracker().update(
      now: _now,
      samples: [
        _link('t:a', 't:b', 20),
        _link('t:b', 't:c', 1),
        _link('t:c', 't:a', 1),
      ],
      nodes: nodes,
      dipThreshold: 6,
      defended: defended,
    );
    expect(track, isNotNull);
    expect(track!.x, inInclusiveRange(5, 35));
    expect(track.linksUsed, 1);
  });

  test('nothing disturbed -> no track', () {
    final nodes = {
      't:a': _n('t:a', 0, 0),
      't:b': _n('t:b', 40, 0),
      't:c': _n('t:c', 20, 35),
    };
    final track = Tracker().update(
      now: _now,
      samples: [
        _link('t:a', 't:b', 1),
        _link('t:b', 't:c', 1),
        _link('t:c', 't:a', 1),
      ],
      nodes: nodes,
      dipThreshold: 6,
      defended: defended,
    );
    expect(track, isNull);
  });

  test('a large mesh still solves (grid cost is capped)', () {
    final nodes = <String, NodePosition>{
      for (var i = 0; i < 12; i++)
        't:$i': _n('t:$i', 40.0 * (i % 4), 40.0 * (i ~/ 4)),
    };
    final ids = nodes.keys.toList();
    final samples = <LinkSample>[
      for (var i = 0; i < ids.length; i++)
        for (var j = i + 1; j < ids.length; j++)
          _link(ids[i], ids[j], (i == 0 && j == 1) ? 20 : 1),
    ];
    final sw = Stopwatch()..start();
    final track = Tracker().update(
      now: _now,
      samples: samples,
      nodes: nodes,
      dipThreshold: 6,
      defended: defended,
    );
    sw.stop();
    expect(track, isNotNull);
    expect(sw.elapsedMilliseconds, lessThan(3000));
  });
}
