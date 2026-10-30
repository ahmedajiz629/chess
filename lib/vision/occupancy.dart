import 'frame.dart';
import 'homography.dart';

int sqIndex(int col, int row) => row * 8 + col;

/// Snapshot of what the detector currently sees on the 64 squares.
class OccupancyResult {
  /// occupied[row][col]
  final List<List<bool>> occupied;

  /// Raw "difference from empty" score per square (debug / confidence).
  final List<List<double>> score;

  /// How much the whole board changed since the previous frame. High while a
  /// hand is moving over the board; near-zero when the scene is still.
  final double motion;

  /// Estimated global illumination floor subtracted from every square this
  /// frame (cancels webcam auto-exposure / white-balance drift).
  final double illumFloor;

  OccupancyResult(this.occupied, this.score, this.motion,
      {this.illumFloor = 0});

  bool at(int col, int row) => occupied[row][col];
}

/// Detects, for each of the 64 squares, whether *something* is on it — without
/// ever trying to identify the piece.
///
/// The signal is the difference between the square's current appearance and its
/// learned "empty" appearance. Hysteresis (two thresholds) stops flicker, and
/// slow re-baselining of known-empty squares keeps it robust to lighting drift.
class OccupancyDetector {
  OccupancyDetector({
    this.occupiedThreshold = 16.0,
    this.emptyThreshold = 10.0,
    this.motionThreshold = 9.0,
    this.gridN = 6,
    this.inset = 0.2,
    this.illumCompensation = true,
    this.illumFactor = 0.9,
  });

  /// Enter "occupied" once the (illumination-compensated) diff exceeds this.
  double occupiedThreshold;

  /// Fall back to "empty" once the diff drops below this (must be < occupied).
  double emptyThreshold;

  /// Above this per-frame change, the scene is considered to be moving.
  double motionThreshold;

  int gridN;
  double inset;

  /// Subtract a per-frame illumination floor so global brightness drift (webcam
  /// auto-exposure reacting to pieces) doesn't inflate empty-square scores.
  bool illumCompensation;

  /// Fraction of the estimated floor to subtract (0..1).
  double illumFactor;

  final List<SquarePatch?> _emptyRef = List.filled(64, null);
  List<SquarePatch>? _prevPatches;
  List<SquarePatch>? _lastPatches;
  final List<bool> _state = List.filled(64, false);

  bool get hasReference => _emptyRef.every((p) => p != null);

  /// Capture the appearance of every square with the board **empty**. This is
  /// the one-time step that makes occupancy detection reliable and
  /// piece-colour-agnostic.
  void captureEmptyReference(CapturedFrame frame, Homography h) {
    for (var row = 0; row < 8; row++) {
      for (var col = 0; col < 8; col++) {
        _emptyRef[sqIndex(col, row)] =
            sampleSquarePatch(frame, h, col, row, gridN: gridN, inset: inset);
      }
    }
    for (var i = 0; i < 64; i++) {
      _state[i] = false;
    }
    _prevPatches = null;
    _lastPatches = null;
  }

  OccupancyResult process(CapturedFrame frame, Homography h) {
    final patches = List<SquarePatch>.generate(64, (i) {
      final col = i % 8;
      final row = i ~/ 8;
      return sampleSquarePatch(frame, h, col, row, gridN: gridN, inset: inset);
    });

    // Motion = mean change vs the previous frame across all squares.
    var motion = 0.0;
    final prev = _prevPatches;
    if (prev != null) {
      for (var i = 0; i < 64; i++) {
        motion += patches[i].meanAbsDiff(prev[i]);
      }
      motion /= 64;
    } else {
      motion = double.infinity; // first frame: force "not stable yet".
    }

    // Raw diff-from-empty for every square.
    final raw = List<double>.filled(64, 0.0);
    for (var i = 0; i < 64; i++) {
      final ref = _emptyRef[i];
      raw[i] = ref == null ? 0.0 : patches[i].meanAbsDiff(ref);
    }

    // Estimate the illumination floor from the low end of the distribution:
    // empty squares are always the lowest-signal ones, so the 25th percentile
    // tracks "what an untouched square looks like right now" even as the camera
    // auto-exposes. Subtracting it makes scores robust to global brightness.
    var floor = 0.0;
    if (illumCompensation) {
      final sorted = List<double>.from(raw)..sort();
      floor = sorted[(sorted.length * 0.25).floor()] * illumFactor;
    }

    final occupied = List.generate(8, (_) => List.filled(8, false));
    final score = List.generate(8, (_) => List.filled(8, 0.0));

    for (var row = 0; row < 8; row++) {
      for (var col = 0; col < 8; col++) {
        final i = sqIndex(col, row);
        var d = raw[i] - floor;
        if (d < 0) d = 0;
        score[row][col] = d;

        // Hysteresis around the last committed state.
        var s = _state[i];
        if (!s && d > occupiedThreshold) {
          s = true;
        } else if (s && d < emptyThreshold) {
          s = false;
        }
        _state[i] = s;
        occupied[row][col] = s;
      }
    }

    _prevPatches = patches;
    _lastPatches = patches;
    return OccupancyResult(occupied, score, motion, illumFloor: floor);
  }

  /// Slowly nudge the empty reference toward the current appearance, but only
  /// for squares the game says should be empty *and* which we also see as empty.
  /// Call this on stable frames to absorb lighting changes without ever baking a
  /// piece into the background.
  void rebaselineEmptySquares(List<List<bool>> expectedEmpty, {double alpha = 0.03}) {
    final last = _lastPatches;
    if (last == null) return;
    for (var row = 0; row < 8; row++) {
      for (var col = 0; col < 8; col++) {
        final i = sqIndex(col, row);
        if (expectedEmpty[row][col] && !_state[i]) {
          _emptyRef[i]?.emaTo(last[i], alpha);
        }
      }
    }
  }

  /// Force the committed occupancy state to a known truth (used after a move is
  /// applied, so detection resumes from the correct baseline).
  void setCommittedState(List<List<bool>> occupied) {
    for (var row = 0; row < 8; row++) {
      for (var col = 0; col < 8; col++) {
        _state[sqIndex(col, row)] = occupied[row][col];
      }
    }
  }
}
