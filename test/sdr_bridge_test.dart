import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepherd/services/radio_driver.dart';
import 'package:shepherd/state/app_state.dart';

Map<String, dynamic> bandPacket({
  double energy = -52.3,
  String kind = 'band',
  int v = 1,
}) =>
    {
      'v': v,
      'kind': kind,
      'radio': 'pluto0',
      'band': '2437',
      'center_mhz': 2437.0,
      'bw_mhz': 20.0,
      'energy_dbfs': energy,
      'noise_dbfs': -81.2,
      'bins_dbfs': [-53.1, -60.0, -61.2, -59.8, -62.0, -60.5, -61.1, -60.9],
      't': 1729123456.789,
    };

void main() {
  group('SdrBand.tryParse', () {
    test('parses a valid band packet', () {
      final b = SdrBand.tryParse(bandPacket());
      expect(b, isNotNull);
      expect(b!.radio, 'pluto0');
      expect(b.band, '2437');
      expect(b.centerMhz, 2437.0);
      expect(b.energyDbfs, -52.3);
      expect(b.noiseDbfs, -81.2);
      expect(b.binsDbfs, hasLength(8));
    });

    test('rejects NaN / infinite readings (they would poison a baseline)', () {
      expect(SdrBand.tryParse(bandPacket(energy: double.nan)), isNull);
      expect(SdrBand.tryParse(bandPacket(energy: double.infinity)), isNull);
      expect(SdrBand.tryParse(bandPacket(energy: double.negativeInfinity)),
          isNull);
    });

    test('optional peak/span fields parse when present, null when absent', () {
      final plain = SdrBand.tryParse(bandPacket())!;
      expect(plain.peakMhz, isNull);
      expect(plain.spanMhz, isNull);
      final j = bandPacket()
        ..['peak_mhz'] = 2441.5
        ..['peak_dbfs'] = -48.2
        ..['span_mhz'] = 3.2;
      final rich = SdrBand.tryParse(j)!;
      expect(rich.peakMhz, 2441.5);
      expect(rich.peakDbfs, -48.2);
      expect(rich.spanMhz, 3.2);
    });

    test('rejects beacons, wrong versions, and garbage without throwing', () {
      expect(SdrBand.tryParse(bandPacket(kind: 'beacon')), isNull);
      expect(SdrBand.tryParse(bandPacket(v: 2)), isNull);
      expect(SdrBand.tryParse({}), isNull);
      expect(SdrBand.tryParse({'v': 1, 'kind': 'band'}), isNull);
      expect(
          SdrBand.tryParse({
            'v': 1,
            'kind': 'band',
            'radio': 'x',
            'band': 'y',
            'center_mhz': 'not-a-number',
          }),
          isNull);
    });
  });

  group('SdrBand.toLinkSample', () {
    test('virtual link naming is namespaced and self-describing', () {
      final s = SdrBand.tryParse(bandPacket())!.toLinkSample();
      expect(s.fromNode, 'sdr:pluto0');
      expect(s.toNode, 'sdr:band-2437');
    });

    test('polarity: an energy RISE reads as a positive dip', () {
      // Quiet band: -81 dBFS. Emitter appears: -52 dBFS.
      final quiet = SdrBand.tryParse(bandPacket(energy: -81.0))!;
      final hot = SdrBand.tryParse(bandPacket(energy: -52.0))!;
      final q = quiet.toLinkSample();
      final h = hot.toLinkSample();
      // Tripwire computes dip = baseline - snr; with a quiet baseline
      // the hot sample must produce a positive dip of ~29 dB.
      final baseline = q.snr!;
      final dip = baseline - h.snr!;
      expect(dip, closeTo(29.0, 0.001));
      expect(dip, greaterThan(0));
    });

    test('sub-band peaks ride along negated in pcns', () {
      final s = SdrBand.tryParse(bandPacket())!.toLinkSample();
      expect(s.pcns, hasLength(8));
      expect(s.pcns.first, closeTo(53.1, 0.001));
    });
  });

  group('SdrDriver.fromAddress', () {
    test('defaults to the bridge listen endpoint', () {
      final d = SdrDriver.fromAddress('');
      expect(d.host, '127.0.0.1');
      expect(d.port, SdrDriver.defaultBridgePort);
    });

    test('parses host:port and bare host', () {
      final a = SdrDriver.fromAddress('192.168.4.10:49200');
      expect(a.host, '192.168.4.10');
      expect(a.port, 49200);
      final b = SdrDriver.fromAddress('192.168.4.10');
      expect(b.host, '192.168.4.10');
      expect(b.port, SdrDriver.defaultBridgePort);
    });

    test('a hostname or wildcard address does not crash construction', () {
      expect(SdrDriver.fromAddress('0.0.0.0:49161').host, '0.0.0.0');
      expect(SdrDriver.fromAddress('my-pc.local').host, 'my-pc.local');
    });

    test('sweeping SDR declares a longer sample lifetime than a mesh radio',
        () {
      final d = SdrDriver.fromAddress('');
      expect(d.sampleMaxAge, isNotNull);
      expect(d.sampleMaxAge!.inSeconds, greaterThan(10));
    });

    test('driver identity', () {
      final d = SdrDriver.fromAddress('');
      expect(d.driverId, 'sdr');
      expect(d.isImplemented, isTrue);
    });
  });
  _elrsTests();
}

Map<String, dynamic> chirpPacket({
  String kind = 'elrs_chirp',
  int v = 1,
  double freqMhz = 2441.23,
  double centerMhz = 2437.0,
}) =>
    {
      'v': v,
      'kind': kind,
      'radio': 'rtlsdr0',
      'band': '2437',
      'center_mhz': centerMhz,
      'freq_mhz': freqMhz,
      'sf': 5,
      'bw_khz': 812.5,
      'snr_db': 14.2,
      't': 1729123456.789,
    };

Map<String, dynamic> sigPacket({
  String kind = 'elrs_signature',
  int v = 1,
  double score = 0.62,
  String mode = 'gemini-2g4',
}) =>
    {
      'v': v,
      'kind': kind,
      'radio': 'usrp0',
      'mode': mode,
      'score': score,
      'obs': 7,
      'bands': ['2437'],
      'freqs_mhz': [2441.2, 2481.3],
      't': 1729123456.789,
    };

ElrsChirp _chirp(String radio, double centerMhz, double freqMhz,
        DateTime t) =>
    ElrsChirp(
      radio: radio,
      band: '${centerMhz.round()}',
      centerMhz: centerMhz,
      freqMhz: freqMhz,
      sf: 5,
      bwKhz: 812.5,
      snrDb: 14.0,
      t: t,
    );

void _elrsTests() {
  group('ElrsChirp.tryParse', () {
    test('parses a valid chirp packet', () {
      final c = ElrsChirp.tryParse(chirpPacket());
      expect(c, isNotNull);
      expect(c!.radio, 'rtlsdr0');
      expect(c.freqMhz, 2441.23);
      expect(c.sf, 5);
      expect(c.family, '2g4');
    });

    test('900 MHz family classified for GemX correlation', () {
      final c = ElrsChirp.tryParse(chirpPacket(centerMhz: 915.0))!;
      expect(c.family, '900m');
    });

    test('rejects wrong kinds, versions, NaN, garbage; never throws', () {
      expect(ElrsChirp.tryParse(chirpPacket(kind: 'band')), isNull);
      expect(ElrsChirp.tryParse(chirpPacket(v: 2)), isNull);
      expect(
          ElrsChirp.tryParse(chirpPacket(freqMhz: double.nan)), isNull);
      expect(ElrsChirp.tryParse({}), isNull);
      expect(ElrsChirp.tryParse({'v': 1, 'kind': 'elrs_chirp'}), isNull);
    });
  });

  group('ElrsSignature.tryParse', () {
    test('parses a valid signature packet', () {
      final s = ElrsSignature.tryParse(sigPacket());
      expect(s, isNotNull);
      expect(s!.mode, 'gemini-2g4');
      expect(s.score, 0.62);
      expect(s.obs, 7);
    });

    test('rejects out-of-range and NaN scores', () {
      expect(ElrsSignature.tryParse(sigPacket(score: 1.5)), isNull);
      expect(ElrsSignature.tryParse(sigPacket(score: -0.1)), isNull);
      expect(
          ElrsSignature.tryParse(sigPacket(score: double.nan)), isNull);
      expect(ElrsSignature.tryParse(sigPacket(kind: 'band')), isNull);
      expect(ElrsSignature.tryParse({}), isNull);
    });
  });

  group('ELRS honesty contract', () {
    test('display label says Possible, never confirmed/identified', () {
      final labels = [
        ElrsSignature.tryParse(sigPacket())!.displayLabel,
        ElrsSignature.tryParse(sigPacket(mode: 'gemx'))!.displayLabel,
        ElrsSignature.tryParse(sigPacket(mode: 'gemini-900m'))!
            .displayLabel,
      ];
      for (final l in labels) {
        expect(l, contains('Possible'));
        final lower = l.toLowerCase();
        expect(lower.contains('confirm'), isFalse, reason: l);
        expect(lower.contains('identified as'), isFalse, reason: l);
        expect(lower.contains('detected elrs'), isFalse, reason: l);
        expect(lower.contains('elrs drone'), isFalse, reason: l);
      }
    });

    test('gemx label names both bands, not a drone claim', () {
      final l =
          ElrsSignature.tryParse(sigPacket(mode: 'gemx'))!.displayLabel;
      expect(l, contains('2.4 GHz + 900 MHz'));
    });
  });

  group('GeminiCorrelator', () {
    final now = DateTime(2026, 10, 17, 12, 0, 0);

    test('GemX: 2.4 GHz + 900 MHz chirps within window correlate', () {
      final chirps = [
        _chirp('r0', 2437.0, 2441.0, now),
        _chirp('r1', 915.0, 915.5, now.add(const Duration(seconds: 1))),
      ];
      final sigs = GeminiCorrelator.correlate(chirps, now);
      expect(sigs, hasLength(1));
      expect(sigs.first.mode, 'gemx');
      expect(sigs.first.obs, 1);
      expect(sigs.first.score, inExclusiveRange(0.0, 1.0));
    });

    test('a lone coincidence is weak evidence (below the app bar)', () {
      // 1 - exp(-1/3) ~= 0.28 < 0.30: the app only surfaces and merges
      // signatures at >= 0.30, so one coincidence never moves the UI.
      final chirps = [
        _chirp('r0', 2437.0, 2441.0, now),
        _chirp('r1', 915.0, 915.5, now),
      ];
      final s = GeminiCorrelator.correlate(chirps, now).first;
      expect(s.score, lessThan(0.30));
    });

    test('repeated coincidences build the score', () {
      final chirps = <ElrsChirp>[];
      for (var k = 0; k < 5; k++) {
        final t = now.subtract(Duration(seconds: k * 20));
        chirps.add(_chirp('r0', 2437.0, 2441.0, t));
        chirps.add(_chirp('r1', 915.0, 915.5, t));
      }
      final s = GeminiCorrelator.correlate(chirps, now).first;
      expect(s.obs, 5);
      expect(s.score, greaterThan(0.5));
    });

    test('chirps too far apart in time do not correlate', () {
      final chirps = [
        _chirp('r0', 2437.0, 2441.0, now.subtract(const Duration(minutes: 5))),
        _chirp('r1', 915.0, 915.5, now),
      ];
      expect(GeminiCorrelator.correlate(chirps, now), isEmpty);
    });

    test('same radio and band never self-correlates', () {
      final chirps = [
        _chirp('r0', 2437.0, 2441.0, now),
        _chirp('r0', 2437.0, 2441.5, now),
      ];
      expect(GeminiCorrelator.correlate(chirps, now), isEmpty);
    });

    test('two 2.4 GHz radios 40 MHz apart correlate as dual-frequency', () {
      final chirps = [
        _chirp('r0', 2437.0, 2420.0, now),
        _chirp('r1', 2437.0, 2460.0, now),
        _chirp('r0', 2437.0, 2420.0, now.subtract(const Duration(seconds: 20))),
        _chirp('r1', 2437.0, 2460.0, now.subtract(const Duration(seconds: 20))),
      ];
      final sigs = GeminiCorrelator.correlate(chirps, now);
      expect(sigs.any((s) => s.mode == 'gemini-2g4'), isTrue);
    });

    test('wrong separation does not correlate', () {
      final chirps = [
        _chirp('r0', 2437.0, 2441.0, now),
        _chirp('r1', 2437.0, 2446.0, now), // 5 MHz: not Gemini
      ];
      expect(GeminiCorrelator.correlate(chirps, now), isEmpty);
    });

    test('stale chirps age out of the correlation window', () {
      final chirps = [
        _chirp('r0', 2437.0, 2441.0,
            now.subtract(const Duration(minutes: 10))),
        _chirp('r1', 915.0, 915.5,
            now.subtract(const Duration(minutes: 10))),
      ];
      expect(GeminiCorrelator.correlate(chirps, now), isEmpty);
    });
  });

  group('PmrReading.tryParse (EXPERIMENTAL monitor)', () {
    Map<String, dynamic> pmrPacket({
      double pmr = 16.0,
      double? threshold,
      double? margin,
      bool alert = false,
      bool experimental = true,
      String kind = 'pmr',
      int v = 1,
    }) =>
        {
          'v': v,
          'kind': kind,
          'radio': 'rtlsdr0',
          'channel_mhz': 915.0,
          'experimental': experimental,
          'pmr_db': pmr,
          'n_chirps': 11,
          'tone_off_hz': 37109.4,
          'threshold_db': threshold,
          'margin_db': margin,
          'alert': alert,
          't': 1729123456.789,
        };

    test('parses a report-only reading (no threshold, never alerts)', () {
      final r = PmrReading.tryParse(pmrPacket());
      expect(r, isNotNull);
      expect(r!.radio, 'rtlsdr0');
      expect(r.channelMhz, 915.0);
      expect(r.pmrDb, 16.0);
      expect(r.nChirps, 11);
      expect(r.thresholdDb, isNull);
      expect(r.marginDb, isNull);
      expect(r.alert, isFalse);
      expect(r.displayLabel, contains('EXPERIMENTAL'));
      expect(r.displayLabel, contains('report-only'));
    });

    test('parses an alerting reading with threshold and margin', () {
      // Margin is RECOMPUTED from pmr and threshold (wire value
      // ignored); 8.1 - 12.0 differs from the literal -3.9 by 1 ULP,
      // hence closeTo.
      final r = PmrReading.tryParse(
          pmrPacket(pmr: 8.1, threshold: 12.0, margin: -3.9, alert: true))!;
      expect(r.alert, isTrue);
      expect(r.thresholdDb, 12.0);
      expect(r.marginDb, closeTo(-3.9, 1e-9));
      expect(r.displayLabel, contains('ALERT'));
      expect(r.displayLabel, contains('consistent with'));
      expect(r.displayLabel, contains('NOT a confirmed jamming verdict'));
    });

    test('recomputes alert/margin, ignoring contradictory wire values', () {
      // Wire claims alert=true, but pmr is ABOVE threshold: the
      // display must be self-consistent (no alert, positive margin).
      final r = PmrReading.tryParse(
          pmrPacket(pmr: 16.0, threshold: 12.0, margin: -3.9, alert: true))!;
      expect(r.alert, isFalse);
      expect(r.marginDb, closeTo(4.0, 1e-9));
      expect(r.displayLabel, contains('above threshold'));
      // And the reverse: wire claims no alert, but pmr is BELOW.
      final r2 = PmrReading.tryParse(
          pmrPacket(pmr: 8.1, threshold: 12.0, margin: 3.9, alert: false))!;
      expect(r2.alert, isTrue);
      expect(r2.marginDb, closeTo(-3.9, 1e-9));
      expect(r2.displayLabel, contains('ALERT'));
    });

    test('rejects pmr packets without the experimental flag', () {
      expect(PmrReading.tryParse(pmrPacket(experimental: false)), isNull);
      final noFlag = pmrPacket()..remove('experimental');
      expect(PmrReading.tryParse(noFlag), isNull);
    });

    test('rejects wrong kinds, versions, NaN; never throws', () {
      expect(PmrReading.tryParse(pmrPacket(kind: 'band')), isNull);
      expect(PmrReading.tryParse(pmrPacket(v: 2)), isNull);
      expect(PmrReading.tryParse(pmrPacket(pmr: double.nan)), isNull);
      expect(PmrReading.tryParse({}), isNull);
      expect(PmrReading.tryParse({'v': 1, 'kind': 'pmr'}), isNull);
    });

    test('driver stores pmr readings and surfaces the latest alert', () {
      final d = SdrDriver(host: '127.0.0.1', port: 49161);
      expect(d.recentPmrReadings, isEmpty);
      expect(d.latestPmrAlert, isNull);
      // Current timestamps: _handle prunes readings older than the
      // 120 s window on arrival, so fixed 2024-era stamps would vanish.
      final nowSec =
          DateTime.now().millisecondsSinceEpoch / 1000.0;
      d.datagramForTest(
          '{"v":1,"kind":"pmr","radio":"rtlsdr0","channel_mhz":915.0,'
          '"experimental":true,"pmr_db":16.0,"n_chirps":11,'
          '"tone_off_hz":1000.0,"threshold_db":null,"margin_db":null,'
          '"alert":false,"t":$nowSec}');
      d.datagramForTest(
          '{"v":1,"kind":"pmr","radio":"rtlsdr0","channel_mhz":915.0,'
          '"experimental":true,"pmr_db":8.1,"n_chirps":10,'
          '"tone_off_hz":1000.0,"threshold_db":12.0,"margin_db":-3.9,'
          '"alert":true,"t":${nowSec + 1}}');
      expect(d.recentPmrReadings, hasLength(2));
      expect(d.latestPmrAlert, isNotNull);
      expect(d.latestPmrAlert!.pmrDb, 8.1);
      // A pmr datagram never becomes a tripwire link sample.
      expect(d.latestBands, isEmpty);
    });
  });

  group('AppState.pmrMonitorLines (EXPERIMENTAL monitor)', () {
    test('alerts first, then readings, capped at 12', () {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      final d = SdrDriver(host: '127.0.0.1', port: 49161);
      state.attachDriverForTest(d);
      final nowSec = DateTime.now().millisecondsSinceEpoch / 1000.0;
      String pkt(double pmr, double? thr, double t) =>
          '{"v":1,"kind":"pmr","radio":"rtlsdr0","channel_mhz":915.0,'
          '"experimental":true,"pmr_db":$pmr,"n_chirps":11,'
          '"tone_off_hz":1000.0,"threshold_db":${thr ?? 'null'},'
          '"margin_db":null,"alert":false,"t":$t}';
      // 12 report-only readings first, then 2 alerts: the lines must
      // still lead with the alerts and cap at 12 total.
      for (var i = 0; i < 12; i++) {
        d.datagramForTest(pkt(16.0, null, nowSec + i));
      }
      d.datagramForTest(pkt(8.1, 12.0, nowSec + 20));
      d.datagramForTest(pkt(7.5, 12.0, nowSec + 21));
      final lines = state.pmrMonitorLines;
      expect(lines, hasLength(12));
      expect(lines[0], contains('ALERT'));
      expect(lines[1], contains('ALERT'));
      for (final l in lines.sublist(2)) {
        expect(l, contains('report-only'));
      }
    });
  });
}
