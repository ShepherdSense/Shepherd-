/// Tests for the Drone tab stream health model + the tab widget
/// (Skydio P3, lib/services/drone_stream.dart, lib/screens/drone_tab.dart).
///
/// The widget test drives the tab with a fake player: it pins the
/// two properties that matter — switching EO/THERMAL opens the OTHER
/// endpoint (viewer-side stream selection only), and the EO view is
/// labeled as the pilot's focal view.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/screens/drone_tab.dart';
import 'package:shepherd/services/drone_stream.dart';
import 'package:shepherd/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeDronePlayer implements DronePlayer {
  final List<String> opened = [];
  bool open_ = false;
  bool playing = false;
  bool error = false;
  Duration pos = Duration.zero;

  @override
  Future<void> open(String url) async {
    opened.add(url);
    open_ = true;
  }

  @override
  Future<void> stop() async {
    open_ = false;
  }

  @override
  bool get isOpen => open_;
  @override
  bool get isPlaying => playing;
  @override
  bool get hasError => error;
  @override
  Duration get position => pos;
  @override
  int get videoWidth => 1280;
  @override
  int get videoHeight => 720;
  @override
  void dispose() {}
}

void main() {
  group('DroneStreamHealthTracker', () {
    final t0 = DateTime.utc(2026, 10, 21, 12);

    test('closed player reads NO SIGNAL', () {
      final h = DroneStreamHealthTracker();
      expect(
          h.snapshot(
              isOpen: false, playing: false, position: Duration.zero, at: t0),
          DroneStreamHealth.noSignal);
    });

    test('open with no frames yet reads CONNECTING, then LIVE', () {
      final h = DroneStreamHealthTracker();
      h.beginOpen(t0);
      expect(
          h.snapshot(
              isOpen: true, playing: false, position: Duration.zero, at: t0),
          DroneStreamHealth.connecting);
      expect(
          h.snapshot(
              isOpen: true,
              playing: true,
              position: const Duration(seconds: 1),
              at: t0.add(const Duration(milliseconds: 500))),
          DroneStreamHealth.live);
    });

    test('stalled playhead past the freeze window reads FROZEN', () {
      final h =
          DroneStreamHealthTracker(freezeAfter: const Duration(seconds: 3));
      h.beginOpen(t0);
      h.snapshot(
          isOpen: true,
          playing: true,
          position: const Duration(seconds: 5),
          at: t0);
      expect(
          h.snapshot(
              isOpen: true,
              playing: true,
              position: const Duration(seconds: 5),
              at: t0.add(const Duration(seconds: 1))),
          DroneStreamHealth.live);
      expect(
          h.snapshot(
              isOpen: true,
              playing: true,
              position: const Duration(seconds: 5),
              at: t0.add(const Duration(seconds: 4))),
          DroneStreamHealth.frozen);
    });

    test('playing at playhead zero never reads LIVE; past the connect '
        'deadline reads FROZEN', () {
      // Regression (reviewer finding): an RTSP session can be
      // accepted with the player reporting "playing" while the
      // encoder sends no frames — playhead pinned at zero. That
      // must read CONNECTING, then FROZEN, never LIVE.
      final h = DroneStreamHealthTracker(
          connectDeadline: const Duration(seconds: 5));
      h.beginOpen(t0);
      for (final s in [0, 1, 3, 4]) {
        expect(
            h.snapshot(
                isOpen: true,
                playing: true,
                position: Duration.zero,
                at: t0.add(Duration(seconds: s))),
            DroneStreamHealth.connecting,
            reason: 'at +${s}s');
      }
      expect(
          h.snapshot(
              isOpen: true,
              playing: true,
              position: Duration.zero,
              at: t0.add(const Duration(seconds: 5))),
          DroneStreamHealth.frozen);
      expect(
          h.snapshot(
              isOpen: true,
              playing: true,
              position: Duration.zero,
              at: t0.add(const Duration(seconds: 60))),
          DroneStreamHealth.frozen);
    });

    test('first frame before the connect deadline reads LIVE', () {
      final h = DroneStreamHealthTracker(
          connectDeadline: const Duration(seconds: 5));
      h.beginOpen(t0);
      expect(
          h.snapshot(
              isOpen: true, playing: true, position: Duration.zero, at: t0),
          DroneStreamHealth.connecting);
      expect(
          h.snapshot(
              isOpen: true,
              playing: true,
              position: const Duration(milliseconds: 250),
              at: t0.add(const Duration(seconds: 3))),
          DroneStreamHealth.live);
    });

    test('re-open restarts the connect deadline', () {
      final h = DroneStreamHealthTracker(
          connectDeadline: const Duration(seconds: 5));
      h.beginOpen(t0);
      expect(
          h.snapshot(
              isOpen: true,
              playing: true,
              position: Duration.zero,
              at: t0.add(const Duration(seconds: 9))),
          DroneStreamHealth.frozen);
      final t1 = t0.add(const Duration(seconds: 20));
      h.beginOpen(t1);
      expect(
          h.snapshot(
              isOpen: true, playing: true, position: Duration.zero, at: t1),
          DroneStreamHealth.connecting);
    });

    test('error reads NO SIGNAL even mid-stream', () {
      final h = DroneStreamHealthTracker();
      h.beginOpen(t0);
      h.snapshot(
          isOpen: true,
          playing: true,
          position: const Duration(seconds: 5),
          at: t0);
      h.markError();
      expect(
          h.snapshot(
              isOpen: true,
              playing: true,
              position: const Duration(seconds: 6),
              at: t0.add(const Duration(seconds: 1))),
          DroneStreamHealth.noSignal);
    });

    test('config: kinds pick their own endpoints', () {
      const c = DroneStreamConfig(
          eoUrl: 'rtsp://eo', irUrl: 'rtsp://ir', sourceLabel: 'LOCAL LINK');
      expect(c.urlFor(DroneStreamKind.eo), 'rtsp://eo');
      expect(c.urlFor(DroneStreamKind.thermal), 'rtsp://ir');
      expect(DroneStreamKind.eo.label, contains('PILOT'));
    });
  });

  group('DroneStreamRetryPolicy', () {
    final t0 = DateTime.utc(2026, 10, 21, 12);

    test('no error, no retry; first error arms one interval out', () {
      final r =
          DroneStreamRetryPolicy(interval: const Duration(seconds: 10));
      expect(r.due(t0), isFalse);
      r.noteError(t0);
      expect(r.due(t0.add(const Duration(seconds: 9))), isFalse);
      expect(r.due(t0.add(const Duration(seconds: 10))), isTrue);
    });

    test('repeated error notes do not move the deadline', () {
      final r =
          DroneStreamRetryPolicy(interval: const Duration(seconds: 10));
      r.noteError(t0);
      r.noteError(t0.add(const Duration(seconds: 8)));
      expect(r.due(t0.add(const Duration(seconds: 10))), isTrue);
    });

    test('an attempt pushes the next retry out by another interval',
        () {
      final r =
          DroneStreamRetryPolicy(interval: const Duration(seconds: 10));
      r.noteError(t0);
      r.noteAttempt(t0.add(const Duration(seconds: 10)));
      expect(r.due(t0.add(const Duration(seconds: 19))), isFalse);
      expect(r.due(t0.add(const Duration(seconds: 20))), isTrue);
    });

    test('clear disarms the schedule', () {
      final r =
          DroneStreamRetryPolicy(interval: const Duration(seconds: 10));
      r.noteError(t0);
      r.clear();
      expect(r.due(t0.add(const Duration(minutes: 5))), isFalse);
    });
  });

  group('DroneTab widget', () {
    testWidgets('EO/THERMAL switch opens the other endpoint', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      final fake = FakeDronePlayer();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DroneTab(state: state, playerFactory: () => fake),
        ),
      ));
      await tester.pump();
      // Default kind is EO: the subject stream opens on mount.
      expect(fake.opened, ['rtsp://192.168.42.10:5554/subject']);
      expect(find.text("EO · PILOT'S FOCAL VIEW"), findsOneWidget);

      await tester.tap(find.text('THERMAL'));
      await tester.pump();
      expect(fake.opened.last, 'rtsp://192.168.42.10:6554/infrared');

      await tester.tap(find.text('EO'));
      await tester.pump();
      expect(fake.opened.last, 'rtsp://192.168.42.10:5554/subject');
      // The tab is a viewer: no control language anywhere.
      expect(find.textContaining('TAKEOFF'), findsNothing);
      expect(find.textContaining('GIMBAL CONTROL'), findsNothing);
      // Unmount so the tab's health timer is cancelled.
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });

    testWidgets('latched error auto-retries on the policy cadence and '
        'stops when the error clears', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      final fake = FakeDronePlayer();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DroneTab(
            state: state,
            playerFactory: () => fake,
            // Zero interval: a retry is due on the first tick that
            // observes the error — deterministic under the fake
            // clock. Production default is 10 s.
            retryInterval: Duration.zero,
          ),
        ),
      ));
      await tester.pump();
      expect(fake.opened, hasLength(1));

      // The aircraft wasn't streaming when the tab opened: the
      // player latches an error. The tab must re-open on its own.
      fake.error = true;
      await tester.pump(const Duration(milliseconds: 600));
      expect(fake.opened, hasLength(2));
      // The manual companion: the dead surface offers tap-to-retry.
      expect(find.text('TAP TO RETRY'), findsOneWidget);
      await tester.tap(find.text('TAP TO RETRY'));
      await tester.pump();
      expect(fake.opened, hasLength(3));

      // Error clears (aircraft now streaming): no more re-opens.
      fake.error = false;
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(fake.opened, hasLength(3));

      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  });
}
