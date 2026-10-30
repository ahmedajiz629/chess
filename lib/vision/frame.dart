import 'dart:typed_data';

import 'homography.dart';

/// A single captured camera frame in RGBA8888 layout (as produced by the
/// browser canvas `getImageData`).
class CapturedFrame {
  final int width;
  final int height;
  final Uint8List rgba;

  CapturedFrame(this.width, this.height, this.rgba);

  /// Bilinear RGB sample at floating-point pixel (x, y). Returns 0..255 values.
  /// Out-of-bounds samples are clamped to the edge.
  (double, double, double) sampleRgb(double x, double y) {
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    final maxX = width - 1;
    final maxY = height - 1;
    if (x > maxX) x = maxX.toDouble();
    if (y > maxY) y = maxY.toDouble();

    final x0 = x.floor();
    final y0 = y.floor();
    final x1 = x0 < maxX ? x0 + 1 : x0;
    final y1 = y0 < maxY ? y0 + 1 : y0;
    final fx = x - x0;
    final fy = y - y0;

    final w00 = (1 - fx) * (1 - fy);
    final w10 = fx * (1 - fy);
    final w01 = (1 - fx) * fy;
    final w11 = fx * fy;

    final i00 = (y0 * width + x0) * 4;
    final i10 = (y0 * width + x1) * 4;
    final i01 = (y1 * width + x0) * 4;
    final i11 = (y1 * width + x1) * 4;

    final r = rgba[i00] * w00 + rgba[i10] * w10 + rgba[i01] * w01 + rgba[i11] * w11;
    final g = rgba[i00 + 1] * w00 + rgba[i10 + 1] * w10 + rgba[i01 + 1] * w01 + rgba[i11 + 1] * w11;
    final b = rgba[i00 + 2] * w00 + rgba[i10 + 2] * w10 + rgba[i01 + 2] * w01 + rgba[i11 + 2] * w11;
    return (r, g, b);
  }
}

/// A fixed-size RGB signature of the inner area of one board square.
///
/// We deliberately keep a *small grid* of colour samples (not a single mean):
/// the spatial layout lets us tell "bare square" from "square with something on
/// it" far more reliably than an average, while staying piece-colour agnostic —
/// any object, light or dark, disturbs the pattern.
class SquarePatch {
  /// gridN x gridN samples, each with r,g,b -> length = gridN*gridN*3.
  final Float32List data;
  final int gridN;

  SquarePatch(this.data, this.gridN);

  /// Mean absolute per-channel difference against another patch (0..255).
  /// This is our core occupancy signal: how much the square changed vs. its
  /// learned empty appearance.
  double meanAbsDiff(SquarePatch other) {
    final a = data;
    final b = other.data;
    final n = a.length;
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final d = a[i] - b[i];
      sum += d < 0 ? -d : d;
    }
    return sum / n;
  }

  /// Exponential moving average toward [newer], used to slowly track lighting
  /// drift on squares we believe are empty. [alpha] in 0..1 (small = slow).
  void emaTo(SquarePatch newer, double alpha) {
    final a = data;
    final b = newer.data;
    for (var i = 0; i < a.length; i++) {
      a[i] += alpha * (b[i] - a[i]);
    }
  }

  SquarePatch copy() => SquarePatch(Float32List.fromList(data), gridN);
}

/// Samples the inner region of grid square (col, row) from [frame] using the
/// [homography]. [gridN] is the sampling resolution per side; [inset] (0..0.5)
/// controls how much of the square border to skip to avoid shadows / neighbour
/// spill (0.2 keeps the central 60%).
SquarePatch sampleSquarePatch(
  CapturedFrame frame,
  Homography homography,
  int col,
  int row, {
  int gridN = 6,
  double inset = 0.2,
}) {
  final data = Float32List(gridN * gridN * 3);
  final lo = inset;
  final hi = 1.0 - inset;
  final step = (hi - lo) / (gridN - 1);
  var k = 0;
  for (var gy = 0; gy < gridN; gy++) {
    final cy = row + lo + gy * step;
    for (var gx = 0; gx < gridN; gx++) {
      final cx = col + lo + gx * step;
      final (px, py) = homography.apply(cx, cy);
      final (r, g, b) = frame.sampleRgb(px, py);
      data[k++] = r;
      data[k++] = g;
      data[k++] = b;
    }
  }
  return SquarePatch(data, gridN);
}
