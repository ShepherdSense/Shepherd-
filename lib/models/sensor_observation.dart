/// Universal sensor observation model — "if it can sense something, it
/// feeds Shepherd."
///
/// A [SensorObservation] is one timestamped measurement from any
/// non-RF-tripwire sensor: lidar / time-of-flight / ultrasonic range,
/// acoustic-array bearing, acoustic spectrum, PIR / break-beam binary,
/// generic RF-energy-like level, or camera motion.
///
/// Design rules (load-bearing, do not weaken):
/// 1. The RF tripwire is the detection authority. Observations are
///    CORROBORATION ONLY — see [Corroboration]. There is deliberately
///    no veto/suppress pathway anywhere in this model.
/// 2. Every field is honest about units and provenance. Estimates are
///    labeled estimates; absence of data is null, never zero-filled.
/// 3. ZMeta export ([toZMetaPayload]) maps each type to a modality that
///    actually fits. Types with no honest modality return null and stay
///    local — never invent a modality.
library;

import 'dart:math' as math;

import 'tracking.dart';

/// The six observation types on the Shepherd sensor bus.
enum SensorObsType {
  /// Lidar / time-of-flight / ultrasonic: distance (+ optional angle).
  range,

  /// Acoustic array: direction of arrival + confidence.
  bearing,

  /// Acoustic: frequency-bin magnitudes (blade-pass tones live here).
  spectrum,

  /// PIR / break-beam: triggered or not.
  binary,

  /// Generic RSSI-like level (the existing `SENSOR <name> <rssi_dbm>`).
  energy,

  /// Camera motion event: zone/label (+ optional local snapshot ref).
  motion,
}

/// Upgrade-only corroboration verdict for one observation against one
/// track.
///
/// There is deliberately NO veto/suppress field. A sensor can raise the
/// displayed confidence of a track that independent RF evidence already
/// supports; it can never cancel, hide, or downgrade a detection.
/// The constructor asserts [boost] is non-negative — any path that
/// tried to express "this sensor says nothing is here" as a negative
/// number fails loudly in tests.
///
/// [quality] is the geometry-alignment channel (0..1): how well the
/// observation lined up with the track, independent of how strong the
/// evidence is. The gated merger (see confidence_merger.dart) uses it
/// as part of the reliability weight w_s — the AV-FDTI lesson is that a
/// misaligned modality must contribute ~nothing, not a degraded
/// average. [Corroboration.none] carries quality 0 ("no opinion").
class Corroboration {
  const Corroboration({required this.boost, this.quality = 1.0, this.note = ''})
      : assert(boost >= 0, 'corroboration is upgrade-only: boost >= 0'),
        assert(quality >= 0 && quality <= 1,
            'alignment quality is a 0..1 weight');

  /// 0 = no opinion. >0 = this observation supports the track.
  /// Capped by producers; the merger caps the total (see spec).
  final double boost;

  /// 0..1 alignment quality feeding the merger's reliability gate.
  final double quality;

  /// Human-readable why, shown in the evidence view.
  final String note;

  static const none = Corroboration(boost: 0, quality: 0);
}

/// One typed measurement from any sensor on the bus.
class SensorObservation {
  const SensorObservation({
    required this.type,
    required this.sensorId,
    required this.timestamp,
    this.sensorLat,
    this.sensorLon,
    // RANGE
    this.distanceM,
    this.angleDeg,
    // BEARING
    this.bearingDeg,
    this.confidence = 0.0,
    // SPECTRUM
    this.freqHz = const [],
    this.magnitudes = const [],
    // BINARY
    this.triggered,
    // ENERGY
    this.levelDb,
    // MOTION
    this.zone,
    this.zoneLabel,
    this.snapshotRef,
  });

  final SensorObsType type;
  final String sensorId;
  final DateTime timestamp;

  /// WGS-84 position of the SENSOR (not the target). Null = unknown;
  /// never zero-filled (a null island fix is a lie).
  final double? sensorLat;
  final double? sensorLon;

  // --- RANGE ---
  /// Meters to the detected surface. Null when the sensor reports
  /// "no return" (max range / no echo) — absence, not zero.
  final double? distanceM;

  /// Degrees clockwise from north of the measurement axis, when the
  /// sensor is directional (scanning lidar). Null = omnidirectional /
  /// unknown axis.
  final double? angleDeg;

  // --- BEARING ---
  /// Degrees clockwise from north of the acoustic arrival bearing.
  final double? bearingDeg;

  /// 0..1 array confidence in the bearing. Estimate.
  final double confidence;

  // --- SPECTRUM ---
  /// Parallel arrays: bin center Hz → magnitude (linear, sensor units).
  final List<double> freqHz;
  final List<double> magnitudes;

  // --- BINARY ---
  final bool? triggered;

  // --- ENERGY ---
  /// RSSI-like level in dBm-ish sensor units. Deltas matter, not
  /// absolutes — same contract as LinkSample.snr.
  final double? levelDb;

  // --- MOTION ---
  /// Camera zone identifier ("3", "north-fence", ...).
  final String? zone;

  /// Human label for the zone, if the camera provides one.
  final String? zoneLabel;

  /// LOCAL reference to a pulled snapshot (file path / cache key).
  /// The image itself is never shipped to ZMeta or off-device.
  final String? snapshotRef;

  /// Strongest spectral peak, or null when no bins / all flat.
  ({double hz, double mag})? get spectralPeak {
    if (freqHz.isEmpty || magnitudes.isEmpty) return null;
    var best = 0;
    for (var i = 1; i < magnitudes.length && i < freqHz.length; i++) {
      if (magnitudes[i] > magnitudes[best]) best = i;
    }
    return (hz: freqHz[best], mag: magnitudes[best]);
  }

  /// Upgrade-only corroboration of [track].
  ///
  /// [sensorX]/[sensorY] is the sensor's field-local position in meters
  /// (x east, y north — the caller converts from lat/lon with the
  /// app's GPS origin; this model stays projection-free).
  ///
  /// Returns [Corroboration.none] ("no opinion") whenever the geometry
  /// doesn't line up OR the inputs are missing — silence is the safe
  /// default. Never negative. Never a veto.
  Corroboration corroborationFor(
    TrackEstimate track, {
    required double sensorX,
    required double sensorY,
  }) {
    switch (type) {
      case SensorObsType.range:
        final d = distanceM;
        if (d == null || !d.isFinite || d <= 0) return Corroboration.none;
        final dx = track.x - sensorX;
        final dy = track.y - sensorY;
        final trackDist = _hypot(dx, dy);
        // Tolerance: lidar-class sensors are ~cm-accurate; the TRACK is
        // the coarse one (±10 m class). Judge by track-grade tolerance.
        const tol = 12.0;
        if ((trackDist - d).abs() > tol) return Corroboration.none;
        if (angleDeg != null) {
          final trackAngle = _bearingDeg(dx, dy);
          var diff = (trackAngle - angleDeg!).abs() % 360;
          if (diff > 180) diff = 360 - diff;
          if (diff > 20) return Corroboration.none;
        }
        final closeness = 1 - ((trackDist - d).abs() / tol).clamp(0.0, 1.0);
        return Corroboration(
          boost: 0.05 + 0.20 * closeness,
          quality: closeness,
          note: 'RANGE ${d.toStringAsFixed(1)} m matches track '
              '(${trackDist.toStringAsFixed(0)} m from sensor)',
        );

      case SensorObsType.bearing:
        final b = bearingDeg;
        if (b == null || !b.isFinite) return Corroboration.none;
        final dx = track.x - sensorX;
        final dy = track.y - sensorY;
        if (_hypot(dx, dy) < 1.0) return Corroboration.none;
        final trackAngle = _bearingDeg(dx, dy);
        var diff = (trackAngle - b).abs() % 360;
        if (diff > 180) diff = 360 - diff;
        // Acoustic arrays are ±10–20° honest instruments; allow that.
        if (diff > 25) return Corroboration.none;
        final align = 1 - (diff / 25).clamp(0.0, 1.0);
        return Corroboration(
          boost: (0.05 + 0.15 * align) * confidence.clamp(0.0, 1.0),
          quality: align,
          note: 'Acoustic bearing ${b.toStringAsFixed(0)}° aligns with '
              'track (Δ${diff.toStringAsFixed(0)}°)',
        );

      case SensorObsType.spectrum:
        // Spectrum alone is context, not corroboration: a tonal peak
        // says "rotating machinery nearby", not "this track".
        // Surfaced in the evidence view + ZMeta; boost stays 0.
        return Corroboration.none;

      case SensorObsType.binary:
        if (triggered != true) return Corroboration.none;
        // PIR-class: ~10 m nominal radius. Crude, documented.
        if (_hypot(track.x - sensorX, track.y - sensorY) > 12.0) {
          return Corroboration.none;
        }
        return const Corroboration(
          boost: 0.10,
          quality: 1.0, // trigger inside the radius is inherently aligned
          note: 'PIR trigger near track',
        );

      case SensorObsType.energy:
        // Energy already drives the tripwire via virtual links (see
        // generic_sensor_driver.dart); double-counting it here would
        // inflate confidence from one measurement.
        return Corroboration.none;

      case SensorObsType.motion:
        // Camera motion near the track upgrades the displayed
        // confidence. It NEVER vetoes: absence of a motion event means
        // nothing (occlusion, night, facing away). The camera's facing
        // is unknown, so the gate is a generous 500 m around the
        // camera position — enough to reject cross-map coincidence
        // without pretending to know the field of view.
        if (_hypot(track.x - sensorX, track.y - sensorY) > 500.0) {
          return Corroboration.none;
        }
        return const Corroboration(
          boost: 0.15,
          quality: 1.0, // inside the 500 m gate; the camera's facing is
          // unknown, so alignment is binary, not graded
          note: 'Camera motion near track',
        );
    }
  }

  /// ZMeta observation *payload* for this observation, or null when no
  /// ZMeta modality honestly fits.
  ///
  /// Returns ONLY the payload object ({modality, features, ...}).
  /// SEAM: at merge, zmeta_adapter.dart wraps this in the envelope
  /// (zmeta_version/event/source/profile/lineage/timing_quality) and
  /// emits it through the existing ZMetaEmitter. The adapter MUST NOT
  /// invent fields the payload doesn't carry.
  ///
  /// Modality mapping (checked against zmeta-spec; never invented):
  /// - MOTION → EO (camera is electro-optical; snapshot_ref is a LOCAL
  ///   reference — the image is never shipped). The EO arm has no
  ///   required features and bans class_name/confidence/classification/
  ///   label — all avoided here.
  /// - BEARING/SPECTRUM → null. The 1.1.0 ACOUSTIC arm REQUIRES
  ///   center_freq_hz plus a level (spl_db, or pressure_pa with
  ///   pressure_statistic). A bearing is a direction with no level;
  ///   spectrum bins are uncalibrated magnitudes, not a sound
  ///   pressure. Fabricating a level would be exactly the kind of lie
  ///   the schema guards against. Both stay local-only: map overlay
  ///   + corroboration, never exported.
  /// - RANGE/BINARY/ENERGY → null. There is no LIDAR/PIR modality and
  ///   shoehorning them into EO/IR would misstate the measurement.
  Map<String, dynamic>? toZMetaPayload() {
    switch (type) {
      case SensorObsType.motion:
        return {
          'modality': 'EO',
          'features': {
            'shepherd_obs_type': 'MOTION',
            'camera_id': sensorId,
            if (zone != null) 'zone': zone,
            if (zoneLabel != null) 'zone_label': zoneLabel,
            // Local-only reference. The frame never leaves the device.
            if (snapshotRef != null) 'snapshot_ref': snapshotRef,
          },
        };
      case SensorObsType.bearing:
      case SensorObsType.spectrum:
      case SensorObsType.range:
      case SensorObsType.binary:
      case SensorObsType.energy:
        return null;
    }
  }

  static double _hypot(double x, double y) => math.sqrt(x * x + y * y);

  /// Degrees clockwise from north for a field-local (x east, y north)
  /// offset.
  static double _bearingDeg(double dx, double dy) {
    var deg = math.atan2(dx, dy) * 180 / math.pi;
    if (deg < 0) deg += 360;
    return deg;
  }
}
