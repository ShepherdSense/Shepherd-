/// Tests for the ASTM F3411 Remote ID decoder + contact tracker
/// (Skydio P2, lib/services/remote_id.dart).
///
/// VECTOR PROVENANCE (honest): no authoritative published wire
/// capture could be obtained — the ASTM annex vectors are
/// paywalled, and the one public hex dump found during research
/// (a DeepWiki page for a third-party parser) contradicts the
/// F3411 layout internally, so it was NOT used. These vectors were
/// hand-constructed field-by-field against the encoded struct
/// layouts in the OpenDroneID core library's odid.h
/// (opendroneid-core-c): ODID_Location_encoded,
/// ODID_System_encoded, ODID_Auth_encoded. Bitfields are declared
/// LSb-first in those structs; in particular the Location flag
/// byte (ODID_Location_encoded) allocates SpeedMult to bit 0,
/// EWDirection to bit 1, HeightType to bit 2, Reserved to bit 3,
/// and Status to bits 4-7. The arithmetic was machine-verified at
/// construction:
///   lat/lon = degrees x 1e7, int32 little-endian;
///   altitude raw = (meters + 1000) / 0.5 (raw 0 = unknown);
///   horizontal speed: mult 0 -> raw x 0.25; mult 1 -> 63.75 +
///   raw x 0.75 (continuous at 63.75; raw 255 + mult = 255 m/s
///   unknown sentinel); direction = byte + (EW ? 180 : 0),
///   360 = unknown; location timestamp = tenths of a second into
///   the UTC hour; system timestamp = seconds since 2019-01-01 UTC.
/// Chosen values mirror the reference library's documented test
/// position (51.477 N, 0.0005 E, 4.25 m/s) so a future maintainer
/// with the ASTM text can cross-check field by field. The first
/// real broadcast received on-device remains the true end-to-end
/// check of these hand-built vectors.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/services/remote_id.dart';

const basicIdBytes = <int>[
  2, 18, 49, 53, 56, 49, 70, 53, 70, 72, //
  74, 50, 50, 57, 82, 48, 48, 78, 51, 75, 55, 80, 0, 0, 0,
];

// Location flag byte (index 1) = 0x22 = 34, per the
// ODID_Location_encoded LSb-first allocation: Status 2 (airborne)
// in bits 4-7, EWDirection bit 1 set, SpeedMult bit 0 clear,
// HeightType bit 2 clear (height above takeoff).
const locationBytes = <int>[
  18, 34, 91, 17, 3, 80, 196, 174, 30, 136, //
  19, 0, 0, 27, 8, 25, 8, 248, 7, 50, 33, 176, 55, 16, 0,
];

// System field offsets per ODID_System_encoded: OperatorAltitudeGeo
// raw 2090 (45.0 m) as uint16 LE at bytes 18-19 = [42, 8]; Timestamp
// 200000000 s as uint32 LE at bytes 20-23 = [0, 194, 235, 11];
// byte 24 reserved (0).
const systemBytes = <int>[
  66, 1, 64, 157, 174, 30, 160, 15, 0, 0, //
  1, 0, 0, 0, 0, 0, 0, 0, 42, 8, 0, 194, 235, 11, 0,
];

// Authentication page 0 per ODID_Auth_encoded page zero: byte 0
// type/version, byte 1 auth type (high nibble) + page (low nibble),
// byte 2 last-page index, byte 3 length, bytes 4-7 timestamp,
// bytes 8-24 AuthData (17 bytes: 0xA0..0xB0 here).
const authPage0Bytes = <int>[
  34, 16, 0, 17, 0, 0, 0, 0, 160, 161, //
  162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175, 176,
];

const operatorIdBytes = <int>[
  82, 0, 79, 80, 45, 49, 50, 51, 52, 53, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

const selfIdBytes = <int>[
  50, 0, 84, 69, 83, 84, 32, 70, 76, 73, //
  71, 72, 84, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

void main() {
  group('decodeRidMessage', () {
    test('Basic ID: serial type, UA type, 20-char ANSI serial', () {
      final m = decodeRidMessage(basicIdBytes);
      expect(m, isA<RidBasicId>());
      final b = m! as RidBasicId;
      expect(b.version, 2);
      expect(b.idType, 1);
      expect(b.isSerial, isTrue);
      expect(b.uaType, 2);
      expect(b.uasId, '1581F5FHJ229R00N3K7P');
    });

    test('Location: position, EW direction, speeds, altitudes', () {
      final m = decodeRidMessage(locationBytes);
      expect(m, isA<RidLocation>());
      final l = m! as RidLocation;
      expect(l.status, 2); // airborne
      expect(l.lat, closeTo(51.477, 1e-9));
      expect(l.lon, closeTo(0.0005, 1e-9));
      expect(l.directionDeg, 271.0); // 91 + EW 180
      expect(l.speedHorizontalMps, 4.25); // 17 x 0.25
      expect(l.speedVerticalMps, 1.5); // 3 x 0.5
      expect(l.altBaroM, 37.5); // 2075 x 0.5 - 1000
      expect(l.altGeoM, 36.5);
      expect(l.heightM, 20.0);
      expect(l.heightAboveTakeoff, isTrue); // HeightType bit 2 = 0
      expect(l.timestampSecOfHour, closeTo(1425.6, 1e-9));
    });

    test('Location regression: flag byte 0x22 reads EW from bit 1', () {
      // Pins the ODID_Location_encoded LSb-first allocation. Under
      // the pre-fix mirrored reading (EW at bit 2, SpeedMult at
      // bit 1), flag 0x22 decoded heading 91 and speed 76.5 m/s
      // (the mult-1 formula applied to raw 17); the correct decode
      // is heading 91 + 180 = 271 and speed 17 x 0.25 = 4.25 m/s.
      final b = List<int>.from(locationBytes);
      b[1] = 0x22; // status 2, EW bit 1, SpeedMult bit 0 clear
      b[2] = 91; // direction byte
      b[3] = 17; // speed byte
      final l = decodeRidMessage(b)! as RidLocation;
      expect(l.directionDeg, 271.0);
      expect(l.speedHorizontalMps, 4.25);
      expect(l.heightAboveTakeoff, isTrue);
    });

    test('Location: speed multiplier range (138.75 m/s)', () {
      final b = List<int>.from(locationBytes);
      // 0x23 = status 2 (bits 4-7) | EW (bit 1) | SpeedMult (bit 0),
      // per the ODID_Location_encoded LSb-first allocation.
      b[1] = 0x23;
      b[3] = 100; // 63.75 + 100 x 0.75
      final l = decodeRidMessage(b)! as RidLocation;
      expect(l.speedHorizontalMps, 138.75);
    });

    test('Location: unknown sentinels decode to null, never zero', () {
      final unkSpeed = List<int>.from(locationBytes)
        ..[1] = 0x23 // SpeedMult bit 0 set
        ..[3] = 255; // 255 m/s sentinel
      expect((decodeRidMessage(unkSpeed)! as RidLocation).speedHorizontalMps,
          isNull);

      final noDir = List<int>.from(locationBytes)..[2] = 180; // 180+EW=360
      expect((decodeRidMessage(noDir)! as RidLocation).directionDeg, isNull);

      final noPos = List<int>.from(locationBytes);
      for (var i = 5; i < 13; i++) {
        noPos[i] = 0;
      }
      final lp = decodeRidMessage(noPos)! as RidLocation;
      expect(lp.lat, isNull);
      expect(lp.lon, isNull);

      final noAlt = List<int>.from(locationBytes)
        ..[13] = 0
        ..[14] = 0; // raw 0 = unknown
      expect((decodeRidMessage(noAlt)! as RidLocation).altBaroM, isNull);
    });

    test('System: operator position, live-GNSS type, F3411 epoch', () {
      final m = decodeRidMessage(systemBytes);
      expect(m, isA<RidSystem>());
      final s = m! as RidSystem;
      expect(s.operatorLocationType, 1);
      expect(s.operatorLat, closeTo(51.476, 1e-9));
      expect(s.operatorLon, closeTo(0.0004, 1e-9));
      expect(s.operatorAltGeoM, 45.0);
      expect(s.areaCount, 1);
      expect(s.areaRadiusM, isNull); // radius byte 0
      expect(s.timestampUtc,
          DateTime.utc(2025, 5, 3, 19, 33, 20)); // 1546300800+200000000
    });

    test('Authentication page 0: payload starts at byte 8', () {
      final m = decodeRidMessage(authPage0Bytes);
      expect(m, isA<RidAuthentication>());
      final a = m! as RidAuthentication;
      expect(a.authType, 1);
      expect(a.page, 0);
      // 17 bytes of AuthData from byte 8 (0xA0..0xB0), not byte 9.
      expect(a.data, hasLength(17));
      expect(a.data, equals(List<int>.generate(17, (i) => 0xA0 + i)));
    });

    test('Operator ID and Self-ID strings', () {
      final o = decodeRidMessage(operatorIdBytes)! as RidOperatorId;
      expect(o.operatorId, 'OP-12345');
      final s = decodeRidMessage(selfIdBytes)! as RidSelfId;
      expect(s.description, 'TEST FLIGHT');
    });

    test('truncated and unknown-type input -> null, never throws', () {
      expect(decodeRidMessage(const [1, 2, 3]), isNull);
      expect(decodeRidMessage(List<int>.filled(25, 0x62)), isNull);
      expect(decodeRidMessage(const []), isNull);
    });
  });

  group('packs and transport framing', () {
    final pack = <int>[0xF2, 25, 2, ...basicIdBytes, ...locationBytes];

    test('message pack decodes all members', () {
      final msgs = decodeRidMessagePack(pack);
      expect(msgs, hasLength(2));
      expect(msgs[0], isA<RidBasicId>());
      expect(msgs[1], isA<RidLocation>());
    });

    test('malformed pack header -> empty', () {
      final badSize = List<int>.from(pack)..[1] = 24;
      expect(decodeRidMessagePack(badSize), isEmpty);
      final short = pack.sublist(0, 30);
      expect(decodeRidMessagePack(short), isEmpty);
    });

    test('app data: bare single message', () {
      final msgs = decodeRidAppData(basicIdBytes);
      expect(msgs, hasLength(1));
      expect(msgs.single, isA<RidBasicId>());
    });

    test('app data: counter + single (BLE legacy service data)', () {
      final msgs = decodeRidAppData([0x07, ...basicIdBytes]);
      expect(msgs, hasLength(1));
      expect((msgs.single as RidBasicId).uasId, '1581F5FHJ229R00N3K7P');
    });

    test('app data: bare pack and counter + pack', () {
      expect(decodeRidAppData(pack), hasLength(2));
      expect(decodeRidAppData([0x09, ...pack]), hasLength(2));
    });

    test('app data: garbage shapes yield nothing', () {
      expect(decodeRidAppData(const []), isEmpty);
      expect(decodeRidAppData(const [1, 2, 3, 4]), isEmpty);
      expect(decodeRidAppData(List<int>.filled(30, 0xAA)), isEmpty);
    });

    test('BLE service UUID matching', () {
      expect(isRidServiceUuid('fffa'), isTrue);
      expect(isRidServiceUuid('FFFA'), isTrue);
      expect(isRidServiceUuid('0000fffa-0000-1000-8000-00805f9b34fb'), isTrue);
      expect(isRidServiceUuid('0000fffb-0000-1000-8000-00805f9b34fb'), isFalse);
      expect(isRidServiceUuid('1800'), isFalse);
    });
  });

  group('RemoteIdTracker', () {
    final t0 = DateTime.utc(2026, 10, 21, 12);

    test('contact assembles across message types by source', () {
      final tr = RemoteIdTracker();
      tr.ingestAppData([0x01, ...basicIdBytes],
          sourceKey: 'ble:AA', sourceKind: 'BLE', at: t0);
      tr.ingestAppData(locationBytes,
          sourceKey: 'ble:AA',
          sourceKind: 'BLE',
          at: t0.add(const Duration(seconds: 1)));
      tr.ingestAppData(systemBytes,
          sourceKey: 'ble:AA',
          sourceKind: 'BLE',
          at: t0.add(const Duration(seconds: 2)));
      final cs = tr.contacts(t0.add(const Duration(seconds: 3)));
      expect(cs, hasLength(1));
      final c = cs.single;
      expect(c.serial, '1581F5FHJ229R00N3K7P');
      expect(c.lat, closeTo(51.477, 1e-9));
      expect(c.operatorLat, closeTo(51.476, 1e-9));
      expect(c.operatorLabel, 'OPERATOR (LIVE)');
      expect(c.messageCount, 3);
      expect(tr.bySerial('1581f5fhj229r00n3k7p', t0), isNotNull);
    });

    test('system message with type 0 labels the point TAKEOFF', () {
      final tr = RemoteIdTracker();
      final sys = List<int>.from(systemBytes)..[1] = 0x00;
      tr.ingest([decodeRidMessage(sys)!],
          sourceKey: 'wifi:B1', sourceKind: 'WIFI', at: t0);
      expect(tr.contacts(t0).single.operatorLabel, 'TAKEOFF POINT');
    });

    test('v0.26.0: default 90 s stale horizon pins expiry', () {
      final tr = RemoteIdTracker(); // default staleAfter = 90 s
      tr.ingestAppData(basicIdBytes,
          sourceKey: 'ble:AA', sourceKind: 'BLE', at: t0);
      expect(tr.contacts(t0.add(const Duration(seconds: 89))), hasLength(1));
      expect(tr.contacts(t0.add(const Duration(seconds: 91))), isEmpty);
    });
  });

  group('v0.26.0 malformed-frame regressions', () {
    test('bad type nibbles decode to null, never throw', () {
      for (final type in [6, 7, 8, 9, 10, 11, 12, 13, 14, 15]) {
        final bytes = List<int>.filled(25, 0);
        bytes[0] = (type << 4) | 2;
        expect(decodeRidMessage(bytes), isNull,
            reason: 'type nibble $type must not decode');
        expect(decodeRidAppData(bytes), isEmpty);
      }
    });

    test('oversized and zero pack counts yield nothing', () {
      final over = <int>[0xF2, 25, 10];
      for (var i = 0; i < 10; i++) {
        over.addAll(basicIdBytes);
      }
      expect(decodeRidMessagePack(over), isEmpty);
      expect(decodeRidAppData(over), isEmpty);
      expect(decodeRidMessagePack(const [0xF2, 25, 0]), isEmpty);
      expect(decodeRidAppData(const [0xF2, 25, 0]), isEmpty);
    });

    test('pack claiming more members than present yields nothing', () {
      final short = <int>[0xF2, 25, 2, ...basicIdBytes];
      expect(decodeRidMessagePack(short), isEmpty);
      expect(decodeRidAppData(short), isEmpty);
    });

    test('empty and single-byte service data yield nothing', () {
      expect(decodeRidAppData(const []), isEmpty);
      expect(decodeRidAppData(const [0x07]), isEmpty);
    });

    test('cooperative labeling is distinct from mesh tracks', () {
      final t0 = DateTime.utc(2026, 10, 21, 12);
      final tr = RemoteIdTracker();
      tr.ingestAppData(basicIdBytes,
          sourceKey: 'ble:AA', sourceKind: 'BLE', at: t0);
      final c = tr.contacts(t0).single;
      expect(c.cooperativeLabel, 'COOPERATIVE (RID)');
      expect(kRidCooperativeLabel, 'COOPERATIVE (RID)');
      expect(c.cooperativeSourceLabel, 'COOPERATIVE (RID · BLE)');
      expect(c.cooperativeLabel, isNot(contains('mesh')));
    });
  });

  test('stale contacts prune; separate sources stay separate', () {
    final t0 = DateTime.utc(2026, 10, 21, 12);
    final tr = RemoteIdTracker(staleAfter: const Duration(seconds: 30));
    tr.ingestAppData(basicIdBytes,
        sourceKey: 'ble:AA', sourceKind: 'BLE', at: t0);
    tr.ingestAppData(basicIdBytes,
        sourceKey: 'ble:BB', sourceKind: 'BLE', at: t0);
    expect(tr.contacts(t0).length, 2);
    expect(tr.contacts(t0.add(const Duration(seconds: 31))), isEmpty);
  });
}
