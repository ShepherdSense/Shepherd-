/// Multi-radio driver framework.
///
/// Every supported radio family implements [RadioDriver]: it polls its
/// hardware and emits plain [LinkSample]s. Everything downstream —
/// tripwire, tracker, dashboard, map — is radio-agnostic and consumes
/// only LinkSamples.
///
/// Namespacing: each driver prefixes its node IDs (`silvus:90550`),
/// so link keys (`silvus:90550 → silvus:90551`) can never collide
/// across vendors, and per-link tripwire baselines stay independent.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/link_sample.dart';
import '../models/tracking.dart';
import 'silvus_api.dart';
import 'simulated.dart';
import 'kraken_driver.dart';
import 'meshtastic_driver.dart';
import 'esp32_driver.dart';
import 'generic_sensor_driver.dart';
import 'camera_driver.dart';

/// One configured radio network.
class RadioConfig {
  RadioConfig({
    required this.driverId,
    required this.address,
    this.label = '',
    this.enabled = true,
    this.pollInterval = 0.25,
  });

  /// 'silvus' | 'mpu5' | 'harris' | 'sdr' | 'simulated'.
  final String driverId;

  /// IP/host for network drivers; '' for simulated.
  final String address;
  final String label;
  bool enabled;
  double pollInterval;

  String get displayLabel =>
      label.isEmpty ? '${driverId.toUpperCase()} · $address' : label;

  Map<String, dynamic> toJson() => {
        'driverId': driverId,
        'address': address,
        'label': label,
        'enabled': enabled,
        'pollInterval': pollInterval,
      };

  factory RadioConfig.fromJson(Map<String, dynamic> j) => RadioConfig(
        driverId: '${j['driverId'] ?? 'silvus'}',
        address: '${j['address'] ?? ''}',
        label: '${j['label'] ?? ''}',
        enabled: j['enabled'] != false,
        pollInterval:
            (double.tryParse('${j['pollInterval']}') ?? 0.25)
                .clamp(0.1, 60.0)
                .toDouble(),
      );
}

/// Live status of one driver instance, for the dashboard radio card.
class DriverStatus {
  DriverStatus({
    required this.driverId,
    required this.label,
    required this.enabled,
    this.lastPoll,
    this.linkCount = 0,
    this.error,
  });

  final String driverId;
  final String label;
  final bool enabled;
  DateTime? lastPoll;
  int linkCount;
  String? error;
}

/// The contract every radio family implements.
abstract class RadioDriver {
  /// 'silvus' | 'mpu5' | 'harris' | 'sdr' | 'simulated'.
  String get driverId;

  /// Human label, e.g. 'SILVUS'.
  String get label;

  /// True when this driver can actually run (telemetry implemented).
  bool get isImplemented;

  /// One poll: raw link samples with driver-namespaced node IDs.
  Future<List<LinkSample>> poll();

  /// Quick reachability check for discovery / setup validation.
  Future<bool> probe();

  /// Shown on the radio card when a poll succeeds but returns no links.
  String get emptyHint =>
      'Radio reachable but reports no RF links (radios unmeshed?)';

  /// Longest a sample from this driver may age before it stops counting
  /// as live evidence. Null = derive from the poll interval (default).
  /// Drivers whose hardware reports slower than they are polled (a
  /// sweeping SDR) override this.
  Duration? get sampleMaxAge => null;

  void dispose() {}
}

/// Silvus StreamCaster driver: HTTP JSON-RPC `streamscape_data`.
class SilvusDriver extends RadioDriver {
  SilvusDriver({required String ip}) : _api = SilvusApi(ip: ip);

  final SilvusApi _api;

  @override
  String get driverId => 'silvus';

  @override
  String get label => 'SILVUS';

  @override
  bool get isImplemented => true;

  @override
  Future<List<LinkSample>> poll() async {
    final snap = await _api.fetchSnapshot();
    if (snap == null) return [];
    // Namespace node IDs so vendors can never collide.
    return [
      for (final l in snap.links)
        LinkSample(
          timestamp: l.timestamp,
          fromNode: 'silvus:${l.fromNode}',
          toNode: 'silvus:${l.toNode}',
          snr: l.snr,
          mcs: l.mcs,
          pcns: l.pcns,
          noiseFrom: l.noiseFrom,
          noiseTo: l.noiseTo,
        ),
    ];
  }

  @override
  Future<bool> probe() => _api.probe();

  @override
  void dispose() => _api.close();
}

/// Simulated mesh driver: wraps [SimulatedSource] so simulated mode is
/// just another driver. Node IDs are namespaced `sim:...`.
class SimulatedDriver extends RadioDriver {
  SimulatedDriver({this.pollInterval = 0.25}) : _sim = SimulatedSource();

  final SimulatedSource _sim;
  final double pollInterval;

  @override
  String get driverId => 'sim';

  @override
  String get label => 'SIMULATED';

  @override
  bool get isImplemented => true;

  @override
  Future<List<LinkSample>> poll() async {
    final raw = _sim.tick(dt: pollInterval);
    return [
      for (final l in raw)
        LinkSample(
          timestamp: l.timestamp,
          fromNode: 'sim:${l.fromNode}',
          toNode: 'sim:${l.toNode}',
          snr: l.snr,
          mcs: l.mcs,
          pcns: l.pcns,
          noiseFrom: l.noiseFrom,
          noiseTo: l.noiseTo,
        ),
    ];
  }

  @override
  Future<bool> probe() async => true;

  /// Canonical sim layout with namespaced keys, matching [poll] output.
  Map<String, NodePosition> get nodeLayout => {
        for (final e in _sim.nodeLayout.entries)
          'sim:${e.key}': NodePosition(
            nodeId: 'sim:${e.key}',
            x: e.value.x,
            y: e.value.y,
            height: e.value.height,
            antenna: e.value.antenna,
          ),
      };
}

/// MPU5 (Persistent Systems Wave Relay) — telemetry not yet implemented.
/// Wave Relay does not mesh with Silvus MN-MIMO; it would be a separate
/// driver emitting LinkSamples once its management API is mapped.
class Mpu5Driver extends RadioDriver {
  @override
  String get driverId => 'mpu5';

  @override
  String get label => 'MPU5';

  @override
  bool get isImplemented => false;

  @override
  Future<List<LinkSample>> poll() =>
      throw UnimplementedError('MPU5 telemetry not yet implemented');

  @override
  Future<bool> probe() async => false;
}

/// L3Harris Falcon family — telemetry not yet implemented.
/// Needs a pollable per-neighbor signal interface (SNMP MIB or similar);
/// an SNMP probe will determine what is actually exposed.
class L3HarrisDriver extends RadioDriver {
  @override
  String get driverId => 'harris';

  @override
  String get label => 'L3HARRIS';

  @override
  bool get isImplemented => false;

  @override
  Future<List<LinkSample>> poll() =>
      throw UnimplementedError('L3Harris telemetry not yet implemented');

  @override
  Future<bool> probe() async => false;
}

/// One band-energy reading from the PC-side `sdr_bridge.py`.
/// Pure data + parsing; unit-tested in test/sdr_bridge_test.dart.
class SdrBand {
  SdrBand({
    required this.radio,
    required this.band,
    required this.centerMhz,
    required this.bwMhz,
    required this.energyDbfs,
    required this.noiseDbfs,
    required this.binsDbfs,
    required this.t,
    this.peakMhz,
    this.peakDbfs,
    this.spanMhz,
    this.sigHint,
  });

  final String radio;
  final String band;
  final double centerMhz;
  final double bwMhz;

  /// Band-median PSD in dBFS (negative). The stable wideband metric.
  final double energyDbfs;

  /// 10th-percentile PSD: the band's noise floor estimate, dBFS.
  final double noiseDbfs;

  /// Per-sub-band (8) PEAK PSD, dBFS. Catches narrowband emitters the
  /// median ignores; peak-based, so spur-sensitive.
  final List<double> binsDbfs;

  final DateTime t;

  /// Absolute frequency (MHz) and level of the strongest non-DC bin the
  /// bridge saw in this band. Null from older bridges. An investigation
  /// aid, not an identification.
  final double? peakMhz;
  final double? peakDbfs;

  /// Width (MHz) of spectrum actually measured; can be narrower than
  /// [bwMhz] when the radio's sample rate can't cover the whole band.
  final double? spanMhz;

  /// Additive signature hint from newer bridges (e.g. `fhss-2g4`,
  /// `ofdm-5g`). Null from older bridges that don't send it. Parsed and
  /// exposed only — no detection logic consumes it.
  final String? sigHint;

  /// Parse a decoded bridge datagram. Returns null for beacons,
  /// wrong versions, and malformed packets (never throws).
  static SdrBand? tryParse(Map<String, dynamic> j) {
    try {
      if (j['v'] != 1 || j['kind'] != 'band') return null;
      final bins = (j['bins_dbfs'] as List)
          .map((e) => (e as num).toDouble())
          .toList();
      final energy = (j['energy_dbfs'] as num).toDouble();
      final noise = (j['noise_dbfs'] as num).toDouble();
      // NaN / infinite readings must never reach the tripwire's baseline.
      if (!energy.isFinite ||
          !noise.isFinite ||
          bins.any((b) => !b.isFinite)) {
        return null;
      }
      double? opt(String k) {
        final v = j[k];
        return v is num && v.isFinite ? v.toDouble() : null;
      }

      // Additive field: old bridges don't send it, so this is null-safe.
      final sh = j['sig_hint'];

      return SdrBand(
        radio: '${j['radio']}',
        band: '${j['band']}',
        centerMhz: (j['center_mhz'] as num).toDouble(),
        bwMhz: (j['bw_mhz'] as num).toDouble(),
        energyDbfs: energy,
        noiseDbfs: noise,
        binsDbfs: bins,
        peakMhz: opt('peak_mhz'),
        peakDbfs: opt('peak_dbfs'),
        spanMhz: opt('span_mhz'),
        sigHint: sh is String && sh.isNotEmpty ? sh : null,
        t: DateTime.fromMillisecondsSinceEpoch(
            ((j['t'] as num).toDouble() * 1000).round()),
      );
    } catch (_) {
      return null;
    }
  }

  /// Virtual link `sdr:<radio> → sdr:band-<label>`.
  ///
  /// Polarity convention (shared with the bridge): bridge energy is dBFS
  /// (negative). Negated into [LinkSample.snr], an emitter APPEARING in
  /// the band reads as a positive "dip" in dB for the tripwire:
  /// dip = baseline - snr = energy_now - energy_baseline. Sub-band peaks
  /// ride along in [LinkSample.pcns] for investigation.
  LinkSample toLinkSample() => LinkSample(
        timestamp: t,
        fromNode: 'sdr:$radio',
        toNode: 'sdr:band-$band',
        snr: -energyDbfs,
        noiseFrom: -noiseDbfs,
        pcns: [for (final b in binsDbfs) -b],
      );
}

/// SDR spectrum-sensor driver: listens for the PC-side bridge
/// (`field_kit/sdr_bridge/sdr_bridge.py` — any supported SDR: RTL-SDR,
/// ADALM-Pluto, USRP B200/B210, HackRF/Airspy/LimeSDR via SoapySDR;
/// RX only, never transmits) on UDP.
///
/// Each watched band becomes a virtual tripwire link, so the whole
/// downstream pipeline (adaptive thresholds, baseline hold, alerts,
/// event log) works unchanged. Honest scope: one radio reports band
/// ENERGY, not direction, range, or identity — and these virtual links
/// carry no geometry, so app_state keeps them out of the position
/// solver, shadow grid, and stitcher. Alerts still fire.
/// One detected LoRa chirp train from the bridge's ELRS detector
/// (`elrs_chirp` UDP event). LoRa MODULATION evidence only: any LoRa
/// emitter inside the detector's (SF, BW) grid lights this up. It is
/// NOT an ELRS identification, and the UI must never present it as one
/// (see [ElrsSignature.displayLabel] for the enforced wording).
class ElrsChirp {
  ElrsChirp({
    required this.radio,
    required this.band,
    required this.centerMhz,
    required this.freqMhz,
    required this.sf,
    required this.bwKhz,
    required this.snrDb,
    required this.t,
  });

  final String radio;
  final String band;
  final double centerMhz;

  /// Absolute frequency of the train, MHz.
  final double freqMhz;
  final int sf;
  final double bwKhz;
  final double snrDb;
  final DateTime t;

  /// 2.4 GHz vs sub-GHz family, for the GemX cross-band correlation.
  String get family {
    if (centerMhz >= 2400 && centerMhz < 2500) return '2g4';
    if (centerMhz >= 850 && centerMhz < 960) return '900m';
    return 'other';
  }

  /// Parse a decoded bridge datagram. Null for wrong kinds/versions
  /// and malformed packets (never throws).
  static ElrsChirp? tryParse(Map<String, dynamic> j) {
    try {
      if (j['v'] != 1 || j['kind'] != 'elrs_chirp') return null;
      double asDouble(String k) => (j[k] as num).toDouble();
      final freq = asDouble('freq_mhz');
      final snr = asDouble('snr_db');
      if (!freq.isFinite || !snr.isFinite) return null;
      return ElrsChirp(
        radio: '${j['radio']}',
        band: '${j['band']}',
        centerMhz: asDouble('center_mhz'),
        freqMhz: freq,
        sf: (j['sf'] as num).toInt(),
        bwKhz: asDouble('bw_khz'),
        snrDb: snr,
        t: DateTime.fromMillisecondsSinceEpoch(
            ((j['t'] as num).toDouble() * 1000).round()),
      );
    } catch (_) {
      return null;
    }
  }
}

/// A scored Gemini dual-emission signature.
///
/// Sources: (a) bridge-local `elrs_signature` events — one wideband
/// capture holding time-correlated chirp trains ~40 MHz apart; (b)
/// app-correlated via [GeminiCorrelator] — chirp trains from two radios
/// coinciding in time (GemX: 2.4 GHz + 900 MHz; or two 2.4 GHz radios
/// ~40 MHz apart).
///
/// HONESTY CONTRACT (enforced by tests in test/sdr_bridge_test.dart):
/// this is "signature consistent with ELRS Gemini", NEVER "confirmed
/// ELRS". The score grows with repeated coincidences; a lone
/// coincidence is weak evidence by construction.
class ElrsSignature {
  ElrsSignature({
    required this.radio,
    required this.mode,
    required this.score,
    required this.obs,
    required this.freqsMhz,
    required this.t,
  });

  /// Bridge radio name, or 'app' for app-level cross-radio correlation.
  final String radio;

  /// 'gemini-2g4' | 'gemini-900m' | 'gemx'.
  final String mode;

  /// 0..1, grows with repeated coincident observations.
  final double score;

  /// How many coincidences built the score.
  final int obs;
  final List<double> freqsMhz;
  final DateTime t;

  /// The ONLY user-facing description. "Possible" is load-bearing:
  /// no public ELRS-specific detector exists, and ours is the first
  /// attempt -- it must not present as ground truth.
  String get displayLabel {
    final bands = mode == 'gemx'
        ? '2.4 GHz + 900 MHz'
        : mode == 'gemini-900m'
            ? '900 MHz dual-frequency'
            : '2.4 GHz dual-frequency';
    return 'Possible ELRS Gemini signature ($bands, '
        'score ${(score * 100).round()}%, $obs coincidence${obs == 1 ? '' : 's'})';
  }

  /// Modes the bridge is allowed to report. A rogue or future bridge
  /// sending an unknown mode string must not reach the UI (reviewer B).
  static const knownModes = {'gemini-2g4', 'gemini-900m', 'gemx'};

  static ElrsSignature? tryParse(Map<String, dynamic> j) {
    try {
      if (j['v'] != 1 || j['kind'] != 'elrs_signature') return null;
      final mode = '${j['mode']}';
      if (!knownModes.contains(mode)) return null;
      final score = (j['score'] as num).toDouble();
      if (!score.isFinite || score < 0 || score > 1) return null;
      final freqs = (j['freqs_mhz'] as List)
          .map((e) => (e as num).toDouble())
          .where((f) => f.isFinite)
          .toList();
      return ElrsSignature(
        radio: '${j['radio']}',
        mode: mode,
        score: score,
        obs: (j['obs'] as num).toInt(),
        freqsMhz: freqs,
        t: DateTime.fromMillisecondsSinceEpoch(
            ((j['t'] as num).toDouble() * 1000).round()),
      );
    } catch (_) {
      return null;
    }
  }
}

/// App-level Gemini correlation across bridge radios.
///
/// Two receivers are needed for GemX (no single SDR spans 2.4 GHz and
/// 900 MHz): typically two bridge instances, one staring at each band.
/// This correlator pairs chirp trains across radios/bands in time and
/// scores the dual-emission signature the same way the bridge does
/// locally: coincident pairs on the documented Gemini separations.
///
/// Pure function over a chirp list: deterministic, unit-tested, no I/O.
class GeminiCorrelator {
  /// Max |t_a - t_b| for two chirp trains to count as coincident.
  /// Captures arrive seconds apart per sweep; 2 s keeps genuinely
  /// simultaneous emissions while rejecting unrelated activity.
  static const coincidenceWindow = Duration(seconds: 2);

  /// How far back chirps stay eligible for correlation.
  static const keepWindow = Duration(seconds: 120);

  /// Correlate [chirps] (already time-pruned by the caller, ideally)
  /// into app-level signatures. Returns at most one signature per
  /// mode; empty when nothing coincides.
  static List<ElrsSignature> correlate(List<ElrsChirp> chirps, DateTime now) {
    final cutoff = now.subtract(keepWindow);
    final live =
        chirps.where((c) => !c.t.isBefore(cutoff)).toList(growable: false);
    final out = <ElrsSignature>[];
    // GemX: 2.4 GHz train + 900 MHz train within the window.
    var gemxPairs = 0;
    final gemxFreqs = <double>[];
    // Cross-radio single-band Gemini: two 2.4 GHz trains ~40 MHz apart
    // (two radios stitched across the Gemini pair).
    var dualPairs = 0;
    final dualFreqs = <double>[];
    for (var i = 0; i < live.length; i++) {
      for (var j = i + 1; j < live.length; j++) {
        final a = live[i], b = live[j];
        if (a.radio == b.radio && a.band == b.band) continue;
        if (a.t.difference(b.t).abs() > coincidenceWindow) continue;
        final fa = {a.family, b.family};
        if (fa.contains('2g4') && fa.contains('900m')) {
          gemxPairs++;
          gemxFreqs.addAll([a.freqMhz, b.freqMhz]);
        } else {
          final sep = (a.freqMhz - b.freqMhz).abs();
          if (sep >= 35 && sep <= 45) {
            dualPairs++;
            dualFreqs.addAll([a.freqMhz, b.freqMhz]);
          }
        }
      }
    }
    // Score: 1 - exp(-pairs/3) -- several coincidences to matter, a
    // lone pair is weak evidence, saturating like the bridge scorer.
    if (gemxPairs > 0) {
      final s = 1 - math.exp(-gemxPairs / 3);
      out.add(ElrsSignature(
        radio: 'app',
        mode: 'gemx',
        score: s,
        obs: gemxPairs,
        freqsMhz: gemxFreqs.toSet().toList(),
        t: now,
      ));
    }
    if (dualPairs > 0) {
      final s = 1 - math.exp(-dualPairs / 3);
      out.add(ElrsSignature(
        radio: 'app',
        mode: 'gemini-2g4',
        score: s,
        obs: dualPairs,
        freqsMhz: dualFreqs.toSet().toList(),
        t: now,
      ));
    }
    return out;
  }
}

/// One passive-Doppler peak from the bridge's Doppler detector
/// (doppler_refinement_spec.md). RX-only: the bridge listens to an
/// ambient LTE downlink the carrier transmits anyway and measures what
/// moving objects do to it. The output is RADIAL VELOCITY, not a
/// position — it answers "the track's motion is Doppler-consistent".
class DopplerRef {
  DopplerRef({
    required this.radio,
    required this.centerMhz,
    required this.dopplerHz,
    required this.radialMs,
    required this.snrDb,
    required this.refLocked,
    required this.t,
  });

  final String radio;
  final double centerMhz;

  /// Measured Doppler shift of the peak, Hz (signed).
  final double dopplerHz;

  /// Radial velocity implied at the tuned center, m/s.
  /// Negative = approaching (documented convention).
  final double radialMs;

  /// Peak SNR over the clutter-canceled noise floor, dB.
  final double snrDb;

  /// Direct-path reference healthy. False ⇒ no coherent measurement;
  /// the app treats it as zero weight.
  final bool refLocked;
  final DateTime t;

  /// Parse a decoded bridge datagram. Null for wrong kinds/versions
  /// and malformed packets (never throws).
  static DopplerRef? tryParse(Map<String, dynamic> j) {
    try {
      if (j['v'] != 1 || j['kind'] != 'doppler_ref') return null;
      double asDouble(String k) => (j[k] as num).toDouble();
      final doppler = asDouble('doppler_hz');
      final radial = asDouble('radial_ms');
      final snr = asDouble('snr_db');
      if (!doppler.isFinite || !radial.isFinite || !snr.isFinite) {
        return null;
      }
      return DopplerRef(
        radio: '${j['radio']}',
        centerMhz: asDouble('center_mhz'),
        dopplerHz: doppler,
        radialMs: radial,
        snrDb: snr,
        refLocked: j['ref_locked'] == true,
        t: DateTime.fromMillisecondsSinceEpoch(
            ((j['t'] as num).toDouble() * 1000).round()),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Verdict of the Doppler correlation: how many observed Doppler peaks
/// agreed with the track's predicted bistatic radial velocity.
class DopplerVerdict {
  const DopplerVerdict({
    required this.agreements,
    required this.score,
    required this.qualified,
    this.newestAgreementAt,
  });

  final int agreements;

  /// 1 − exp(−agreements/2) — saturating, like the ELRS scorers.
  final double score;

  /// True when ≥ 2 agreements, or a single > 12 dB SNR agreement (the
  /// single-coincidence bar from the ELRS Urban-LoRa lesson).
  final bool qualified;

  final DateTime? newestAgreementAt;
}

/// App-side Doppler correlator (doppler_refinement_spec.md, Stage 2).
///
/// Predicted bistatic radial velocity of the RF tripwire track along
/// the radio↔eNB geometry vs observed doppler_ref events in a 120 s
/// window. Pure function over inputs: deterministic, unit-tested, no
/// I/O. Station positions are operator-configured field-local meters
/// (x east, y north) — the app converts from lat/lon with its GPS
/// origin; this stays projection-free.
///
/// A Doppler DISAGREEMENT contributes exactly 0 and never deletes or
/// downgrades the tripwire track: a null can mean tangential motion
/// (zero radial component), a payload-stripped RCS ~22 dB below the
/// brochure number, or the mover being RF-quiet to this geometry —
/// none of which disproves the tripwire.
class DopplerCorrelator {
  /// How far back Doppler refs stay eligible for correlation.
  static const agreementWindow = Duration(seconds: 120);

  /// Minimum in-gate agreements for the score to count.
  static const minAgreements = 2;

  /// A single agreement above this SNR counts (high-SNR exception).
  static const singleHighSnrDb = 12.0;

  static DopplerVerdict correlate({
    required TrackEstimate track,
    required List<DopplerRef> refs,
    required DateTime now,
    required double radioX,
    required double radioY,
    required double enbX,
    required double enbY,
  }) {
    final speed = track.speedMps;
    final heading = track.headingDeg;
    if (speed == null || heading == null || speed < 0.2) {
      // No velocity estimate (or effectively stationary): nothing to
      // predict — silence, not disagreement.
      return const DopplerVerdict(
          agreements: 0, score: 0.0, qualified: false);
    }
    // Track velocity vector (heading clockwise from north).
    final hr = heading * math.pi / 180;
    final vx = speed * math.sin(hr);
    final vy = speed * math.cos(hr);
    // Predicted bistatic radial velocity: v · (û_tx + û_rx) / 2, with
    // û_tx = unit vector target→eNB, û_rx = target→radio.
    var tx = enbX - track.x, ty = enbY - track.y;
    var rx = radioX - track.x, ry = radioY - track.y;
    final tl = math.sqrt(tx * tx + ty * ty);
    final rl = math.sqrt(rx * rx + ry * ry);
    if (tl < 1e-6 || rl < 1e-6) {
      return const DopplerVerdict(
          agreements: 0, score: 0.0, qualified: false);
    }
    tx /= tl;
    ty /= tl;
    rx /= rl;
    ry /= rl;
    // Sign convention (documented): approaching = negative, matching
    // the bridge's radial_ms and the app tracker's velocity sign.
    // v·û > 0 means moving toward the station ⇒ negate.
    final predicted = -(vx * (tx + rx) + vy * (ty + ry)) / 2;
    final gate = math.max(0.5, 0.25 * predicted.abs());

    final cutoff = now.subtract(agreementWindow);
    var agreements = 0;
    var highSnrSingle = false;
    DateTime? newest;
    for (final r in refs) {
      if (!r.refLocked) continue; // no reference, no measurement
      if (r.t.isBefore(cutoff) || r.t.isAfter(now)) continue;
      if ((predicted - r.radialMs).abs() <= gate) {
        agreements++;
        if (r.snrDb > singleHighSnrDb) highSnrSingle = true;
        if (newest == null || r.t.isAfter(newest)) newest = r.t;
      }
    }
    final qualified =
        agreements >= minAgreements || (agreements == 1 && highSnrSingle);
    return DopplerVerdict(
      agreements: agreements,
      score: 1 - math.exp(-agreements / 2),
      qualified: qualified,
      newestAgreementAt: newest,
    );
  }
}

/// One WPP-IDP Doppler-line detection (passive_radar_wpp_idp_spec.md).
///
/// Single-RX-channel, no-clean-reference passive radar: per-packet
/// (preamble) energy → DC removal → STFT → Doppler-line detector.
/// RX-only; listens to signals of opportunity. Output is a
/// *disturbance bearing estimate* — never an identity, never a
/// position fix. Demonstrated geometry is meters to tens of meters:
/// a perimeter/area gap-filler, not a standoff sensor.
class WppIdpDoppler {
  WppIdpDoppler({
    required this.radio,
    required this.band,
    required this.dopplerHz,
    required this.strength,
    required this.motionState,
    required this.t,
    this.bladeFlashHz,
    this.rcsDbm2,
  });

  /// Radio/node id that produced the detection.
  final String radio;
  final String band;

  /// Doppler line frequency, Hz (signed: sign gives inbound/outbound
  /// relative to the baseline).
  final double dopplerHz;

  /// Detector strength (dB over the CFAR threshold).
  final double strength;

  /// 'static' or 'moving' — the NODE's motion state. The paper assumes
  /// a static receiver; moving-node outputs are R&D logging only and
  /// must not merge into track confidence (ego-motion gate).
  final String motionState;

  final DateTime t;

  /// Blade-pass modulation frequency, Hz (opt) — ONE corroborating
  /// feature behind the RCS-reasonableness gate, never identity
  /// (Kozlov deception constraint: micro-Doppler is spoofable).
  final double? bladeFlashHz;

  /// Estimated RCS in dBsm (opt) — the counter-countermeasure the
  /// deception paper itself names.
  final double? rcsDbm2;

  bool get nodeStatic => motionState == 'static';

  /// Ego-motion gate (passive_radar_wpp_idp_spec.md): the paper assumes
  /// a static receiver — node motion impresses its own slow amplitude
  /// modulation on the packet-energy series and masquerades as Doppler.
  /// Moving-node outputs are R&D logging only: they contribute exactly
  /// 0 to track confidence. This is the predicate the merger wiring
  /// uses; tested directly.
  bool get mergesIntoConfidence => nodeStatic;

  /// Parse a decoded bridge/node datagram. Null for wrong
  /// kinds/versions and malformed packets (never throws).
  static WppIdpDoppler? tryParse(Map<String, dynamic> j) {
    try {
      if (j['v'] != 1 || j['kind'] != 'wpp_idp_doppler') return null;
      double asDouble(String k) => (j[k] as num).toDouble();
      final doppler = asDouble('doppler_hz');
      final strength = asDouble('strength');
      if (!doppler.isFinite || !strength.isFinite) return null;
      double? opt(String k) {
        final v = j[k];
        return v is num && v.isFinite ? v.toDouble() : null;
      }

      final ms = '${j['motion_state'] ?? ''}';
      return WppIdpDoppler(
        radio: '${j['radio']}',
        band: '${j['band'] ?? ''}',
        dopplerHz: doppler,
        strength: strength,
        // Fail-safe default: an unknown motion state is treated as
        // moving (R&D logging only, never merged).
        motionState: ms == 'static' ? 'static' : 'moving',
        t: DateTime.fromMillisecondsSinceEpoch(
            ((j['t'] as num).toDouble() * 1000).round()),
        bladeFlashHz: opt('blade_flash_hz'),
        rcsDbm2: opt('rcs_dbm2'),
      );
    } catch (_) {
      return null;
    }
  }

  /// Honesty + deception-constraint assessment. The label ALWAYS says
  /// "Possible"/"consistent with" — never a type assertion. A
  /// textbook helicopter-like blade flash on a 250 g-quad RCS is
  /// flagged as an RCS mismatch, not an identification.
  WppIdpAssessment assess() {
    final buf = StringBuffer(
        'Possible moving reflector (WPP-IDP Doppler ${dopplerHz.toStringAsFixed(1)} Hz, '
        'strength ${strength.toStringAsFixed(1)} dB) — consistent with a baseline crossing');
    var mismatch = false;
    String? rcsNote;
    final bf = bladeFlashHz;
    final rcs = rcsDbm2;
    if (bf != null && bf.isFinite && bf > 0) {
      buf.write('; blade-flash-like modulation ~${bf.toStringAsFixed(0)} Hz '
          '(one corroborating feature, never identity)');
      if (rcs != null && rcs.isFinite) {
        mismatch = _rcsMismatch(bf, rcs);
        if (mismatch) {
          rcsNote =
              'RCS-reasonableness gate: blade modulation implies a larger rotor class than '
              '${rcs.toStringAsFixed(0)} dBsm supports — treating as possible deception/spoof, not identification';
          buf.write('. $rcsNote');
        }
      }
    }
    return WppIdpAssessment(
      label: buf.toString(),
      rcsMismatch: mismatch,
      note: rcsNote ?? '',
    );
  }

  /// Coarse heuristic (documented, not physics): blade-pass frequency
  /// implies a rotor-size class (WIDELY REPORTED: frequency = blade
  /// count × RPM); RCS implies a size class. Differing by more than
  /// one class step is flagged. This is the counter-countermeasure
  /// the Kozlov paper names — a Mini 2 cannot have a helicopter's
  /// RCS, so the lie fails the sanity check.
  static bool _rcsMismatch(double bladeFlashHz, double rcsDbm2) {
    final flashClass = bladeFlashHz >= 120
        ? 2
        : bladeFlashHz >= 40
            ? 1
            : 0;
    final rcsClass = rcsDbm2 >= -5
        ? 2
        : rcsDbm2 >= -15
            ? 1
            : 0;
    return (flashClass - rcsClass).abs() > 1;
  }
}

/// Honesty/deception assessment of one WPP-IDP detection.
class WppIdpAssessment {
  const WppIdpAssessment({
    required this.label,
    required this.rcsMismatch,
    required this.note,
  });

  /// User-facing text. Always "Possible"/"consistent with" — never a
  /// type assertion, never "confirmed/located/identified".
  final String label;

  /// True when the blade-flash feature contradicts the RCS estimate.
  final bool rcsMismatch;
  final String note;
}

/// One LoRa preamble PMR reading from the bridge's EXPERIMENTAL PMR
/// monitor (`pmr` UDP event; see pmr_monitor_spec.md). PMR is the
/// dechirp-domain peak-to-mean ratio of a detected preamble: a LOW
/// PMR on an otherwise present preamble is CONSISTENT WITH preamble
/// interference — it is never a confirmed jamming verdict, never an
/// identification, and never evidence about position. Readings are
/// ALERTS ONLY: app_state must never feed them into the tripwire,
/// the confidence merger, tracks, or any veto. The `experimental`
/// flag is REQUIRED: a `pmr` packet without it is rejected, so a
/// future non-experimental PMR format can never be silently treated
/// as this experimental one.
class PmrReading {
  PmrReading({
    required this.radio,
    required this.channelMhz,
    required this.pmrDb,
    required this.nChirps,
    required this.toneOffHz,
    required this.thresholdDb,
    required this.marginDb,
    required this.alert,
    required this.t,
  });

  final String radio;
  final double channelMhz;
  final double pmrDb;
  final int nChirps;

  /// Dechirped tone offset in Hz. Mixes the true frequency offset
  /// with the monitor's symbol-alignment offset (up to +/-16 bins =
  /// +/-15.6 kHz): a COARSE channel identifier only, NEVER a CFO
  /// measurement. See pmr_monitor_spec.md.
  final double toneOffHz;

  /// Operator-set alert threshold in dB, or null (report-only: the
  /// monitor never alerts without one).
  final double? thresholdDb;

  /// pmrDb - thresholdDb, or null when report-only. Negative means
  /// the reading is below threshold (alerting).
  final double? marginDb;

  /// True only when a threshold is set AND pmrDb falls below it.
  final bool alert;
  final DateTime t;

  /// Parse a decoded bridge datagram. Null for wrong kinds/versions,
  /// a missing `experimental` flag, and malformed packets (never
  /// throws).
  static PmrReading? tryParse(Map<String, dynamic> j) {
    try {
      if (j['v'] != 1 || j['kind'] != 'pmr') return null;
      if (j['experimental'] != true) return null;
      double asDouble(String k) => (j[k] as num).toDouble();
      double? asNullableDouble(String k) {
        final v = j[k];
        if (v == null) return null;
        return (v as num).toDouble();
      }

      final pmr = asDouble('pmr_db');
      final tone = asDouble('tone_off_hz');
      final thr = asNullableDouble('threshold_db');
      if (!pmr.isFinite || !tone.isFinite) return null;
      if (thr != null && !thr.isFinite) return null;
      // Alert and margin are RECOMPUTED here, never trusted from the
      // wire: a lying or stale bridge must not make the display
      // self-contradictory (alert true while pmr is above threshold).
      final alert = thr != null && pmr < thr;
      final mar = thr == null ? null : pmr - thr;
      return PmrReading(
        radio: '${j['radio']}',
        channelMhz: asDouble('channel_mhz'),
        pmrDb: pmr,
        nChirps: (j['n_chirps'] as num).toInt(),
        toneOffHz: tone,
        thresholdDb: thr,
        marginDb: mar,
        alert: alert,
        t: DateTime.fromMillisecondsSinceEpoch(
            ((j['t'] as num).toDouble() * 1000).round()),
      );
    } catch (_) {
      return null;
    }
  }

  /// Display wording. The honesty contract, enforced here so no UI
  /// can soften it: "consistent with", never "confirmed"; the
  /// EXPERIMENTAL tag is always present.
  String get displayLabel {
    final base = 'EXPERIMENTAL PMR ${pmrDb.toStringAsFixed(1)} dB '
        '($nChirps chirps, ${channelMhz.toStringAsFixed(1)} MHz)';
    if (thresholdDb == null) return '$base — report-only, no threshold set';
    final m = marginDb;
    final mStr = m == null
        ? ''
        : ' (margin ${m >= 0 ? '+' : ''}${m.toStringAsFixed(1)} dB)';
    if (alert) {
      return '$base — ALERT: below threshold '
          '${thresholdDb!.toStringAsFixed(1)} dB$mStr — consistent with '
          'preamble interference, NOT a confirmed jamming verdict';
    }
    return '$base — above threshold '
        '${thresholdDb!.toStringAsFixed(1)} dB$mStr';
  }
}

class SdrDriver extends RadioDriver {
  SdrDriver({required this.host, required this.port});

  /// The bridge's destination, i.e. where THIS app listens:
  /// "127.0.0.1:49161" (default), "host", or "host:port".
  factory SdrDriver.fromAddress(String address) {
    var host = '127.0.0.1';
    var port = defaultBridgePort;
    final addr = address.trim();
    if (addr.isNotEmpty) {
      final i = addr.lastIndexOf(':');
      if (i > 0) {
        host = addr.substring(0, i);
        port = int.tryParse(addr.substring(i + 1)) ?? port;
      } else {
        host = addr;
      }
    }
    return SdrDriver(host: host, port: port);
  }

  /// UDP port the bridge sends to (and this driver listens on).
  static const int defaultBridgePort = 49161;

  final String host;
  final int port;

  /// Bands the bridge hasn't refreshed in this long are dropped, so a
  /// dead bridge reads as no data instead of a frozen last reading.
  static const Duration maxBandAge = Duration(seconds: 15);

  RawDatagramSocket? _socket;
  DateTime? _lastBeaconAt;
  DateTime? _lastDataAt;
  String _bridgeBackend = '';
  final Map<String, SdrBand> _latest = {};
  final Map<String, DateTime> _arrivedAt = {};

  /// Recent LoRa chirp trains (elrs_chirp events), oldest-first.
  /// Bounded; pruned to [GeminiCorrelator.keepWindow] on read.
  final List<ElrsChirp> _chirps = [];

  /// Latest bridge-local Gemini signature per radio (elrs_signature).
  final Map<String, ElrsSignature> _signatures = {};

  /// Recent passive-Doppler peaks (doppler_ref events), oldest-first.
  /// Bounded; pruned to [DopplerCorrelator.agreementWindow] in _handle.
  final List<DopplerRef> _dopplerRefs = [];

  /// Recent WPP-IDP Doppler-line detections, oldest-first.
  /// Bounded; pruned to [_wppIdpWindow] in _handle.
  final List<WppIdpDoppler> _wppIdp = [];

  /// WPP-IDP observation window (120 s, like the ELRS/Doppler paths).
  static const Duration wppIdpWindow = Duration(seconds: 120);

  /// Recent EXPERIMENTAL PMR preamble readings, oldest-first.
  /// Bounded; pruned to [pmrWindow] in _handle. Alerts only: never
  /// a tripwire input, never fused into tracks, never a veto.
  final List<PmrReading> _pmrReadings = [];

  /// PMR observation window (120 s, like the other additive paths).
  static const Duration pmrWindow = Duration(seconds: 120);

  /// Operator-configured station data for the Doppler correlator
  /// (field-local meters, x east / y north): the SDR radio's position
  /// and the LTE eNB's position. Null until configured — the
  /// correlator abstains without them (silence, never a guess).
  double? stationX;
  double? stationY;
  double? enbX;
  double? enbY;

  /// What the bridge last announced itself as ('' until first beacon).
  String get bridgeBackend => _bridgeBackend;

  /// Latest reading per band (read-only view, for UI panels).
  List<SdrBand> get latestBands => List.unmodifiable(_latest.values);

  /// Recent chirp trains for the app-level Gemini correlator.
  /// Read-only: pruning happens in _handle, never here.
  List<ElrsChirp> get recentChirps => List.unmodifiable(_chirps);

  /// Latest bridge-local Gemini signature per radio.
  List<ElrsSignature> get latestSignatures =>
      List.unmodifiable(_signatures.values);

  /// Recent passive-Doppler peaks for the app-level correlator.
  /// Read-only: pruning happens in _handle, never here.
  List<DopplerRef> get recentDopplerRefs => List.unmodifiable(_dopplerRefs);

  /// Recent WPP-IDP Doppler-line detections. Read-only: pruning
  /// happens in _handle, never here.
  List<WppIdpDoppler> get recentWppIdp => List.unmodifiable(_wppIdp);

  /// Recent EXPERIMENTAL PMR readings. Read-only: pruning happens
  /// in _handle, never here. Alerts only, never tripwire input.
  List<PmrReading> get recentPmrReadings =>
      List.unmodifiable(_pmrReadings);

  /// Most recent alerting PMR reading, or null when none is alerting.
  PmrReading? get latestPmrAlert {
    for (var i = _pmrReadings.length - 1; i >= 0; i--) {
      if (_pmrReadings[i].alert) return _pmrReadings[i];
    }
    return null;
  }

  Future<void> _ensureSocket() async {
    if (_socket != null) return;
    // `InternetAddress(host)` throws for anything but an IP literal;
    // fall back to all interfaces so a hostname (or "0.0.0.0") works.
    final ip = InternetAddress.tryParse(host) ?? InternetAddress.anyIPv4;
    _socket = await RawDatagramSocket.bind(ip, port);
  }

  /// Test hook: feed one raw UDP datagram body through the parser.
  @visibleForTesting
  void datagramForTest(String text) =>
      _handle(utf8.encode(text));

  void _handle(List<int> data) {    Map<String, dynamic>? j;
    try {
      j = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (j['v'] != 1) return;
    if (j['kind'] == 'beacon') {
      _lastBeaconAt = DateTime.now();
      final b = j['backend'];
      if (b is String) _bridgeBackend = b;
      return;
    }
    // ELRS detector events: additive, older bridges never send them.
    if (j['kind'] == 'elrs_chirp') {
      final c = ElrsChirp.tryParse(j);
      if (c != null) {
        _chirps.add(c);
        // Bounded: chirps are small; 300 covers >10 min at the
        // throttled 1-per-2s-per-band rate with headroom. Prune by
        // age here (not in the getter) so reads never mutate state.
        if (_chirps.length > 300) {
          _chirps.removeRange(0, _chirps.length - 300);
        }
        final cutoff =
            DateTime.now().subtract(GeminiCorrelator.keepWindow);
        _chirps.removeWhere((e) => e.t.isBefore(cutoff));
        _lastDataAt = DateTime.now();
      }
      return;
    }
    if (j['kind'] == 'elrs_signature') {
      final s = ElrsSignature.tryParse(j);
      if (s != null) {
        _signatures[s.radio] = s;
        _lastDataAt = DateTime.now();
      }
      return;
    }
    // Passive-Doppler peaks: additive, older bridges never send them.
    if (j['kind'] == 'doppler_ref') {
      final r = DopplerRef.tryParse(j);
      if (r != null) {
        _dopplerRefs.add(r);
        if (_dopplerRefs.length > 300) {
          _dopplerRefs.removeRange(0, _dopplerRefs.length - 300);
        }
        final cutoff =
            DateTime.now().subtract(DopplerCorrelator.agreementWindow);
        _dopplerRefs.removeWhere((e) => e.t.isBefore(cutoff));
        _lastDataAt = DateTime.now();
      }
      return;
    }
    // EXPERIMENTAL PMR readings: additive, same transport. Alerts
    // only — they are stored for the monitor section and never
    // converted into LinkSamples anywhere in this file.
    if (j['kind'] == 'pmr') {
      final r = PmrReading.tryParse(j);
      if (r != null) {
        _pmrReadings.add(r);
        if (_pmrReadings.length > 300) {
          _pmrReadings.removeRange(0, _pmrReadings.length - 300);
        }
        final cutoff = DateTime.now().subtract(pmrWindow);
        _pmrReadings.removeWhere((e) => e.t.isBefore(cutoff));
        _lastDataAt = DateTime.now();
      }
      return;
    }
    // WPP-IDP Doppler lines: additive, same transport.
    if (j['kind'] == 'wpp_idp_doppler') {
      final w = WppIdpDoppler.tryParse(j);
      if (w != null) {
        _wppIdp.add(w);
        if (_wppIdp.length > 300) {
          _wppIdp.removeRange(0, _wppIdp.length - 300);
        }
        final cutoff = DateTime.now().subtract(wppIdpWindow);
        _wppIdp.removeWhere((e) => e.t.isBefore(cutoff));
        _lastDataAt = DateTime.now();
      }
      return;
    }
    final band = SdrBand.tryParse(j);
    if (band == null) return;
    _lastDataAt = DateTime.now();
    final key = '${band.radio}:${band.band}';
    _latest[key] = band;
    _arrivedAt[key] = DateTime.now();
  }

  void _drain() {
    final s = _socket;
    if (s == null) return;
    Datagram? d;
    while ((d = s.receive()) != null) {
      _handle(d!.data);
    }
  }

  @override
  String get driverId => 'sdr';

  @override
  String get label => 'SDR';

  @override
  bool get isImplemented => true;

  @override
  String get emptyHint =>
      'No SDR bridge data — is sdr_bridge.py running and sending to '
      '$host:$port?';

  // The bridge sweeps bands one after another, so each band refreshes
  // only every few seconds. Stay live as long as the driver itself
  // keeps the reading.
  @override
  Duration? get sampleMaxAge => maxBandAge + const Duration(seconds: 1);

  @override
  Future<List<LinkSample>> poll() async {
    await _ensureSocket();
    _drain();
    // Report the latest reading per band on EVERY poll, not just fresh
    // arrivals: a sweep revisits each band every couple of seconds, and
    // an empty poll reads as "radio broken" downstream. But bands the
    // bridge hasn't refreshed in a while are dropped, so a dead bridge
    // reads as no data instead of a frozen last reading.
    final cutoff = DateTime.now().subtract(maxBandAge);
    _latest.removeWhere((k, _) => (_arrivedAt[k] ?? cutoff).isBefore(cutoff));
    _arrivedAt.removeWhere((k, _) => !_latest.containsKey(k));
    return [for (final b in _latest.values) b.toLinkSample()];
  }

  @override
  Future<bool> probe() async {
    try {
      await _ensureSocket();
    } catch (_) {
      return false;
    }
    // Listen briefly for the bridge; it is a separate process the user
    // starts, so probe() reports what setup validation needs: true only
    // when the bridge is actually talking. ANY bridge packet counts --
    // beacons come every few seconds and a sweep's band packets nearly
    // as often, so waiting for one specific kind made a healthy bridge
    // fail the probe most of the time.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      _drain();
      final now = DateTime.now();
      for (final heard in [_lastBeaconAt, _lastDataAt]) {
        if (heard != null &&
            now.difference(heard) < const Duration(seconds: 30)) {
          return true;
        }
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  @override
  void dispose() {
    _socket?.close();
    _socket = null;
    _latest.clear();
    _arrivedAt.clear();
    _chirps.clear();
    _signatures.clear();
    _dopplerRefs.clear();
    _wppIdp.clear();
  }
}

/// Build a driver from a config. Throws for unimplemented families.
RadioDriver driverFor(RadioConfig config) {
  switch (config.driverId) {
    case 'silvus':
      return SilvusDriver(ip: config.address);
    case 'mpu5':
      return Mpu5Driver();
    case 'harris':
      return L3HarrisDriver();
    case 'sdr':
      return SdrDriver.fromAddress(config.address);
    case 'kraken':
      return KrakenDriver.fromAddress(config.address);
    case 'meshtastic':
      return MeshtasticDriver.fromAddress(config.address);
    case 'esp32':
      return Esp32Driver();
    case 'sensor':
      return GenericSensorDriver();
    case 'camera':
      return CameraDriver();
    default:
      throw ArgumentError('Unknown driver: ${config.driverId}');
  }
}

/// Driver types the user can pick in the radio manager.
const List<({String id, String label, bool implemented})> driverTypes = [
  (id: 'silvus', label: 'SILVUS', implemented: true),
  (id: 'sdr', label: 'SDR (Pluto / USRP / RTL-SDR / HackRF…)', implemented: true),
  (id: 'kraken', label: 'KRAKENSDR (DF bearings)', implemented: true),
  (id: 'meshtastic', label: 'MESHTASTIC (LoRa mesh nodes)', implemented: true),
  (id: 'esp32', label: 'ESP32 NODE (UDP beacons)', implemented: true),
  (id: 'sensor', label: 'SENSOR BUS (lidar / acoustic / PIR / …)', implemented: true),
  (id: 'camera', label: 'CAMERA (webhook / ONVIF)', implemented: true),
  (id: 'mpu5', label: 'MPU5 (Wave Relay)', implemented: false),
  (id: 'harris', label: 'L3HARRIS', implemented: false),
];
