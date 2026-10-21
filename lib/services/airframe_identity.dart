/// Airframe identity + capability classification for the Skydio
/// integration (docs/skydio_integration_spec.md).
///
/// Shepherd meets an airframe through whatever evidence actually
/// arrives — a controller CoT feed, a Remote ID broadcast, a mesh node
/// with the right callsign — and classifies it by that evidence:
///
///  - Class A: full sensing node (StreamScape link metrics for a node
///    whose position moves in 3D; AirMesh/SL5200 fit today).
///  - Class B: position node (CoT / telemetry position, no link
///    metrics; the standard X10D fit via controller CoT).
///  - Class C: broadcast contact (Remote ID only; civil fleets).
///  - Class D: RF cue only. NOT an airframe — energy cannot attribute
///    a platform, so Class D never enters this registry at all; it
///    stays in the emitter/SDR layer where it belongs.
///
/// Rules (binding, from the spec):
///  - Promote on evidence, never demote on silence. A record's class
///    only ever rises while the record lives.
///  - A whitelist match changes rendering and correlation priority
///    ONLY. Nothing here can suppress a track or an alert — there is
///    deliberately no code path from this file to detection.
///  - Remote ID identity is asserted, unauthenticated, spoofable:
///    an RID-only friendly renders FRIENDLY (claimed) until a Class
///    A/B feed corroborates the same airframe.
library;

/// Capability class of an airframe, by evidence. Declaration order is
/// rank order (D excluded by design — see library docs).
enum AirframeClass {
  /// Remote ID broadcast only.
  c,

  /// Telemetry/CoT position, no link metrics.
  b,

  /// Mesh sensing node with per-link metrics.
  a,
}

/// Rank for promotion comparisons (higher = more capable evidence).
int airframeClassRank(AirframeClass c) => switch (c) {
      AirframeClass.c => 1,
      AirframeClass.b => 2,
      AirframeClass.a => 3,
    };

/// One friendly-fleet registry entry (the "whitelist").
///
/// Population is manual entry of battery-tray ANSI serials (the
/// right-sized source for a handful of airframes); a future Cloud
/// `/vehicles` sync would produce the same entries.
class FriendlyEntry {
  const FriendlyEntry({
    required this.serial,
    this.callsign = '',
    this.classHint,
  });

  /// ANSI serial, normalized (trimmed, uppercased) at parse time.
  final String serial;

  /// Operator label / tail callsign shown on the map. May be empty.
  final String callsign;

  /// Operator-declared fit hint from the registry text (A or B).
  /// A hint is declared-fit evidence for promotion decisions, never
  /// a substitute for observed link metrics on its own — see
  /// [AirframeClassifier.observeMeshNode].
  final AirframeClass? classHint;

  @override
  String toString() =>
      'FriendlyEntry($serial${callsign.isEmpty ? '' : ', $callsign'}'
      '${classHint == null ? '' : ', ${classHint!.name.toUpperCase()}'})';
}

/// The friendly-serial registry, parsed from the operator's settings
/// text. One entry per line:
///
/// ```
/// 1581F5FHJ229R00N3K7P
/// 1581F6ABC123R00M4Q2W, VIPER-1
/// 1581F7XYZ789R00P8T3E, VIPER-2, A
/// ```
///
/// Format: `SERIAL[, CALLSIGN[, HINT]]` where HINT is `A` or `B`.
/// Blank lines and `#` comments are ignored; malformed lines are
/// skipped (never throw — a typo in settings must not kill ingest).
class FriendlyRegistry {
  const FriendlyRegistry(this.entries);

  final List<FriendlyEntry> entries;

  static const empty = FriendlyRegistry([]);

  static FriendlyRegistry parse(String text) {
    final out = <FriendlyEntry>[];
    final seen = <String>{};
    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final parts = line.split(',').map((p) => p.trim()).toList();
      final serial = normalizeSerial(parts[0]);
      if (serial.isEmpty || !seen.add(serial)) continue;
      AirframeClass? hint;
      if (parts.length >= 3) {
        hint = switch (parts[2].toUpperCase()) {
          'A' => AirframeClass.a,
          'B' => AirframeClass.b,
          _ => null,
        };
      }
      out.add(FriendlyEntry(
        serial: serial,
        callsign: parts.length >= 2 ? parts[1] : '',
        classHint: hint,
      ));
    }
    return FriendlyRegistry(out);
  }

  /// Serial comparison form: Remote ID broadcasts the ANSI serial
  /// verbatim; operators type it from a label. Trim + uppercase is
  /// the whole normalization — no character is ever rewritten.
  static String normalizeSerial(String s) => s.trim().toUpperCase();

  bool get isEmpty => entries.isEmpty;
  bool get isNotEmpty => entries.isNotEmpty;

  FriendlyEntry? entryForSerial(String? serial) {
    if (serial == null) return null;
    final n = normalizeSerial(serial);
    if (n.isEmpty) return null;
    for (final e in entries) {
      if (e.serial == n) return e;
    }
    return null;
  }

  FriendlyEntry? entryForCallsign(String? callsign) {
    if (callsign == null) return null;
    final n = callsign.trim().toUpperCase();
    if (n.isEmpty) return null;
    for (final e in entries) {
      if (e.callsign.toUpperCase() == n) return e;
    }
    return null;
  }

  /// CoT uids sometimes ARE the serial (UAS-tool style) and sometimes
  /// embed it. Exact equality after normalization, or the uid ends
  /// with the serial (e.g. `ANDROID-<serial>` style suffixes are NOT
  /// assumed — only a full-length suffix match counts, so a short
  /// serial can't accidentally match an unrelated uid tail).
  FriendlyEntry? entryForUid(String? uid) {
    if (uid == null) return null;
    final n = normalizeSerial(uid);
    if (n.isEmpty) return null;
    for (final e in entries) {
      if (e.serial == n) return e;
      if (e.serial.length >= 8 && n.endsWith(e.serial)) return e;
    }
    return null;
  }

  /// Any registry identity match for one observed airframe.
  FriendlyEntry? match({String? serial, String? callsign, String? uid}) =>
      entryForSerial(serial) ?? entryForCallsign(callsign) ?? entryForUid(uid);
}

/// Mutable per-airframe record held by [AirframeClassifier].
///
/// Identity fields merge across feeds: a Class C Remote ID contact
/// and a Class B CoT platform with the same serial (or the same
/// registry callsign) are ONE record — that merge is what lets a
/// second feed corroborate the first.
class AirframeRecord {
  AirframeRecord({required this.key});

  /// Canonical identity key: `serial:<SERIAL>` when a serial is
  /// known, else `callsign:<CALLSIGN>`, else `uid:<uid>`.
  String key;

  String? serial;
  String? callsign;
  String? cotUid;

  /// Highest-evidence class reached. Only ever rises (promotion).
  AirframeClass klass = AirframeClass.c;

  /// Registry entry matched to this airframe, if any.
  FriendlyEntry? registryEntry;

  /// How friendliness was established: 'registry' (whitelist match),
  /// 'cot' (friendly-affiliation CoT from the cooperative feed), or
  /// null (not friendly). RID alone NEVER sets this — an RID serial
  /// match sets [ridClaimed] instead (see [affiliationLabel]).
  String? friendlyBasis;

  /// True when a Remote ID serial matched the registry but no
  /// Class A/B feed has corroborated the airframe yet.
  bool ridClaimed = false;

  /// Evidence flags (monotonic — once true, stay true).
  bool hasLinkMetrics = false;
  bool hasTelemetryPosition = false;
  bool hasRid = false;

  /// Latest known position (WGS84) from the strongest feed.
  double? lat;
  double? lon;

  /// Geodetic altitude in meters, when the feed carries it.
  double? altM;

  /// Operator/control-station position (Remote ID System message).
  double? operatorLat;
  double? operatorLon;

  /// What the RID System message says that point IS (0 takeoff,
  /// 1 live operator GNSS, 2 fixed) — rendering must not upgrade a
  /// takeoff point into an operator. See ridOperatorLabel.
  int operatorLocationType = 0;

  /// Battery percent 0..100 when a feed reports it (CoT status).
  double? batteryPct;

  /// Heading/course in degrees, when reported.
  double? courseDeg;

  /// Ground speed m/s, when reported.
  double? speedMps;

  DateTime? lastSeen;
  String lastSource = '';

  bool get isFriendly => friendlyBasis != null;

  /// Display affiliation, honesty contract:
  ///  - registry/CoT-corroborated friendly → `FRIENDLY`
  ///  - CoT-affiliation-only → `FRIENDLY (FEED)` (the feed asserts
  ///    it; Shepherd did not verify it)
  ///  - RID whitelist claim, uncorroborated → `FRIENDLY (claimed)`
  ///  - anything else → `UNKNOWN`
  String get affiliationLabel {
    if (friendlyBasis == 'registry') return 'FRIENDLY';
    if (friendlyBasis == 'cot') return 'FRIENDLY (FEED)';
    if (ridClaimed) return 'FRIENDLY (claimed)';
    return 'UNKNOWN';
  }

  /// Short class chip text, e.g. `CLASS B · POSITION NODE`.
  String get classLabel => switch (klass) {
        AirframeClass.a => 'CLASS A · SENSING NODE',
        AirframeClass.b => 'CLASS B · POSITION NODE',
        AirframeClass.c => 'CLASS C · BROADCAST CONTACT',
      };

  /// Display name: registry/observed callsign, else serial, else key.
  String get displayName {
    final cs = callsign;
    if (cs != null && cs.isNotEmpty) return cs;
    final s = serial;
    if (s != null && s.isNotEmpty) return s;
    return key;
  }
}

/// Evidence input: one CoT platform observation (from the CoT
/// listener's platform path — see cot_listener.dart).
class CotPlatformEvidence {
  const CotPlatformEvidence({
    required this.uid,
    required this.callsign,
    required this.cotType,
    required this.lat,
    required this.lon,
    required this.time,
    this.haeM,
    this.courseDeg,
    this.speedMps,
    this.batteryPct,
  });

  final String uid;
  final String callsign;

  /// CoT type string, e.g. `a-f-A` (friendly air).
  final String cotType;
  final double lat;
  final double lon;
  final DateTime time;
  final double? haeM;
  final double? courseDeg;
  final double? speedMps;
  final double? batteryPct;
}

/// Evidence input: one aggregated Remote ID contact (from
/// remote_id.dart's tracker).
class RidEvidence {
  const RidEvidence({
    required this.serial,
    required this.time,
    this.lat,
    this.lon,
    this.altM,
    this.operatorLat,
    this.operatorLon,
    this.operatorLocationType = 0,
    this.courseDeg,
    this.speedMps,
  });

  /// Broadcast ANSI serial ('' when the contact has no Basic ID yet —
  /// such contacts key by transport source in the RID tracker and are
  /// only promoted here once a serial exists).
  final String serial;
  final DateTime time;
  final double? lat;
  final double? lon;
  final double? altM;
  final double? operatorLat;
  final double? operatorLon;
  final int operatorLocationType;
  final double? courseDeg;
  final double? speedMps;
}

/// The classifier: folds evidence into [AirframeRecord]s.
///
/// Pure Dart, no I/O, fully deterministic given the evidence stream —
/// the promotion rules below are the spec's capability-discovery
/// table, and the tests pin them.
class AirframeClassifier {
  AirframeClassifier({this.registry = FriendlyRegistry.empty});

  /// The friendly registry. Replaced wholesale when settings change;
  /// records re-match lazily on their next evidence event and on
  /// [rematchAll].
  FriendlyRegistry registry;

  final Map<String, AirframeRecord> _records = {};

  /// All live records, freshest first.
  List<AirframeRecord> get records {
    final out = _records.values.toList()
      ..sort((a, b) =>
          (b.lastSeen ?? DateTime(0)).compareTo(a.lastSeen ?? DateTime(0)));
    return List.unmodifiable(out);
  }

  AirframeRecord? recordFor({String? serial, String? callsign}) {
    for (final r in _records.values) {
      if (serial != null &&
          r.serial != null &&
          FriendlyRegistry.normalizeSerial(r.serial!) ==
              FriendlyRegistry.normalizeSerial(serial)) {
        return r;
      }
      if (callsign != null &&
          r.callsign != null &&
          r.callsign!.toUpperCase() == callsign.toUpperCase()) {
        return r;
      }
    }
    return null;
  }

  String _keyFor({String? serial, String? callsign, String? uid}) {
    if (serial != null && serial.isNotEmpty) {
      return 'serial:${FriendlyRegistry.normalizeSerial(serial)}';
    }
    if (callsign != null && callsign.isNotEmpty) {
      return 'callsign:${callsign.toUpperCase()}';
    }
    return 'uid:${uid ?? ''}';
  }

  /// Find-or-create the record for one identity, merging into an
  /// existing record when the identity overlaps by serial or
  /// callsign (the cross-feed corroboration merge).
  AirframeRecord _resolve({String? serial, String? callsign, String? uid}) {
    AirframeRecord? byUid;
    if (uid != null) {
      for (final r in _records.values) {
        if (r.cotUid == uid) {
          byUid = r;
          break;
        }
      }
    }
    final existing = recordFor(serial: serial, callsign: callsign) ?? byUid;
    if (existing != null) {
      // Re-key upward: once a serial is known it becomes canonical.
      if (serial != null && serial.isNotEmpty && existing.serial == null) {
        final newKey = _keyFor(serial: serial);
        if (newKey != existing.key && !_records.containsKey(newKey)) {
          _records.remove(existing.key);
          existing.key = newKey;
          _records[newKey] = existing;
        }
      }
      return existing;
    }
    final key = _keyFor(serial: serial, callsign: callsign, uid: uid);
    final rec = AirframeRecord(key: key);
    _records[key] = rec;
    return rec;
  }

  void _promote(AirframeRecord r, AirframeClass to) {
    if (airframeClassRank(to) > airframeClassRank(r.klass)) {
      r.klass = to;
    }
  }

  void _applyRegistry(AirframeRecord r) {
    final entry =
        registry.match(serial: r.serial, callsign: r.callsign, uid: r.cotUid);
    if (entry != null) {
      r.registryEntry = entry;
      if (r.serial == null && entry.serial.isNotEmpty) {
        r.serial = entry.serial;
      }
      if ((r.callsign == null || r.callsign!.isEmpty) &&
          entry.callsign.isNotEmpty) {
        r.callsign = entry.callsign;
      }
      // A registry match corroborated by a cooperative (A/B) feed is
      // plain FRIENDLY. An RID-only match stays (claimed) until such
      // a feed arrives — handled where ridClaimed is set.
      if (r.hasTelemetryPosition || r.hasLinkMetrics) {
        r.friendlyBasis = 'registry';
        r.ridClaimed = false;
      }
    }
  }

  /// Fold one controller-CoT platform observation in. CoT platforms
  /// are Class B evidence (position, no link metrics). A friendly-
  /// affiliation type (`a-f-*`) marks the record friendly-by-feed;
  /// a registry match marks it friendly-by-registry.
  AirframeRecord observeCotPlatform(CotPlatformEvidence e) {
    final entry = registry.match(callsign: e.callsign, uid: e.uid);
    final r = _resolve(
      serial: entry?.serial,
      callsign: e.callsign.isEmpty ? null : e.callsign,
      uid: e.uid,
    );
    r.cotUid = e.uid;
    if (e.callsign.isNotEmpty) r.callsign = e.callsign;
    r.hasTelemetryPosition = true;
    _promote(r, AirframeClass.b);
    r.lat = e.lat;
    r.lon = e.lon;
    if (e.haeM != null) r.altM = e.haeM;
    if (e.courseDeg != null) r.courseDeg = e.courseDeg;
    if (e.speedMps != null) r.speedMps = e.speedMps;
    if (e.batteryPct != null) r.batteryPct = e.batteryPct;
    r.lastSeen = e.time;
    r.lastSource = 'cot';
    if (e.cotType.startsWith('a-f-') && r.friendlyBasis == null) {
      r.friendlyBasis = 'cot';
    }
    _applyRegistry(r);
    return r;
  }

  /// Fold one Remote ID contact in. RID-only evidence is Class C.
  /// A registry serial match sets the (claimed) flag — and clears
  /// it again only when a cooperative feed has ALSO seen this
  /// airframe (the merge in [_resolve] makes that the same record).
  AirframeRecord? observeRid(RidEvidence e) {
    if (e.serial.isEmpty) return null;
    final r = _resolve(serial: e.serial);
    r.serial = FriendlyRegistry.normalizeSerial(e.serial);
    r.hasRid = true;
    // Never demote: class stays wherever stronger evidence put it.
    if (e.lat != null && e.lon != null) {
      // RID position fills the map only when no cooperative feed is
      // driving the record (cooperative positions outrank broadcast
      // assertions of the same airframe).
      if (!r.hasTelemetryPosition) {
        r.lat = e.lat;
        r.lon = e.lon;
      }
    }
    if (e.altM != null && !r.hasTelemetryPosition) r.altM = e.altM;
    if (e.operatorLat != null) r.operatorLat = e.operatorLat;
    if (e.operatorLon != null) r.operatorLon = e.operatorLon;
    r.operatorLocationType = e.operatorLocationType;
    if (e.courseDeg != null && !r.hasTelemetryPosition) {
      r.courseDeg = e.courseDeg;
    }
    if (e.speedMps != null && !r.hasTelemetryPosition) {
      r.speedMps = e.speedMps;
    }
    if (r.lastSeen == null || e.time.isAfter(r.lastSeen!)) {
      r.lastSeen = e.time;
    }
    if (r.lastSource != 'cot') r.lastSource = 'rid';
    _applyRegistry(r);
    if (r.registryEntry != null &&
        !r.hasTelemetryPosition &&
        !r.hasLinkMetrics &&
        r.friendlyBasis == null) {
      r.ridClaimed = true;
    }
    return r;
  }

  /// Fold mesh-node evidence in (Class A path): a registry-matched
  /// node present in the mesh WITH per-link metrics. Promotion to A
  /// requires the motion evidence (position moving in 3D) or the
  /// operator's declared A hint in the registry — link metrics alone
  /// prove a mesh node, not that it is the airborne one.
  AirframeRecord? observeMeshNode({
    required String nodeCallsign,
    required bool hasLinkMetrics,
    required bool moving3d,
    required DateTime time,
    double? lat,
    double? lon,
    double? altM,
  }) {
    final entry = registry.entryForCallsign(nodeCallsign);
    if (entry == null) return null;
    final r = _resolve(serial: entry.serial, callsign: nodeCallsign);
    r.callsign = nodeCallsign;
    if (hasLinkMetrics) {
      r.hasLinkMetrics = true;
      if (moving3d || entry.classHint == AirframeClass.a) {
        _promote(r, AirframeClass.a);
      } else {
        _promote(r, AirframeClass.b);
      }
    }
    if (lat != null && lon != null) {
      r.lat = lat;
      r.lon = lon;
    }
    if (altM != null) r.altM = altM;
    r.lastSeen = time;
    r.lastSource = 'mesh';
    _applyRegistry(r);
    return r;
  }

  /// Re-run registry matching over all records (call after the
  /// registry is replaced, so a freshly typed serial takes effect
  /// on airframes already being observed).
  void rematchAll() {
    for (final r in _records.values) {
      _applyRegistry(r);
      if (r.registryEntry != null &&
          r.hasRid &&
          !r.hasTelemetryPosition &&
          !r.hasLinkMetrics &&
          r.friendlyBasis == null) {
        r.ridClaimed = true;
      }
    }
  }

  /// Display hygiene only: drop Class C stranger records silent for
  /// [stale]. Friendly records and Class A/B records are NEVER
  /// pruned — silence never demotes a friendly classification.
  void prune(DateTime now, {Duration stale = const Duration(minutes: 10)}) {
    _records.removeWhere((_, r) {
      if (r.isFriendly || r.ridClaimed) return false;
      if (r.klass != AirframeClass.c) return false;
      final seen = r.lastSeen;
      return seen == null || now.difference(seen) > stale;
    });
  }

  void clear() => _records.clear();
}
