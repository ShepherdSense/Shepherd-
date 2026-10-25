/// Hunt session screen (Shepherd v0.26.0, Fieldwatch-borrow item 3).
///
/// Opt-in walk-around proximity mode for one selected emitter: RSSI
/// samples accumulate into a heat grid, motion-sensor steps carry
/// the walk between GPS fixes, and the loudest cell is highlighted.
///
/// HONEST LABELS, stated on the screen itself:
/// - PROXIMITY ONLY — NOT A POSITION FIX. The loudest cell is "the
///   grid cell where the strongest samples were heard", never "the
///   emitter is here". Nothing here outputs a lat/lon, a bearing,
///   or an emitter position.
/// - BEEP = SYSTEM CLICK. There is no audio plugin in this build,
///   so onBeep plays [SystemSoundType.click] plus a visual flash —
///   not a dedicated tone. Documented, not faked.
/// - Step distance is steps × an assumed 0.75 m step length — an
///   ESTIMATE, not a measurement; field accuracy is UNVERIFIED.
/// - An empty grid means "nothing heard", never "nothing present"
///   (phone-OS scan quotas and randomized MACs hide quiet radios).
/// - TILE BACKGROUND: when a cached tile for the current origin is
///   available it paints underneath the grid; otherwise the
///   [TileBackgroundPainter] renders its honestly labeled
///   NO CACHED TILE grid — never an invented map. The hunt grid
///   itself is hunt-local meters, not geography, so the tile is an
///   origin backdrop only, labeled as such.
/// - GPS fixes here are operator-entered hunt-local coordinates
///   (meters east/north of the hunt start point) plus the step
///   source between them; no live GPS feed is wired into this
///   screen in this build. The session's [HuntTracker.onGpsFix]
///   path is the real one — it is the feed that is manual, not the
///   plumbing.
///
/// The session is owned by [AppState] ([AppState.startHuntSession] /
/// [AppState.endHuntSession]) so the step source is closed exactly
/// once; this screen starts it on open and ends it on dispose.
/// Receive-only throughout: nothing here transmits anything.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/hunt_tracker.dart';
import '../services/offline_map_source.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Opt-in Hunt session screen, pushed from the dashboard (phone-tier
/// banner) — deliberately NOT a bottom-nav tab, so the main tab bar
/// and every existing screen stay untouched.
class HuntScreen extends StatefulWidget {
  const HuntScreen({super.key, required this.state});

  final AppState state;

  @override
  State<HuntScreen> createState() => _HuntScreenState();
}

class _HuntScreenState extends State<HuntScreen> {
  HuntTracker? _session;
  Timer? _decayTimer;
  Timer? _flashTimer;
  bool _flash = false;
  String _note = 'NO SAMPLES YET — NOTHING HEARD, NOT NOTHING PRESENT.';
  String _tileStatus = 'NO CACHED TILE';
  ui.Image? _tileImage;
  TileCoord? _originCoord;

  late final TextEditingController _emitter;
  late final TextEditingController _rssi;
  late final TextEditingController _east;
  late final TextEditingController _north;

  @override
  void initState() {
    super.initState();
    _emitter = TextEditingController(text: 'UNNAMED EMITTER');
    _rssi = TextEditingController(text: '-70');
    _east = TextEditingController(text: '0');
    _north = TextEditingController(text: '0');
    _session = widget.state.startHuntSession(
      onBeep: (_) {
        // No audio plugin in this build: system click + flash.
        SystemSound.play(SystemSoundType.click);
        if (!mounted) return;
        setState(() => _flash = true);
        _flashTimer?.cancel();
        _flashTimer = Timer(const Duration(milliseconds: 300), () {
          if (mounted) setState(() => _flash = false);
        });
      },
      onVibrate: (_) => HapticFeedback.vibrate(),
      onFeedback: (f) {
        if (!mounted) return;
        setState(() {
          _note = f.gettingWarmer
              ? 'GETTING WARMER (${f.rssiDbm.toStringAsFixed(0)} dBm, '
                  '+${f.deltaDb.toStringAsFixed(1)} dB)'
              : f.gettingColder
                  ? 'GETTING COLDER (${f.rssiDbm.toStringAsFixed(0)} dBm, '
                      '${f.deltaDb.toStringAsFixed(1)} dB)'
                  : 'SAMPLE ${f.rssiDbm.toStringAsFixed(0)} dBm';
        });
      },
    );
    // Grid decay on a ~5 s timer; without it stale cells linger
    // (fail-safe: they never become a confident wrong answer).
    _decayTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) {
        final session = _session;
        if (session == null || !mounted) return;
        session.grid.decay(now: DateTime.now());
        setState(() {});
      },
    );
    unawaited(_loadOriginTile());
  }

  /// Best-effort origin tile: OPPORTUNISTIC REFRESH on open via
  /// the shared tile cache (v0.26.0 fix-pass), so cached tiles are
  /// not served forever without a refresh attempt — refresh falls
  /// back to the stale cache when offline, and the status line
  /// labels that case. Any failure (no origin, offline with no
  /// cache, undecodable bytes) leaves the null-image placement,
  /// which the painter renders as the NO CACHED TILE grid.
  /// Tile AGE is not shown: the cache manifest tracks last-USED
  /// time for LRU eviction, not download time, so no honest age
  /// can be derived from a fetch result (see TileFetchResult).
  Future<void> _loadOriginTile() async {
    try {
      final origin = widget.state.displayOrigin;
      if (origin == null) return;
      const zoom = 16;
      final coord = latLonToTile(origin.lat, origin.lon, zoom);
      _originCoord = coord;
      final result = await widget.state.tileCache
          .refresh(widget.state.selectedTileSource, coord);
      if (!mounted || result.bytes == null) return;
      final codec = await ui.instantiateImageCodec(result.bytes!);
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _tileImage = frame.image;
        _tileStatus = result.isStale
            ? 'CACHED TILE (STALE — REFRESH FAILED)'
            : 'CACHED TILE (REFRESHED ON OPEN)';
      });
    } catch (_) {
      // Missing tile degrades to the labeled blank grid, never a crash.
    }
  }

  @override
  void dispose() {
    _decayTimer?.cancel();
    _flashTimer?.cancel();
    _tileImage?.dispose();
    _emitter.dispose();
    _rssi.dispose();
    _east.dispose();
    _north.dispose();
    // Ends the session and closes its motion-sensor subscription.
    unawaited(widget.state.endHuntSession());
    super.dispose();
  }

  void _addSample() {
    final session = _session;
    if (session == null) return;
    final rssi = double.tryParse(_rssi.text.trim());
    final east = double.tryParse(_east.text.trim());
    final north = double.tryParse(_north.text.trim());
    if (rssi == null || east == null || north == null) {
      setState(() => _note = 'ENTER NUMBERS FOR RSSI, EAST, AND NORTH.');
      return;
    }
    final accepted = session.addSample(HuntSample(
      xEast: east,
      yNorth: north,
      rssiDbm: rssi,
      at: DateTime.now(),
    ));
    setState(() {
      if (!accepted) {
        _note = 'SAMPLE REJECTED (RSSI OUTSIDE −120..0 dBm OR OUTSIDE '
            'THE GRID) — COUNTED, NEVER SILENTLY DROPPED.';
      }
    });
  }

  // Manual position entry only: this is NOT a GPS fix (see the
  // on-screen disclosure) — it records the operator-typed
  // hunt-local coordinates as the walker's reference point.
  void _setGpsFix() {
    final session = _session;
    if (session == null) return;
    final east = double.tryParse(_east.text.trim());
    final north = double.tryParse(_north.text.trim());
    if (east == null || north == null) {
      setState(() => _note = 'ENTER NUMBERS FOR EAST AND NORTH FIRST.');
      return;
    }
    session.onGpsFix(east, north);
    setState(() => _note = 'MANUAL POSITION SET — STEP COUNT RESET.');
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final grid = session?.grid;
    final loudest = grid?.loudest;
    return Scaffold(
      appBar: AppBar(
        title: const Text('HUNT — PROXIMITY ONLY'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(
                color: _flash ? SentryColors.amber : SentryColors.border,
                width: _flash ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'PROXIMITY ONLY — NOT A POSITION FIX',
                  style: SentryType.section().copyWith(
                    color: SentryColors.amber,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'THE LOUDEST CELL IS WHERE THE STRONGEST SAMPLES '
                  'WERE HEARD — NEVER "THE EMITTER IS HERE". BEEP = '
                  'SYSTEM CLICK + FLASH (NO AUDIO PLUGIN IN THIS '
                  'BUILD, SO THERE IS NO DEDICATED TONE). STEP '
                  'DISTANCE USES AN ASSUMED 0.75 m STEP — AN ESTIMATE, '
                  'NOT A MEASUREMENT.',
                  style: SentryType.section(10).copyWith(height: 1.6),
                ),
                const SizedBox(height: 6),
                Text(
                  'TILE: $_tileStatus · '
                  '${widget.state.selectedTileSource.attribution}',
                  style: SentryType.section(10).copyWith(
                    color: SentryColors.muted,
                  ),
                ),
                const SizedBox(height: 6),
                // v0.26.0 fix-pass: explicit disclosure — samples
                // (RSSI + position) are operator-typed in this
                // build; no live RSSI/GPS feed is wired in.
                Text(
                  'SAMPLES (RSSI + POSITION) ARE OPERATOR-TYPED IN '
                  'THIS BUILD — NO LIVE RSSI/GPS FEED IS WIRED IN. '
                  'STEPS ARE INFORMATIONAL ONLY: WITH NO HEADING '
                  'SOURCE, STEP DISTANCE NEVER PLACES SAMPLES.',
                  style: SentryType.section(10).copyWith(height: 1.6),
                ),
                // v0.26.0 fix-pass: surface the step source's last
                // error (previously written and read by nothing).
                if (widget.state.huntSensorError != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'MOTION SENSOR UNAVAILABLE — '
                    '${widget.state.huntSensorError}',
                    style: SentryType.section(10).copyWith(
                      color: SentryColors.orange,
                      height: 1.6,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 320,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(
                  constraints.maxWidth,
                  320,
                );
                return CustomPaint(
                  size: size,
                  painter: TileBackgroundPainter(
                    placements: [
                      TilePlacement(
                        rect: Offset.zero & size,
                        coord: _originCoord ?? const TileCoord(0, 0, 0),
                        image: _tileImage,
                      ),
                    ],
                  ),
                  foregroundPainter: _HeatPainter(
                    cells: grid?.cellsSorted ?? const [],
                    loudest: loudest,
                    halfExtentMeters: grid?.halfExtentMeters ?? 50.0,
                    cellSizeMeters: grid?.cellSizeMeters ?? 2.0,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _emitter,
            style: SentryType.rowValue(SentryColors.onDark),
            decoration: const InputDecoration(
              labelText: 'SELECTED EMITTER (LABEL ONLY — NOT AN IDENTITY)',
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _rssi,
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  ),
                  style: SentryType.rowValue(SentryColors.onDark),
                  decoration: const InputDecoration(
                    labelText: 'RSSI (dBm)',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _east,
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  ),
                  style: SentryType.rowValue(SentryColors.onDark),
                  decoration: const InputDecoration(
                    labelText: 'EAST (m, hunt-local)',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _north,
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  ),
                  style: SentryType.rowValue(SentryColors.onDark),
                  decoration: const InputDecoration(
                    labelText: 'NORTH (m, hunt-local)',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _addSample,
                  child: const Text('FEED SAMPLE'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _setGpsFix,
                  child: const Text('SET POSITION HERE (MANUAL)'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    grid?.clear();
                    setState(() => _note = 'GRID CLEARED.');
                  },
                  child: const Text('CLEAR GRID'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(_note, style: SentryType.rowValue(SentryColors.onDark)),
          const SizedBox(height: 6),
          Text(
            'SAMPLES ACCEPTED: ${session?.acceptedSamples ?? 0} · '
            'REJECTED: ${grid?.rejectedCount ?? 0} · '
            'CELLS: ${grid?.cellCount ?? 0}',
            style: SentryType.section(10),
          ),
          Text(
            'STEPS SINCE MANUAL POSITION: '
            '${session?.walker.stepsSinceFix ?? 0} · '
            'EST. DISTANCE: '
            '${(session?.walker.distanceSinceFix ?? 0).toStringAsFixed(1)} m '
            '· INFORMATIONAL ONLY — DOES NOT PLACE SAMPLES',
            style: SentryType.section(10),
          ),
          if (loudest != null)
            Text(
              'LOUDEST CELL (PROXIMITY ONLY): '
              '(${loudest.centerX.toStringAsFixed(0)} m E, '
              '${loudest.centerY.toStringAsFixed(0)} m N) · '
              'BEST ${loudest.bestRssi.toStringAsFixed(0)} dBm · '
              '${loudest.sampleCount} SAMPLES',
              style: SentryType.section(10).copyWith(
                color: SentryColors.amber,
              ),
            ),
          const SizedBox(height: 6),
          Text(
            'COORDINATES ARE HUNT-LOCAL METERS FROM THE HUNT START '
            'POINT. THE TILE BACKDROP IS THE ORIGIN TILE ONLY — THE '
            'GRID IS NOT GEOGRAPHY.',
            style: SentryType.section(10).copyWith(
              color: SentryColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}

/// Heat-grid painter: cells as translucent squares, strength from
/// best RSSI (weak purple → strong red), loudest cell ringed in
/// amber. No position, bearing, or lat/lon is drawn — the grid is
/// hunt-local meters around the start point.
class _HeatPainter extends CustomPainter {
  _HeatPainter({
    required this.cells,
    required this.loudest,
    required this.halfExtentMeters,
    this.cellSizeMeters = 2.0,
  });

  final List<HeatCell> cells;
  final HeatCell? loudest;
  final double halfExtentMeters;

  /// Grid cell size in meters, from the grid itself (v0.26.0
  /// fix-pass: previously hardcoded to 2 m regardless of the
  /// grid's actual cellSizeMeters).
  final double cellSizeMeters;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final scale = (size.width < size.height ? size.width : size.height) /
        (2 * halfExtentMeters);
    // Start-point crosshair.
    final axisPaint = Paint()
      ..color = SentryColors.muted
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(0, cy), Offset(size.width, cy), axisPaint);
    canvas.drawLine(Offset(cx, 0), Offset(cx, size.height), axisPaint);
    for (final cell in cells) {
      final strength =
          ((cell.bestRssi + 100.0) / 60.0).clamp(0.0, 1.0);
      final color = Color.lerp(
        SentryColors.purple,
        SentryColors.red,
        strength,
      )!;
      // Cell square sized from the grid's actual cellSizeMeters,
      // centered on the cell center.
      final rect = Rect.fromCenter(
        center: Offset(cx + cell.centerX * scale, cy - cell.centerY * scale),
        width: cellSizeMeters * scale,
        height: cellSizeMeters * scale,
      );
      canvas.drawRect(
        rect,
        Paint()..color = color.withValues(alpha: 0.25 + 0.55 * strength),
      );
      final l = loudest;
      if (identical(cell, l) ||
          (l != null && cell.col == l.col && cell.row == l.row)) {
        canvas.drawRect(
          rect,
          Paint()
            ..color = SentryColors.amber
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HeatPainter oldDelegate) =>
      !identical(cells, oldDelegate.cells) ||
      loudest != oldDelegate.loudest ||
      cellSizeMeters != oldDelegate.cellSizeMeters ||
      halfExtentMeters != oldDelegate.halfExtentMeters;
}
