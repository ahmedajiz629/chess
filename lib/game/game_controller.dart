import 'package:chess/chess.dart' as ch;

const _files = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];

/// A legal move described in the terms the vision side cares about:
/// which squares should become empty and which should become occupied.
class ExpectedMove {
  final String from;
  final String to;
  final String flags; // chess package flag chars: n c b e p k q
  final String? promotion; // 'q','r','b','n' when flags contains 'p'
  final String san;

  ExpectedMove({
    required this.from,
    required this.to,
    required this.flags,
    required this.san,
    this.promotion,
  });

  bool get isCapture => flags.contains('c') || flags.contains('e');
  bool get isEnPassant => flags.contains('e');
  bool get isKingsideCastle => flags.contains('k');
  bool get isQueensideCastle => flags.contains('q');
  bool get isPromotion => flags.contains('p');
}

/// Authoritative game state. Vision proposes; this engine disposes — a proposed
/// move is only accepted if it is legal. That constraint is the backbone of the
/// "never loses track of the board" guarantee.
class GameController {
  ch.Chess _chess = ch.Chess();

  /// When true the physical board is rotated 180° relative to the default
  /// (white on the near/bottom side). Toggling this re-maps grid<->square.
  bool boardFlipped;

  GameController({this.boardFlipped = false});

  String get fen => _chess.fen;
  bool get whiteToMove => _chess.turn == ch.Color.WHITE;
  bool get isGameOver => _chess.game_over;
  bool get inCheck => _chess.in_check;
  bool get inCheckmate => _chess.in_checkmate;

  void reset() => _chess = ch.Chess();

  void loadFen(String fen) => _chess.load(fen);

  // --- Grid <-> algebraic square mapping (handles board orientation) ---

  /// Maps a UI/vision grid cell (col 0..7 left->right, row 0..7 top->bottom)
  /// to an algebraic square like "e4".
  String gridToSquare(int col, int row) {
    if (!boardFlipped) {
      return '${_files[col]}${8 - row}';
    } else {
      return '${_files[7 - col]}${row + 1}';
    }
  }

  (int, int) squareToGrid(String square) {
    final file = _files.indexOf(square[0]);
    final rank = int.parse(square[1]);
    if (!boardFlipped) {
      return (file, 8 - rank);
    } else {
      return (7 - file, rank - 1);
    }
  }

  /// Is there a piece on this grid cell according to the engine?
  bool occupiedAtGrid(int col, int row) =>
      _chess.get(gridToSquare(col, row)) != null;

  /// 8x8 [row][col] of expected occupancy from the authoritative state.
  List<List<bool>> expectedOccupancy() {
    return List.generate(
      8,
      (row) => List.generate(8, (col) => occupiedAtGrid(col, row)),
    );
  }

  /// Complement of [expectedOccupancy].
  List<List<bool>> expectedEmpty() {
    final occ = expectedOccupancy();
    return List.generate(
      8,
      (row) => List.generate(8, (col) => !occ[row][col]),
    );
  }

  /// Colour of the piece on a grid cell: true=white, false=black, null=empty.
  bool? pieceIsWhiteAtGrid(int col, int row) {
    final p = _chess.get(gridToSquare(col, row));
    if (p == null) return null;
    return p.color == ch.Color.WHITE;
  }

  /// Piece type letter (lowercase: p n b r q k) on a grid cell, or null.
  String? pieceTypeAtGrid(int col, int row) {
    final p = _chess.get(gridToSquare(col, row));
    return p?.type.toLowerCase();
  }

  // --- Legal moves ---

  List<ExpectedMove> legalMoves() {
    final raw = _chess.moves({'verbose': true});
    return raw.map(_toExpected).toList();
  }

  List<ExpectedMove> legalMovesFrom(String square) {
    final raw = _chess.moves({'square': square, 'verbose': true});
    return raw.map(_toExpected).toList();
  }

  ExpectedMove _toExpected(dynamic m) {
    final map = m as Map;
    final promo = map['promotion'];
    return ExpectedMove(
      from: map['from'] as String,
      to: map['to'] as String,
      flags: map['flags'] as String,
      san: map['san'] as String,
      promotion: promo is ch.PieceType ? promo.toLowerCase() : promo as String?,
    );
  }

  /// Destination grid cells for a piece on [square] — used to highlight where a
  /// picked-up piece may go.
  List<(int, int)> targetsGridFrom(String square) {
    return legalMovesFrom(square).map((mv) => squareToGrid(mv.to)).toList();
  }

  /// Apply a move. Returns true if it was legal and applied.
  bool applyMove(String from, String to, {String? promotion}) {
    final req = <String, String>{'from': from, 'to': to};
    if (promotion != null) req['promotion'] = promotion;
    return _chess.move(req);
  }

  bool applyExpected(ExpectedMove mv) =>
      applyMove(mv.from, mv.to, promotion: mv.promotion);

  Map<String, dynamic>? undo() => _chess.undo();

  /// Move history as SAN strings.
  List<String> historySan() {
    final h = _chess.getHistory();
    return h.map((e) => e.toString()).toList();
  }
}
