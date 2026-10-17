import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/link_sample.dart';

/// HTTP JSON-RPC 2.0 client for the Silvus StreamCaster web API.
///
/// The radio exposes a single endpoint, /cgi-bin/streamscape_api, which takes
/// batched JSON-RPC 2.0 POSTs with no authentication. The telemetry method is
/// "streamscape_data": it returns every node the radio knows about, each with
/// an `adjacencies` array carrying per-link-direction stats. Polling ONE radio
/// yields the whole mesh view (both link directions).
///
/// Per-link keys are shaped like `$snr_<from>_<to>`, `$laMCS_<from>_<to>` and
/// `$pcns_<from>_<to>` (per-chain values). All numeric fields are parsed
/// tolerantly: anything missing or malformed becomes null rather than throwing.
class SilvusApi {
  // 3 s, not 8: a hung radio blinds that poller for the whole timeout,
  // and the health check can only report it once the call returns.
  SilvusApi({required this.ip, this.timeout = const Duration(seconds: 3)});

  final String ip;
  final Duration timeout;

  /// One keep-alive client for the life of the poller. A fresh client per
  /// call opened a new TCP connection four times a second.
  final http.Client _client = http.Client();

  /// Release the connection. Safe to call more than once.
  void close() => _client.close();

  static const _path = '/cgi-bin/streamscape_api';
  static final _keyRe = RegExp(r'^\$(snr|laMCS|pcns|vgm)_(\d+)_(\d+)$');

  Uri get _uri => Uri.parse('http://$ip$_path');

  /// POST a JSON-RPC batch; returns the decoded batch on success, else null.
  Future<List<dynamic>?> _post(List<Map<String, Object>> methods) async {
    final resp = await _client
        .post(
          _uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(methods),
        )
        .timeout(timeout);
    if (resp.statusCode != 200) return null;
    final body = jsonDecode(resp.body);
    if (body is List && body.isNotEmpty) {
      final first = body[0];
      if (first is Map && first['jsonrpc'] == '2.0') return body;
    }
    return null;
  }

  /// True when the host answers like a Silvus radio. Used by discovery.
  Future<bool> probe() async {
    try {
      final r = await _post([
        {'jsonrpc': '2.0', 'method': 'streamscape_data', 'id': 1},
      ]);
      return r != null;
    } catch (_) {
      return false;
    }
  }

  /// Fetch one full mesh snapshot. Returns null when unreachable/invalid.
  /// Link samples are raw (dip 0, baseline NaN) — run them through
  /// [Tripwire] before display.
  Future<MeshSnapshot?> fetchSnapshot() async {
    final batch = await _post([
      {'jsonrpc': '2.0', 'method': 'streamscape_data', 'id': 1},
    ]);
    if (batch == null) return null;
    final first = batch[0];
    final result = first is Map ? first['result'] : null;
    if (result is! List) return null;

    final now = DateTime.now();
    final nodes = <SilvusNodeInfo>[];
    final noiseById = <String, double?>{};
    final pending = <_PendingLink>[];

    for (final n in result) {
      if (n is! Map) continue;
      final nid = '${n['id']}';
      final data = n['data'] is Map
          ? Map<String, dynamic>.from(n['data'] as Map)
          : <String, dynamic>{};
      final noise = _toDouble(data['\$noise_level']);
      noiseById[nid] = noise;
      nodes.add(SilvusNodeInfo(
        id: nid,
        name: '${n['name'] ?? nid}',
        freq: '${data['\$freq'] ?? '?'}',
        bw: '${data['\$bw'] ?? '?'}',
        noiseLevel: noise,
      ));

      final adjs = n['adjacencies'];
      if (adjs is! List) continue;
      for (final a in adjs) {
        if (a is! Map) continue;
        final frm = '${a['nodeFrom']}';
        final to = '${a['nodeTo']}';
        final ad = a['data'] is Map
            ? Map<String, dynamic>.from(a['data'] as Map)
            : <String, dynamic>{};
        double? snr;
        int? mcs;
        var pcns = <double>[];
        ad.forEach((k, v) {
          final m = _keyRe.firstMatch(k);
          if (m == null) return;
          if (m.group(2) != frm || m.group(3) != to) return;
          switch (m.group(1)) {
            case 'snr':
              snr = _toDouble(v);
            case 'laMCS':
              mcs = _toInt(v);
            case 'pcns':
              pcns = '$v'
                  .split('_')
                  .map(_toDouble)
                  .whereType<double>()
                  .toList();
          }
        });
        pending.add(_PendingLink(
          timestamp: now,
          fromNode: frm,
          toNode: to,
          snr: snr,
          mcs: mcs,
          pcns: pcns,
        ));
      }
    }

    // A link direction must appear once per snapshot. If the radio lists
    // the same direction under more than one node, feeding both copies to
    // the tripwire would let ONE reading satisfy "confirm over N polls".
    final seen = <String>{};
    final unique = <_PendingLink>[];
    for (final p in pending) {
      if (seen.add('${p.fromNode}>${p.toNode}')) {
        unique.add(p);
      } else if (p.snr != null) {
        final i = unique.indexWhere(
            (u) => u.fromNode == p.fromNode && u.toNode == p.toNode);
        if (i >= 0 && unique[i].snr == null) unique[i] = p;
      }
    }
    final links = unique
        .map((p) => LinkSample(
              timestamp: p.timestamp,
              fromNode: p.fromNode,
              toNode: p.toNode,
              snr: p.snr,
              mcs: p.mcs,
              pcns: p.pcns,
              noiseFrom: noiseById[p.fromNode],
              noiseTo: noiseById[p.toNode],
            ))
        .toList();
    return MeshSnapshot(fetchedAt: now, nodes: nodes, links: links);
  }

  static double? _toDouble(Object? v) =>
      v == null ? null : double.tryParse('$v');

  static int? _toInt(Object? v) => v == null ? null : int.tryParse('$v');
}

class _PendingLink {
  _PendingLink({
    required this.timestamp,
    required this.fromNode,
    required this.toNode,
    this.snr,
    this.mcs,
    this.pcns = const [],
  });

  final DateTime timestamp;
  final String fromNode;
  final String toNode;
  final double? snr;
  final int? mcs;
  final List<double> pcns;
}

/// Basic identity/config info for one mesh node.
class SilvusNodeInfo {
  const SilvusNodeInfo({
    required this.id,
    required this.name,
    required this.freq,
    required this.bw,
    this.noiseLevel,
  });

  final String id;
  final String name;
  final String freq;
  final String bw;
  final double? noiseLevel;
}

/// One poll's worth of mesh telemetry.
class MeshSnapshot {
  const MeshSnapshot({
    required this.fetchedAt,
    required this.nodes,
    required this.links,
  });

  final DateTime fetchedAt;
  final List<SilvusNodeInfo> nodes;
  final List<LinkSample> links;
}
