import 'dart:collection';
import 'dart:math' as math;

import '../models/link_sample.dart';

/// Tunables for the tripwire detector. Mirrors silvus_tripwire.py defaults,
/// plus the adaptive-threshold and baseline-hold options.
class TripwireConfig {
  const TripwireConfig({
    this.baselineWindow = 120,
    this.minBaseline = 10,
    this.dipThreshold = 6.0,
    this.confirmPolls = 2,
    this.adaptive = true,
    this.madK = 5.0,
    this.adaptiveFloorFrac = 0.67,
    this.adaptiveCapMult = 3.0,
    this.maxHoldPolls = 480,
    this.signedDetection = true,
    this.fadeGate = 3.0,
    this.varianceChannel = true,
    this.varK = 3.0,
    this.varWindow = 12,
    this.varFloor = 1.0,
  });

  /// Rolling history kept per link direction (in polls).
  final int baselineWindow;

  /// Polls of history before the baseline is trusted.
  final int minBaseline;

  /// Reference dip depth (radio units) that counts as a possible crossing.
  /// With [adaptive] on, each link's own threshold is derived from its
  /// noise and kept within [adaptiveFloorFrac]..[adaptiveCapMult] times
  /// this value; with [adaptive] off it is used as-is on every link.
  final double dipThreshold;

  /// Consecutive polls above threshold required to confirm an event.
  /// Lower = faster alerts, higher = fewer false alarms.
  final int confirmPolls;

  /// Derive each link's threshold from its own noise (robust spread of
  /// its baseline window) instead of one fixed number for every link.
  /// Noisy links get a higher bar, quiet links a lower one.
  final bool adaptive;

  /// Adaptive threshold = madK × robust sigma (1.4826 × MAD) of the link's
  /// baseline window, then clamped (see below).
  final double madK;

  /// Lower clamp for the adaptive threshold, as a fraction of
  /// [dipThreshold]. Stops a perfectly flat (quantized) link from
  /// triggering on tiny wiggles.
  final double adaptiveFloorFrac;

  /// Upper clamp for the adaptive threshold, as a multiple of
  /// [dipThreshold]. Stops one very noisy link from going deaf.
  final double adaptiveCapMult;

  /// Longest a link's baseline is frozen during a continuous disturbance,
  /// in polls. Past this the new level is treated as the new normal
  /// (a node moved, lasting interference) and the link re-baselines.
  /// At the default 0.25 s poll interval, 480 polls = 2 minutes.
  final int maxHoldPolls;

  /// Fade-level-aware signed detection (Wilson & Patwari 2012): estimate
  /// each link's fade level during quiet calibration and expect the
  /// disturbance in the physically likely direction — a *dip* on
  /// anti-fade links, a *rise* on deep-fade links, either on intermediate
  /// ones. Dip-only detection discards real signal on deep-fade links.
  final bool signedDetection;

  /// |fade level| below this (radio units) counts as intermediate, where
  /// either direction may signal.
  final double fadeGate;

  /// Variance (VRTI) second channel (Patwari & Wilson 2011): motion raises
  /// RSS variance even when the mean barely moves. Runs alongside the
  /// mean-deviation detector with different false-alarm behavior; the two
  /// cross-check.
  final bool varianceChannel;

  /// Variance alarm factor over the link's quiet variance.
  final double varK;

  /// Rolling window (polls) for the variance estimate. Shorter than the
  /// baseline window on purpose: variance must react in a few polls.
  final int varWindow;

  /// Floor for the variance alarm (radio units squared). Stops a
  /// perfectly flat link from alarming on quantization jitter.
  final double varFloor;
}

/// Rolling-median baseline disturbance detector, one instance per link
/// direction.
///
/// For each poll: baseline = median of the link's recent SNR history
/// (not including the current sample); deviation = baseline − snr on
/// anti-fade links, snr − baseline on deep-fade links (fade level from
/// the network median of link medians — Wilson & Patwari 2012), the
/// larger of the two on intermediate links. A deviation at/above the
/// link's threshold for [TripwireConfig.confirmPolls] consecutive polls
/// emits a [CrossingEvent] carrying the disturbance's peak depth,
/// direction, and duration.
///
/// A variance (VRTI) second channel (Patwari & Wilson 2011) runs
/// alongside: motion raises RSS variance even when the mean barely
/// moves.
///
/// Baseline hold: samples that are themselves disturbed are NOT added to
/// the history (nor to the quiet variance estimate). Otherwise a target
/// that lingers drags the median down and the detector "heals" around it
/// while it is still there. The hold is bounded by
/// [TripwireConfig.maxHoldPolls] so a genuine, lasting change of level
/// re-baselines instead of alarming forever.
///
/// All magnitudes are estimates in radio-internal units.
class Tripwire {
  Tripwire({TripwireConfig? config})
      : config = config ?? const TripwireConfig();

  final TripwireConfig config;

  /// Polls of history before the baseline is trusted, clamped to ≥ 1:
  /// a 0 would open the "trusted" gate on an empty history and
  /// `_medianSorted([])` would throw a RangeError.
  int get _minBaseline => config.minBaseline < 1 ? 1 : config.minBaseline;

  /// Variance window actually used: never below 1 poll — a 0/negative
  /// varWindow would otherwise drain the window on every poll.
  int get _varWindow => math.max(1, config.varWindow);

  final Map<String, ListQueue<double>> _hist = {};
  final Map<String, int> _dipCount = {};
  final Map<String, DateTime> _dipStart = {};
  final Map<String, double> _dipPeak = {};
  final Map<String, int> _held = {};
  final List<CrossingEvent> _pending = [];
  final Map<String, DateTime> _rebaselinedAt = {};
  int _rebaselines = 0;

  /// Last trusted baseline median per link — the fade-level reference.
  final Map<String, double> _linkMedian = {};

  /// Rolling raw-SNR window per link for the variance (VRTI) channel.
  final Map<String, ListQueue<double>> _varHist = {};

  /// Quiet variance estimate per link (EWMA, updated only while calm).
  final Map<String, double> _varBase = {};

  /// Whether the variance channel fired during the current episode.
  final Map<String, bool> _varFired = {};

  /// How many times a link gave up holding its baseline and re-baselined
  /// (lasting level change). Diagnostic.
  int get rebaselineCount => _rebaselines;

  /// When each link last gave up holding its baseline. After a reset the
  /// detector treats the new level as normal, so anything still standing
  /// there is invisible; callers should surface this, not show CLEAR.
  Map<String, DateTime> get rebaselinedAt => Map.unmodifiable(_rebaselinedAt);

  /// Feed one raw sample; returns the sample enriched with deviation,
  /// baseline and this link's threshold.
  ///
  /// `dip` on the returned sample is the deviation in the *expected*
  /// direction (baseline−snr on anti-fade links, snr−baseline on
  /// deep-fade links, the larger of the two on intermediate links) —
  /// always ≥ 0 when disturbed.
  LinkSample process(LinkSample raw) {
    final snr = raw.snr;

    // Non-finite SNR is never real data: NaN poisons the median
    // baseline, -inf would confirm a bogus max-depth event. Drop the
    // sample before it touches any history.
    if (snr != null && !snr.isFinite) {
      return raw;
    }

    final key = raw.linkKey;
    final hist = _hist.putIfAbsent(key, () => ListQueue<double>());

    final trusted = hist.length >= _minBaseline;
    var baseline = double.nan;
    var threshold = config.dipThreshold;
    var dev = 0.0;
    var direction = 'dip';

    if (trusted) {
      final sorted = hist.toList()..sort();
      baseline = _medianSorted(sorted);
      threshold = _thresholdFor(sorted, baseline);
      _linkMedian[key] = baseline;
      if (snr != null) {
        final sign = _expectedSign(key);
        final d = baseline - snr;
        final r = snr - baseline;
        if (sign > 0) {
          dev = d;
          direction = 'dip';
        } else if (sign < 0) {
          dev = r;
          direction = 'rise';
        } else if (d >= r) {
          dev = d;
          direction = 'dip';
        } else {
          dev = r;
          direction = 'rise';
        }
      }
    } else if (snr != null) {
      baseline = snr; // warming up: not trusted yet
    }

    final meanDisturbed = trusted && snr != null && dev >= threshold;

    // Variance (VRTI) second channel: motion raises RSS variance even
    // when the mean barely moves. It only fires when the mean channel is
    // quiet (|dev| < threshold) — the two channels are complementary:
    // large mean shifts are judged by the signed mean test, subtle
    // motion by variance. It also needs a TRUSTED baseline: during
    // warmup dev is 0.0, which would leave this gate trivially open and
    // let a variance event confirm before the mean baseline is learned.
    var varDisturbed = false;
    double? vNow;
    if (trusted &&
        snr != null &&
        config.varianceChannel &&
        dev.abs() < threshold) {
      final vh = _varHist.putIfAbsent(key, () => ListQueue<double>());
      vh.addLast(snr);
      while (vh.length > _varWindow) {
        vh.removeFirst();
      }
      // The confirmation window never exceeds the stored window: a
      // varWindow below 8 would otherwise silently disable the channel.
      if (vh.length >= math.min(8, _varWindow)) {
        vNow = _variance(vh);
        final base = _varBase[key];
        if (base != null &&
            vNow > math.max(base * config.varK, config.varFloor)) {
          varDisturbed = true;
          // Don't let the outlier pollute the variance window — otherwise
          // one blip keeps the variance high for a whole window and the
          // baseline hold freezes on a transient.
          vh.removeLast();
        }
      }
    }

    final disturbed = meanDisturbed || varDisturbed;
    if (varDisturbed) _varFired[key] = true;

    // History update. Disturbed samples extend neither the baseline nor
    // the quiet variance estimate.
    if (snr != null) {
      if (!trusted || !disturbed) {
        hist.addLast(snr);
        while (hist.length > config.baselineWindow) {
          hist.removeFirst();
        }
        _held[key] = 0;
        if (vNow != null) {
          final base = _varBase[key];
          _varBase[key] = base == null ? vNow : base * 0.9 + vNow * 0.1;
        }
      } else {
        final held = (_held[key] ?? 0) + 1;
        _held[key] = held;
        if (held > config.maxHoldPolls) {
          // The disturbance never ended: treat the new level as normal.
          hist
            ..clear()
            ..addLast(snr);
          _held[key] = 0;
          _resetEpisode(key);
          _rebaselines += 1;
          _rebaselinedAt[key] = raw.timestamp;
          return raw.copyWith(
            dip: 0.0,
            baseline: snr,
            threshold: config.dipThreshold,
          );
        }
      }
    }

    var count = _dipCount[key] ?? 0;
    if (disturbed) {
      if (count == 0) {
        _dipStart[key] = raw.timestamp;
        _dipPeak[key] = dev;
        _varFired[key] = varDisturbed;
      } else {
        _dipPeak[key] = math.max(_dipPeak[key] ?? dev, dev);
        if (varDisturbed) _varFired[key] = true;
      }
      count += 1;
      if (count == config.confirmPolls) {
        final start = _dipStart[key] ?? raw.timestamp;
        final peak = _dipPeak[key] ?? dev;
        _pending.add(CrossingEvent(
          timestamp: raw.timestamp,
          linkKey: key,
          dipDepth: peak,
          durationSecs:
              raw.timestamp.difference(start).inMilliseconds / 1000.0,
          sizeEstimate: _sizeEstimate(peak),
          direction: direction,
          viaVariance: _varFired[key] ?? false,
        ));
      }
      _dipCount[key] = count;
    } else {
      _resetEpisode(key);
    }

    return raw.copyWith(dip: dev, baseline: baseline, threshold: threshold);
  }

  /// Take and clear confirmed events.
  List<CrossingEvent> drainEvents() {
    final out = List<CrossingEvent>.from(_pending);
    _pending.clear();
    return out;
  }

  void _resetEpisode(String key) {
    _dipCount[key] = 0;
    _dipStart.remove(key);
    _dipPeak.remove(key);
    _varFired.remove(key);
  }

  /// Fade-level proxy for a link: its baseline median vs the network
  /// median of link medians. Positive = anti-fade (expect dips),
  /// negative = deep fade (expect rises). Wilson & Patwari 2012 use a
  /// fitted path-loss model as the reference; the network median is the
  /// honest no-model proxy. Needs 2+ links; a lone link is intermediate.
  double _fadeLevel(String key) {
    final med = _linkMedian[key];
    if (med == null || _linkMedian.length < 2) return 0.0;
    final all = _linkMedian.values.toList()..sort();
    return med - _medianSorted(all);
  }

  /// Expected disturbance sign: +1 dip (baseline−snr), −1 rise
  /// (snr−baseline), 0 intermediate (either may signal).
  int _expectedSign(String key) {
    if (!config.signedDetection) return 1;
    final f = _fadeLevel(key);
    if (f > config.fadeGate) return 1;
    if (f < -config.fadeGate) return -1;
    return 0;
  }

  /// Population variance of the values in [xs].
  static double _variance(ListQueue<double> xs) {
    var mean = 0.0;
    for (final x in xs) {
      mean += x;
    }
    mean /= xs.length;
    var v = 0.0;
    for (final x in xs) {
      final d = x - mean;
      v += d * d;
    }
    return v / xs.length;
  }

  /// This link's detection threshold given its sorted baseline window.
  double _thresholdFor(List<double> sorted, double median) {
    final base = config.dipThreshold;
    if (!config.adaptive) return base;
    final devs = [for (final x in sorted) (x - median).abs()]..sort();
    final sigma = 1.4826 * _medianSorted(devs);
    final lo = base * config.adaptiveFloorFrac;
    final hi = base * config.adaptiveCapMult;
    return math.min(math.max(config.madK * sigma, lo), hi);
  }

  /// Crude heuristic size class from peak dip depth. Estimate only.
  static String _sizeEstimate(double dip) =>
      dip < 10 ? 'S' : dip < 20 ? 'M' : 'L';

  /// Median of an already-sorted, non-empty list.
  static double _medianSorted(List<double> xs) {
    final n = xs.length;
    if (n.isOdd) return xs[n ~/ 2];
    return (xs[n ~/ 2 - 1] + xs[n ~/ 2]) / 2;
  }
}
