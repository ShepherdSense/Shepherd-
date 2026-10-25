/// Phone-only tier (Shepherd v0.26.0, Fieldwatch-borrow item 4).
///
/// Detects "no mesh / SDR hardware attached" and gates a
/// phone-scans-only mode: phone BLE scan + phone Wi-Fi survey +
/// Remote ID + signature library + Hunt. Nothing else.
///
/// HONEST LABELS, used everywhere this mode surfaces:
///  - Mode label: `PHONE-ONLY` (never "mesh", never unqualified).
///  - Range label: `PHONE-RANGE · tens of meters, not area
///    coverage` — distinct from mesh coverage, never presented as
///    mesh-equivalent.
///  - Phone-OS scan quotas and randomized MACs may hide quiet or
///    randomized radios; absence of results is "nothing heard",
///    never "nothing present".
///
/// This service never claims hardware: it only evaluates the
/// attachment state the coordinator passes in, and it only ever
/// exposes phone sources. Silvus / SDR / serial drivers are not
/// representable in its output at all — there is no field that
/// could carry them.
///
/// Receive-only. Nothing here transmits anything. Fail-safe: a
/// missing or unavailable scan source degrades that source to off
/// (and is named in [unavailableSources]), never to a confident
/// wrong answer.
library;

/// Phone-resident scan sources. These are the ONLY sources the
/// phone tier can ever expose.
enum PhoneScanSource {
  bleScan,
  wifiSurvey,
  remoteId,
  signatureLibrary,
  hunt,
}

/// Human-readable names for phone sources (used in UI strings).
extension PhoneScanSourceLabel on PhoneScanSource {
  String get label {
    switch (this) {
      case PhoneScanSource.bleScan:
        return 'Phone BLE scan';
      case PhoneScanSource.wifiSurvey:
        return 'Phone Wi-Fi survey';
      case PhoneScanSource.remoteId:
        return 'Remote ID';
      case PhoneScanSource.signatureLibrary:
        return 'Signature library';
      case PhoneScanSource.hunt:
        return 'Hunt';
    }
  }
}

/// Hardware attachment state, as reported by the coordinator (which
/// owns driver detection). All flags default to "not attached", so
/// a coordinator that knows nothing gets the phone tier, not a
/// false claim of mesh coverage.
class HardwareAttachment {
  const HardwareAttachment({
    this.meshDriverAttached = false,
    this.sdrAttached = false,
    this.serialDriverAttached = false,
    this.meshDriverConfigured = false,
  });

  /// A mesh driver (Silvus, Meshtastic, ESP32/LoRa gateway, or any
  /// other mesh radio driver) is attached and active.
  final bool meshDriverAttached;

  /// An SDR receiver is attached (e.g. via the SDR bridge).
  final bool sdrAttached;

  /// A serial/USB radio driver is attached.
  final bool serialDriverAttached;

  /// A mesh driver is CONFIGURED / KNOWN (e.g. saved in the
  /// persisted radio list) even if it is not currently polling.
  /// v0.26.0 fix-pass: a mesh user who has not pressed START yet
  /// (or pressed STOP) must not see a false PHONE-ONLY banner, so
  /// a configured mesh driver deactivates the tier exactly like an
  /// attached one. The coordinator also passes this as true while
  /// the saved-radio list has not finished loading yet, because
  /// until then no attachment determination has been made at all.
  final bool meshDriverConfigured;

  bool get anyHardwareAttached =>
      meshDriverAttached ||
      sdrAttached ||
      serialDriverAttached ||
      meshDriverConfigured;
}

/// Evaluated phone-tier state. Construct via [PhoneTier.evaluate].
class PhoneTier {
  const PhoneTier._({
    required this.active,
    required this.availableSources,
    required this.unavailableSources,
  });

  /// Evaluates the tier from the coordinator's attachment state
  /// plus per-source availability (a source the OS or device does
  /// not provide is passed as false and degrades to off).
  ///
  /// The tier is active ONLY when no mesh, SDR, or serial hardware
  /// is attached or configured. Any hardware attached or configured
  /// means the phone tier is off — the hardware path owns the
  /// picture.
  factory PhoneTier.evaluate({
    required HardwareAttachment hardware,
    Map<PhoneScanSource, bool> sourceAvailable = const {},
  }) {
    if (hardware.anyHardwareAttached) {
      return const PhoneTier._(
        active: false,
        availableSources: [],
        unavailableSources: [],
      );
    }
    final available = <PhoneScanSource>[];
    final unavailable = <PhoneScanSource>[];
    for (final source in PhoneScanSource.values) {
      if (sourceAvailable[source] ?? true) {
        available.add(source);
      } else {
        unavailable.add(source);
      }
    }
    return PhoneTier._(
      active: true,
      availableSources: available,
      unavailableSources: unavailable,
    );
  }

  /// True when the phone-scans-only mode is the active mode.
  final bool active;

  /// Phone sources currently usable. Empty when inactive, and
  /// never contains a hardware driver source (none exists in
  /// [PhoneScanSource] by construction).
  final List<PhoneScanSource> availableSources;

  /// Phone sources that are unavailable on this device / OS and
  /// have degraded to off. Named, never silently dropped.
  final List<PhoneScanSource> unavailableSources;

  /// Mode label for UI. Always `PHONE-ONLY` when active; the
  /// inactive label never claims phone-only coverage.
  String get modeLabel => active ? 'PHONE-ONLY' : 'HARDWARE';

  /// Range honesty label. Only meaningful when active.
  String get rangeLabel => active
      ? 'PHONE-RANGE · tens of meters, not area coverage'
      : 'Hardware coverage (not phone range)';

  /// Short explanation of why a source is off, or null when every
  /// active-tier source is available.
  String? get unavailableReason {
    if (!active || unavailableSources.isEmpty) return null;
    final names = unavailableSources.map((s) => s.label).join(', ');
    return 'Unavailable on this device, degraded to off: $names';
  }

  bool get hasAnySource => availableSources.isNotEmpty;
}
