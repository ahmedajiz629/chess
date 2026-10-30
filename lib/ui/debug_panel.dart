import 'package:flutter/material.dart';

import '../app_state.dart';

/// Developer/diagnostics panel. Shows live pipeline signals, a per-square score
/// heatmap with vision-vs-game mismatches, tuning sliders, telemetry controls,
/// quick "mark" buttons for lining data up with physical actions, and the event
/// log.
class DebugPanel extends StatelessWidget {
  final AppState state;
  const DebugPanel({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0F1720),
      padding: const EdgeInsets.all(10),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _telemetryControls(),
            const SizedBox(height: 10),
            _markButtons(),
            const SizedBox(height: 12),
            _signals(),
            const SizedBox(height: 12),
            _stats(),
            const SizedBox(height: 12),
            _heatmap(),
            const SizedBox(height: 12),
            _sliders(),
            const SizedBox(height: 12),
            _eventLog(),
          ],
        ),
      ),
    );
  }

  TextStyle get _k =>
      const TextStyle(color: Colors.white70, fontSize: 12);
  TextStyle get _v => const TextStyle(
      color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold);

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(title.toUpperCase(),
            style: const TextStyle(
                color: Colors.cyanAccent,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.1)),
      );

  Widget _telemetryControls() {
    final t = state.telemetry;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section('telemetry → ${t.endpoint}'),
        Row(
          children: [
            Expanded(
              child: SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('Send telemetry', style: _k),
                value: t.enabled,
                onChanged: state.setTelemetry,
              ),
            ),
          ],
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _btn(Icons.camera_alt, 'Snapshot', state.snapshotNow),
            _btn(Icons.delete_sweep, 'Clear log', () => t.resetRemote()),
            for (final s in const [0.0, 1.0, 2.0, 5.0])
              ChoiceChip(
                label: Text(s == 0 ? 'auto off' : 'auto ${s.toInt()}s',
                    style: const TextStyle(fontSize: 11)),
                selected: state.autoSnapshotSec == s,
                onSelected: (_) => state.setAutoSnapshot(s),
              ),
          ],
        ),
      ],
    );
  }

  Widget _markButtons() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section('mark an action (for lining up data)'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final label in const [
              'lifting piece',
              'placed piece',
              'hand removed',
              'capturing',
              'castling',
              'ready',
              'wrong!',
            ])
              ActionChip(
                label: Text(label, style: const TextStyle(fontSize: 11)),
                onPressed: () => state.mark(label),
              ),
          ],
        ),
      ],
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: [
            SizedBox(width: 92, child: Text(k, style: _k)),
            Expanded(child: Text(v, style: _v)),
          ],
        ),
      );

  Widget _signals() {
    final d = state.detector.diag;
    final motion = (d['motion'] as num?)?.toDouble() ?? -1;
    final gate = state.detector.motionGate;
    final still = d['still'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section('live signals'),
        _row('frame', '${state.frameCount}'),
        _row('phase', state.phase.name),
        _row('turn', state.game.whiteToMove ? 'white' : 'black'),
        _row('picked', state.pickedSquare ?? '—'),
        _row('reason', state.lastReason),
        _row('kind', '${d['kind'] ?? '—'}'),
        _row('stillCount',
            '${d['stillCount'] ?? 0} / ${state.detector.requiredStableFrames}  ${d['isStable'] == true ? '✓stable' : ''}'),
        const SizedBox(height: 4),
        Row(
          children: [
            SizedBox(width: 92, child: Text('motion/gate', style: _k)),
            Expanded(
              child: Stack(
                children: [
                  Container(height: 14, color: Colors.white10),
                  FractionallySizedBox(
                    widthFactor:
                        motion < 0 ? 1.0 : (motion / (gate * 3)).clamp(0.0, 1.0),
                    child: Container(
                      height: 14,
                      color: still ? Colors.green : Colors.orangeAccent,
                    ),
                  ),
                  Align(
                    alignment: Alignment(((gate / (gate * 3)) * 2 - 1), 0),
                    child: Container(width: 2, height: 14, color: Colors.white),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Text(motion < 0 ? '∞' : motion.toStringAsFixed(1), style: _v),
          ],
        ),
        if (d['vanished'] != null)
          _row('vanished', '${d['vanished']}'),
        if (d['appeared'] != null) _row('appeared', '${d['appeared']}'),
        if (d['transient'] != null) _row('transient', '${d['transient']}'),
        if (d['matches'] != null) _row('matches', '${d['matches']}'),
      ],
    );
  }

  Widget _stats() {
    final s = state.separationStats();
    if (s.isEmpty) return const SizedBox.shrink();
    String f(dynamic x) => (x as num).toStringAsFixed(1);
    final gap = (s['gap'] as num).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section('threshold separation'),
        _row('empty max', f(s['emptyMax'])),
        _row('full min', f(s['fullMin'])),
        Row(
          children: [
            SizedBox(width: 92, child: Text('gap', style: _k)),
            Expanded(
              child: Text(
                f(s['gap']),
                style: TextStyle(
                  color: gap > 4 ? Colors.greenAccent : Colors.redAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
        _row('suggested', f(s['suggested'])),
        if (gap <= 4)
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text(
              '⚠ low separation — lighting/calibration may be off',
              style: TextStyle(color: Colors.redAccent, fontSize: 11),
            ),
          ),
      ],
    );
  }

  Widget _heatmap() {
    final occ = state.lastOcc;
    if (occ == null) return const SizedBox.shrink();
    final exp = state.phase == AppPhase.tracking
        ? state.game.expectedOccupancy()
        : null;
    final thr = state.occupancy.occupiedThreshold;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section('score heatmap (red=occupied dot · yellow=mismatch)'),
        AspectRatio(
          aspectRatio: 1,
          child: Column(
            children: List.generate(8, (r) {
              return Expanded(
                child: Row(
                  children: List.generate(8, (c) {
                    final score = occ.score[r][c];
                    final occupied = occ.occupied[r][c];
                    final mism = exp != null && exp[r][c] != occupied;
                    final intensity = (score / (thr * 2)).clamp(0.0, 1.0);
                    return Expanded(
                      child: Container(
                        margin: const EdgeInsets.all(0.5),
                        decoration: BoxDecoration(
                          color: Color.lerp(
                              const Color(0xFF16222E),
                              occupied
                                  ? Colors.red
                                  : Colors.lightGreen,
                              occupied ? 0.5 : 0.25 + intensity * 0.4),
                          border: mism
                              ? Border.all(color: Colors.yellow, width: 2)
                              : null,
                        ),
                        alignment: Alignment.center,
                        child: FittedBox(
                          child: Text(
                            score.round().toString(),
                            style: const TextStyle(
                                color: Colors.white, fontSize: 10),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }

  Widget _sliders() {
    final o = state.occupancy;
    final det = state.detector;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section('tuning (live)'),
        _slider('occupied ≥', o.occupiedThreshold, 2, 60,
            (v) => state.setOccupiedThreshold(v)),
        _slider('empty <', o.emptyThreshold, 1, 55,
            (v) => state.setEmptyThreshold(v)),
        _slider('motion gate', det.motionGate, 1, 40,
            (v) => state.setMotionGate(v)),
        _slider('stable frames', det.requiredStableFrames.toDouble(), 1, 12,
            (v) => state.setRequiredStableFrames(v.round()),
            divisions: 11),
      ],
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    int? divisions,
  }) {
    return Row(
      children: [
        SizedBox(width: 92, child: Text(label, style: _k)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: value.toStringAsFixed(divisions == null ? 1 : 0),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 32,
          child: Text(value.toStringAsFixed(divisions == null ? 1 : 0),
              style: _v, textAlign: TextAlign.right),
        ),
      ],
    );
  }

  Widget _eventLog() {
    final events = state.telemetry.recent.reversed.take(40).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section('event log'),
        Container(
          height: 180,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF060B10),
            borderRadius: BorderRadius.circular(6),
          ),
          child: ListView.builder(
            itemCount: events.length,
            itemBuilder: (context, i) {
              final e = events[i];
              final t = e['t'] as int?;
              final time = t == null
                  ? ''
                  : DateTime.fromMillisecondsSinceEpoch(t)
                      .toIso8601String()
                      .substring(11, 19);
              final type = e['type'];
              final rest = Map.of(e)
                ..remove('t')
                ..remove('type')
                ..remove('diag');
              return Text(
                '$time  $type  ${rest.isEmpty ? '' : rest}',
                style: const TextStyle(
                    color: Colors.white70,
                    fontFamily: 'monospace',
                    fontSize: 10.5),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _btn(IconData icon, String label, VoidCallback onTap) {
    return FilledButton.tonalIcon(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        visualDensity: VisualDensity.compact,
      ),
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 11)),
      onPressed: onTap,
    );
  }
}
