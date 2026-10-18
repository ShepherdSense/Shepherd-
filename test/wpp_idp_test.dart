import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/services/confidence_merger.dart';
import 'package:shepherd/services/radio_driver.dart';

WppIdpDoppler _w({
  double dopplerHz = 40.0,
  double strength = 8.0,
  String motionState = 'static',
  double? bladeFlashHz,
  double? rcsDbm2,
}) =>
    WppIdpDoppler(
      radio: 'rtlsdr0',
      band: '2437',
      dopplerHz: dopplerHz,
      strength: strength,
      motionState: motionState,
      t: DateTime(2026, 1, 1, 12),
      bladeFlashHz: bladeFlashHz,
      rcsDbm2: rcsDbm2,
    );

void main() {
  group('WppIdpDoppler parsing', () {
    test('parses the event schema', () {
      final w = WppIdpDoppler.tryParse({
        'v': 1,
        'kind': 'wpp_idp_doppler',
        'radio': 'rtlsdr0',
        'band': '2437',
        'doppler_hz': 40.0,
        'strength': 8.0,
        'motion_state': 'static',
        'blade_flash_hz': 220.0,
        'rcs_dbm2': -8.0,
        't': 1729123456.0,
      })!;
      expect(w.radio, 'rtlsdr0');
      expect(w.dopplerHz, 40.0);
      expect(w.strength, 8.0);
      expect(w.nodeStatic, isTrue);
      expect(w.bladeFlashHz, 220.0);
      expect(w.rcsDbm2, -8.0);
    });

    test('unknown motion state fails safe to moving', () {
      final w = WppIdpDoppler.tryParse({
        'v': 1,
        'kind': 'wpp_idp_doppler',
        'radio': 'r',
        'doppler_hz': 40.0,
        'strength': 8.0,
        't': 1729123456.0,
      })!;
      expect(w.nodeStatic, isFalse);
      expect(w.mergesIntoConfidence, isFalse);
    });

    test('malformed datagrams return null, never throw', () {
      expect(WppIdpDoppler.tryParse({'v': 1, 'kind': 'nope'}), isNull);
      expect(
          WppIdpDoppler.tryParse({
            'v': 1,
            'kind': 'wpp_idp_doppler',
            'radio': 'r',
            'doppler_hz': double.nan,
            'strength': 8.0,
            't': 1729123456.0,
          }),
          isNull);
    });
  });

  group('deception constraint (Kozlov)', () {
    test('helicopter-like flash on a 250 g RCS refuses identity', () {
      // The Kozlov attack: a PCB-scale backscatter device makes a
      // DJI Mini 2 look like a helicopter to micro-Doppler. The
      // classifier must refuse identity — micro-Doppler is NEVER
      // sufficient for it.
      final a = _w(bladeFlashHz: 300.0, rcsDbm2: -20.0).assess();
      expect(a.rcsMismatch, isTrue,
          reason: 'large-rotor flash vs 250 g-quad RCS must trip the '
              'RCS-reasonableness gate');
      expect(a.label, contains('Possible'));
      for (final banned in [
        'confirmed',
        'identified',
        'located',
        'helicopter confirmed',
      ]) {
        expect(a.label.toLowerCase().contains(banned), isFalse,
            reason: 'banned assertion "$banned" in: ${a.label}');
      }
      expect(a.note, contains('RCS-reasonableness gate'));
    });

    test('blade flash is one corroborating feature, never identity', () {
      final a = _w(bladeFlashHz: 220.0, rcsDbm2: -8.0).assess();
      expect(a.rcsMismatch, isFalse);
      expect(a.label, contains('Possible'));
      expect(a.label, contains('never identity'));
    });

    test('consistent flash + RCS: no mismatch, still Possible', () {
      final a = _w(bladeFlashHz: 60.0, rcsDbm2: -10.0).assess();
      expect(a.rcsMismatch, isFalse);
      expect(a.label.startsWith('Possible'), isTrue);
    });

    test('plain Doppler line: Possible moving reflector, no identity',
        () {
      final a = _w().assess();
      expect(a.rcsMismatch, isFalse);
      expect(a.label, contains('Possible moving reflector'));
      expect(a.label, contains('consistent with'));
    });
  });

  group('ego-motion gate', () {
    test('moving-node events contribute exactly 0', () {
      expect(_w(motionState: 'moving').mergesIntoConfidence, isFalse);
      expect(_w(motionState: 'static').mergesIntoConfidence, isTrue);
      // The merger wiring's contract: a moving-node event yields no
      // contribution — modeled here as an empty contribution list.
      final contributions = <GatedCorroboration>[
        for (final w in [_w(motionState: 'moving')])
          if (w.mergesIntoConfidence)
            const GatedCorroboration(
                sensorId: 'wpp_idp:x',
                boost: kWppIdpBoost,
                gateWeight: 1.0),
      ];
      expect(contributions, isEmpty);
      final m = mergeTrackConfidence(
        baseConfidence: 0.54,
        contributions: contributions,
        trackConsistent: true,
      );
      expect(m.upgrade, 0.0);
      expect(m.displayed, 0.54);
    });
  });

  group('merger properties with WPP-IDP evidence', () {
    test('upgrade-only: never subtractive, capped, gated', () {
      expect(kWppIdpBoost, 0.10);
      final m = mergeTrackConfidence(
        baseConfidence: 0.60,
        contributions: const [
          GatedCorroboration(
              sensorId: 'wpp_idp:rtlsdr0',
              boost: kWppIdpBoost,
              gateWeight: 0.8),
        ],
        trackConsistent: true,
      );
      expect(m.displayed, greaterThanOrEqualTo(m.base));
      expect(m.upgrade, lessThanOrEqualTo(kMaxTotalUpgrade));
      final suspended = mergeTrackConfidence(
        baseConfidence: 0.60,
        contributions: const [
          GatedCorroboration(
              sensorId: 'wpp_idp:rtlsdr0',
              boost: kWppIdpBoost,
              gateWeight: 0.8),
        ],
        trackConsistent: false,
      );
      expect(suspended.upgrade, 0.0);
    });
  });

  group('SdrDriver WPP-IDP storage', () {
    test('wpp_idp_doppler datagrams land in the window', () {
      final d = SdrDriver(host: '127.0.0.1', port: 49161);
      final t = DateTime.now().millisecondsSinceEpoch / 1000.0;
      d.datagramForTest(jsonEncode({
        'v': 1,
        'kind': 'wpp_idp_doppler',
        'radio': 'rtlsdr0',
        'band': '2437',
        'doppler_hz': 40.0,
        'strength': 8.0,
        'motion_state': 'moving',
        't': t,
      }));
      expect(d.recentWppIdp, hasLength(1));
      final w = d.recentWppIdp.single;
      expect(w.nodeStatic, isFalse);
      expect(w.mergesIntoConfidence, isFalse);
      d.dispose();
    });
  });
}
