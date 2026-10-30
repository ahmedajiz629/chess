# Chess Tracker (for teaching kids)

Reads a top-down camera stream of a real chessboard and follows the game live —
no piece recognition, just **which squares are occupied** turned into legal chess
moves. When a piece is lifted, the on-screen board highlights where it may go.
Flutter **web** only for now.

## The technique (why it stays reliable)

**Difference-based occupancy tracking, constrained by chess rules.**

1. **Fixed camera + one-time calibration.** You click the four board corners
   once; a homography warps every frame to a clean 8×8 grid. We only sample the
   centre of each square, so shadows and neighbouring pieces don't leak in.
2. **No piece ID — only occupied vs. empty.** Each square is compared to its
   learned *empty* appearance (captured once with the board clear). Any object,
   light or dark, shows up. Hysteresis + slow re-baselining handle flicker and
   lighting drift.
3. **Only *stable* frames are trusted.** A hand over the board moves the whole
   frame; we detect that and freeze decisions until the scene settles. Captures
   are recovered by remembering every square that *briefly* went empty between
   two stable states.
4. **Chess rules are the safety net.** The engine holds the authoritative state,
   so vision only picks among *legal* moves. Castling / en-passant / promotion
   are resolved by the engine. If nothing legal matches, it asks you to **Resync**
   instead of corrupting the game — it never silently loses the board.

## Run it

```bash
flutter pub get
flutter run -d chrome        # or: flutter build web
```

Grant camera permission when the browser asks.

## Using it

1. Enter the **Camera index** (your setup uses `1`) and press **Start camera**.
   You can switch devices later from the dropdown.
2. **Calibrate:** click the four board corners in order —
   ① top-left ② top-right ③ bottom-right ④ bottom-left. The fiducial markers in
   the corners make good aim points.
3. **Capture empty board:** clear all pieces, press the button. (One-time; this
   is what makes detection robust.)
4. Set up the starting position and press **Start game**.
5. Play. Lift a piece → its legal destinations light up on the board. Complete a
   move → the board updates and the move is logged.

Controls: **Undo**, **Resync** (re-align after fixing the board), **Flip**
(board orientation), **New game**. You can also tap the on-screen board to make
or correct moves manually (teacher override).

## Code map

| File | Role |
|------|------|
| `lib/vision/homography.dart` | 4-point projective transform (board → image) |
| `lib/vision/frame.dart` | RGBA frame + per-square patch sampling |
| `lib/vision/occupancy.dart` | empty-reference templates, occupied/empty + motion |
| `lib/vision/move_detector.dart` | stable-frame state machine → chess moves |
| `lib/vision/camera_service.dart` | `getUserMedia` interop, device-by-index, frames |
| `lib/game/game_controller.dart` | `chess` engine wrapper + grid↔square mapping |
| `lib/app_state.dart` | per-frame loop tying it together |
| `lib/ui/*` | camera view (+calibration overlay), board, controls |

## Tuning

If detection is jumpy or misses pieces, adjust in `lib/vision/occupancy.dart`:
`occupiedThreshold` / `emptyThreshold` (diff-from-empty, 0–255) and in
`lib/vision/move_detector.dart`: `requiredStableFrames` and `_motionGate`.

## Later (mobile)

The vision core is platform-agnostic Dart. Only `camera_service.dart` is
web-specific; swap it for the `camera` plugin on mobile and the rest is reused.
