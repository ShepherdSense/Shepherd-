import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/services/radio_driver.dart';

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

    test('driver identity', () {
      final d = SdrDriver.fromAddress('');
      expect(d.driverId, 'sdr');
      expect(d.isImplemented, isTrue);
    });
  });
}
