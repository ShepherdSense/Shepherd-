import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/screens/wifi_vision.dart';
import 'package:shepherd/services/wifi_sense.dart';
import 'package:shepherd/state/app_state.dart';

/// Regression tests for the field report of 2026-10-20 (BLE section):
/// the NEARBY WIRELESS (BLE) header put the title, MONITOR and SCAN in
/// a single Row — MONITOR was pushed half off a phone-width card and
/// SCAN landed entirely off-screen (measured: title ends x=310,
/// MONITOR to x=433, SCAN to x=521 at 360 px wide). The same screen's
/// WI-FI FIELD STATUS header also overflowed by 14 px with the status
/// chip beside the title. Headers now use a title row + Wrap.
void main() {
  testWidgets('wifi vision headers fit a phone-width screen',
      (tester) async {
    // Tall viewport so every card lays out in a single pass.
    tester.view.physicalSize = const Size(360, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState();
    addTearDown(state.dispose);
    state.toggleWifiVision(true);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: WifiVisionScreen(state: state))),
    );
    await tester.pump();
    // Any RenderFlex overflow in any card surfaces here.
    expect(tester.takeException(), isNull);

    // BLE actions: both present, both fully on-screen, same row.
    final monitor = find.widgetWithText(TextButton, 'MONITOR');
    final scan = find.widgetWithText(TextButton, 'SCAN');
    expect(monitor, findsWidgets);
    expect(scan, findsWidgets);
    // The BLE card's SCAN is the one below the BLE title.
    final bleTitle = find.text('NEARBY WIRELESS (BLE)');
    expect(bleTitle, findsOneWidget);
    final titleRect = tester.getRect(bleTitle);
    Rect? bleScan;
    for (final e in scan.evaluate()) {
      final r = tester.getRect(find.byWidget(e.widget));
      if (r.top > titleRect.top) bleScan = r;
    }
    expect(bleScan, isNotNull, reason: 'BLE SCAN button exists');
    final monitorRect = tester.getRect(monitor.first);
    expect(monitorRect.left, greaterThanOrEqualTo(0));
    expect(monitorRect.right, lessThanOrEqualTo(360));
    expect(bleScan!.left, greaterThanOrEqualTo(0));
    expect(bleScan.right, lessThanOrEqualTo(360));
    // Same Wrap row: tops align.
    expect((bleScan.top - monitorRect.top).abs(), lessThan(2.0),
        reason: 'MONITOR and SCAN share a row');
    state.toggleWifiVision(false);
  });

  // Field report 2026-10-21: the WI-FI FIELD STATUS headline at
  // 40 pt wrapped mid-word on a phone ('DETECTE' / 'D'). The status
  // word now renders at 28 pt, single-line, inside a scale-down
  // FittedBox — assert it stays on one line at 360 px wide.
  testWidgets('wifi DETECTED headline stays on one line', (tester) async {
    tester.view.physicalSize = const Size(360, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState();
    addTearDown(state.dispose);
    state.toggleWifiVision(true);
    // Register the AP first: ingest() closes any crossing whose AP
    // is not in the registry, so a bare injected crossing would be
    // swept away by the first poll before the panel ever paints.
    state.wifi.ingest([
      WifiApReading(
        ssid: 'TESTNET',
        bssid: 'aa:bb:cc:dd:ee:ff',
        rssiDbm: -55,
        isConnected: false,
      ),
    ]);
    state.wifi.activeCrossings['aa:bb:cc:dd:ee:ff'] = WifiCrossingEvent(
      bssid: 'aa:bb:cc:dd:ee:ff',
      ssid: 'TESTNET',
      startTime: DateTime.now(),
      peakDipDb: 9.0,
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: WifiVisionScreen(state: state))),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    final headline = find.text('DETECTED');
    expect(headline, findsOneWidget);
    final widget = tester.widget<Text>(headline);
    expect(widget.maxLines, 1);
    expect(widget.softWrap, isFalse);
    expect(find.ancestor(of: headline, matching: find.byType(FittedBox)),
        findsOneWidget);
    // One line at 28 pt is ~34 px tall; the old two-line wrap at
    // 40 pt measured ~96 px. A wrapped headline fails this.
    final rect = tester.getRect(headline);
    expect(rect.height, lessThan(60),
        reason: 'DETECTED headline must be a single line');
    expect(rect.right, lessThanOrEqualTo(360));
    state.toggleWifiVision(false);
  });
}
