import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/state/app_state.dart';

/// AUTO station for the passive-Doppler correlator (field ask
/// 2026-10-20): station position from the device GPS fix, eNB always
/// manual. These tests cover the persistence shape and the status
/// surface; the GPS-dependent arming path itself abstains without a
/// fix by design (silence, never a guess), which the status strings
/// must say out loud.
void main() {
  group('settings persistence', () {
    test('sdrAutoStation round-trips through JSON', () {
      final a = AppSettings(sdrAutoStation: true);
      final b = AppSettings()..applyJson(a.toJson());
      expect(b.sdrAutoStation, isTrue);
      final c = AppSettings()..applyJson(AppSettings().toJson());
      expect(c.sdrAutoStation, isFalse);
    });

    test('eNB-only geometry persists without a manual station', () {
      final a = AppSettings(sdrEnbLat: 35.1, sdrEnbLon: -78.9);
      final b = AppSettings()..applyJson(a.toJson());
      expect(b.sdrEnbLat, 35.1);
      expect(b.sdrEnbLon, -78.9);
      expect(b.sdrStationLat, isNull);
      expect(b.sdrStationLon, isNull);
    });

    test('a partial pair is dropped, the whole pair survives', () {
      final a = AppSettings(sdrStationLat: 35.0); // lon missing
      final b = AppSettings()..applyJson(a.toJson());
      expect(b.sdrStationLat, isNull);
      final c = AppSettings(sdrStationLat: 35.0, sdrStationLon: -78.0);
      final d = AppSettings()..applyJson(c.toJson());
      expect(d.sdrStationLat, 35.0);
      expect(d.sdrStationLon, -78.0);
    });
  });

  group('sdrGeometryStatus', () {
    test('no eNB: not configured, says eNB is always manual', () {
      final s = AppState();
      addTearDown(s.dispose);
      s.applySettings(AppSettings(sdrAutoStation: true));
      expect(s.sdrGeometryStatus, contains('NOT CONFIGURED'));
      expect(s.sdrGeometryStatus, contains('ALWAYS MANUAL'));
    });

    test('auto + eNB, no fix yet: waiting, correlator abstains', () {
      final s = AppState();
      addTearDown(s.dispose);
      s.applySettings(AppSettings(
          sdrAutoStation: true, sdrEnbLat: 35.1, sdrEnbLon: -78.9));
      expect(s.sdrGeometryStatus, contains('AUTO STATION'));
      expect(s.sdrGeometryStatus, contains('WAITING FOR A PHONE GPS FIX'));
    });

    test('manual full geometry: armed label', () {
      final s = AppState();
      addTearDown(s.dispose);
      s.applySettings(AppSettings(
        sdrStationLat: 35.0,
        sdrStationLon: -78.0,
        sdrEnbLat: 35.1,
        sdrEnbLon: -78.9,
      ));
      expect(s.sdrGeometryStatus, contains('MANUAL GEOMETRY'));
    });

    test('auto off + eNB only: tells the operator to set the station',
        () {
      final s = AppState();
      addTearDown(s.dispose);
      s.applySettings(AppSettings(sdrEnbLat: 35.1, sdrEnbLon: -78.9));
      expect(s.sdrGeometryStatus, contains('SET THE STATION'));
    });
  });
}
