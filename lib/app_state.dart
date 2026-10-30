import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'debug/telemetry.dart';
import 'game/game_controller.dart';
import 'vision/camera_service.dart';
import 'vision/frame.dart';
import 'vision/homography.dart';
import 'vision/move_detector.dart';
import 'vision/occupancy.dart';

enum AppPhase {
  /// No camera yet — choose index and start.
  idle,

  /// Camera running; click the four board corners.
  calibrate,

  /// Capture the empty-board reference.
  captureEmpty,

  /// Live move tracking.
  tracking,
}

/// Central controller: owns the camera, vision pipeline and game state, runs the
/// per-frame loop, exposes everything the UI renders, and emits telemetry so the
/// pipeline can be observed and tuned against the real board.
class AppState extends ChangeNotifier {
  final CameraService camera = CameraService();
  final GameController game = GameController();
  final OccupancyDetector occupancy = OccupancyDetector();
  final MoveDetector detector = MoveDetector();
  final Telemetry telemetry = Telemetry();

  AppPhase phase = AppPhase.idle;
  String status = 'Choose a camera and press Start.';

  int cameraIndex = 1; // user's current setup; configurable.
  List<CameraDevice> availableDevices = [];

  // --- Calibration ---
  /// Clicked corners in capture-pixel space, order: TL, TR, BR, BL.
  final List<ui.Offset?> corners = [null, null, null, null];
  Homography? _homography;

  // --- Live view / detection ---
  ui.Image? frameImage;
  int frameW = 0;
  int frameH = 0;
  OccupancyResult? lastOcc;
  int frameCount = 0;

  String? pickedSquare;
  Set<int> targetCells = {}; // row*8+col destinations for picked piece

  // --- Pending interactions ---
  String? promoFrom;
  String? promoTo;
  List<ExpectedMove> confirmCandidates = [];
  bool needsResync = false;

  // Manual tap-to-move (teacher override / no-camera fallback).
  String? manualFrom;
  Set<int> manualTargets = {};

  // --- Debug ---
  bool debugMode = false;
  double autoSnapshotSec = 0; // 0 = off
  int _lastSnapshotMs = 0;
  String lastReason = '';

  Timer? _ticker;
  bool _processing = false;

  bool get calibrated => _homography != null;
  bool get hasReference => occupancy.hasReference;
  Homography? get homography => _homography;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> startCamera() async {
    status = 'Starting camera…';
    notifyListeners();
    try {
      await camera.start(cameraIndex);
      availableDevices = camera.devices;
      frameW = camera.frameWidth;
      frameH = camera.frameHeight;
      phase = AppPhase.calibrate;
      status = 'Click the four board corners: top-left, top-right, '
          'bottom-right, bottom-left.';
      telemetry.event('camera_started', {
        'index': cameraIndex,
        'w': frameW,
        'h': frameH,
        'devices': availableDevices.map((d) => d.label).toList(),
      });
      _startTicker();
    } catch (e) {
      status = 'Camera error: $e';
      telemetry.event('camera_error', {'error': '$e'});
    }
    notifyListeners();
  }

  Future<void> setCameraIndex(int index) async {
    cameraIndex = index;
    if (phase != AppPhase.idle) {
      _resetCalibration();
      await startCamera();
    } else {
      notifyListeners();
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 120), (_) => _tick());
  }

  Future<void> _tick() async {
    if (_processing) return;
    _processing = true;
    try {
      final frame = camera.grab();
      if (frame == null) return;
      frameW = frame.width;
      frameH = frame.height;
      frameCount++;

      frameImage = await _decode(frame);

      if (phase == AppPhase.tracking) {
        _runDetection(frame);
      }
      _maybeAutoSnapshot();
      _publishDebugGlobal();
      notifyListeners();
    } finally {
      _processing = false;
    }
  }

  Future<ui.Image> _decode(CapturedFrame f) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      f.rgba,
      f.width,
      f.height,
      ui.PixelFormat.rgba8888,
      c.complete,
    );
    return c.future;
  }

  // ---------------------------------------------------------------------------
  // Calibration
  // ---------------------------------------------------------------------------

  void addCorner(ui.Offset capturePx) {
    final slot = corners.indexWhere((c) => c == null);
    if (slot < 0) return;
    corners[slot] = capturePx;
    if (corners.every((c) => c != null)) {
      _buildHomography();
      phase = AppPhase.captureEmpty;
      status = 'Remove all pieces from the board, then "Capture empty board".';
      telemetry.event('calibrated', {
        'corners': corners.map((c) => [c!.dx, c.dy]).toList(),
      });
    } else {
      status = 'Corner ${slot + 1}/4 set.';
    }
    notifyListeners();
  }

  void clearCorners() {
    for (var i = 0; i < 4; i++) {
      corners[i] = null;
    }
    _homography = null;
    phase = AppPhase.calibrate;
    status = 'Click the four board corners: TL, TR, BR, BL.';
    notifyListeners();
  }

  void _buildHomography() {
    final src = <(double, double)>[(0, 0), (8, 0), (8, 8), (0, 8)];
    final dst = corners.map((c) => (c!.dx, c.dy)).toList(growable: false);
    _homography = Homography.fromCorrespondences(src, dst);
  }

  void _resetCalibration() {
    for (var i = 0; i < 4; i++) {
      corners[i] = null;
    }
    _homography = null;
  }

  // ---------------------------------------------------------------------------
  // Reference capture + game start
  // ---------------------------------------------------------------------------

  void captureEmptyBoard() {
    final frame = camera.grab();
    final h = _homography;
    if (frame == null || h == null) return;
    occupancy.captureEmptyReference(frame, h);
    status = 'Empty board captured. Set up the starting position, '
        'then press "Start game".';
    telemetry.event('empty_reference_captured');
    notifyListeners();
  }

  void startGame() {
    if (!hasReference) {
      status = 'Capture the empty board first.';
      notifyListeners();
      return;
    }
    game.reset();
    occupancy.setCommittedState(game.expectedOccupancy());
    detector.reset();
    _clearInteractions();
    phase = AppPhase.tracking;
    status = 'Tracking. White to move.';
    telemetry.event('game_started', {'fen': game.fen});
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Detection loop
  // ---------------------------------------------------------------------------

  void _runDetection(CapturedFrame frame) {
    final h = _homography;
    if (h == null || !occupancy.hasReference) return;

    final occ = occupancy.process(frame, h);
    lastOcc = occ;

    final waiting =
        promoFrom != null || confirmCandidates.isNotEmpty || needsResync;

    final event = detector.update(occ, game);
    lastReason = detector.diag['reason']?.toString() ?? lastReason;

    if (!waiting) {
      switch (event.kind) {
        case DetectionKind.idle:
          _applyPicked(event);
          occupancy.rebaselineEmptySquares(game.expectedEmpty());
          break;
        case DetectionKind.holding:
          _applyPicked(event);
          break;
        case DetectionKind.moved:
          telemetry.event('move_detected', {
            'san': event.move!.san,
            'from': event.move!.from,
            'to': event.move!.to,
            'flags': event.move!.flags,
          });
          _snapshotNow('move:${event.move!.san}');
          _commitMove(event.move!);
          break;
        case DetectionKind.needsPromotion:
          promoFrom = event.promoFrom;
          promoTo = event.promoTo;
          status = 'Promotion! Choose a piece.';
          telemetry.event('needs_promotion', {'from': promoFrom, 'to': promoTo});
          break;
        case DetectionKind.needsConfirm:
          confirmCandidates = event.candidates;
          status = 'Which move was it?';
          telemetry.event('needs_confirm', {
            'candidates': event.candidates.map((m) => m.san).toList(),
          });
          _snapshotNow('ambiguous');
          break;
        case DetectionKind.noMatch:
          needsResync = true;
          status = "Hmm, I couldn't read that. Fix the board and press Resync.";
          telemetry.event('no_match', {
            'vanished': detector.diag['vanished'],
            'appeared': detector.diag['appeared'],
            'transient': detector.diag['transient'],
          });
          _snapshotNow('no_match');
          break;
      }
    } else {
      _applyPicked(event);
    }

    _logFrame(occ);
  }

  void _applyPicked(DetectionEvent event) {
    pickedSquare = event.pickedSquare;
    if (pickedSquare != null) {
      targetCells = game
          .targetsGridFrom(pickedSquare!)
          .map((c) => c.$2 * 8 + c.$1)
          .toSet();
      status = 'Picked $pickedSquare — showing legal moves.';
    } else {
      targetCells = {};
      if (!needsResync && promoFrom == null && confirmCandidates.isEmpty) {
        status = game.whiteToMove ? 'White to move.' : 'Black to move.';
      }
    }
  }

  void _commitMove(ExpectedMove mv) {
    final ok = game.applyExpected(mv);
    if (!ok) {
      needsResync = true;
      status = 'Illegal move detected — press Resync.';
      return;
    }
    occupancy.setCommittedState(game.expectedOccupancy());
    _clearInteractions();
    status = 'Move: ${mv.san}. '
        '${game.inCheckmate ? 'Checkmate!' : game.inCheck ? 'Check!' : (game.whiteToMove ? 'White' : 'Black')} '
        '${game.isGameOver ? '' : 'to move.'}';
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Telemetry helpers
  // ---------------------------------------------------------------------------

  void _logFrame(OccupancyResult occ) {
    if (!telemetry.enabled) return;
    // Throttle high-volume frame logging to ~4/s.
    if (frameCount % 2 != 0) return;
    telemetry.frame({
      'f': frameCount,
      'phase': phase.name,
      'turn': game.whiteToMove ? 'w' : 'b',
      'fen': game.fen,
      ...detector.diag,
      'illum': double.parse(occ.illumFloor.toStringAsFixed(1)),
      'scores': _flattenScores(occ.score),
      'occ': _flattenBoolStr(occ.occupied),
      'exp': _flattenBoolStr(game.expectedOccupancy()),
      'thr': {
        'occ': occupancy.occupiedThreshold,
        'emp': occupancy.emptyThreshold,
        'mg': detector.motionGate,
        'rsf': detector.requiredStableFrames,
      },
    });
  }

  List<int> _flattenScores(List<List<double>> s) {
    final out = <int>[];
    for (final row in s) {
      for (final v in row) {
        out.add(v.round());
      }
    }
    return out;
  }

  String _flattenBoolStr(List<List<bool>> b) {
    final sb = StringBuffer();
    for (final row in b) {
      for (final v in row) {
        sb.write(v ? '1' : '0');
      }
    }
    return sb.toString();
  }

  /// Mean/min/max occupancy score for squares the game expects empty vs.
  /// occupied — the key numbers for choosing thresholds.
  Map<String, dynamic> separationStats() {
    final occ = lastOcc;
    if (occ == null) return {};
    final exp = game.expectedOccupancy();
    final empty = <double>[];
    final full = <double>[];
    for (var r = 0; r < 8; r++) {
      for (var c = 0; c < 8; c++) {
        (exp[r][c] ? full : empty).add(occ.score[r][c]);
      }
    }
    double mean(List<double> x) =>
        x.isEmpty ? 0 : x.reduce((a, b) => a + b) / x.length;
    double maxOf(List<double> x) =>
        x.isEmpty ? 0 : x.reduce((a, b) => a > b ? a : b);
    double minOf(List<double> x) =>
        x.isEmpty ? 0 : x.reduce((a, b) => a < b ? a : b);
    final emptyMax = maxOf(empty);
    final fullMin = minOf(full);
    return {
      'emptyMean': mean(empty),
      'emptyMax': emptyMax,
      'fullMean': mean(full),
      'fullMin': fullMin,
      // Positive gap = clean separation; suggest the midpoint as threshold.
      'gap': fullMin - emptyMax,
      'suggested': (emptyMax + fullMin) / 2,
    };
  }

  void _maybeAutoSnapshot() {
    if (!debugMode || !telemetry.enabled || autoSnapshotSec <= 0) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastSnapshotMs >= autoSnapshotSec * 1000) {
      _snapshotNow('auto');
    }
  }

  void _snapshotNow(String tag) {
    final url = camera.annotatedDataUrl(
      _homography,
      lastOcc,
      phase == AppPhase.tracking ? game.expectedOccupancy() : null,
    );
    if (url == null) return;
    _lastSnapshotMs = DateTime.now().millisecondsSinceEpoch;
    telemetry.snapshot(url, {
      'tag': tag,
      'w': frameW,
      'h': frameH,
      'phase': phase.name,
      'fen': game.fen,
      'turn': game.whiteToMove ? 'w' : 'b',
      'reason': lastReason,
      'diag': detector.diag,
      'stats': separationStats(),
      'thr': {
        'occ': occupancy.occupiedThreshold,
        'emp': occupancy.emptyThreshold,
        'mg': detector.motionGate,
        'rsf': detector.requiredStableFrames,
      },
    });
  }

  void _publishDebugGlobal() {
    try {
      final payload = jsonEncode({
        'phase': phase.name,
        'frame': frameCount,
        'fen': game.fen,
        'turn': game.whiteToMove ? 'w' : 'b',
        'picked': pickedSquare,
        'reason': lastReason,
        'diag': detector.diag,
        'stats': separationStats(),
        'needsResync': needsResync,
      });
      globalContext.setProperty('__chessDebug'.toJS, payload.toJS);
    } catch (_) {
      // ignore
    }
  }

  // ---------------------------------------------------------------------------
  // User interactions
  // ---------------------------------------------------------------------------

  void choosePromotion(String piece) {
    final from = promoFrom;
    final to = promoTo;
    promoFrom = null;
    promoTo = null;
    if (from == null || to == null) return;
    final ok = game.applyMove(from, to, promotion: piece);
    if (ok) {
      occupancy.setCommittedState(game.expectedOccupancy());
      detector.reset();
      status = 'Promotion to $piece.';
      telemetry.event('promotion_chosen', {'piece': piece, 'to': to});
    } else {
      needsResync = true;
      status = 'Promotion failed — press Resync.';
    }
    _clearInteractions(keepStatus: true);
    notifyListeners();
  }

  void chooseCandidate(ExpectedMove mv) {
    confirmCandidates = [];
    if (mv.isPromotion && mv.promotion == null) {
      promoFrom = mv.from;
      promoTo = mv.to;
      notifyListeners();
      return;
    }
    telemetry.event('candidate_chosen', {'san': mv.san});
    _commitMove(mv);
    detector.reset();
  }

  void resync() {
    occupancy.setCommittedState(game.expectedOccupancy());
    detector.reset();
    _clearInteractions();
    status = 'Resynced. ${game.whiteToMove ? 'White' : 'Black'} to move.';
    telemetry.event('resync', {'fen': game.fen});
    notifyListeners();
  }

  void undo() {
    final m = game.undo();
    if (m == null) return;
    occupancy.setCommittedState(game.expectedOccupancy());
    detector.reset();
    _clearInteractions();
    status = 'Took back a move.';
    telemetry.event('undo', {'fen': game.fen});
    notifyListeners();
  }

  void resetGame() {
    game.reset();
    occupancy.setCommittedState(game.expectedOccupancy());
    detector.reset();
    _clearInteractions();
    status = 'New game. White to move.';
    telemetry.event('reset_game');
    notifyListeners();
  }

  void toggleFlip() {
    game.boardFlipped = !game.boardFlipped;
    occupancy.setCommittedState(game.expectedOccupancy());
    detector.reset();
    status = 'Board orientation flipped.';
    telemetry.event('flip', {'flipped': game.boardFlipped});
    notifyListeners();
  }

  void tapBoardCell(int col, int row) {
    final sq = game.gridToSquare(col, row);
    if (manualFrom == null) {
      final isMover = game.pieceIsWhiteAtGrid(col, row) == game.whiteToMove;
      if (game.pieceIsWhiteAtGrid(col, row) != null && isMover) {
        manualFrom = sq;
        manualTargets = game
            .targetsGridFrom(sq)
            .map((c) => c.$2 * 8 + c.$1)
            .toSet();
      }
    } else {
      final from = manualFrom!;
      if (from == sq) {
        manualFrom = null;
        manualTargets = {};
      } else {
        final candidate =
            game.legalMovesFrom(from).where((m) => m.to == sq).toList();
        if (candidate.isEmpty) {
          final isMover = game.pieceIsWhiteAtGrid(col, row) == game.whiteToMove;
          if (isMover) {
            manualFrom = sq;
            manualTargets = game
                .targetsGridFrom(sq)
                .map((c) => c.$2 * 8 + c.$1)
                .toSet();
          }
        } else if (candidate.first.isPromotion) {
          promoFrom = from;
          promoTo = sq;
          manualFrom = null;
          manualTargets = {};
        } else {
          telemetry.event('manual_move', {'san': candidate.first.san});
          _commitMove(candidate.first);
          detector.reset();
          manualFrom = null;
          manualTargets = {};
        }
      }
    }
    notifyListeners();
  }

  void _clearInteractions({bool keepStatus = false}) {
    pickedSquare = null;
    targetCells = {};
    manualFrom = null;
    manualTargets = {};
    promoFrom = null;
    promoTo = null;
    confirmCandidates = [];
    needsResync = false;
  }

  // ---------------------------------------------------------------------------
  // Debug controls
  // ---------------------------------------------------------------------------

  void setDebugMode(bool on) {
    debugMode = on;
    notifyListeners();
  }

  void setTelemetry(bool on) {
    telemetry.enabled = on;
    if (on) {
      telemetry.start();
      telemetry.event('telemetry_on', {'fen': game.fen, 'phase': phase.name});
    } else {
      telemetry.event('telemetry_off');
      telemetry.stop();
    }
    notifyListeners();
  }

  void setAutoSnapshot(double seconds) {
    autoSnapshotSec = seconds;
    notifyListeners();
  }

  /// Inject a labelled marker into the telemetry stream — e.g. the user clicks
  /// "I'm lifting a piece now" so I can line up data with their actions.
  void mark(String label) {
    telemetry.event('mark', {
      'label': label,
      'fen': game.fen,
      'reason': lastReason,
      'diag': detector.diag,
    });
    _snapshotNow('mark:$label');
    status = 'Marked: $label';
    notifyListeners();
  }

  void snapshotNow() {
    _snapshotNow('manual');
    status = 'Snapshot sent.';
    notifyListeners();
  }

  void setOccupiedThreshold(double v) {
    occupancy.occupiedThreshold = v;
    telemetry.event('tune', {'occupiedThreshold': v});
    notifyListeners();
  }

  void setEmptyThreshold(double v) {
    occupancy.emptyThreshold = v;
    telemetry.event('tune', {'emptyThreshold': v});
    notifyListeners();
  }

  void setMotionGate(double v) {
    detector.motionGate = v;
    telemetry.event('tune', {'motionGate': v});
    notifyListeners();
  }

  void setRequiredStableFrames(int v) {
    detector.requiredStableFrames = v;
    telemetry.event('tune', {'requiredStableFrames': v});
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    telemetry.stop();
    camera.stop();
    super.dispose();
  }
}
