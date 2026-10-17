import 'dart:async';
import 'dart:io';

import 'silvus_api.dart';

/// LAN discovery for Silvus radios. Ports silvus_link_doctor.py:
/// fast TCP port-80 pre-check per host, then validate as a Silvus radio with
/// a real `streamscape_data` JSON-RPC call. Hosts are probed in small
/// concurrent chunks so a /24 scan stays quick without flooding the network.
class DiscoveredRadio {
  const DiscoveredRadio({
    required this.ip,
    required this.nodeIds,
    required this.nodeNames,
  });

  final String ip;
  final List<String> nodeIds;
  final List<String> nodeNames;

  String get label =>
      nodeNames.isEmpty ? ip : '$ip (${nodeNames.join(', ')})';
}

class RadioDiscovery {
  /// Scan a CIDR (prefix /20–/30, /24 typical). Progress callback reports
  /// (done, total) for a progress bar.
  static Future<List<DiscoveredRadio>> scanSubnet(
    String cidr, {
    void Function(int done, int total)? onProgress,
  }) async {
    final hosts = _hostsFor(cidr);
    final found = <DiscoveredRadio>[];
    var done = 0;
    const chunk = 32;
    for (var i = 0; i < hosts.length; i += chunk) {
      final end = i + chunk > hosts.length ? hosts.length : i + chunk;
      final slice = hosts.sublist(i, end);
      final results = await Future.wait(slice.map(_probeHost));
      for (final r in results) {
        if (r != null) found.add(r);
      }
      done += slice.length;
      onProgress?.call(done, hosts.length);
    }
    return found;
  }

  static Future<DiscoveredRadio?> _probeHost(String ip) async {
    try {
      final sock = await Socket.connect(
        ip,
        80,
        timeout: const Duration(milliseconds: 700),
      );
      sock.destroy();
    } catch (_) {
      return null;
    }
    final api = SilvusApi(ip: ip, timeout: const Duration(seconds: 4));
    try {
      final snap = await api.fetchSnapshot();
      if (snap == null) return null;
      return DiscoveredRadio(
        ip: ip,
        nodeIds: snap.nodes.map((n) => n.id).toList(),
        nodeNames: snap.nodes.map((n) => n.name).toList(),
      );
    } catch (_) {
      return null;
    } finally {
      api.close();
    }
  }

  /// Expand "a.b.c.d/n" into host addresses (network/broadcast excluded).
  static List<String> _hostsFor(String cidr) {
    final slash = cidr.indexOf('/');
    if (slash < 0) throw const FormatException('CIDR needs a /prefix');
    final base = cidr.substring(0, slash).trim();
    final prefix = int.tryParse(cidr.substring(slash + 1).trim());
    // /20 is the largest scan (4096 addresses); the old text promised
    // /16 but the size check below rejected everything under /20.
    if (prefix == null || prefix < 20 || prefix > 30) {
      throw const FormatException('prefix must be /20../30');
    }
    final parts = base.split('.');
    if (parts.length != 4) throw const FormatException('bad IPv4 address');
    final o = parts.map((e) {
      final v = int.tryParse(e.trim());
      if (v == null || v < 0 || v > 255) {
        throw const FormatException('bad IPv4 octet');
      }
      return v;
    }).toList();
    final baseInt = (o[0] << 24) | (o[1] << 16) | (o[2] << 8) | o[3];
    final count = 1 << (32 - prefix);
    if (count > 4096) throw const FormatException('subnet too large');
    final mask = (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
    final net = baseInt & mask;
    final hosts = <String>[];
    for (var i = 1; i < count - 1; i++) {
      final a = net + i;
      hosts.add(
          '${(a >> 24) & 0xFF}.${(a >> 16) & 0xFF}.${(a >> 8) & 0xFF}.${a & 0xFF}');
    }
    return hosts;
  }
}
