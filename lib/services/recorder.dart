import 'dart:async';
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

  /// Human-readable description of the most recent start/stop failure,
  /// or null when the last operation succeeded. start()/stop() never
  /// throw — a full disk surfaces here instead of crashing the UI.
  String? _lastError;

  String? get lastError => _lastError;

  bool get isRecording => _sink != null;

  int get rows => _rows;

  /// Start a new recording. Returns the file path, or '' on failure
  /// (check [lastError] for the reason). Never throws.
  Future<String> start() async {
    if (isRecording) return _file!.path;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final recDir = Directory('${dir.path}/shepherd_recordings');
      if (!await recDir.exists()) await recDir.create(recursive: true);
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      _file = File('${recDir.path}/recording_$stamp.csv');
      _sink = _file!.openWrite();
      _sink!.writeln('t_iso,link_key,from_node,to_node,snr_db');
      _rows = 0;
      _startedAt = DateTime.now();
      _lastError = null;
      return _file!.path;
    } catch (e) {
      _sink = null;
      _file = null;
      _lastError = 'recording start failed: $e';
      return '';
    }
  }

  /// Record one raw (pre-tripwire) sample. Buffered, with a periodic
  /// flush every 50 rows so an OS kill mid-recording loses at most a
  /// small tail instead of the whole buffer.
  void record(LinkSample raw) {
    final s = _sink;
    final snr = raw.snr;
    if (s == null || snr == null || !snr.isFinite) return;
    try {
      s.writeln('${raw.timestamp.toIso8601String()},'
          '"${raw.linkKey}",'
          '"${raw.fromNode}","${raw.toNode}",'
          '${snr.toStringAsFixed(3)}');
      _rows++;
      if (_rows % 50 == 0) unawaited(s.flush());
    } catch (e) {
      _lastError = 'recording write failed: $e';
    }
  }

  /// Stop and flush. Returns a summary string, or an error description
  /// on failure (also in [lastError]). Never throws.
  Future<String> stop() async {
    final path = _file?.path ?? '';
    final rows = _rows;
    final secs =
        DateTime.now().difference(_startedAt ?? DateTime.now()).inSeconds;
    try {
      await _sink?.flush();
      await _sink?.close();
      _lastError = null;
    } catch (e) {
      _lastError = 'recording stop failed: $e';
      return 'STOP FAILED: $_lastError';
    } finally {
      _sink = null;
      _file = null;
    }
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
