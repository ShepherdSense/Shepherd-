import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/services/esp32_driver.dart';
import 'package:shepherd/services/meshtastic_driver.dart';

// --- Minimal protobuf encoder for building synthetic frames ---

List<int> _varint(int v) {
  final out = <int>[];
  var x = v;
  do {
    var b = x & 0x7F;
    x >>= 7;
    if (x != 0) b |= 0x80;
    out.add(b);
  } while (x != 0);
  return out;
}

List<int> _tag(int field, int wire) => _varint((field << 3) | wire);

List<int> _lenField(int field, List<int> bytes) => [
      ..._tag(field, 2),
      ..._varint(bytes.length),
      ...bytes,
    ];

List<int> _u32(int field, int v) => [..._tag(field, 0), ..._varint(v)];

List<int> _fixed32(int field, int v) {
  final b = ByteData(4)..setUint32(0, v, Endian.little);
  return [..._tag(field, 5), ...b.buffer.asUint8List()];
}

List<int> _sfix32(int field, int v) {
  final b = ByteData(4)..setInt32(0, v, Endian.little);
  return [..._tag(field, 5), ...b.buffer.asUint8List()];
}

List<int> _float32(int field, double v) {
  final b = ByteData(4)..setFloat32(0, v, Endian.little);
  return [..._tag(field, 5), ...b.buffer.asUint8List()];
}

List<int> _frame(List<int> payload) => [
      0x94,
      0xC3,
      (payload.length >> 8) & 0xFF,
      payload.length & 0xFF,
      ...payload,
    ];

void main() {
  group('Meshtastic framing + protobuf decode', () {
    test('NodeInfo with position and SNR decodes', () {
      final d = MeshtasticDriver(host: '127.0.0.1', port: 4403);
      // Position: lat 37.7749, lon -122.4194 (x1e-7 sfixed32)
      final pos = [
        ..._sfix32(1, 377749000),
        ..._sfix32(2, -1224194000),
      ];
      final nodeInfo = [
        ..._u32(1, 0x12345678),
        ..._lenField(3, pos),
        ..._float32(4, 7.5),
      ];
      final fromRadio = _lenField(4, nodeInfo);
      d.ingestBytesForTest(_frame(fromRadio));

      final mp = d.meshPositions();
      expect(mp.containsKey('meshtastic:!12345678'), isTrue);
      expect(mp['meshtastic:!12345678']!.lat, closeTo(37.7749, 1e-4));
      expect(mp['meshtastic:!12345678']!.lon, closeTo(-122.4194, 1e-4));

      final samples = d.buildSamplesForTest();
      final direct = samples.where((s) =>
          s.fromNode == 'meshtastic:local' &&
          s.toNode == 'meshtastic:!12345678');
      expect(direct.length, 1);
      expect(direct.first.snr, closeTo(7.5, 1e-3));
      d.dispose();
    });

    test('NeighborInfo edge decodes via MeshPacket', () {
      final d = MeshtasticDriver(host: '127.0.0.1', port: 4403);
      final neighbor = [
        ..._u32(1, 0x22222222),
        ..._float32(2, 5.5),
      ];
      final neighborInfo = _lenField(4, neighbor);
      final data = [
        ..._u32(1, 71), // NEIGHBORINFO_APP
        ..._lenField(2, neighborInfo),
      ];
      final packet = [
        ..._fixed32(1, 0x11111111),
        ..._lenField(4, data),
        ..._float32(8, 9.0),
      ];
      d.ingestBytesForTest(_frame(_lenField(2, packet)));

      final samples = d.buildSamplesForTest();
      final edge = samples.where((s) =>
          s.fromNode == 'meshtastic:!11111111' &&
          s.toNode == 'meshtastic:!22222222');
      expect(edge.length, 1);
      expect(edge.first.snr, closeTo(5.5, 1e-3));
      d.dispose();
    });

    test('debug text before a frame does not break the framer', () {
      final d = MeshtasticDriver(host: '127.0.0.1', port: 4403);
      final nodeInfo = _u32(1, 0xABCDEF01);
      final stream = [
        ...'booting...\n'.codeUnits,
        ..._frame(_lenField(4, nodeInfo)),
      ];
      d.ingestBytesForTest(stream);
      // Node without position/SNR: no samples, but must not crash.
      expect(d.buildSamplesForTest(), isEmpty);
      d.dispose();
    });

    test('non-neighbor portnum is ignored', () {
      final d = MeshtasticDriver(host: '127.0.0.1', port: 4403);
      final data = [
        ..._u32(1, 1), // TEXT_MESSAGE_APP
        ..._lenField(2, 'hi'.codeUnits),
      ];
      final packet = [
        ..._fixed32(1, 0x11111111),
        ..._lenField(4, data),
      ];
      d.ingestBytesForTest(_frame(_lenField(2, packet)));
      expect(d.buildSamplesForTest(), isEmpty);
      d.dispose();
    });

    test('fromAddress parsing', () {
      var d = MeshtasticDriver.fromAddress('192.168.1.50');
      expect(d.host, '192.168.1.50');
      expect(d.port, 4403);
      d = MeshtasticDriver.fromAddress('192.168.1.50:4404');
      expect(d.port, 4404);
      expect(
        () => MeshtasticDriver.fromAddress('serial:/dev/ttyUSB0'),
        throwsArgumentError,
      );
    });

    test('nodeIdOf matches documented convention', () {
      expect(MeshtasticDriver.nodeIdOf(0x00a1b2c3d4),
          'meshtastic:!a1b2c3d4');
    });
  });

  group('ESP32 UDP driver', () {
    test('beacon registers position; event becomes a dip sample', () async {
      final d = Esp32Driver();
      d.datagramForTest(
        '{"type":"beacon","node":"SLN-AB12","ip":"192.168.4.1",'
        '"sensors":["wifi"],"lat":37.7749,"lon":-122.4194}',
      );
      d.datagramForTest(
        '{"type":"event","node":"SLN-AB12","sensor":"wifi","t0":12,'
        '"dur_s":5.0,"depth_db":6.5,"class":"PASSING","conf":0.7}',
      );
      final samples = await d.poll();
      final dip = samples.where((s) =>
          s.fromNode == 'esp32:SLN-AB12' &&
          s.toNode == 'esp32:SLN-AB12:wifi');
      expect(dip.length, 1);
      expect(dip.first.snr, closeTo(-6.5, 1e-9));

      final mp = d.meshPositions();
      expect(mp['SLN-AB12']!.lat, closeTo(37.7749, 1e-9));
      d.dispose();
    });

    test('malformed datagrams are ignored', () async {
      final d = Esp32Driver();
      d.datagramForTest('not json at all');
      d.datagramForTest('{"type":"beacon"}'); // no node
      d.datagramForTest('{"type":"event","node":"X","depth_db":"nan"}');
      expect(await d.poll(), isEmpty);
      d.dispose();
    });

    test('quiet node emits flat-zero keepalive', () async {
      final d = Esp32Driver();
      d.datagramForTest(
        '{"type":"beacon","node":"SHN-00FF","sensors":["wifi","ble"]}',
      );
      final samples = await d.poll();
      expect(
        samples
            .where((s) => s.toNode == 'esp32:SHN-00FF:wifi')
            .first
            .snr,
        0.0,
      );
      expect(
        samples
            .where((s) => s.toNode == 'esp32:SHN-00FF:ble')
            .first
            .snr,
        0.0,
      );
      d.dispose();
    });
  });
}
