/// Wi-Fi / BLE device-signature library — "what's around me"
/// (Shepherd v0.26.0, Fieldwatch-borrow item 2).
///
/// CONCEPT ATTRIBUTION: the concept — matching phone-visible Wi-Fi
/// scan results and BLE advertisements against an extensible
/// signature catalog — is adapted from Fieldwatch (MIT license).
/// No Fieldwatch code and no Fieldwatch catalog data was copied:
/// the built-in catalog below was constructed independently, and
/// is deliberately SMALL (see the honesty note on vendor OUIs).
///
/// HONESTY CONTRACT — every match this service produces is a
/// HYPOTHESIS, never identity:
///  - An SSID is operator-chosen text, not a fingerprint. A keyword
///    match is weak evidence and is scored that way.
///  - A BLE service UUID names a protocol, not a product. Only the
///    Remote ID service (0xFFFA, ASTM F3411) maps to a class, and
///    even that is a cooperative claim, never verified identity.
///  - NO built-in vendor OUI / company-ID entries: an IEEE OUI or a
///    Bluetooth SIG company ID names a MANUFACTURER, not a device
///    class, so asserting a class from one alone would be an
///    invented OUI-to-product mapping. OUI and company-ID matching
///    are supported for USER-ADDED entries, where the user asserts
///    the mapping and it is labeled USER-ADDED wherever it surfaces.
///  - A locally-administered (randomized) MAC carries no
///    manufacturer OUI at all, so OUI matching is skipped for such
///    addresses — a randomized MAC must never manufacture a match.
///  - Phone-OS scan quotas hide quiet/randomized radios, so absence
///    of a match never means absence of a device.
///  - This service only IDENTIFIES; it never creates, deletes, or
///    downgrades a detection, track, or alert (never-subtractive).
///
/// USER CATALOG: user-added signatures load from a JSON file named
/// [kUserSignaturesFileName] in the app documents directory. The
/// coordinator reads that file (path_provider) and passes its TEXT
/// to [DeviceSignatureCatalog.fromUserJsonText] — this service
/// stays pure Dart with no file or platform dependency, so it is
/// fully unit-testable. User entries merge OVER the built-in
/// catalog by id (same id = user entry replaces the built-in one)
/// and are always labeled USER-ADDED. Malformed JSON, or a
/// malformed single entry, degrades to the built-in catalog (plus
/// the surviving valid user entries) with the reason surfaced in
/// [DeviceSignatureCatalog.userLoadWarnings] — never a crash, never
/// a silent whole-catalog drop.
///
/// User JSON format:
/// ```json
/// { "signatures": [
///   { "id": "my-drone",
///     "class": "drone",
///     "label": "My drone hotspot",
///     "wifiOui": "00:1A:2B",
///     "ssidPattern": "mydrone",
///     "confidence": 0.7,
///     "notes": "optional" }
/// ] }
/// ```
/// A top-level JSON list of signature objects is also accepted.
/// `"class"` accepts: tracker, camera, bodyCam / body-cam /
/// "body cam", drone, routerIoT / router / iot / "router/IoT",
/// unknown. `ssidPattern` is a regular expression matched
/// case-insensitively; an invalid pattern drops that field (or the
/// entry, if it has no other matcher) with a warning, never a crash.
///
/// RX-only, defensive-only: this service reads scan/advertisement
/// data the phone already collected. It transmits nothing.
library;

import 'dart:convert';

/// Confidence at or above which a match counts as confident.
/// Keyword-only matches sit below this by design (see the built-in
/// catalog); only protocol-level or user-asserted matches clear it.
const double kSignatureConfidentThreshold = 0.5;

/// File name for the user-added signature JSON in the app
/// documents directory (read by the coordinator, parsed here).
const String kUserSignaturesFileName = 'device_signatures.json';

/// Candidate device classes a signature can suggest. `unknown` is
/// the honest answer when nothing matches confidently — it is a
/// class in its own right, not a failure.
enum DeviceClass {
  tracker,
  camera,
  bodyCam,
  drone,
  routerIoT,
  unknown,
}

/// UI-facing label for a device class.
String deviceClassLabel(DeviceClass c) => switch (c) {
      DeviceClass.tracker => 'tracker',
      DeviceClass.camera => 'camera',
      DeviceClass.bodyCam => 'body cam',
      DeviceClass.drone => 'drone',
      DeviceClass.routerIoT => 'router/IoT',
      DeviceClass.unknown => 'unknown',
    };

/// Where a signature came from. Only [publicAssignment] entries
/// rest on a public assignment (a standards service UUID); keyword
/// patterns are [community] (UNVERIFIED/COMMUNITY); anything the
/// user added is [userAdded] (USER-ADDED), whatever its JSON said.
enum SignatureSource {
  publicAssignment,
  community,
  userAdded,
}

/// UI-facing provenance label for a signature source.
String signatureSourceLabel(SignatureSource s) => switch (s) {
      SignatureSource.publicAssignment => 'PUBLIC ASSIGNMENT',
      SignatureSource.community => 'UNVERIFIED/COMMUNITY',
      SignatureSource.userAdded => 'USER-ADDED',
    };

/// One catalog entry: matchers plus the class it suggests.
///
/// A signature may carry any combination of matchers; an
/// observation matches the signature when ANY matcher fires, and
/// the match evidence lists every matcher that fired.
class DeviceSignature {
  const DeviceSignature({
    required this.id,
    required this.deviceClass,
    required this.label,
    this.bleServiceUuid,
    this.bleCompanyId,
    this.wifiOui,
    this.ssidPattern,
    this.confidence = 0.5,
    this.source = SignatureSource.community,
    this.notes,
  })  : assert(confidence >= 0.0 && confidence <= 1.0,
            'confidence must be in 0..1'),
        assert(id != '', 'signature id must not be empty');

  /// Stable id. A user entry with the same id replaces this entry.
  final String id;

  /// Suggested class — a hypothesis, never identity.
  final DeviceClass deviceClass;

  /// Human-readable description, e.g. 'Remote ID broadcast (ASTM F3411)'.
  final String label;

  /// BLE service UUID: 'fffa', or the full 128-bit form
  /// '0000fffa-0000-1000-8000-00805f9b34fb' (normalized on match).
  final String? bleServiceUuid;

  /// Bluetooth SIG company ID (e.g. 0x004C), or null.
  final int? bleCompanyId;

  /// IEEE OUI as 'AA:BB:CC', 'AABBCC', or similar (normalized on
  /// match). Manufacturer OUI only — see the header contract.
  final String? wifiOui;

  /// SSID regular expression, matched case-insensitively, or null.
  final String? ssidPattern;

  /// 0..1 strength of this evidence. Keyword patterns are weak by
  /// design; protocol-level matches are stronger. Never 1.0: a
  /// match is a hypothesis, not identity.
  final double confidence;

  /// Provenance; user entries are always [SignatureSource.userAdded].
  final SignatureSource source;

  /// Optional grounding note (standard, assignment, or caveat).
  final String? notes;

  /// Copy with user provenance forced (used when loading user JSON).
  DeviceSignature asUserAdded() => DeviceSignature(
        id: id,
        deviceClass: deviceClass,
        label: label,
        bleServiceUuid: bleServiceUuid,
        bleCompanyId: bleCompanyId,
        wifiOui: wifiOui,
        ssidPattern: ssidPattern,
        confidence: confidence,
        source: SignatureSource.userAdded,
        notes: notes,
      );
}

/// One ranked candidate for one observation.
class SignatureMatch {
  SignatureMatch({required this.signature, required List<String> evidence})
      : evidence = List.unmodifiable(evidence);

  final DeviceSignature signature;

  /// Every matcher that fired, in catalog order, deduplicated.
  final List<String> evidence;

  DeviceClass get deviceClass => signature.deviceClass;
  double get confidence => signature.confidence;
  bool get isConfident => confidence >= kSignatureConfidentThreshold;
  bool get isUserAdded => signature.source == SignatureSource.userAdded;
  String get sourceLabel => signatureSourceLabel(signature.source);

  /// UI-facing hypothesis label. The word HYPOTHESIS is load-bearing:
  /// a match suggests a class, it does not identify a device.
  String get hypothesisLabel => 'HYPOTHESIS — ${signature.label} '
      '(${deviceClassLabel(deviceClass)}) — not identity '
      '[$sourceLabel]';

  @override
  String toString() => hypothesisLabel;
}

/// A phone-visible observation to match: BLE service UUIDs and/or
/// company ID from an advertisement, and/or a Wi-Fi BSSID + SSID
/// from a scan result. Any field may be absent; missing input
/// degrades to fewer (or no) matches, never to a confident answer.
class DeviceObservation {
  const DeviceObservation({
    this.bleServiceUuids = const [],
    this.bleCompanyId,
    this.wifiBssid,
    this.ssid,
  });

  final List<String> bleServiceUuids;
  final int? bleCompanyId;
  final String? wifiBssid;
  final String? ssid;
}

/// Normalize a BLE service-UUID string for comparison: lowercase,
/// dashes removed; a 16-bit UUID expanded to 128-bit form collapses
/// back to its 16-bit value.
String normalizeBleServiceUuid(String uuid) {
  final stripped = uuid.trim().toLowerCase().replaceAll('-', '');
  if (stripped.length == 32 &&
      stripped.startsWith('0000') &&
      stripped.endsWith('00805f9b34fb')) {
    return stripped.substring(4, 8);
  }
  return stripped;
}

/// Manufacturer OUI (first 6 hex digits, uppercase) of a MAC/BSSID,
/// or null when the address carries no manufacturer OUI: too short,
/// or locally administered (U/L bit set — randomized MACs, which
/// must never manufacture a vendor match).
String? manufacturerOui(String mac) {
  final stripped = mac.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
  if (stripped.length < 6) return null;
  final firstOctet = int.tryParse(stripped.substring(0, 2), radix: 16);
  if (firstOctet == null) return null;
  if (firstOctet & 0x02 != 0) return null; // locally administered
  return stripped.substring(0, 6);
}

/// Normalize a catalog OUI entry ('AA:BB:CC' / 'AABBCC' / longer
/// forms) to its first 6 hex digits, or null when unusable.
String? normalizeCatalogOui(String oui) {
  final stripped = oui.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
  if (stripped.length < 6) return null;
  return stripped.substring(0, 6);
}

/// Built-in catalog (Dart const, no pubspec change).
///
/// Deliberately small: one protocol-level entry (Remote ID over
/// BLE 0xFFFA, ASTM F3411 — a public assignment) plus generic
/// SSID-keyword entries (UNVERIFIED/COMMUNITY, weak confidence).
/// No vendor OUI or company-ID entries, for the reason in the
/// header: a manufacturer id is not a device class.
const List<DeviceSignature> kBuiltInDeviceSignatures = [
  DeviceSignature(
    id: 'rid-ble-fffa',
    deviceClass: DeviceClass.drone,
    label: 'Remote ID broadcast (ASTM F3411)',
    bleServiceUuid: 'fffa',
    confidence: 0.85,
    source: SignatureSource.publicAssignment,
    notes: 'ASTM F3411 Remote ID transport service. Cooperative '
        'claim, never verified identity. BLE 5 extended advertising '
        'is platform-dependent.',
  ),
  DeviceSignature(
    id: 'ssid-bodycam-keyword',
    deviceClass: DeviceClass.bodyCam,
    label: 'SSID contains "bodycam"',
    ssidPattern: r'body[-_ ]?cam',
    confidence: 0.45,
    source: SignatureSource.community,
    notes: 'Keyword only — an SSID is operator-chosen text, not a '
        'device fingerprint.',
  ),
  DeviceSignature(
    id: 'ssid-drone-keyword',
    deviceClass: DeviceClass.drone,
    label: 'SSID contains "drone"',
    ssidPattern: r'drone',
    confidence: 0.40,
    source: SignatureSource.community,
    notes: 'Keyword only — an SSID is operator-chosen text, not a '
        'device fingerprint.',
  ),
  DeviceSignature(
    id: 'ssid-tracker-keyword',
    deviceClass: DeviceClass.tracker,
    label: 'SSID contains "tracker"',
    ssidPattern: r'tracker',
    confidence: 0.40,
    source: SignatureSource.community,
    notes: 'Keyword only — an SSID is operator-chosen text, not a '
        'device fingerprint.',
  ),
  DeviceSignature(
    id: 'ssid-camera-keyword',
    deviceClass: DeviceClass.camera,
    label: 'SSID contains "cam"/"camera"',
    // INTENTIONALLY WEAK, DO NOT "FIX" WITH A WORD BOUNDARY: this
    // substring pattern matches 'camera'/'bodycam' but also
    // 'camping'/'scam' — that over-match is accepted because the
    // match is hypothesis-labeled (never identity) and scored low
    // (0.35, below the confident threshold), and a word boundary
    // would break bodycam matching ('bodycam' has no boundary
    // before 'cam'). Weakness is disclosed here and in the notes.
    ssidPattern: r'cam(era)?',
    confidence: 0.35,
    source: SignatureSource.community,
    notes: 'Keyword only — an SSID is operator-chosen text, not a '
        'device fingerprint. Substring pattern: also matches '
        '"camping"/"scam" — hypothesis only, scored below the '
        'confident threshold.',
  ),
  DeviceSignature(
    id: 'ssid-iot-keyword',
    deviceClass: DeviceClass.routerIoT,
    label: 'SSID contains "iot"',
    ssidPattern: r'\biot\b',
    confidence: 0.35,
    source: SignatureSource.community,
    notes: 'Keyword only — an SSID is operator-chosen text, not a '
        'device fingerprint.',
  ),
];

DeviceClass? _parseDeviceClass(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'tracker':
      return DeviceClass.tracker;
    case 'camera':
      return DeviceClass.camera;
    case 'bodycam':
    case 'body-cam':
    case 'body cam':
      return DeviceClass.bodyCam;
    case 'drone':
      return DeviceClass.drone;
    case 'routeriot':
    case 'router':
    case 'iot':
    case 'router/iot':
      return DeviceClass.routerIoT;
    case 'unknown':
      return DeviceClass.unknown;
    default:
      return null;
  }
}

/// A signature catalog: built-in entries plus user-added entries
/// merged over them, with any user-load problems surfaced (never
/// thrown, never silent).
class DeviceSignatureCatalog {
  const DeviceSignatureCatalog({
    this.userSignatures = const [],
    this.userLoadWarnings = const [],
  });

  /// Valid user-added entries, in file order.
  final List<DeviceSignature> userSignatures;

  /// Reasons for anything dropped or degraded while loading user
  /// JSON. Empty means the user file was absent, empty, or fully
  /// valid. A non-empty list with a usable catalog is a degraded
  /// load, not a failure — surface it in the UI, do not hide it.
  final List<String> userLoadWarnings;

  bool get hasUserLoadWarnings => userLoadWarnings.isNotEmpty;

  List<DeviceSignature> get builtIn => kBuiltInDeviceSignatures;

  /// Merged catalog: built-in order, with a user entry of the same
  /// id replacing the built-in entry in place; brand-new user
  /// entries appended in file order.
  List<DeviceSignature> get merged {
    final byId = <String, DeviceSignature>{
      for (final s in kBuiltInDeviceSignatures) s.id: s,
    };
    final order = <String>[for (final s in kBuiltInDeviceSignatures) s.id];
    for (final u in userSignatures) {
      if (!byId.containsKey(u.id)) order.add(u.id);
      byId[u.id] = u;
    }
    return List.unmodifiable([for (final id in order) byId[id]!]);
  }

  /// Parse user JSON text into a catalog. `null` or blank text
  /// means "no user file" — built-in only, no warning. Malformed
  /// JSON degrades to built-in only with a warning. A malformed
  /// single entry is skipped with a warning; valid entries survive.
  /// Never throws.
  static DeviceSignatureCatalog fromUserJsonText(String? jsonText) {
    if (jsonText == null || jsonText.trim().isEmpty) {
      return const DeviceSignatureCatalog();
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(jsonText);
    } catch (e) {
      return DeviceSignatureCatalog(userLoadWarnings: [
        'User signatures ignored: malformed JSON ($e) — '
            'built-in catalog only.',
      ]);
    }
    List<dynamic>? entries;
    if (decoded is List) {
      entries = decoded;
    } else if (decoded is Map && decoded['signatures'] is List) {
      entries = decoded['signatures'] as List;
    } else {
      return const DeviceSignatureCatalog(userLoadWarnings: [
        'User signatures ignored: expected a list or an object with '
            'a "signatures" list — built-in catalog only.',
      ]);
    }
    final users = <DeviceSignature>[];
    final warnings = <String>[];
    for (var i = 0; i < entries.length; i++) {
      final raw = entries[i];
      if (raw is! Map) {
        warnings.add('User signature #$i skipped: not an object.');
        continue;
      }
      final id = raw['id'];
      if (id is! String || id.trim().isEmpty) {
        warnings.add('User signature #$i skipped: missing id.');
        continue;
      }
      final cls = raw['class'];
      final deviceClass = cls is String ? _parseDeviceClass(cls) : null;
      if (deviceClass == null) {
        warnings.add('User signature "$id" skipped: unknown class "$cls".');
        continue;
      }
      final label =
          raw['label'] is String && (raw['label'] as String).isNotEmpty
              ? raw['label'] as String
              : id;
      String? bleUuid;
      if (raw['bleServiceUuid'] is String) {
        bleUuid = normalizeBleServiceUuid(raw['bleServiceUuid'] as String);
        if (bleUuid.isEmpty) bleUuid = null;
      }
      int? companyId;
      final rawCompany = raw['bleCompanyId'];
      if (rawCompany is num) {
        companyId = rawCompany.toInt();
      } else if (rawCompany is String) {
        final t = rawCompany.trim().toLowerCase();
        companyId = t.startsWith('0x')
            ? int.tryParse(t.substring(2), radix: 16)
            : int.tryParse(t);
        if (companyId == null) {
          warnings
              .add('User signature "$id": unparsable bleCompanyId ignored.');
        }
      }
      String? oui;
      if (raw['wifiOui'] is String) {
        oui = normalizeCatalogOui(raw['wifiOui'] as String);
        if (oui == null) {
          warnings.add('User signature "$id": unusable wifiOui ignored.');
        }
      }
      String? pattern;
      if (raw['ssidPattern'] is String &&
          (raw['ssidPattern'] as String).isNotEmpty) {
        try {
          RegExp(raw['ssidPattern'] as String, caseSensitive: false);
          pattern = raw['ssidPattern'] as String;
        } catch (_) {
          warnings.add('User signature "$id": invalid ssidPattern ignored.');
        }
      }
      if (bleUuid == null &&
          companyId == null &&
          oui == null &&
          pattern == null) {
        warnings.add('User signature "$id" skipped: no usable matcher.');
        continue;
      }
      var confidence = 0.5;
      if (raw['confidence'] is num) {
        // Service contract: Never 1.0 — a match is a hypothesis,
        // not identity — so user JSON confidence clamps to 0.99.
        confidence = (raw['confidence'] as num).toDouble().clamp(0.0, 0.99);
      }
      users.add(DeviceSignature(
        id: id,
        deviceClass: deviceClass,
        label: label,
        bleServiceUuid: bleUuid,
        bleCompanyId: companyId,
        wifiOui: oui,
        ssidPattern: pattern,
        confidence: confidence,
        source: SignatureSource.userAdded,
        notes: raw['notes'] is String ? raw['notes'] as String : null,
      ));
    }
    // v0.26.0 fix-pass: a user entry overriding the protocol-level
    // Remote ID entry changes what a cooperative broadcast means
    // in the catalog — that override must surface as a warning,
    // not slip in silently alongside the replacement.
    if (users.any((u) => u.id == 'rid-ble-fffa')) {
      warnings.add(
        'User signature "rid-ble-fffa" overrides the protocol-level '
        'Remote ID (ASTM F3411) entry — RID matches now use the '
        'user entry, not the built-in protocol assignment.',
      );
    }
    return DeviceSignatureCatalog(
      userSignatures: users,
      userLoadWarnings: warnings,
    );
  }

  /// Ranked candidate matches for [observation], highest
  /// confidence first (ties: catalog order, via stable id order).
  /// Empty when nothing matches — the caller renders that as
  /// `unknown`, never as a guessed class. A signature matching on
  /// several matchers appears once, with all firing evidence.
  List<SignatureMatch> match(DeviceObservation observation) {
    final mergedList = merged;
    final byId = <String, List<String>>{};
    final sigById = <String, DeviceSignature>{};
    void add(DeviceSignature sig, String evidence) {
      sigById[sig.id] = sig;
      final list = byId.putIfAbsent(sig.id, () => <String>[]);
      if (!list.contains(evidence)) list.add(evidence);
    }

    final obsBle = {
      for (final u in observation.bleServiceUuids) normalizeBleServiceUuid(u),
    };
    final obsOui = observation.wifiBssid == null
        ? null
        : manufacturerOui(observation.wifiBssid!);
    for (final sig in mergedList) {
      if (sig.bleServiceUuid != null &&
          obsBle.contains(normalizeBleServiceUuid(sig.bleServiceUuid!))) {
        add(sig, 'BLE service UUID ${sig.bleServiceUuid}');
      }
      if (sig.bleCompanyId != null &&
          observation.bleCompanyId == sig.bleCompanyId) {
        add(sig,
            'BLE company ID 0x${sig.bleCompanyId!.toRadixString(16).toUpperCase().padLeft(4, '0')}');
      }
      if (sig.wifiOui != null && obsOui != null) {
        final entryOui = normalizeCatalogOui(sig.wifiOui!);
        if (entryOui != null && entryOui == obsOui) {
          add(sig, 'Wi-Fi OUI $obsOui');
        }
      }
      if (sig.ssidPattern != null &&
          observation.ssid != null &&
          observation.ssid!.isNotEmpty) {
        var matched = false;
        try {
          matched = RegExp(sig.ssidPattern!, caseSensitive: false)
              .hasMatch(observation.ssid!);
        } catch (_) {
          matched = false; // invalid pattern can never match
        }
        if (matched) {
          add(sig, 'SSID matches pattern "${sig.ssidPattern}"');
        }
      }
    }
    final out = [
      for (final id in byId.keys)
        SignatureMatch(signature: sigById[id]!, evidence: byId[id]!),
    ];
    // Sort by confidence desc; keep catalog order on ties (the
    // merged list order is the tiebreak, via index lookup).
    final index = {
      for (var i = 0; i < mergedList.length; i++) mergedList[i].id: i,
    };
    out.sort((a, b) {
      final c = b.confidence.compareTo(a.confidence);
      if (c != 0) return c;
      return index[a.signature.id]!.compareTo(index[b.signature.id]!);
    });
    return out;
  }

  /// Only the confident subset of [match] — the list to render as
  /// a candidate class. Anything below threshold stays a weak
  /// candidate in [match], never a confident answer.
  List<SignatureMatch> confidentMatches(DeviceObservation observation) =>
      match(observation).where((m) => m.isConfident).toList();

  /// Convenience: match BLE advertisements only.
  List<SignatureMatch> matchBle({
    List<String> serviceUuids = const [],
    int? companyId,
  }) =>
      match(DeviceObservation(
          bleServiceUuids: serviceUuids, bleCompanyId: companyId));

  /// Convenience: match a Wi-Fi scan row only.
  List<SignatureMatch> matchWifi({String? bssid, String? ssid}) =>
      match(DeviceObservation(wifiBssid: bssid, ssid: ssid));
}
