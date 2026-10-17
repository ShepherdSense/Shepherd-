import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/models/link_sample.dart';
import 'package:shepherd/services/tripwire.dart';

final _t0 = DateTime(2026, 1, 1, 12);

LinkSample _s(double snr, int i, {String from = 'a', String to = 'b'}) =>
    LinkSample(
      timestamp: _t0.add(Duration(milliseconds: 250 * i)),
      fromNode: from,
      toNode: to,
      snr: snr,
    );

/// Feed [n] quiet polls (tiny deterministic wiggle) starting at index 0.
int _warm(Tripwire tw, int n) {
  for (var i = 0; i < n; i++) {
    tw.process(_s(i.isEven ? 90.0 : 90.2, i));
  }
  return n;
}

void main() {
  group('Tripwire', () {
    test('a sustained dip emits exactly one crossing event', () {
      final tw = Tripwire(config: const TripwireConfig(confirmPolls: 2));
      var i = _warm(tw, 20);
      for (var k = 0; k < 5; k++) {
        tw.process(_s(78.0, i++)); // ~12 below baseline
      }
      final events = tw.drainEvents();
      expect(events, hasLength(1));
      expect(events.first.dipDepth, greaterThan(10));
    });

    test('a single-poll blip does not confirm (confirmPolls = 2)', () {
      final tw = Tripwire(config: const TripwireConfig(confirmPolls: 2));
      var i = _warm(tw, 20);
      tw.process(_s(78.0, i++));
      tw.process(_s(90.0, i++));
      expect(tw.drainEvents(), isEmpty);
    });

    test('baseline holds during a long disturbance', () {
      final tw = Tripwire(config: const TripwireConfig());
      var i = _warm(tw, 20);
      LinkSample last = _s(0, 0);
      for (var k = 0; k < 100; k++) {
        last = tw.process(_s(78.0, i++));
      }
      // Still reads as a ~12 dip: the baseline did not heal toward 78.
      expect(last.dip, greaterThan(10));
      expect(last.baseline, closeTo(90.1, 0.5));
    });

    test('gives up holding after maxHoldPolls and reports the reset', () {
      final tw = Tripwire(config: const TripwireConfig(maxHoldPolls: 20));
      var i = _warm(tw, 20);
      for (var k = 0; k < 30; k++) {
        tw.process(_s(78.0, i++));
      }
      expect(tw.rebaselineCount, 1);
      expect(tw.rebaselinedAt.keys, contains('a → b'));
    });

    test('links are independent', () {
      final tw = Tripwire(config: const TripwireConfig(confirmPolls: 2));
      var i = 0;
      for (; i < 20; i++) {
        tw.process(_s(90.0, i));
        tw.process(_s(70.0, i, from: 'b', to: 'a'));
      }
      for (var k = 0; k < 4; k++, i++) {
        tw.process(_s(78.0, i)); // only a→b dips
        tw.process(_s(70.0, i, from: 'b', to: 'a'));
      }
      final events = tw.drainEvents();
      expect(events, hasLength(1));
      expect(events.first.linkKey, 'a → b');
    });
  });
}
