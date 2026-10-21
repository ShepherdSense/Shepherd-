/// The Skydio settings block (P1–P3) must survive the JSON
/// round trip — a friendly registry or stream URL that silently
/// resets on restart would look exactly like the feature not
/// working.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/state/app_state.dart';

void main() {
  test('Skydio settings round-trip through toJson/applyJson', () {
    final a = AppSettings(
      friendlySerials: '1581F5FHJ229R00N3K7P, VIPER-1, A',
      remoteIdEnabled: true,
      droneEoUrl: 'rtsp://10.0.0.5:5554/subject',
      droneIrUrl: 'rtsp://10.0.0.5:6554/infrared',
      droneCloudEoUrl: 'rtsp://cloud.example/eo',
      droneCloudIrUrl: 'rtsp://cloud.example/ir',
      droneStreamSource: 'cloud',
    );
    final b = AppSettings()..applyJson(a.toJson());
    expect(b.friendlySerials, a.friendlySerials);
    expect(b.remoteIdEnabled, isTrue);
    expect(b.droneEoUrl, a.droneEoUrl);
    expect(b.droneIrUrl, a.droneIrUrl);
    expect(b.droneCloudEoUrl, a.droneCloudEoUrl);
    expect(b.droneCloudIrUrl, a.droneCloudIrUrl);
    expect(b.droneStreamSource, 'cloud');
  });

  test('defaults: RID off, local streams at the documented fit', () {
    final d = AppSettings();
    expect(d.remoteIdEnabled, isFalse);
    expect(d.friendlySerials, '');
    expect(d.droneEoUrl, 'rtsp://192.168.42.10:5554/subject');
    expect(d.droneIrUrl, 'rtsp://192.168.42.10:6554/infrared');
    expect(d.droneStreamSource, 'local');
  });

  test('invalid stream source in JSON keeps the current value', () {
    final b = AppSettings()..applyJson({'droneStreamSource': 'satellite'});
    expect(b.droneStreamSource, 'local');
  });
}
