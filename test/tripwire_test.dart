import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/models/link_sample.dart';
import 'package:shepherd/services/adaptive_baseline.dart';
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

    test('a rise on a deep-fade link alarms (signed detection)', () {
      final tw = Tripwire(config: const TripwireConfig(confirmPolls: 2));
      var i = 0;
      for (; i < 20; i++) {
        tw.process(_s(90.0, i)); // anti-fade link
        tw.process(_s(70.0, i, from: 'b', to: 'a')); // deep-fade link
      }
      // +5 on the deep-fade link: the mean channel expects a rise here.
      // Dip-only logic would see -5 and stay silent.
      for (var k = 0; k < 3; k++, i++) {
        tw.process(_s(75.0, i, from: 'b', to: 'a'));
        tw.process(_s(90.0, i));
      }
      final events = tw.drainEvents();
      expect(events, hasLength(1));
      expect(events.first.direction, 'rise');
      expect(events.first.linkKey, 'b → a');
    });

    test('the same rise is missed with signed detection off', () {
      final tw = Tripwire(
          config: const TripwireConfig(
              confirmPolls: 2, signedDetection: false));
      var i = 0;
      for (; i < 20; i++) {
        tw.process(_s(90.0, i));
        tw.process(_s(70.0, i, from: 'b', to: 'a'));
      }
      for (var k = 0; k < 3; k++, i++) {
        tw.process(_s(75.0, i, from: 'b', to: 'a'));
        tw.process(_s(90.0, i));
      }
      expect(tw.drainEvents(), isEmpty);
    });

    test('a modest wrong-sign shift on an anti-fade link stays silent', () {
      final tw = Tripwire(config: const TripwireConfig(confirmPolls: 2));
      var i = 0;
      for (; i < 20; i++) {
        tw.process(_s(90.0, i));
        tw.process(_s(70.0, i, from: 'b', to: 'a'));
      }
      // +5 rise on the anti-fade (a→b) link: mean channel expects a dip,
      // variance stays under its floor. No event.
      for (var k = 0; k < 3; k++, i++) {
        tw.process(_s(95.0, i));
        tw.process(_s(70.0, i, from: 'b', to: 'a'));
      }
      expect(tw.drainEvents(), isEmpty);
      // The same magnitude as a dip DOES alarm.
      for (var k = 0; k < 3; k++, i++) {
        tw.process(_s(85.0, i));
        tw.process(_s(70.0, i, from: 'b', to: 'a'));
      }
      final events = tw.drainEvents();
      expect(events, hasLength(1));
      expect(events.first.direction, 'dip');
    });

    test('variance channel fires on jitter the mean channel ignores', () {
      final tw = Tripwire(config: const TripwireConfig(confirmPolls: 2));
      var i = _warm(tw, 20);
      // ±3 jitter: mean deviation 3 < threshold 4, but variance 9 > floor.
      for (var k = 0; k < 4; k++, i++) {
        tw.process(_s(k.isEven ? 93.0 : 87.0, i));
      }
      final events = tw.drainEvents();
      expect(events, hasLength(1));
      expect(events.first.viaVariance, isTrue);
    });

    test('a lone link treats a rise like a dip (intermediate fade)', () {
      final tw = Tripwire(config: const TripwireConfig(confirmPolls: 2));
      var i = _warm(tw, 20);
      for (var k = 0; k < 3; k++, i++) {
        tw.process(_s(102.0, i)); // +12 rise, single link
      }
      final events = tw.drainEvents();
      expect(events, hasLength(1));
      expect(events.first.direction, 'rise');
    });

    group('ARTI feed (spec integration b/c)', () {
      // Four links: an anti-fade pair (80) and a deep-fade pair (60).
      // A sustained 12 dB dip hits one anti-fade link.
      List<CrossingEvent> runScenario(
          Tripwire tw, AdaptiveBaseline? ab) {
        const links = ['a → b', 'c → d', 'e → f', 'g → h'];
        double level(String l, int k) {
          if (l == 'a → b' && k >= 30) return 68.0; // the dip event
          return (l == 'a → b' || l == 'c → d') ? 80.0 : 60.0;
        }

        var i = 0;
        for (var k = 0; k < 34; k++, i++) {
          for (final l in links) {
            final parts = l.split(' → ');
            tw.process(LinkSample(
              timestamp: _t0.add(Duration(milliseconds: 250 * i)),
              fromNode: parts[0],
              toNode: parts[1],
              snr: level(l, k),
            ));
          }
          // Mirror the app: every poll also feeds the ARTI updater
          // (vacant window — nothing is tracked in this scenario).
          final a = ab;
          if (a != null) {
            a.update(
              now: _t0.add(Duration(milliseconds: 250 * i)),
              samples: [
                for (final l in links)
                  for (final dir in const ['dip', 'rise'])
                    ArtiSample(
                      linkKey: l,
                      channel: 'mesh',
                      direction: dir,
                      level: level(l, k),
                      madThreshold: 3.0,
                    ),
              ],
              tracks: const [],
              nodes: const {},
              heldLinks: tw.heldLinkPolls,
            );
          }
        }
        return tw.drainEvents();
      }

      test('detection outcomes are unchanged with the ARTI feed attached',
          () {
        // The feed is live (ARTI learned the quiet levels, phi at the
        // unset prior): it must change NOTHING — same events, same
        // depths, same directions. MAD thresholds and detection
        // decisions stay on the tripwire's own rolling-median baseline.
        final plain = runScenario(
            Tripwire(config: const TripwireConfig(confirmPolls: 2)),
            null);
        final fedTw =
            Tripwire(config: const TripwireConfig(confirmPolls: 2));
        final ab = AdaptiveBaseline();
        fedTw.attachAdaptiveBaseline(ab);
        final fed = runScenario(fedTw, ab);

        expect(plain, hasLength(1));
        expect(fed, hasLength(plain.length));
        for (var i = 0; i < plain.length; i++) {
          expect(fed[i].linkKey, plain[i].linkKey);
          expect(fed[i].direction, plain[i].direction);
          expect(fed[i].dipDepth, plain[i].dipDepth);
          expect(fed[i].durationSecs, plain[i].durationSecs);
          expect(fed[i].viaVariance, plain[i].viaVariance);
        }
        // Sanity: the scenario really did detect the dip.
        expect(plain.first.linkKey, 'a → b');
        expect(plain.first.direction, 'dip');
        expect(plain.first.dipDepth, greaterThan(10));
      });

      test('suspect ARTI entries abstain from the fade-level feed', () {
        // Drive an entry past the divergence cap: it registers at −60
        // (muCalib = −60), then the level moves to −50 and mu follows —
        // |mu − muCalib| ≈ 10 dB > the 6 dB cap → suspect → the feed
        // abstains instead of handing the detector a runaway reference.
        final ab = AdaptiveBaseline();
        List<ArtiSample> at(double level) => [
              for (final dir in const ['dip', 'rise'])
                ArtiSample(
                  linkKey: 'a → b',
                  channel: 'mesh',
                  direction: dir,
                  level: level,
                  madThreshold: 3.0,
                ),
            ];
        ab.update(
          now: _t0,
          samples: at(-60.0),
          tracks: const [],
          nodes: const {},
        );
        for (var i = 1; i < 40; i++) {
          ab.update(
            now: _t0.add(Duration(seconds: i)),
            samples: at(-50.0),
            tracks: const [],
            nodes: const {},
          );
        }
        expect(ab.suspectLinkKeys, contains('a → b'));
        expect(ab.muForLink('a → b'), isNull);
        // A healthy link still feeds.
        ab.register(
            linkKey: 'c → d',
            channel: 'mesh',
            direction: 'dip',
            mu0: -70.0);
        expect(ab.muForLink('c → d'), closeTo(-70.0, 1e-9));
        // Unknown link abstains.
        expect(ab.muForLink('nope → nope'), isNull);
      });
    });
  });
}
