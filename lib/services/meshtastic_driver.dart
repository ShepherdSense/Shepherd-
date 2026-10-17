import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/link_sample.dart';
import 'radio_driver.dart';

/// Meshtastic LoRa-mesh driver (RX only — the driver never transmits on
/// the mesh; it only talks to the local node's client API over TCP).
///
/// Connects to a Meshtastic node's client API on TCP port 4403, performs
/// the `want_config` handshake, and maintains the mesh's NodeDB:
/// per-node GPS position, last-heard SNR, and neighbor edges
/// (from the NeighborInfo module when the mesh broadcasts it).
///
/// What Shepherd gets from this:
/// - every mesh node on the map (GPS → node position, auto-placed)
/// - coarse link-health samples: `meshtastic:local → meshtastic:!<id>`
///   (SNR at which OUR node heard that node) and
///   `meshtastic:!<a> → meshtastic:!<b>` (neighbor edges with SNR)
///
/// HONEST SCOPE: Meshtastic telemetry is coarse — positions update on
/// the mesh's own slow cadence (often minutes) and neighbor SNR is a
/// single number per edge, not a fast disturbance signal. This driver
/// gives you node presence, node-loss, and coarse link health. It is
/// NOT tripwire-grade sensing; fine disturbance detection is the job
/// of the SX1276 LoRa backhaul nodes (field_kit/esp32/lora_node),
/// whose events arrive as proper tripwire links.
///
/// Protocol notes (meshtastic/protobufs, verified against mesh.proto):
/// TCP framing is 4 bytes [0x94, 0xC3, lenMSB, lenLSB] + protobuf.
/// Client → radio: ToRadio; radio → client: FromRadio. On connect we
/// send ToRadio{want_config_id} and the radio streams its NodeDB as
/// FromRadio{node_info} packets, then live MeshPackets. Protobuf is
/// decoded by the minimal wire reader below — only the fields we need:
/// FromRadio{packet=2,node_info=4}, NodeInfo{num=1,position=3,snr=4},
/// Position{latitude_i=1,longitude_i=2 (sfixed32, x1e-7 deg)},
/// MeshPacket{from=1,decoded=4,rx_snr=8}, Data{portnum=1,payload=2},
/// NeighborInfo{neighbors=4} / Neighbor{node_id=1,snr=2},
/// NEIGHBORINFO_APP portnum = 71.
class MeshtasticDriver extends RadioDriver {
  MeshtasticDriver({required this.host, required this.port});

  factory MeshtasticDriver.fromAddress(String address) {
    var addr = address.trim();
    if (addr.toLowerCase().startsWith('serial:')) {
      throw ArgumentError(
        'USB serial needs a TCP bridge: run the Meshtastic serial-to-TCP '
        'bridge on the PC (e.g. `meshtastic --tcp-bridge`), then add the '
        'bridge address here. Raw serial ports are not opened directly.',
      );
    }
    var host = '127.0.0.1';
    var port = 4403;
    if (addr.isNotEmpty) {
      // Strip scheme if the user pasted a URL.
      final scheme = addr.indexOf('://');
      if (scheme >= 0) addr = addr.substring(scheme + 3);
      final i = addr.lastIndexOf(':');
      if (i > 0 && !addr.endsWith(']')) {
        host = addr.substring(0, i);
        port = int.tryParse(addr.substring(i + 1)) ?? port;
      } else {
        host = addr;
      }
    }
    return MeshtasticDriver(host: host, port: port);
  }

  final String host;
  final int port;

  /// Node number → mesh state.
  final Map<int, _MeshNode> _nodes = {};

  Socket? _socket;
  final BytesBuilder _inbox = BytesBuilder();
  bool _configRequested = false;

  /// Shepherd node ID for a Meshtastic node number: the `!` + 8-hex
  /// convention from the Meshtastic ecosystem (e.g. `!a1b2c3d4`).
  static String nodeIdOf(int num) =>
      'meshtastic:!${num.toRadixString(16).padLeft(8, '0')}';

  /// GPS positions for map placement, keyed by Shepherd node ID.
  Map<String, ({double lat, double lon})> meshPositions() {
    final out = <String, ({double lat, double lon})>{};
    for (final n in _nodes.values) {
      if (n.lat != null && n.lon != null) {
        out[nodeIdOf(n.num)] = (lat: n.lat!, lon: n.lon!);
      }
    }
    return out;
  }

  @override
  String get driverId => 'meshtastic';

  @override
  String get label => 'MESHTASTIC';

  @override
  bool get isImplemented => true;

  @override
  String get emptyHint =>
      'No Meshtastic nodes seen — is a node reachable at $host:$port?';

  /// Meshtastic telemetry moves on the mesh's own slow cadence
  /// (minutes); don't treat a few-minute-old SNR as dead evidence.
  @override
  Duration? get sampleMaxAge => const Duration(minutes: 15);

  Future<void> _ensureConnected() async {
    if (_socket != null) return;
    final s = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 5),
    );
    s.setOption(SocketOption.tcpNoDelay, true);
    _socket = s;
    _inbox.clear();
    _configRequested = false;
    // The radio may emit debug text before we speak protobuf; the
    // framer skips anything that isn't a frame header.
    s.listen(
      (data) {
        _inbox.add(data);
        _drainFrames();
      },
      onError: (_) => _drop(),
      onDone: () => _drop(),
      cancelOnError: true,
    );
  }

  void _drop() {
    try {
      _socket?.destroy();
    } catch (_) {}
    _socket = null;
    _configRequested = false;
  }

  /// Send ToRadio{want_config_id} with the 4-byte stream framing.
  void _requestConfig() {
    final s = _socket;
    if (s == null || _configRequested) return;
    _configRequested = true;
    // want_config_id = field 3, varint → tag 0x18, value 42.
    const payload = [0x18, 0x2A];
    s.add([0x94, 0xC3, 0x00, payload.length, ...payload]);
  }

  /// Pull complete frames off the inbox and parse them.
  void _drainFrames() {
    final bytes = _inbox.toBytes();
    var i = 0;
    final keep = <int>[];
    while (i + 4 <= bytes.length) {
      if (bytes[i] != 0x94 || bytes[i + 1] != 0xC3) {
        i++; // debug text / resync: skip one byte
        continue;
      }
      final len = (bytes[i + 2] << 8) | bytes[i + 3];
      if (len > 512 || len < 0) {
        i += 2; // corrupt length: resync past the header
        continue;
      }
      if (i + 4 + len > bytes.length) break; // incomplete frame
      _parseFromRadio(bytes.sublist(i + 4, i + 4 + len));
      i += 4 + len;
    }
    keep.addAll(bytes.sublist(i));
    _inbox.clear();
    _inbox.add(keep);
  }

  void _parseFromRadio(Uint8List pb) {
    final r = _PbReader(pb);
    while (!r.done) {
      final tag = r.readTag();
      final field = tag >> 3;
      final wire = tag & 7;
      if (field == 2 && wire == 2) {
        _parseMeshPacket(r.readBytes());
      } else if (field == 4 && wire == 2) {
        _parseNodeInfo(r.readBytes());
      } else {
        r.skip(wire);
      }
    }
  }

  void _parseNodeInfo(Uint8List pb) {
    final r = _PbReader(pb);
    var num = 0;
    double? lat, lon, snr;
    while (!r.done) {
      final tag = r.readTag();
      final field = tag >> 3;
      final wire = tag & 7;
      if (field == 1 && wire == 0) {
        num = r.readVarint();
      } else if (field == 3 && wire == 2) {
        final p = _parsePosition(r.readBytes());
        lat = p.$1;
        lon = p.$2;
      } else if (field == 4 && wire == 5) {
        snr = r.readFloat();
      } else {
        r.skip(wire);
      }
    }
    if (num == 0) return;
    final n = _nodes.putIfAbsent(num, () => _MeshNode(num));
    if (lat != null && lon != null && lat != 0 && lon != 0) {
      n.lat = lat;
      n.lon = lon;
    }
    if (snr != null && snr.isFinite) {
      n.snr = snr;
      n.snrAt = DateTime.now();
    }
    n.lastHeard = DateTime.now();
  }

  /// Returns (lat, lon) in degrees, or (null, null).
  (double?, double?) _parsePosition(Uint8List pb) {
    final r = _PbReader(pb);
    double? lat, lon;
    while (!r.done) {
      final tag = r.readTag();
      final field = tag >> 3;
      final wire = tag & 7;
      if (field == 1 && wire == 5) {
        lat = r.readSfixed32() * 1e-7;
      } else if (field == 2 && wire == 5) {
        lon = r.readSfixed32() * 1e-7;
      } else {
        r.skip(wire);
      }
    }
    return (lat, lon);
  }

  void _parseMeshPacket(Uint8List pb) {
    final r = _PbReader(pb);
    var from = 0;
    double? rxSnr;
    Uint8List? decoded;
    while (!r.done) {
      final tag = r.readTag();
      final field = tag >> 3;
      final wire = tag & 7;
      if (field == 1 && wire == 5) {
        from = r.readFixed32();
      } else if (field == 4 && wire == 2) {
        decoded = r.readBytes();
      } else if (field == 8 && wire == 5) {
        rxSnr = r.readFloat();
      } else {
        r.skip(wire);
      }
    }
    if (decoded != null) _parseData(from, decoded, rxSnr);
  }

  void _parseData(int from, Uint8List pb, double? rxSnr) {
    final r = _PbReader(pb);
    var portnum = 0;
    Uint8List? payload;
    while (!r.done) {
      final tag = r.readTag();
      final field = tag >> 3;
      final wire = tag & 7;
      if (field == 1 && wire == 0) {
        portnum = r.readVarint();
      } else if (field == 2 && wire == 2) {
        payload = r.readBytes();
      } else {
        r.skip(wire);
      }
    }
    if (portnum != 71 || payload == null) return; // NEIGHBORINFO_APP
    final now = DateTime.now();
    final pr = _PbReader(payload);
    while (!pr.done) {
      final tag = pr.readTag();
      if ((tag >> 3) == 4 && (tag & 7) == 2) {
        final nb = _parseNeighbor(pr.readBytes());
        if (nb != null && from != 0) {
          final a = _nodes.putIfAbsent(from, () => _MeshNode(from));
          a.neighbors[nb.$1] = nb.$2;
          a.neighborsAt = now;
          a.lastHeard = now;
        }
      } else {
        pr.skip(tag & 7);
      }
    }
  }

  (int, double)? _parseNeighbor(Uint8List pb) {
    final r = _PbReader(pb);
    var id = 0;
    double? snr;
    while (!r.done) {
      final tag = r.readTag();
      final field = tag >> 3;
      final wire = tag & 7;
      if (field == 1 && wire == 0) {
        id = r.readVarint();
      } else if (field == 2 && wire == 5) {
        snr = r.readFloat();
      } else {
        r.skip(wire);
      }
    }
    if (id == 0 || snr == null || !snr.isFinite) return null;
    return (id, snr);
  }

  /// Test hook: feed raw stream bytes (framed or debug text) through
  /// the same framer/parser the socket listener uses.
  @visibleForTesting
  void ingestBytesForTest(List<int> bytes) {
    _inbox.add(bytes);
    _drainFrames();
  }

  /// Test hook: build link samples from the current node table without
  /// touching the socket.
  @visibleForTesting
  List<LinkSample> buildSamplesForTest() => _buildSamples(DateTime.now());

  @override
  Future<List<LinkSample>> poll() async {
    try {
      await _ensureConnected();
    } catch (_) {
      _drop();
      return [];
    }
    _requestConfig();
    // Give the radio a beat to answer; frames already arrived are
    // parsed by the socket listener. A short settle keeps poll()
    // from returning before the first NodeDB burst lands.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    _drainFrames();
    return _buildSamples(DateTime.now());
  }

  List<LinkSample> _buildSamples(DateTime now) {
    final maxAge = sampleMaxAge!;
    final out = <LinkSample>[];

    // Prune nodes silent too long; they are node-LOSS, not links.
    _nodes.removeWhere((_, n) => now.difference(n.lastHeard) > maxAge * 2);

    for (final n in _nodes.values) {
      final id = nodeIdOf(n.num);
      // Direct edge: SNR at which OUR node heard this node.
      if (n.snr != null &&
          n.snrAt != null &&
          now.difference(n.snrAt!) <= maxAge) {
        out.add(LinkSample(
          timestamp: now,
          fromNode: 'meshtastic:local',
          toNode: id,
          snr: n.snr,
        ));
      }
      // Neighbor edges reported by this node.
      if (n.neighborsAt != null &&
          now.difference(n.neighborsAt!) <= maxAge) {
        for (final e in n.neighbors.entries) {
          out.add(LinkSample(
            timestamp: now,
            fromNode: id,
            toNode: nodeIdOf(e.key),
            snr: e.value,
          ));
        }
      }
    }
    return out;
  }

  @override
  Future<bool> probe() async {
    Socket? s;
    try {
      s = await Socket.connect(host, port,
          timeout: const Duration(seconds: 4));
      // want_config handshake; a real node answers with framed FromRadio.
      s.add(const [0x94, 0xC3, 0x00, 0x02, 0x18, 0x2A]);
      final completer = Completer<bool>();
      var seen = BytesBuilder();
      late StreamSubscription<List<int>> sub;
      sub = s.listen(
        (data) {
          seen.add(data);
          final b = seen.toBytes();
          for (var i = 0; i + 1 < b.length; i++) {
            if (b[i] == 0x94 && b[i + 1] == 0xC3) {
              if (!completer.isCompleted) completer.complete(true);
              sub.cancel();
              return;
            }
          }
          if (seen.length > 4096 && !completer.isCompleted) {
            completer.complete(false);
            sub.cancel();
          }
        },
        onError: (_) {
          if (!completer.isCompleted) completer.complete(false);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(false);
        },
        cancelOnError: true,
      );
      return await completer.future.timeout(
        const Duration(seconds: 4),
        onTimeout: () => false,
      );
    } catch (_) {
      return false;
    } finally {
      try {
        s?.destroy();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _drop();
    _nodes.clear();
  }
}

class _MeshNode {
  _MeshNode(this.num);
  final int num;
  double? lat;
  double? lon;
  double? snr;
  DateTime? snrAt;
  DateTime lastHeard = DateTime.now();
  final Map<int, double> neighbors = {};
  DateTime? neighborsAt;
}

/// Minimal protobuf wire-format reader: varint, 32-bit, and
/// length-delimited fields. Skips anything it doesn't understand,
/// so firmware additions can't break the parse.
class _PbReader {
  _PbReader(this.buf) : _b = ByteData.sublistView(buf);

  final Uint8List buf;
  final ByteData _b;
  int _i = 0;

  bool get done => _i >= buf.length;

  int readTag() => readVarint();

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (_i < buf.length && shift < 64) {
      final byte = buf[_i++];
      result |= (byte & 0x7F) << shift;
      if ((byte & 0x80) == 0) return result;
      shift += 7;
    }
    return result; // truncated varint: best effort
  }

  int readFixed32() {
    if (_i + 4 > buf.length) {
      _i = buf.length;
      return 0;
    }
    final v = _b.getUint32(_i, Endian.little);
    _i += 4;
    return v;
  }

  int readSfixed32() {
    if (_i + 4 > buf.length) {
      _i = buf.length;
      return 0;
    }
    final v = _b.getInt32(_i, Endian.little);
    _i += 4;
    return v;
  }

  double readFloat() {
    if (_i + 4 > buf.length) {
      _i = buf.length;
      return double.nan;
    }
    final v = _b.getFloat32(_i, Endian.little);
    _i += 4;
    return v;
  }

  Uint8List readBytes() {
    final len = readVarint();
    if (len <= 0 || _i + len > buf.length) {
      _i = buf.length;
      return Uint8List(0);
    }
    final out = buf.sublist(_i, _i + len);
    _i += len;
    return out;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        readVarint();
      case 1:
        _i += 8;
      case 2:
        final len = readVarint();
        _i += len < 0 ? 0 : len;
      case 5:
        _i += 4;
      default:
        _i = buf.length; // groups (3/4): deprecated, abort field
    }
    if (_i > buf.length) _i = buf.length;
  }
}
