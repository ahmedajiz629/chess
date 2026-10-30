import '../game/game_controller.dart';
import 'occupancy.dart';

enum DetectionKind {
  /// Board matches the game state and nothing is being held.
  idle,

  /// Exactly one piece is currently lifted — show its legal destinations.
  holding,

  /// A complete, unambiguous legal move was recognised.
  moved,

  /// A move was recognised but needs a promotion piece chosen.
  needsPromotion,

  /// Several legal moves fit what was seen — ask the user to pick.
  needsConfirm,

  /// Something changed on the board that matches no legal move. The game state
  /// is left untouched; the UI should ask for a resync/correction.
  noMatch,
}

class DetectionEvent {
  final DetectionKind kind;

  /// Square of the currently lifted piece (idle/holding), for live highlight.
  final String? pickedSquare;

  /// The resolved move (kind == moved).
  final ExpectedMove? move;

  /// Promotion target (kind == needsPromotion).
  final String? promoFrom;
  final String? promoTo;

  /// Candidate moves (kind == needsConfirm).
  final List<ExpectedMove> candidates;

  const DetectionEvent(
    this.kind, {
    this.pickedSquare,
    this.move,
    this.promoFrom,
    this.promoTo,
    this.candidates = const [],
  });
}

/// Turns a stream of occupancy snapshots into chess moves, using the rules
/// engine to stay correct.
///
/// Key idea: only *stable* frames (no hand motion) are trusted. Between two
/// stable states we remember every square that briefly went empty — that lets
/// us recover the destination of a capture, where the final occupancy of the
/// target square is unchanged.
class MoveDetector {
  MoveDetector({
    this.requiredStableFrames = 4,
    this.motionGate = 9.0,
  });

  /// Consecutive low-motion frames needed before a position is "settled".
  int requiredStableFrames;

  /// Below this per-frame change (0..255 mean-abs-diff) the scene is "still".
  double motionGate;

  int _stillCount = 0;
  bool _resolvedSinceMotion = true;
  final Set<String> _transientEmpty = {};

  /// Live diagnostics from the most recent [update], for telemetry / debug UI.
  final Map<String, dynamic> diag = {};

  void reset() {
    _stillCount = 0;
    _resolvedSinceMotion = true;
    _transientEmpty.clear();
  }

  DetectionEvent update(OccupancyResult occ, GameController game) {
    final expected = game.expectedOccupancy();

    // --- Live "which piece is lifted" detection (every frame) ---
    final picked = _detectPicked(occ, expected, game);

    // --- Stability tracking ---
    final motion = occ.motion;
    final still = motion.isFinite && motion < motionGate;
    if (still) {
      _stillCount++;
    } else {
      _stillCount = 0;
    }
    final isStable = _stillCount >= requiredStableFrames;

    diag
      ..clear()
      ..addAll({
        'motion': motion.isFinite ? double.parse(motion.toStringAsFixed(2)) : -1,
        'still': still,
        'stillCount': _stillCount,
        'isStable': isStable,
        'resolved': _resolvedSinceMotion,
        'picked': picked,
        'transient': _transientEmpty.toList(),
      });

    if (!isStable) {
      // Accumulate squares that blinked empty while we expect them occupied.
      for (var row = 0; row < 8; row++) {
        for (var col = 0; col < 8; col++) {
          if (expected[row][col] && !occ.occupied[row][col]) {
            _transientEmpty.add(game.gridToSquare(col, row));
          }
        }
      }
      _resolvedSinceMotion = false;
      final kind = picked == null ? DetectionKind.idle : DetectionKind.holding;
      diag['kind'] = kind.name;
      return DetectionEvent(kind, pickedSquare: picked);
    }

    // Stable. If we already resolved this quiet period, just report idle.
    if (_resolvedSinceMotion) {
      final kind = picked == null ? DetectionKind.idle : DetectionKind.holding;
      diag['kind'] = kind.name;
      return DetectionEvent(kind, pickedSquare: picked);
    }

    // Freshly settled -> try to resolve what happened.
    final event = _resolve(occ, expected, game, picked);
    diag['kind'] = event.kind.name;
    if (event.kind != DetectionKind.holding) {
      // A terminal outcome: close the window.
      _resolvedSinceMotion = true;
      _transientEmpty.clear();
    }
    return event;
  }

  String? _detectPicked(
    OccupancyResult occ,
    List<List<bool>> expected,
    GameController game,
  ) {
    String? found;
    for (var row = 0; row < 8; row++) {
      for (var col = 0; col < 8; col++) {
        if (expected[row][col] && !occ.occupied[row][col]) {
          final sq = game.gridToSquare(col, row);
          final isMover = game.pieceIsWhiteAtGrid(col, row) == game.whiteToMove;
          if (isMover) {
            if (found != null) return null; // more than one -> ambiguous
            found = sq;
          }
        }
      }
    }
    return found;
  }

  DetectionEvent _resolve(
    OccupancyResult occ,
    List<List<bool>> expected,
    GameController game,
    String? picked,
  ) {
    final vanished = <String>{};
    final appeared = <String>{};
    for (var row = 0; row < 8; row++) {
      for (var col = 0; col < 8; col++) {
        final sq = game.gridToSquare(col, row);
        final exp = expected[row][col];
        final obs = occ.occupied[row][col];
        if (exp && !obs) vanished.add(sq);
        if (!exp && obs) appeared.add(sq);
      }
    }
    diag['vanished'] = vanished.toList();
    diag['appeared'] = appeared.toList();

    if (vanished.isEmpty && appeared.isEmpty) {
      diag['reason'] = 'no_change';
      final kind = picked == null ? DetectionKind.idle : DetectionKind.holding;
      return DetectionEvent(kind, pickedSquare: picked);
    }

    final legal = game.legalMoves();
    final matches = <ExpectedMove>[];
    for (final mv in legal) {
      if (_moveFits(mv, vanished, appeared, game)) {
        matches.add(mv);
      }
    }
    diag['matchCount'] = matches.length;
    diag['matches'] = matches.map((m) => m.san).toList();

    if (matches.isEmpty) {
      if (appeared.isEmpty && vanished.length == 1) {
        final only = vanished.first;
        if (game.legalMovesFrom(only).isNotEmpty) {
          diag['reason'] = 'holding';
          return DetectionEvent(DetectionKind.holding, pickedSquare: only);
        }
      }
      diag['reason'] = 'no_legal_match';
      return const DetectionEvent(DetectionKind.noMatch);
    }

    final froms = matches.map((m) => m.from).toSet();
    final tos = matches.map((m) => m.to).toSet();
    if (matches.every((m) => m.isPromotion) &&
        froms.length == 1 &&
        tos.length == 1) {
      diag['reason'] = 'promotion';
      return DetectionEvent(
        DetectionKind.needsPromotion,
        promoFrom: froms.first,
        promoTo: tos.first,
      );
    }

    if (matches.length == 1) {
      diag['reason'] = 'unique_move';
      return DetectionEvent(DetectionKind.moved, move: matches.first);
    }

    diag['reason'] = 'ambiguous';
    return DetectionEvent(DetectionKind.needsConfirm, candidates: matches);
  }

  bool _moveFits(
    ExpectedMove mv,
    Set<String> vanished,
    Set<String> appeared,
    GameController game,
  ) {
    final predV = <String>{};
    final predA = <String>{};

    if (mv.isKingsideCastle || mv.isQueensideCastle) {
      final rank = mv.from[1];
      predV.add(mv.from);
      predA.add(mv.to);
      if (mv.isKingsideCastle) {
        predV.add('h$rank');
        predA.add('f$rank');
      } else {
        predV.add('a$rank');
        predA.add('d$rank');
      }
      return setEquals(vanished, predV) && setEquals(appeared, predA);
    }

    if (mv.isEnPassant) {
      final capturedPawn = '${mv.to[0]}${mv.from[1]}';
      predV.add(mv.from);
      predV.add(capturedPawn);
      predA.add(mv.to);
      return setEquals(vanished, predV) && setEquals(appeared, predA);
    }

    if (mv.isCapture) {
      predV.add(mv.from);
      return setEquals(vanished, predV) &&
          appeared.isEmpty &&
          _transientEmpty.contains(mv.to);
    }

    predV.add(mv.from);
    predA.add(mv.to);
    return setEquals(vanished, predV) && setEquals(appeared, predA);
  }
}

bool setEquals(Set<String> a, Set<String> b) {
  if (a.length != b.length) return false;
  for (final e in a) {
    if (!b.contains(e)) return false;
  }
  return true;
}
