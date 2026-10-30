import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'frame.dart';
import 'homography.dart';
import 'occupancy.dart';

class CameraDevice {
  final int index;
  final String deviceId;
  final String label;
  CameraDevice(this.index, this.deviceId, this.label);
}

/// Thin wrapper around the browser camera (getUserMedia). It keeps a hidden
/// <video> element playing the chosen device and grabs frames into RGBA buffers
/// by drawing onto an offscreen <canvas>.
///
/// The camera is chosen by *index* into the list of video input devices, which
/// is what the app exposes as a configurable setting.
class CameraService {
  CameraService({this.captureWidth = 640});

  /// Width we capture/process at (height follows the camera aspect ratio).
  /// Smaller = faster; 640 is plenty for 8x8 occupancy sampling.
  int captureWidth;

  web.HTMLVideoElement? _video;
  web.HTMLCanvasElement? _canvas;
  web.CanvasRenderingContext2D? _ctx;
  web.MediaStream? _stream;

  List<CameraDevice> devices = [];

  bool get isRunning => _stream != null;
  int get frameWidth => _canvas?.width ?? 0;
  int get frameHeight => _canvas?.height ?? 0;

  /// Lists the available video input devices. Labels are only populated after
  /// camera permission has been granted at least once.
  Future<List<CameraDevice>> enumerate() async {
    final md = web.window.navigator.mediaDevices;
    final infos = (await md.enumerateDevices().toDart).toDart;
    final cams = <CameraDevice>[];
    var i = 0;
    for (final info in infos) {
      if (info.kind == 'videoinput') {
        final label = info.label.isEmpty ? 'Camera $i' : info.label;
        cams.add(CameraDevice(i, info.deviceId, label));
        i++;
      }
    }
    devices = cams;
    return cams;
  }

  /// Starts streaming from the camera at [index]. If the list of devices is not
  /// known yet, a generic request is made first to unlock permission/labels.
  Future<void> start(int index) async {
    await stop();
    final md = web.window.navigator.mediaDevices;

    if (devices.isEmpty) {
      final tmp = await md
          .getUserMedia(web.MediaStreamConstraints(video: true.toJS))
          .toDart;
      _stopStream(tmp);
      await enumerate();
    }

    final JSAny videoConstraint;
    if (index >= 0 && index < devices.length) {
      videoConstraint = {
        'deviceId': {'exact': devices[index].deviceId},
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
      }.jsify()!;
    } else {
      videoConstraint = {
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
      }.jsify()!;
    }

    final stream = await md
        .getUserMedia(web.MediaStreamConstraints(video: videoConstraint))
        .toDart;
    _stream = stream;

    final video =
        web.document.createElement('video') as web.HTMLVideoElement
          ..autoplay = true
          ..muted = true;
    video.setAttribute('playsinline', 'true');
    video.srcObject = stream;
    await video.play().toDart;
    _video = video;

    // videoWidth is 0 until metadata arrives; poll briefly.
    for (var tries = 0; tries < 60 && video.videoWidth == 0; tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final vw = video.videoWidth == 0 ? 640 : video.videoWidth;
    final vh = video.videoHeight == 0 ? 480 : video.videoHeight;
    final cw = captureWidth;
    final ch = (cw * vh / vw).round();

    final canvas =
        web.document.createElement('canvas') as web.HTMLCanvasElement
          ..width = cw
          ..height = ch;
    _canvas = canvas;
    _ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;
  }

  /// Grabs the current frame as RGBA. Returns null if not ready yet.
  CapturedFrame? grab() {
    final video = _video;
    final canvas = _canvas;
    final ctx = _ctx;
    if (video == null || canvas == null || ctx == null) return null;
    if (video.videoWidth == 0) return null;

    ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
    final img = ctx.getImageData(0, 0, canvas.width, canvas.height);
    final data = img.data.toDart; // Uint8ClampedList, RGBA
    final bytes = Uint8List.view(data.buffer, data.offsetInBytes, data.length);
    return CapturedFrame(canvas.width, canvas.height, bytes);
  }

  /// Renders the current frame with the detection overlay (projected grid,
  /// per-square occupancy dots, red rings where observed != expected) and
  /// returns it as a PNG data URL — so the debug collector can save an image
  /// that shows exactly what the pipeline sees.
  String? annotatedDataUrl(
    Homography? h,
    OccupancyResult? occ,
    List<List<bool>>? expected,
  ) {
    final video = _video;
    final canvas = _canvas;
    if (video == null || canvas == null || video.videoWidth == 0) return null;
    final w = canvas.width;
    final hgt = canvas.height;

    final tmp = web.document.createElement('canvas') as web.HTMLCanvasElement
      ..width = w
      ..height = hgt;
    final ctx = tmp.getContext('2d') as web.CanvasRenderingContext2D;
    ctx.drawImage(video, 0, 0, w, hgt);

    if (h != null) {
      ctx.lineWidth = 1;
      ctx.strokeStyle = 'rgba(0,220,255,0.55)'.toJS;
      for (var k = 0; k <= 8; k++) {
        final a = h.apply(k.toDouble(), 0);
        final b = h.apply(k.toDouble(), 8);
        ctx.beginPath();
        ctx.moveTo(a.$1, a.$2);
        ctx.lineTo(b.$1, b.$2);
        ctx.stroke();
        final c = h.apply(0, k.toDouble());
        final d = h.apply(8, k.toDouble());
        ctx.beginPath();
        ctx.moveTo(c.$1, c.$2);
        ctx.lineTo(d.$1, d.$2);
        ctx.stroke();
      }

      if (occ != null) {
        for (var row = 0; row < 8; row++) {
          for (var col = 0; col < 8; col++) {
            final center = h.apply(col + 0.5, row + 0.5);
            final occupied = occ.occupied[row][col];
            ctx.beginPath();
            ctx.fillStyle = (occupied
                    ? 'rgba(255,70,70,0.85)'
                    : 'rgba(80,255,120,0.55)')
                .toJS;
            ctx.arc(center.$1, center.$2, 5, 0, 6.2832);
            ctx.fill();

            // Highlight disagreement between vision and the game state.
            if (expected != null && expected[row][col] != occupied) {
              ctx.beginPath();
              ctx.strokeStyle = 'rgba(255,230,0,0.95)'.toJS;
              ctx.lineWidth = 3;
              ctx.arc(center.$1, center.$2, 11, 0, 6.2832);
              ctx.stroke();
              ctx.lineWidth = 1;
            }
          }
        }
      }
    }

    return tmp.toDataURL('image/png');
  }

  Future<void> stop() async {
    final s = _stream;
    if (s != null) _stopStream(s);
    _stream = null;
    _video?.srcObject = null;
    _video = null;
  }

  void _stopStream(web.MediaStream s) {
    final tracks = s.getTracks().toDart;
    for (final t in tracks) {
      t.stop();
    }
  }
}
