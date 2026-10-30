import 'package:flutter/material.dart';

import '../app_state.dart';

const _whiteGlyphs = {
  'k': '♔',
  'q': '♕',
  'r': '♖',
  'b': '♗',
  'n': '♘',
  'p': '♙',
};
const _blackGlyphs = {
  'k': '♚',
  'q': '♛',
  'r': '♜',
  'b': '♝',
  'n': '♞',
  'p': '♟',
};

/// The authoritative board view — this is what the kids watch. It always shows
/// the game engine's state (never raw vision), with highlights for the piece
/// currently picked up and its legal destinations.
class ChessBoardWidget extends StatelessWidget {
  final AppState state;
  const ChessBoardWidget({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final game = state.game;
    final pickedIdx = <int>{};
    if (state.pickedSquare != null) {
      final (c, r) = game.squareToGrid(state.pickedSquare!);
      pickedIdx.add(r * 8 + c);
    }
    if (state.manualFrom != null) {
      final (c, r) = game.squareToGrid(state.manualFrom!);
      pickedIdx.add(r * 8 + c);
    }
    final targets = {...state.targetCells, ...state.manualTargets};

    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = constraints.biggest.shortestSide;
          final cell = side / 8;
          return SizedBox(
            width: side,
            height: side,
            child: Column(
              children: List.generate(8, (row) {
                return Row(
                  children: List.generate(8, (col) {
                    final idx = row * 8 + col;
                    final isLight = (row + col) % 2 == 0;
                    final type = game.pieceTypeAtGrid(col, row);
                    final isWhite = game.pieceIsWhiteAtGrid(col, row);
                    final glyph = type == null
                        ? ''
                        : (isWhite == true ? _whiteGlyphs : _blackGlyphs)[type]!;
                    final isPicked = pickedIdx.contains(idx);
                    final isTarget = targets.contains(idx);
                    final occupied = type != null;

                    Color bg = isLight
                        ? const Color(0xFFEFF3F7)
                        : const Color(0xFF4A79A8);
                    if (isPicked) bg = const Color(0xFFF6C85F);

                    return GestureDetector(
                      onTap: () => state.tapBoardCell(col, row),
                      child: Container(
                        width: cell,
                        height: cell,
                        decoration: BoxDecoration(
                          color: bg,
                          border: Border.all(
                            color: Colors.black12,
                            width: 0.5,
                          ),
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            if (isTarget)
                              Center(
                                child: Container(
                                  width: occupied ? cell * 0.9 : cell * 0.34,
                                  height: occupied ? cell * 0.9 : cell * 0.34,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: occupied
                                        ? Colors.transparent
                                        : Colors.green.withValues(alpha: 0.55),
                                    border: occupied
                                        ? Border.all(
                                            color: Colors.green
                                                .withValues(alpha: 0.75),
                                            width: 3,
                                          )
                                        : null,
                                  ),
                                ),
                              ),
                            if (glyph.isNotEmpty)
                              Text(
                                glyph,
                                style: TextStyle(
                                  fontSize: cell * 0.72,
                                  height: 1.0,
                                  color: isWhite == true
                                      ? const Color(0xFFFCFCFC)
                                      : const Color(0xFF17202A),
                                  shadows: const [
                                    Shadow(
                                      blurRadius: 1.5,
                                      color: Colors.black38,
                                      offset: Offset(0.5, 0.5),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  }),
                );
              }),
            ),
          );
        },
      ),
    );
  }
}
