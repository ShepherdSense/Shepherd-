/// FAA Remote ID broadcast decoder — ASTM F3411 (Open Drone ID),
/// pure Dart (Skydio integration P2, docs/skydio_integration_spec.md).
///
/// Decodes the 25-byte messages a compliant drone broadcasts over
/// BLE (service UUID 0xFFFA) and Wi-Fi Beacon: Basic ID,
/// Location/Vector, Authentication, Self-ID, System, Operator ID,
/// and Message Packs bundling several of them.
///
/// HONESTY CONTRACT (mirrored in the UI copy):
///  - Broadcast-only: this hears drones that CHOOSE to broadcast.
///    Military D-model airframes (Skydio X10D, federal X2D) are
///    Part 89-exempt and may broadcast nothing — silence from this
///    decoder never means an empty sky.
///  - Identity is ASSERTED, never verified: Remote ID has no
///    authentication in the broadcast path (the Authentication
///    message type exists but is rarely populated and is not
///    verified here). A serial is a claim, rendered as such.
///  - Absence of data is null, never zero-filled: an encoded
///    "unknown" sentinel decodes to null, not to 0.0 at the Gulf of
///    Guinea.
///
/// Wire format (ASTM F3411-22a; field packing as implemented in the
/// OpenDroneID core library, opendroneid-core-c odid.h): every
/// message is 25 bytes; byte 0 is message type (high nibble) +
/// protocol version (low nibble). Multi-byte integers are little
/// endian. Altitudes encode as raw * 0.5 - 1000 (raw 0 = unknown).
library;

import 'dart:typed_data';

/// Message size in bytes for every non-pack message.
const int kRidMessageSize = 25;

/// Transport service UUID for BLE Remote ID (0xFFFA), as the string
/// forms universal_ble reports: a 16-bit UUID, possibly expanded.
const String kRidBleServiceUuid = 'fffa';

/// True when a BLE service-UUID string names the Remote ID service.
bool isRidServiceUuid(String uuid) {
  final u = uuid.trim().toLowerCase();
  return u == kRidBleServiceUuid || u == '0000fffa-0000-1000-8000-00805f9b34fb';
}

/// Base type for decoded Remote ID messages.
sealed class RidMessage {
  const RidMessage(this.version);

  /// Protocol version nibble from byte 0 (1 = F3411-19,
  /// 2 = F3411-22a; receivers accept any).
  final int version;
}

/// Basic ID (type 0): the airframe's claimed identity.
class RidBasicId extends RidMessage {
  const RidBasicId(super.version,
      {required this.idType, required this.uaType, required this.uasId});

  /// 0 none, 1 serial number (ANSI/CTA-2063), 2 CAA registration ID,
  /// 3 UTM UUID, 4 specific session ID.
  final int idType;

  /// UA type nibble (1 aeroplane, 2 helicopter/multirotor, ...).
  final int uaType;

  /// The ID string as broadcast (trailing NUL/space padding removed).
  final String uasId;

  /// True when the ID claims to be an ANSI serial — the only kind
  /// the friendly whitelist can match.
  bool get isSerial => idType == 1;
}

/// Location/Vector (type 1): where the drone says it is.
class RidLocation extends RidMessage {
  const RidLocation(
    super.version, {
    required this.status,
    required this.heightAboveTakeoff,
    this.directionDeg,
    this.speedHorizontalMps,
    this.speedVerticalMps,
    this.lat,
    this.lon,
    this.altBaroM,
    this.altGeoM,
    this.heightM,
    this.timestampSecOfHour,
  });

  /// 0 undeclared, 1 ground, 2 airborne, 3 emergency,
  /// 4 Remote ID system failure.
  final int status;

  /// Height reference: true = above takeoff, false = above ground.
  final bool heightAboveTakeoff;

  /// Track direction over ground, degrees. Null = broadcast unknown.
  final double? directionDeg;

  /// Ground speed m/s. Null = unknown sentinel (255 m/s encoding).
  final double? speedHorizontalMps;

  /// Vertical speed m/s, up positive. Null = unknown.
  final double? speedVerticalMps;

  /// WGS84 position. Both null when the (0,0) no-value pair is sent.
  final double? lat;
  final double? lon;

  /// Altitudes (m). Null = encoded unknown (raw 0).
  final double? altBaroM;
  final double? altGeoM;

  /// Height above takeoff/ground per [heightAboveTakeoff] (m).
  final double? heightM;

  /// Seconds into the current UTC hour (0.1 s wire units), when the
  /// 0xFFFF unknown sentinel is not sent. Informational — freshness
  /// is judged on local receive time, never on this field.
  final double? timestampSecOfHour;
}

/// System (type 4): operator position + operating area.
class RidSystem extends RidMessage {
  const RidSystem(
    super.version, {
    required this.operatorLocationType,
    this.operatorLat,
    this.operatorLon,
    this.operatorAltGeoM,
    this.areaCount,
    this.areaRadiusM,
    this.timestampUtc,
  });

  /// 0 = takeoff location, 1 = live GNSS operator location,
  /// 2 = fixed location. Decides what the operator marker MEANS —
  /// the UI labels it accordingly.
  final int operatorLocationType;

  final double? operatorLat;
  final double? operatorLon;
  final double? operatorAltGeoM;

  /// Operating-area fields, when the broadcast populates them.
  final int? areaCount;
  final double? areaRadiusM;

  /// Broadcast clock: wire value is seconds since 2019-01-01 UTC
  /// (the F3411 epoch). Informational only.
  final DateTime? timestampUtc;
}

/// Operator ID (type 5): the operator's claimed registration ID
/// (mandatory in the EU profile; uncommon in US broadcasts).
class RidOperatorId extends RidMessage {
  const RidOperatorId(super.version,
      {required this.operatorIdType, required this.operatorId});

  final int operatorIdType;
  final String operatorId;
}

/// Self-ID (type 3): free-text description from the operator.
class RidSelfId extends RidMessage {
  const RidSelfId(super.version,
      {required this.descriptionType, required this.description});

  final int descriptionType;
  final String description;
}

/// Authentication (type 2): decoded structurally only. Shepherd
/// does NOT verify authentication data — see the library honesty
/// contract. Carried so a populated auth message is visible as a
/// claim, never rendered as proof.
class RidAuthentication extends RidMessage {
  const RidAuthentication(super.version,
      {required this.authType, required this.page, required this.data});

  final int authType;
  final int page;
  final Uint8List data;
}

double? _decodeAltitude(int raw) => raw == 0 ? null : raw * 0.5 - 1000.0;

String _decodeIdString(List<int> bytes) {
  final end = bytes.lastIndexWhere((b) => b != 0 && b != 0x20);
  if (end < 0) return '';
  return String.fromCharCodes(bytes.sublist(0, end + 1));
}

/// Decode ONE 25-byte message. Returns null for truncated input or
/// an unknown/reserved message type. Never throws.
RidMessage? decodeRidMessage(List<int> bytes) {
  if (bytes.length < kRidMessageSize) return null;
  final b = bytes.length == kRidMessageSize
      ? bytes
      : bytes.sublist(0, kRidMessageSize);
  final type = (b[0] >> 4) & 0xF;
  final version = b[0] & 0xF;
  int u16(int off) => b[off] | (b[off + 1] << 8);
  int i32(int off) =>
      (b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24))
          .toSigned(32);
  switch (type) {
    case 0:
      return RidBasicId(
        version,
        idType: (b[1] >> 4) & 0xF,
        uaType: b[1] & 0xF,
        uasId: _decodeIdString(b.sublist(2, 22)),
      );
    case 1:
      final flags = b[1];
      // Flag-byte allocation per ODID_Location_encoded in odid.h
      // (bitfields declared LSb-first): SpeedMult bit 0, EWDirection
      // bit 1, HeightType bit 2, Reserved bit 3, Status bits 4-7.
      final status = (flags >> 4) & 0xF;
      final heightType = (flags >> 2) & 0x1;
      final ew = (flags >> 1) & 0x1;
      final speedMult = flags & 0x1;
      // Direction: 0..179 in the byte, +180 when the EW flag is set;
      // the 360 result is the broadcast "unknown" marker.
      // v0.26.0 fix-pass: with the EW flag CLEAR, a byte of 180-255
      // is out of the valid 0-179 range and decodes to null — it
      // must not leak through as a 180-255 degree heading.
      final dirRaw = b[2] + (ew == 1 ? 180 : 0);
      final directionUnknown = (ew == 0 && b[2] >= 180) || dirRaw >= 360;
      final speedRaw = b[3];
      final double? speedH;
      if (speedMult == 1 && speedRaw == 255) {
        speedH = null; // 255 m/s sentinel = unknown
      } else if (speedMult == 1) {
        speedH = 63.75 + 0.75 * speedRaw;
      } else {
        speedH = 0.25 * speedRaw;
      }
      final vsRaw = b[4].toSigned(8);
      final vs = vsRaw * 0.5;
      final latRaw = i32(5);
      final lonRaw = i32(9);
      final hasPos = !(latRaw == 0 && lonRaw == 0);
      final tsRaw = u16(21);
      return RidLocation(
        version,
        status: status,
        heightAboveTakeoff: heightType == 0,
        directionDeg: directionUnknown ? null : dirRaw.toDouble(),
        speedHorizontalMps: speedH,
        speedVerticalMps: vs.abs() >= 63 ? null : vs,
        lat: hasPos ? latRaw * 1e-7 : null,
        lon: hasPos ? lonRaw * 1e-7 : null,
        altBaroM: _decodeAltitude(u16(13)),
        altGeoM: _decodeAltitude(u16(15)),
        heightM: _decodeAltitude(u16(17)),
        timestampSecOfHour: tsRaw == 0xFFFF ? null : tsRaw / 10.0,
      );
    case 2:
      final page = b[1] & 0xF;
      return RidAuthentication(
        version,
        authType: (b[1] >> 4) & 0xF,
        page: page,
        // Page 0 spends bytes 2..7 on last-page/length/timestamp;
        // AuthData starts at byte 8 (17 bytes, ODID_Auth page zero).
        data: Uint8List.fromList(page == 0 ? b.sublist(8) : b.sublist(2)),
      );
    case 3:
      return RidSelfId(
        version,
        descriptionType: b[1],
        description: _decodeIdString(b.sublist(2)),
      );
    case 4:
      final opLatRaw = i32(2);
      final opLonRaw = i32(6);
      final hasOpPos = !(opLatRaw == 0 && opLonRaw == 0);
      // Field offsets per ODID_System_encoded in odid.h:
      // OperatorAltitudeGeo uint16 at bytes 18-19, Timestamp uint32
      // at bytes 20-23, byte 24 reserved.
      final tsSec = b[20] | (b[21] << 8) | (b[22] << 16) | (b[23] << 24);
      return RidSystem(
        version,
        // Flag byte allocation per odid.h bitfields: location type
        // in the low two bits, classification type above it.
        operatorLocationType: b[1] & 0x3,
        operatorLat: hasOpPos ? opLatRaw * 1e-7 : null,
        operatorLon: hasOpPos ? opLonRaw * 1e-7 : null,
        operatorAltGeoM: _decodeAltitude(u16(18)),
        areaCount: u16(10),
        areaRadiusM: b[12] == 0 ? null : b[12] * 10.0,
        timestampUtc: tsSec == 0
            ? null
            : DateTime.fromMillisecondsSinceEpoch((1546300800 + tsSec) * 1000,
                isUtc: true),
      );
    case 5:
      return RidOperatorId(
        version,
        operatorIdType: b[1],
        operatorId: _decodeIdString(b.sublist(2, 22)),
      );
    default:
      return null;
  }
}

/// Expand a Message Pack payload (the full frame INCLUDING its
/// 3-byte header: type/version, single-message size, count).
/// Returns the decoded member messages; malformed packs yield
/// whatever members decode cleanly (never throws).
/// v0.26.0 fix-pass: when called DIRECTLY, the length must be
/// EXACT (3 + count * size) — trailing garbage is rejected, not
/// silently ignored. (The transport cascade in
/// [decodeRidAppData] already requires exact length before it
/// routes a frame here, so that path is unchanged.)
List<RidMessage> decodeRidMessagePack(List<int> bytes) {
  if (bytes.length < 3) return const [];
  if (((bytes[0] >> 4) & 0xF) != 0xF) return const [];
  final size = bytes[1];
  final count = bytes[2];
  if (size != kRidMessageSize || count < 1 || count > 9) return const [];
  if (bytes.length != 3 + count * size) return const [];
  final out = <RidMessage>[];
  for (var i = 0; i < count; i++) {
    final m = decodeRidMessage(bytes.sublist(3 + i * size, 3 + (i + 1) * size));
    if (m != null) out.add(m);
  }
  return out;
}

/// Decode one transport payload ("app data") into messages.
///
/// Accepted forms (ASTM F3411 transport mappings):
///  - a single 25-byte message;
///  - a message pack (27+ bytes, self-describing header);
///  - a 1-byte message counter followed by either of the above
///    (BLE legacy service data and the Wi-Fi Beacon vendor payload
///    both prefix the counter; BLE 5 long-range carries the pack).
///
/// The cascade is length- and header-checked, so a counter byte that
/// happens to look like a header cannot misroute a frame. Unknown
/// shapes yield an empty list — a garbled frame is dropped, never
/// guessed at.
List<RidMessage> decodeRidAppData(List<int> bytes) {
  if (bytes.isEmpty) return const [];
  bool isPackAt(int off) =>
      bytes.length >= off + 3 &&
      ((bytes[off] >> 4) & 0xF) == 0xF &&
      bytes[off + 1] == kRidMessageSize &&
      bytes[off + 2] >= 1 &&
      bytes[off + 2] <= 9 &&
      bytes.length == off + 3 + bytes[off + 2] * kRidMessageSize;
  if (isPackAt(0)) return decodeRidMessagePack(bytes);
  if (bytes.length == kRidMessageSize) {
    final m = decodeRidMessage(bytes);
    return m == null ? const [] : [m];
  }
  // Counter-prefixed forms.
  if (bytes.length == kRidMessageSize + 1) {
    final m = decodeRidMessage(bytes.sublist(1));
    return m == null ? const [] : [m];
  }
  if (isPackAt(1)) return decodeRidMessagePack(bytes.sublist(1));
  return const [];
}

/// UI-facing label for any RID-derived record (v0.26.0 Fieldwatch
/// borrow, item 1). RID is a COOPERATIVE broadcast: the drone chose
/// to identify itself. This label keeps RID records visually distinct
/// from mesh tracks, which are non-cooperative RF sensing. RID
/// evidence is display-only identification — it never feeds
/// detection, the tracker, or the confidence merger (see
/// test/remote_id_never_override_test.dart).
const String kRidCooperativeLabel = 'COOPERATIVE (RID)';

/// Wi-Fi NAN Remote ID is NOT available: stock Android does not
/// expose NAN Remote ID frames to the app, so Shepherd hears RID
/// over BLE and Wi-Fi Beacon only. Documented, never faked.
const String kRidWifiNanUnavailableNote =
    'Wi-Fi NAN Remote ID unavailable on stock Android — BLE / Wi-Fi Beacon only';

/// BLE 5 extended advertising is platform-dependent: whether a long
/// RID pack arrives depends on the phone's BLE stack, not Shepherd.
const String kRidBle5Note = 'BLE 5 extended advertising is platform-dependent';

/// Marker meaning for a Remote ID operator position, from the
/// System message's location type: the UI must not call a takeoff
/// point a live operator. Shared by contacts and airframe records.
String ridOperatorLabel(int operatorLocationType) =>
    switch (operatorLocationType) {
      1 => 'OPERATOR (LIVE)',
      2 => 'OPERATOR (FIXED)',
      _ => 'TAKEOFF POINT',
    };

/// One aggregated Remote ID contact: every message heard from one
/// transport source, merged. Position/identity fields keep the
/// LATEST value per message type; a field never heard stays null.
class RidContact {
  RidContact({required this.sourceKey, required this.sourceKind});

  /// Transport identity: `ble:<deviceId>` or `wifi:<bssid>`. The
  /// association between a Location message and a Basic ID is by
  /// transport source — the broadcast itself carries no linkage.
  final String sourceKey;

  /// 'BLE' or 'WIFI'.
  final String sourceKind;

  String? serial;
  int? idType;
  int? uaType;
  double? lat;
  double? lon;
  double? altGeoM;
  double? heightM;
  bool heightAboveTakeoff = true;
  double? directionDeg;
  double? speedHorizontalMps;
  int? status;
  double? operatorLat;
  double? operatorLon;
  int operatorLocationType = 0;
  String? operatorId;
  String? selfIdText;
  DateTime? lastSeen;
  int messageCount = 0;

  bool get hasPosition => lat != null && lon != null;
  bool get hasOperatorPosition => operatorLat != null && operatorLon != null;

  /// Operator marker meaning, from the System message's location
  /// type: the UI must not call a takeoff point a live operator.
  String get operatorLabel => ridOperatorLabel(operatorLocationType);

  /// UI-facing cooperative label for this contact: distinct from
  /// mesh tracks by construction. Identity here is ASSERTED by a
  /// cooperative broadcast, never verified (see the library honesty
  /// contract) — a label, not a proof.
  String get cooperativeLabel => kRidCooperativeLabel;

  /// Cooperative label with the transport that carried it, e.g.
  /// `COOPERATIVE (RID · BLE)`.
  String get cooperativeSourceLabel => 'COOPERATIVE (RID · $sourceKind)';

  void absorb(RidMessage m, DateTime at) {
    messageCount++;
    lastSeen = at;
    switch (m) {
      case RidBasicId():
        if (m.uasId.isNotEmpty) {
          serial = m.uasId;
          idType = m.idType;
          uaType = m.uaType;
        }
      case RidLocation():
        status = m.status;
        heightAboveTakeoff = m.heightAboveTakeoff;
        if (m.lat != null && m.lon != null) {
          lat = m.lat;
          lon = m.lon;
        }
        if (m.altGeoM != null) altGeoM = m.altGeoM;
        if (m.heightM != null) heightM = m.heightM;
        if (m.directionDeg != null) directionDeg = m.directionDeg;
        if (m.speedHorizontalMps != null) {
          speedHorizontalMps = m.speedHorizontalMps;
        }
      case RidSystem():
        operatorLocationType = m.operatorLocationType;
        if (m.operatorLat != null && m.operatorLon != null) {
          operatorLat = m.operatorLat;
          operatorLon = m.operatorLon;
        }
      case RidOperatorId():
        if (m.operatorId.isNotEmpty) operatorId = m.operatorId;
      case RidSelfId():
        if (m.description.isNotEmpty) selfIdText = m.description;
      case RidAuthentication():
        // Structural only — never verified, never displayed as proof.
        break;
    }
  }
}

/// Holds live Remote ID contacts, keyed by transport source, and
/// prunes silent ones. [staleAfter] is generous against the 1 Hz /
/// 3 s broadcast cadence: a contact is a claim with an age, and the
/// UI shows that age rather than the contact vanishing mid-flight.
class RemoteIdTracker {
  RemoteIdTracker({this.staleAfter = const Duration(seconds: 90)});

  final Duration staleAfter;
  final Map<String, RidContact> _contacts = {};

  /// Feed decoded messages from one transport frame.
  void ingest(List<RidMessage> messages,
      {required String sourceKey,
      required String sourceKind,
      required DateTime at}) {
    if (messages.isEmpty) return;
    final c = _contacts.putIfAbsent(sourceKey,
        () => RidContact(sourceKey: sourceKey, sourceKind: sourceKind));
    for (final m in messages) {
      c.absorb(m, at);
    }
  }

  /// Convenience: decode + ingest one raw transport payload.
  void ingestAppData(List<int> bytes,
      {required String sourceKey,
      required String sourceKind,
      required DateTime at}) {
    ingest(decodeRidAppData(bytes),
        sourceKey: sourceKey, sourceKind: sourceKind, at: at);
  }

  /// Live contacts (pruned to [staleAfter]), freshest first.
  List<RidContact> contacts(DateTime now) {
    _contacts.removeWhere((_, c) =>
        c.lastSeen == null || now.difference(c.lastSeen!) > staleAfter);
    final out = _contacts.values.toList()
      ..sort((a, b) =>
          (b.lastSeen ?? DateTime(0)).compareTo(a.lastSeen ?? DateTime(0)));
    return List.unmodifiable(out);
  }

  RidContact? bySerial(String serial, DateTime now) {
    final n = serial.trim().toUpperCase();
    for (final c in contacts(now)) {
      if (c.serial != null && c.serial!.toUpperCase() == n) return c;
    }
    return null;
  }

  void clear() => _contacts.clear();
}
