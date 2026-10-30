import 'dart:typed_data';

/// A planar projective transform (3x3 homography) mapping points from a
/// "canonical" board space into camera-image pixel space.
///
/// We use canonical coordinates where the whole board spans [0, 8] x [0, 8]:
/// column/file runs along x (0..8) and row/rank along y (0..8). The centre of
/// grid square (col, row) is therefore (col + 0.5, row + 0.5).
///
/// Because the camera is fixed over the board, we compute this once from the
/// four clicked board corners and reuse it for every frame — this is what makes
/// square sampling cheap and stable.
class Homography {
  /// Row-major 3x3 matrix, 9 entries, with h[8] == 1.
  final Float64List m;

  const Homography._(this.m);

  /// Maps a canonical point (x, y) into image pixel coordinates.
  (double, double) apply(double x, double y) {
    final denom = m[6] * x + m[7] * y + m[8];
    final px = (m[0] * x + m[1] * y + m[2]) / denom;
    final py = (m[3] * x + m[4] * y + m[5]) / denom;
    return (px, py);
  }

  /// Solves the 3x3 homography from four source->destination correspondences.
  ///
  /// [src] are points in canonical space, [dst] the matching image pixels.
  /// Order of the four points must be consistent between the two lists.
  static Homography fromCorrespondences(
    List<(double, double)> src,
    List<(double, double)> dst,
  ) {
    assert(src.length == 4 && dst.length == 4);

    // Build the 8x8 linear system A h = b for the 8 unknown homography
    // parameters (h8 fixed to 1). Each correspondence contributes 2 rows.
    final a = List.generate(8, (_) => Float64List(8));
    final b = Float64List(8);

    for (var i = 0; i < 4; i++) {
      final (x, y) = src[i];
      final (bx, by) = dst[i];

      final r0 = a[2 * i];
      r0[0] = x;
      r0[1] = y;
      r0[2] = 1;
      r0[3] = 0;
      r0[4] = 0;
      r0[5] = 0;
      r0[6] = -bx * x;
      r0[7] = -bx * y;
      b[2 * i] = bx;

      final r1 = a[2 * i + 1];
      r1[0] = 0;
      r1[1] = 0;
      r1[2] = 0;
      r1[3] = x;
      r1[4] = y;
      r1[5] = 1;
      r1[6] = -by * x;
      r1[7] = -by * y;
      b[2 * i + 1] = by;
    }

    final h = _solve8(a, b);
    final m = Float64List(9);
    for (var i = 0; i < 8; i++) {
      m[i] = h[i];
    }
    m[8] = 1.0;
    return Homography._(m);
  }

  /// Gaussian elimination with partial pivoting for an 8x8 system.
  static Float64List _solve8(List<Float64List> a, Float64List b) {
    const n = 8;
    for (var col = 0; col < n; col++) {
      // Partial pivot: find the largest magnitude entry in this column.
      var pivot = col;
      var best = a[col][col].abs();
      for (var r = col + 1; r < n; r++) {
        final v = a[r][col].abs();
        if (v > best) {
          best = v;
          pivot = r;
        }
      }
      if (pivot != col) {
        final tmp = a[col];
        a[col] = a[pivot];
        a[pivot] = tmp;
        final tb = b[col];
        b[col] = b[pivot];
        b[pivot] = tb;
      }

      final diag = a[col][col];
      if (diag.abs() < 1e-12) {
        // Degenerate (collinear) correspondences; return identity-ish.
        return Float64List.fromList([1, 0, 0, 0, 1, 0, 0, 0]);
      }

      for (var r = 0; r < n; r++) {
        if (r == col) continue;
        final factor = a[r][col] / diag;
        if (factor == 0) continue;
        for (var c = col; c < n; c++) {
          a[r][c] -= factor * a[col][c];
        }
        b[r] -= factor * b[col];
      }
    }

    final x = Float64List(n);
    for (var i = 0; i < n; i++) {
      x[i] = b[i] / a[i][i];
    }
    return x;
  }
}
