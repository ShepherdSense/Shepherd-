import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/link_sample.dart';

/// Records raw link samples to CSV for later replay through the detector.
///
/// This is the tuning accelerator: every threshold tweak gets tested
/// against yesterday's real data instead of vibes. Recordings are plain
/// CSV so the Stone Soup bench and any other tool can read them too.
///
/// Schema: `t_iso,link_key,from_node,to_node,snr_db`
class RecordingService {
  File? _file;
  IOSink? _sink;
  int _rows = 0;
  DateTime? _startedAt;

  bool get isRecording => _sink != null;

  int get rows => _rows;

  /// Start a new recording. Returns the file path.
  Future<String> start() async {
    if (isRecording) return _file!.path;
    final dir = await getApplicationDocumentsDirectory();
    final recDir = Directory('${dir.path}/shepherd_recordings');
    if (!await recDir.exists()) await recDir.create(recursive: true);
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    _file = File('${recDir.path}/recording_$stamp.csv');
    _sink = _file!.openWrite();
    _sink!.writeln('t_iso,link_key,from_node,to_node,snr_db');
    _rows = 0;
    _startedAt = DateTime.now();
    return _file!.path;
  }

  /// Record one raw (pre-tripwire) sample. Cheap: buffered, flushed on stop.
  void record(LinkSample raw) {
    final s = _sink;
    final snr = raw.snr;
    if (s == null || snr == null || !snr.isFinite) return;
    s.writeln('${raw.timestamp.toIso8601String()},'
        '"${raw.linkKey}",'
        '"${raw.fromNode}","${raw.toNode}",'
        '${snr.toStringAsFixed(3)}');
    _rows++;
  }

  /// Stop and flush. Returns a summary string.
  Future<String> stop() async {
    final path = _file?.path ?? '';
    final rows = _rows;
    final secs =
        DateTime.now().difference(_startedAt ?? DateTime.now()).inSeconds;
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
    _file = null;
    return '$rows samples, ${secs}s → $path';
  }

  /// List existing recordings, newest first.
  static Future<List<File>> listRecordings() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final recDir = Directory('${dir.path}/shepherd_recordings');
      if (!await recDir.exists()) return [];
      final files = await recDir
          .list()
          .where((e) => e is File && e.path.endsWith('.csv'))
          .cast<File>()
          .toList();
      files.sort((a, b) => b.path.compareTo(a.path));
      return files;
    } catch (_) {
      return [];
    }
  }
}
