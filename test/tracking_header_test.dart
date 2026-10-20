import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/screens/tracking.dart';
import 'package:shepherd/state/app_state.dart';

/// Regression test for the field report of 2026-10-20: the FIELD MAP
/// header put the title, fullscreen button, four layer toggles and the
/// mode label in a single Row, which overflowed a phone-width card —
/// HEALTH clipped mid-word and SENSORS fell off the screen.
void main() {
  testWidgets('field-map header fits a phone-width card, nothing clipped',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TrackingScreen(state: state))),
    );
    await tester.pump();
    // A RenderFlex overflow would surface here as a framework error.
    expect(tester.takeException(), isNull);
    expect(find.text('FIELD MAP'), findsOneWidget);
    expect(find.textContaining('LAYOUT'), findsOneWidget);
    // All four layer toggles present with their default labels.
    for (final label in
        ['SHADOW ON', 'RTI ON', 'HEALTH OFF', 'SENSORS ON']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('live mode: GPS + heights cards also fit phone width',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TrackingScreen(state: state))),
    );
    await tester.pump();
    // Go live the way the app does — a direct field write races the
    // async settings load and gets flipped back to simulated.
    state.applySettings(AppSettings(simulatedMode: false));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // The GPS + heights cards sit below the fold; a ListView only
    // builds children near the viewport, so scroll them into layout
    // step by step and re-check for overflows after each step.
    for (var i = 0; i < 4; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
    expect(find.text('GPS POSITIONING'), findsOneWidget);
    expect(find.text('NODE HEIGHTS + ANTENNAS'), findsOneWidget);
  });
}
