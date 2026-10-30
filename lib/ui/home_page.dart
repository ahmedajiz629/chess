import 'package:flutter/material.dart';

import '../app_state.dart';
import '../game/game_controller.dart';
import 'camera_view.dart';
import 'chess_board_widget.dart';
import 'debug_panel.dart';

class HomePage extends StatefulWidget {
  final AppState state;
  const HomePage({super.key, required this.state});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final TextEditingController _indexCtrl =
      TextEditingController(text: widget.state.cameraIndex.toString());

  AppState get s => widget.state;

  @override
  void dispose() {
    _indexCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: const Color(0xFF1C2530),
          appBar: AppBar(
            backgroundColor: const Color(0xFF14202C),
            foregroundColor: Colors.white,
            title: const Text('Chess Tracker — teach kids by playing'),
            actions: [
              if (s.telemetry.enabled)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(Icons.sensors, color: Colors.greenAccent, size: 20),
                ),
              IconButton(
                tooltip: 'Debug tools',
                icon: Icon(Icons.bug_report,
                    color: s.debugMode ? Colors.cyanAccent : Colors.white70),
                onPressed: () => s.setDebugMode(!s.debugMode),
              ),
            ],
          ),
          body: LayoutBuilder(
            builder: (context, c) {
              final wide = c.maxWidth > 900;
              final camera = _cameraPanel();
              final board = _boardPanel();
              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 5, child: camera),
                    Expanded(flex: 4, child: board),
                    if (s.debugMode)
                      SizedBox(width: 340, child: DebugPanel(state: s)),
                  ],
                );
              }
              return SingleChildScrollView(
                child: Column(
                  children: [
                    SizedBox(height: 320, child: camera),
                    board,
                    if (s.debugMode)
                      SizedBox(height: 620, child: DebugPanel(state: s)),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  // --------------------------------------------------------------------------

  Widget _cameraPanel() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          Expanded(child: CameraView(state: s)),
          const SizedBox(height: 8),
          _cameraControls(),
        ],
      ),
    );
  }

  Widget _cameraControls() {
    switch (s.phase) {
      case AppPhase.idle:
        return Row(
          children: [
            SizedBox(
              width: 120,
              child: TextField(
                controller: _indexCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Camera index',
                  labelStyle: TextStyle(color: Colors.white70),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              icon: const Icon(Icons.videocam),
              label: const Text('Start camera'),
              onPressed: () {
                s.cameraIndex = int.tryParse(_indexCtrl.text) ?? 1;
                s.startCamera();
              },
            ),
          ],
        );
      case AppPhase.calibrate:
        return Row(
          children: [
            Expanded(
              child: Text(
                'Tap the 4 corners: ①top-left ②top-right ③bottom-right ④bottom-left',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: s.clearCorners,
              child: const Text('Clear'),
            ),
          ],
        );
      case AppPhase.captureEmpty:
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            FilledButton.tonal(
              onPressed: s.captureEmptyBoard,
              child: const Text('Capture empty board'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start game'),
              onPressed: s.hasReference ? s.startGame : null,
            ),
            TextButton(onPressed: s.clearCorners, child: const Text('Recalibrate')),
          ],
        );
      case AppPhase.tracking:
        return _deviceSwitcher();
    }
  }

  Widget _deviceSwitcher() {
    final devices = s.availableDevices;
    return Row(
      children: [
        const Icon(Icons.videocam, color: Colors.white54, size: 18),
        const SizedBox(width: 8),
        if (devices.isNotEmpty)
          Expanded(
            child: DropdownButton<int>(
              isExpanded: true,
              dropdownColor: const Color(0xFF22303C),
              value: s.cameraIndex < devices.length ? s.cameraIndex : null,
              style: const TextStyle(color: Colors.white),
              items: [
                for (final d in devices)
                  DropdownMenuItem(
                    value: d.index,
                    child: Text('${d.index}: ${d.label}',
                        overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) {
                if (v != null) s.setCameraIndex(v);
              },
            ),
          )
        else
          const Expanded(
            child: Text('Camera running',
                style: TextStyle(color: Colors.white54)),
          ),
        TextButton(onPressed: s.clearCorners, child: const Text('Recalibrate')),
      ],
    );
  }

  // --------------------------------------------------------------------------

  Widget _boardPanel() {
    return Container(
      color: const Color(0xFF1C2530),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _statusBanner(),
          const SizedBox(height: 10),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: ChessBoardWidget(state: s),
            ),
          ),
          const SizedBox(height: 10),
          if (s.promoFrom != null) _promotionChooser(),
          if (s.confirmCandidates.isNotEmpty) _confirmChooser(),
          if (s.needsResync) _resyncBar(),
          const SizedBox(height: 10),
          _actionButtons(),
          const SizedBox(height: 12),
          _moveHistory(),
        ],
      ),
    );
  }

  Widget _statusBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: s.needsResync
            ? const Color(0xFF6B2B2B)
            : const Color(0xFF22303C),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        s.status,
        style: const TextStyle(color: Colors.white, fontSize: 14),
      ),
    );
  }

  Widget _promotionChooser() {
    Widget b(String piece, String glyph) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: FilledButton(
            onPressed: () => s.choosePromotion(piece),
            child: Text(glyph, style: const TextStyle(fontSize: 22)),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('Promote to: ',
              style: TextStyle(color: Colors.white)),
          b('q', '♛'),
          b('r', '♜'),
          b('b', '♝'),
          b('n', '♞'),
        ],
      ),
    );
  }

  Widget _confirmChooser() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        children: [
          for (final ExpectedMove m in s.confirmCandidates)
            FilledButton.tonal(
              onPressed: () => s.chooseCandidate(m),
              child: Text(m.san),
            ),
        ],
      ),
    );
  }

  Widget _resyncBar() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: FilledButton.icon(
        style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
        icon: const Icon(Icons.sync),
        label: const Text('Resync board'),
        onPressed: s.resync,
      ),
    );
  }

  Widget _actionButtons() {
    final enabled = s.phase == AppPhase.tracking;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: [
        OutlinedButton.icon(
          onPressed: enabled ? s.undo : null,
          icon: const Icon(Icons.undo),
          label: const Text('Undo'),
        ),
        OutlinedButton.icon(
          onPressed: enabled ? s.resync : null,
          icon: const Icon(Icons.sync),
          label: const Text('Resync'),
        ),
        OutlinedButton.icon(
          onPressed: enabled ? s.toggleFlip : null,
          icon: const Icon(Icons.flip),
          label: const Text('Flip'),
        ),
        OutlinedButton.icon(
          onPressed: enabled ? s.resetGame : null,
          icon: const Icon(Icons.restart_alt),
          label: const Text('New game'),
        ),
      ].map((w) => _whiteOutlined(w)).toList(),
    );
  }

  Widget _whiteOutlined(Widget w) => Theme(
        data: Theme.of(context).copyWith(
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white24),
            ),
          ),
        ),
        child: w,
      );

  Widget _moveHistory() {
    final history = s.game.historySan();
    if (history.isEmpty) {
      return const SizedBox.shrink();
    }
    final rows = <String>[];
    for (var i = 0; i < history.length; i += 2) {
      final n = (i ~/ 2) + 1;
      final white = history[i];
      final black = i + 1 < history.length ? history[i + 1] : '';
      rows.add('$n. $white  $black');
    }
    return Container(
      constraints: const BoxConstraints(maxHeight: 160),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF14202C),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        child: Text(
          rows.join('\n'),
          style: const TextStyle(
            color: Colors.white70,
            fontFamily: 'monospace',
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}
