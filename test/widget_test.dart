import 'package:flutter_test/flutter_test.dart';

import 'package:chess_tracker/game/game_controller.dart';

void main() {
  test('starting position occupancy and legal moves', () {
    final game = GameController();

    // Ranks 1,2,7,8 occupied (grid rows 0,1,6,7); ranks 3-6 empty.
    final occ = game.expectedOccupancy();
    for (final row in [0, 1, 6, 7]) {
      expect(occ[row].every((v) => v), isTrue, reason: 'row $row full');
    }
    for (final row in [2, 3, 4, 5]) {
      expect(occ[row].every((v) => !v), isTrue, reason: 'row $row empty');
    }

    // White has 20 legal moves at the start.
    expect(game.legalMoves().length, 20);

    // e2-e4 is legal and updates state.
    expect(game.applyMove('e2', 'e4'), isTrue);
    expect(game.whiteToMove, isFalse);
  });

  test('grid<->square mapping round-trips', () {
    final game = GameController();
    for (var col = 0; col < 8; col++) {
      for (var row = 0; row < 8; row++) {
        final sq = game.gridToSquare(col, row);
        final (c, r) = game.squareToGrid(sq);
        expect(c, col);
        expect(r, row);
      }
    }
  });
}
