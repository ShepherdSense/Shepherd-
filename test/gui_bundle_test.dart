import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shepherd/models/link_sample.dart';
import 'package:shepherd/models/tracking.dart';
import 'package:shepherd/screens/dashboard.dart';
import 'package:shepherd/state/app_state.dart';
import 'package:shepherd/theme.dart';

CrossingEvent _ev(String link, int secs, {String size = 'M'}) =>
    CrossingEvent(
      timestamp: DateTime.utc(2026, 10, 16, 12, 0, secs),
      linkKey: link,
      dipDepth: 8.0,
      durationSecs: 2.0,
      sizeEstimate: size,
    );

void main() {
  group('eventSizeColor', () {
    test('S/M/L mapping matches the detection card', () {
      expect(eventSizeColor('S'), SentryColors.blue);
      expect(eventSizeColor('M'), SentryColors.amber);
      expect(eventSizeColor('L'), SentryColors.red);
      // Unknown sizes read as large, never as small.
      expect(eventSizeColor('?'), SentryColors.red);
    });
  });

  group('timelineEvents', () {
    test('takes the last N, oldest first', () {
      final evts = [
        for (var i = 0; i < 5; i++) _ev('a → b', i),
      ]; // newest-first: secs 4..0
      final newestFirst = evts.reversed.toList();
      final tl = timelineEvents(newestFirst, 3);
      expect(tl.length, 3);
      expect(tl.first.timestamp.second, 2);
      expect(tl.last.timestamp.second, 4);
    });

    test('empty in, empty out', () {
      expect(timelineEvents([]), isEmpty);
    });

    test('fewer than N returns all, oldest first', () {
      final evts = [_ev('a → b', 2), _ev('a → b', 1)];
      final tl = timelineEvents(evts);
      expect(tl.length, 2);
      expect(tl.first.timestamp.second, 1);
    });
  });

  group('triage', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('triageKeyFor is stable and unique per event', () {
      final a = _ev('a → b', 1);
      final b = _ev('a → b', 2);
      final c = _ev('a → c', 1);
      expect(AppState.triageKeyFor(a), AppState.triageKeyFor(a));
      expect(AppState.triageKeyFor(a) == AppState.triageKeyFor(b),
          isFalse);
      expect(AppState.triageKeyFor(a) == AppState.triageKeyFor(c),
          isFalse);
    });

    test('triageEvent toggles; stats and falseAlarmRate follow', () {
      final s = AppState();
      addTearDown(s.dispose);
      final e1 = _ev('a → b', 1);
      final e2 = _ev('c → d', 2);
      final e3 = _ev('e → f', 3);
      s.events.addAll([e1, e2, e3]);

      expect(s.triageStats,
          {'acked': 0, 'falseAlarm': 0, 'unreviewed': 3});
      expect(s.falseAlarmRate, 0.0);

      s.triageEvent(e1, AppState.triageAcked);
      s.triageEvent(e2, AppState.triageFalseAlarm);
      expect(s.triageStats,
          {'acked': 1, 'falseAlarm': 1, 'unreviewed': 1});
      expect(s.falseAlarmRate, 0.5);

      // Tapping the same verdict again clears it.
      s.triageEvent(e2, AppState.triageFalseAlarm);
      expect(s.triageStats,
          {'acked': 1, 'falseAlarm': 0, 'unreviewed': 2});
      expect(s.falseAlarmRate, 0.0);

      // Switching verdict replaces, never double-counts.
      s.triageEvent(e1, AppState.triageFalseAlarm);
      expect(s.triageStats,
          {'acked': 0, 'falseAlarm': 1, 'unreviewed': 2});
    });

    test('stats ignore triage keys for events no longer listed', () {
      final s = AppState();
      addTearDown(s.dispose);
      final e = _ev('a → b', 1);
      s.events.add(e);
      s.triageEvent(e, AppState.triageAcked);
      expect(s.triageStats['acked'], 1);
      s.events.clear(); // evicted; the trim path also prunes the map
      expect(s.triageStats,
          {'acked': 0, 'falseAlarm': 0, 'unreviewed': 0});
    });
  });

  group('camera confirmation hook', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('stub: default off, always NOT_CONFIGURED', () {
      final s = AppState();
      addTearDown(s.dispose);
      expect(s.cameraConfirmationEnabled, isFalse);
      final r = s.requestCameraConfirmation(_ev('a → b', 1));
      expect(r.status, 'NOT_CONFIGURED');
      expect(r.note, isNotEmpty);
      // Even enabled, the stub cannot confirm — upgrade-only contract.
      s.toggleCameraConfirmation(true);
      expect(s.cameraConfirmationEnabled, isTrue);
      expect(
          s.requestCameraConfirmation(_ev('a → b', 1)).status,
          'NOT_CONFIGURED');
    });
  });

  group('node health map', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('unknown when no links touch the node', () {
      final s = AppState();
      addTearDown(s.dispose);
      s.nodePositions['x:1'] =
          NodePosition(nodeId: 'x:1', x: 0, y: 0);
      expect(s.nodeHealthMap['x:1'], NodeHealthStatus.unknown);
    });

    test('empty when no positioned nodes', () {
      final s = AppState();
      addTearDown(s.dispose);
      expect(s.nodeHealthMap, isEmpty);
    });
  });

  group('SDR accessors', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('no pollers means no SDR driver and no bands', () {
      final s = AppState();
      addTearDown(s.dispose);
      expect(s.hasSdrDriver, isFalse);
      expect(s.sdrBands, isEmpty);
    });
  });
}
