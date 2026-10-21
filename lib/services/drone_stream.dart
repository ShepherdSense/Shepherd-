/// Drone tab stream configuration + health model (Skydio P3).
///
/// The tab is a VIEWER. It selects between streams the aircraft is
/// already emitting — EO (subject) and thermal (infrared) are
/// separate simultaneous RTSP streams on the local link — and shows
/// their health honestly. There is deliberately NO control surface
/// here: no flight, gimbal, or focal commands exist in this file or
/// its screen. The EO stream carries the pilot's selected focal view
/// (wide/tele is chosen in the aircraft, not here).
///
/// Player note: media_kit (libmpv) plays H.264 over RTSP/MPEG-TS,
/// which is what Skydio's documented endpoints emit. MISB 0601 KLV
/// extraction through media_kit is not practical (no demuxed-metadata
/// API surface for RTSP KLV tracks), so the tab overlays position
/// from the Class B telemetry track (CoT) instead — the telemetry
/// Shepherd already has — and says so on screen.
library;

/// Which camera stream the viewer is watching.
enum DroneStreamKind { eo, thermal }

extension DroneStreamKindLabel on DroneStreamKind {
  /// EO carries the pilot's focal choice — always labeled as such.
  String get label =>
      this == DroneStreamKind.eo ? "EO · PILOT'S FOCAL VIEW" : 'THERMAL';
}

/// Stream health, derived from real player signals (see
/// [DroneStreamHealthTracker]) — shown verbatim on the tab. There is
/// no latency figure anywhere: the platform publishes none and the
/// player can't measure glass-to-glass, so none is shown.
enum DroneStreamHealth { noSignal, connecting, live, frozen }

extension DroneStreamHealthLabel on DroneStreamHealth {
  String get label => switch (this) {
        DroneStreamHealth.noSignal => 'NO SIGNAL',
        DroneStreamHealth.connecting => 'CONNECTING',
        DroneStreamHealth.live => 'LIVE',
        DroneStreamHealth.frozen => 'FROZEN',
      };
}

/// Endpoint set for the viewer, from settings. 'local' = vehicle-
/// direct RTSP on the link; 'cloud' = the webhook-announced URLs.
class DroneStreamConfig {
  const DroneStreamConfig({
    required this.eoUrl,
    required this.irUrl,
    required this.sourceLabel,
  });

  final String eoUrl;
  final String irUrl;

  /// 'LOCAL LINK' or 'CLOUD' — shown on the tab so the operator
  /// knows which path the video rides.
  final String sourceLabel;

  String urlFor(DroneStreamKind kind) =>
      kind == DroneStreamKind.eo ? eoUrl : irUrl;

  bool get hasAnyEndpoint => eoUrl.isNotEmpty || irUrl.isNotEmpty;
}

/// Maps periodic player snapshots onto [DroneStreamHealth].
///
/// Pure logic (no player types) so the state machine is unit-tested
/// without a native player:
///  - no open/play attempt yet, or an error → noSignal
///  - an open is in flight and no frame has arrived → connecting,
///    until [connectDeadline] passes with the playhead still at
///    zero → frozen (session up, nothing arriving — a playhead at
///    zero is NEVER live: a wedged encoder that accepts the RTSP
///    session but sends no frames must not read LIVE)
///  - a real playhead position (> 0) has been observed and is
///    advancing → live
///  - the playhead has not advanced for [freezeAfter] while a stream
///    is open → frozen (a stalled feed is never left reading LIVE)
class DroneStreamHealthTracker {
  DroneStreamHealthTracker({
    this.freezeAfter = const Duration(seconds: 3),
    this.connectDeadline = const Duration(seconds: 10),
  });

  final Duration freezeAfter;

  /// How long an open stream may sit at playhead zero (no frame
  /// ever observed) before CONNECTING gives up and reads FROZEN.
  final Duration connectDeadline;

  Duration? _lastPosition;
  DateTime? _lastAdvanceAt;
  DateTime? _openedAt;
  bool _open = false;
  bool _error = false;
  bool _sawPosition = false;

  /// A new stream open was requested (URL/kind changed). The
  /// timestamp starts the connect deadline.
  void beginOpen(DateTime at) {
    _open = true;
    _error = false;
    _openedAt = at;
    _lastPosition = null;
    _lastAdvanceAt = null;
    _sawPosition = false;
  }

  /// The player reported an error (bad URL, unreachable host).
  void markError() {
    _error = true;
  }

  /// Feed one snapshot: whether a stream is open, whether it reports
  /// itself playing, and the current playhead position.
  DroneStreamHealth snapshot({
    required bool isOpen,
    required bool playing,
    required Duration position,
    required DateTime at,
  }) {
    if (_error || !isOpen) return DroneStreamHealth.noSignal;
    if (!_open) return DroneStreamHealth.noSignal;
    if (_lastPosition == null || position != _lastPosition) {
      // First observation, or the playhead moved.
      _lastPosition = position;
      if (position > Duration.zero) {
        _sawPosition = true;
        _lastAdvanceAt = at;
        return DroneStreamHealth.live;
      }
      // Playhead at zero. Before any real frame that is startup,
      // not liveness — regardless of what the player claims about
      // "playing".
      if (!_sawPosition) return _beforeFirstFrame(at);
      // Position reset to zero after having played: the playhead
      // demonstrably moved, so count it as an advance and let the
      // unchanged branch's freeze window judge what follows.
      _lastAdvanceAt = at;
      return playing ? DroneStreamHealth.live : DroneStreamHealth.connecting;
    }
    // Position unchanged since the last snapshot.
    if (!_sawPosition) return _beforeFirstFrame(at);
    final since = _lastAdvanceAt;
    if (since != null && at.difference(since) >= freezeAfter) {
      return DroneStreamHealth.frozen;
    }
    return playing ? DroneStreamHealth.live : DroneStreamHealth.connecting;
  }

  /// Health while an open stream has not delivered a single frame:
  /// CONNECTING until the connect deadline, then FROZEN.
  DroneStreamHealth _beforeFirstFrame(DateTime at) {
    final opened = _openedAt;
    if (opened != null && at.difference(opened) >= connectDeadline) {
      return DroneStreamHealth.frozen;
    }
    return DroneStreamHealth.connecting;
  }

  void reset() {
    _open = false;
    _error = false;
    _openedAt = null;
    _lastPosition = null;
    _lastAdvanceAt = null;
    _sawPosition = false;
  }
}

/// Bounded re-open schedule for a stream stuck in the error state.
///
/// Pure logic (explicit timestamps) so the cadence is unit-tested
/// without a player or a clock: while a stream keeps erroring, a
/// re-open is due at most once per [interval]. This is what recovers
/// the normal field sequence — tab opened before the aircraft starts
/// streaming — without a re-open storm.
class DroneStreamRetryPolicy {
  DroneStreamRetryPolicy({this.interval = const Duration(seconds: 10)});

  final Duration interval;

  DateTime? _nextRetryAt;

  /// Record that the stream is in the error state at [at]. The
  /// first observation arms the schedule one interval out; repeats
  /// while armed don't move it.
  void noteError(DateTime at) {
    _nextRetryAt ??= at.add(interval);
  }

  /// Record that a re-open attempt is being made at [at]; the next
  /// one is due one interval later.
  void noteAttempt(DateTime at) {
    _nextRetryAt = at.add(interval);
  }

  /// The error state ended (or a fresh open was requested): stop
  /// scheduling retries.
  void clear() {
    _nextRetryAt = null;
  }

  /// Whether a re-open attempt is due at [at].
  bool due(DateTime at) {
    final next = _nextRetryAt;
    return next != null && !at.isBefore(next);
  }
}

/// Player abstraction for the Drone tab. The real implementation
/// wraps media_kit; widget tests use a fake. Deliberately minimal —
/// open/stop, a video widget source handle, snapshot getters. There
/// are no transport controls (this is a live viewer, not a DVR).
abstract class DronePlayer {
  /// Open (or switch to) a stream URL. Fire-and-forget; health is
  /// read back through the snapshot getters.
  Future<void> open(String url);

  /// Stop playback and release the stream.
  Future<void> stop();

  bool get isOpen;
  bool get isPlaying;
  bool get hasError;
  Duration get position;

  /// Video dimensions once known (0 = unknown).
  int get videoWidth;
  int get videoHeight;

  void dispose();
}
