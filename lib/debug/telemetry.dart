import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Ships debug data from the running app to the local collector (server.py) so
/// it can be read and analysed off-line, and keeps a small in-memory ring of
/// recent events for the on-screen debug log.
///
/// High-volume "frame" records only go to the network buffer; discrete "events"
/// (moves, no-match, resync, …) are also kept locally for the UI log.
class Telemetry {
  bool enabled = false;
  String endpoint = 'http://localhost:8181';

  final List<Map<String, dynamic>> _netBuffer = [];
  final List<Map<String, dynamic>> _log = [];
  int maxLog = 80;

  Timer? _flushTimer;

  void start() {
    _flushTimer ??=
        Timer.periodic(const Duration(milliseconds: 400), (_) => flush());
  }

  void stop() {
    flush();
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  List<Map<String, dynamic>> get recent => _log;

  int _ts() => DateTime.now().millisecondsSinceEpoch;

  /// A discrete, human-interesting event. Always kept for the UI; sent to the
  /// collector when enabled.
  void event(String type, [Map<String, dynamic>? data]) {
    final rec = <String, dynamic>{'type': type, 't': _ts(), ...?data};
    _log.add(rec);
    if (_log.length > maxLog) _log.removeRange(0, _log.length - maxLog);
    if (enabled) _netBuffer.add(rec);
  }

  /// A per-frame telemetry record (high volume). Network only.
  void frame(Map<String, dynamic> data) {
    if (!enabled) return;
    _netBuffer.add(<String, dynamic>{'type': 'frame', 't': _ts(), ...data});
    if (_netBuffer.length > 400) {
      _netBuffer.removeRange(0, _netBuffer.length - 400);
    }
  }

  void flush() {
    if (!enabled || _netBuffer.isEmpty) return;
    final batch = List<Map<String, dynamic>>.from(_netBuffer);
    _netBuffer.clear();
    // Small bodies -> keepalive is fine and survives page navigation.
    _post('/events', jsonEncode(batch), keepalive: true);
  }

  /// Send an annotated PNG (data URL) plus metadata for visual inspection.
  void snapshot(String pngDataUrl, Map<String, dynamic> meta) {
    if (!enabled) return;
    _post(
      '/snapshot',
      jsonEncode({
        'name': 'snap-${_ts()}.png',
        'png': pngDataUrl,
        'meta': meta,
      }),
    );
    event('snapshot_sent', {'w': meta['w'], 'h': meta['h']});
  }

  void resetRemote() {
    _post('/reset', '');
    _log.clear();
  }

  void _post(String path, String body, {bool keepalive = false}) {
    try {
      // keepalive caps the body at ~64KB, which drops large PNG snapshots —
      // only use it for the small event batches.
      final init = web.RequestInit(
        method: 'POST',
        body: body.toJS,
        keepalive: keepalive,
      );
      final p = web.window.fetch('$endpoint$path'.toJS, init).toDart;
      // Fire and forget; swallow network errors (collector may be off).
      p.then((_) {}, onError: (_) {});
    } catch (_) {
      // ignore
    }
  }
}
