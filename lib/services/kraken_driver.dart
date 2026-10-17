import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/link_sample.dart';
import 'radio_driver.dart';

/// KrakenSDR direction-finding driver (RX only).
///
/// Reads direction-of-arrival estimates from a KrakenSDR's network output
/// and surfaces them as directional events. Each DF'd emitter becomes a
/// virtual link `kraken:doa → kraken:<freq>MHz` carrying the bearing.
///
/// HONEST SCOPE: the hobbyist KrakenSDR tunes 24–1766 MHz — it sees
/// 433/900 MHz and 1.2/1.3 GHz drone links but is BLIND to 2.4/5.8 GHz.
/// One station gives a bearing, not a position; multipath smears
/// bearings. If the Kraken in hand is CACI's tactical unit (closed
/// system), this driver does not apply.
///
/// The KrakenSDR web UI exposes DOA data; this driver polls the CSV
/// endpoint (default port 8081) and parses bearing/frequency/confidence.
/// Verify the column layout against your krakensdr_suite version — the
/// parser is lenient by design and skips rows it can't read.
class KrakenDriver extends RadioDriver {
  KrakenDriver({required this.host, required this.port});

  factory KrakenDriver.fromAddress(String address) {
    var host = '127.0.0.1';
    var port = 8081;
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
    return KrakenDriver(host: host, port: port);
  }

  final String host;
  final int port;

  final http.Client _client = http.Client();

  @override
  String get driverId => 'kraken';

  @override
  String get label => 'KRAKENSDR';

  @override
  bool get isImplemented => true;

  @override
  String get emptyHint =>
      'No KrakenSDR data — is the KrakenSDR web UI running at $host:$port?';

  /// One poll: fetch DOA rows, one LinkSample per emitter.
  @override
  Future<List<LinkSample>> poll() async {
    final uri = Uri.parse('http://$host:$port/api/doa');
    http.Response resp;
    try {
      resp = await _client.get(uri).timeout(const Duration(seconds: 4));
    } catch (_) {
      return [];
    }
    if (resp.statusCode != 200) return [];
    final now = DateTime.now();
    final out = <LinkSample>[];
    for (final line in const LineSplitter().convert(resp.body)) {
      final row = _parseRow(line);
      if (row == null) continue;
      out.add(LinkSample(
        timestamp: now,
        fromNode: 'kraken:doa',
        toNode: 'kraken:${row.freqMhz.toStringAsFixed(1)}MHz',
        // Confidence 0..1 → pseudo-SNR in the tripwire's expected
        // direction is meaningless here; bearings don't disturb links.
        // Report level so the UI can show it; the tripwire treats these
        // as informational (see app_state: kraken links skip the
        // geometric fuser like sdr bands do).
        snr: row.confidence * 100,
        bearingDeg: row.bearingDeg,
      ));
    }
    return out;
  }

  /// Parse one CSV-ish row. Returns null when the row isn't readable.
  /// Expected columns (any order, header optional):
  /// bearing_deg, freq_mhz, confidence(0..1 or 0..100).
  static _DoaRow? _parseRow(String line) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#')) return null;
    final parts = t.split(RegExp(r'[,\s;]+')).where((p) => p.isNotEmpty).toList();
    if (parts.length < 3) return null;
    // Heuristic column assignment: the value in 0..360 is the bearing,
    // the value in 24..1766 (or 0.024..1.766 GHz) is the frequency,
    // the remaining 0..100 value is confidence.
    double? bearing, freq, conf;
    for (final p in parts) {
      final v = double.tryParse(p);
      if (v == null || !v.isFinite) continue;
      if (bearing == null && v >= 0 && v <= 360) {
        bearing = v;
      } else if (freq == null && ((v >= 24 && v <= 6000) || (v >= 0.024 && v <= 6))) {
        freq = v < 10 ? v * 1000 : v; // GHz → MHz
      } else if (conf == null && v >= 0 && v <= 100) {
        conf = v <= 1 ? v : v / 100;
      }
    }
    if (bearing == null || freq == null) return null;
    return _DoaRow(bearing, freq, (conf ?? 0.5).clamp(0.0, 1.0));
  }

  @override
  Future<bool> probe() async {
    try {
      final resp = await _client
          .get(Uri.parse('http://$host:$port/'))
          .timeout(const Duration(seconds: 3));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    try {
      _client.close();
    } catch (_) {}
  }
}

class _DoaRow {
  _DoaRow(this.bearingDeg, this.freqMhz, this.confidence);
  final double bearingDeg;
  final double freqMhz;
  final double confidence;
}
