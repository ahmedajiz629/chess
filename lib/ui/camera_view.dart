import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../vision/homography.dart';
import '../vision/occupancy.dart';

/// Shows the live camera frame. During calibration the user clicks the four
/// board corners here; during tracking it overlays the detected grid and
/// per-square occupancy so you can see exactly what the pipeline sees.
class CameraView extends StatelessWidget {
  final AppState state;
  const CameraView({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final img = state.frameImage;
    if (img == null) {
      return const Center(
        child: Text('No camera feed yet.',
            style: TextStyle(color: Colors.white70)),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final box = constraints.biggest;
        final imgW = img.width.toDouble();
        final imgH = img.height.toDouble();
        // BoxFit.contain: uniform scale that fits the image inside the box.
        final sx = box.width / imgW;
        final sy = box.height / imgH;
        final scale = sx < sy ? sx : sy;
        final dstW = imgW * scale;
        final dstH = imgH * scale;
        final offset = Offset((box.width - dstW) / 2, (box.height - dstH) / 2);

        void handleTap(Offset local) {
          if (state.phase != AppPhase.calibrate) return;
          final capX = (local.dx - offset.dx) / scale;
          final capY = (local.dy - offset.dy) / scale;
          if (capX < 0 || capY < 0 || capX > imgW || capY > imgH) return;
          state.addCorner(Offset(capX, capY));
        }

        return GestureDetector(
          onTapDown: (d) => handleTap(d.localPosition),
          child: CustomPaint(
            size: box,
            painter: _FramePainter(
              image: img,
              scale: scale,
              offset: offset,
              corners: state.corners,
              homography: state.phase == AppPhase.tracking ? state.homography : null,
              occ: state.phase == AppPhase.tracking ? state.lastOcc : null,
            ),
          ),
        );
      },
    );
  }
}

class _FramePainter extends CustomPainter {
  final ui.Image image;
  final double scale;
  final Offset offset;
  final List<Offset?> corners;
  final Homography? homography;
  final OccupancyResult? occ;

  _FramePainter({
    required this.image,
    required this.scale,
    required this.offset,
    required this.corners,
    this.homography,
    this.occ,
  });

  Offset _toScreen(double capX, double capY) =>
      Offset(offset.dx + capX * scale, offset.dy + capY * scale);

  @override
  void paint(Canvas canvas, Size size) {
    final dst = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      image.width * scale,
      image.height * scale,
    );
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      dst,
      Paint(),
    );

    // Calibration corners + outline.
    final set = corners.whereType<Offset>().toList();
    final cornerPaint = Paint()..color = Colors.orangeAccent;
    final linePaint = Paint()
      ..color = Colors.orangeAccent
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    if (set.length >= 2) {
      final path = Path()
        ..moveTo(_toScreen(set[0].dx, set[0].dy).dx,
            _toScreen(set[0].dx, set[0].dy).dy);
      for (var i = 1; i < set.length; i++) {
        final p = _toScreen(set[i].dx, set[i].dy);
        path.lineTo(p.dx, p.dy);
      }
      if (set.length == 4) path.close();
      canvas.drawPath(path, linePaint);
    }
    for (var i = 0; i < corners.length; i++) {
      final c = corners[i];
      if (c == null) continue;
      final p = _toScreen(c.dx, c.dy);
      canvas.drawCircle(p, 7, cornerPaint);
      _label(canvas, p, '${i + 1}');
    }

    // Tracking overlay: projected grid + occupancy dots.
    final h = homography;
    if (h != null) {
      final gridPaint = Paint()
        ..color = Colors.cyanAccent.withValues(alpha: 0.5)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke;
      for (var k = 0; k <= 8; k++) {
        // vertical lines
        final a = h.apply(k.toDouble(), 0);
        final b = h.apply(k.toDouble(), 8);
        canvas.drawLine(_toScreen(a.$1, a.$2), _toScreen(b.$1, b.$2), gridPaint);
        // horizontal lines
        final c = h.apply(0, k.toDouble());
        final d = h.apply(8, k.toDouble());
        canvas.drawLine(_toScreen(c.$1, c.$2), _toScreen(d.$1, d.$2), gridPaint);
      }
      final o = occ;
      if (o != null) {
        for (var row = 0; row < 8; row++) {
          for (var col = 0; col < 8; col++) {
            final center = h.apply(col + 0.5, row + 0.5);
            final p = _toScreen(center.$1, center.$2);
            final occupied = o.occupied[row][col];
            canvas.drawCircle(
              p,
              5,
              Paint()
                ..color = occupied
                    ? Colors.redAccent.withValues(alpha: 0.85)
                    : Colors.greenAccent.withValues(alpha: 0.5),
            );
          }
        }
      }
    }
  }

  void _label(Canvas canvas, Offset p, String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, p + const Offset(8, -6));
  }

  @override
  bool shouldRepaint(covariant _FramePainter old) => true;
}
