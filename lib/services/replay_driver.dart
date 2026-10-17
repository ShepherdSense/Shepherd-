import 'dart:io';

import '../models/link_sample.dart';
import 'radio_driver.dart';

/// Replays a [RecordingService] CSV through the live detector pipeline.
///
/// The replay runs on the recording's own clock (optionally sped up), so
/// durations and confirm-polls behave exactly as they did live. Feed the
/// same recording through after changing thresholds to see what the new
/// settings *would have* caught — honest, data-driven tuning.
class ReplayDriver extends RadioDriver {
  ReplayDriver({required this.path, this.speed = 1.0});

  final String path;
  final double speed;

  final List<_Row> _rows = [];
  int _next = 0;
  DateTime? _recStart;
  DateTime? _playStart;
  bool _loaded = false;
  String _error = '';

  String get error => _error;

  int get totalRows => _rows.length;

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final lines = await File(path).readAsLines();
      for (var i = 1; i < lines.length; i++) {
        final parts = _splitCsv(lines[i]);
        if (parts.length < 5) continue;
        final t = DateTime.tryParse(parts[0]);
        final snr = double.tryParse(parts[4]);
        if (t == null || snr == null || !snr.isFinite) continue;
        _rows.add(_Row(t, parts[2], parts[3], snr));
      }
      _rows.sort((a, b) => a.t.compareTo(b.t));
      if (_rows.isNotEmpty) _recStart = _rows.first.t;
    } catch (e) {
      _error = 'replay load failed: $e';
    }
  }

  /// Elapsed recording time mapped onto the wall clock.
  Duration get _playElapsed {
    final ps = _playStart;
    if (ps == null) return Duration.zero;
    final micros = DateTime.now().difference(ps).inMicroseconds;
    return Duration(microseconds: (micros * speed).round());
  }

  @override
  String get driverId => 'replay';

  @override
  String get label => 'REPLAY';

  @override
  bool get isImplemented => true;

  @override
  Future<List<LinkSample>> poll() async {
    await _load();
    final rs = _recStart;
    if (rs == null) return [];
    _playStart ??= DateTime.now();
    final cutoff = rs.add(_playElapsed);
    final out = <LinkSample>[];
    while (_next < _rows.length && !_rows[_next].t.isAfter(cutoff)) {
      final r = _rows[_next++];
      out.add(LinkSample(
        timestamp: r.t,
        fromNode: r.from,
        toNode: r.to,
        snr: r.snr,
      ));
    }
    return out;
  }

  @override
  Future<bool> probe() async {
    await _load();
    return _rows.isNotEmpty && _error.isEmpty;
  }

  @override
  String get emptyHint =>
      _error.isNotEmpty ? _error : 'Replay finished — no more samples.';

  @override
  void dispose() {}

  /// Minimal CSV split honoring double quotes.
  static List<String> _splitCsv(String line) {
    final out = <String>[];
    final buf = StringBuffer();
    var inQ = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        inQ = !inQ;
      } else if (c == ',' && !inQ) {
        out.add(buf.toString());
        buf.clear();
      } else {
        buf.write(c);
      }
    }
    out.add(buf.toString());
    return out;
  }
}

class _Row {
  _Row(this.t, this.from, this.to, this.snr);
  final DateTime t;
  final String from;
  final String to;
  final double snr;
}

/// Build a replay driver entry for the driver picker.
RadioDriver replayDriverFor(String path, {double speed = 1.0}) =>
    ReplayDriver(path: path, speed: speed);
