/// A signature capture that produces a real PNG.
///
/// Nothing in the 46 mockups captured a signature — "Confirm Dispatch" was the last wired action
/// in the corpus, and a high-value piece was handed over with no record of who took it. A proof of
/// delivery is the difference between a handover and a claim, so this writes an actual image into
/// `attachments` rather than a tick on a row.
///
/// Two deliberate choices:
///
///  * **The exported image is always black ink on white**, whatever theme the shop-floor tablet is
///    running. A signature is evidence that may be printed, emailed to an insurer or attached to a
///    police report; pale gold strokes on a midnight ground are not.
///  * **Points are captured in the pad's own logical coordinates** and the export is scaled from
///    them, so the same signature drawn on a 360dp handset and a 1200dp tablet produces the same
///    proportioned mark.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';

/// Holds the strokes and turns them into a PNG.
///
/// A [ChangeNotifier] rather than widget state so the screen's action bar can watch
/// [isEmpty] — the button that uploads a signature must be shut until there is one.
final class SignatureController extends ChangeNotifier {
  final List<List<Offset>> _strokes = <List<Offset>>[];
  List<Offset>? _current;
  Size _canvasSize = Size.zero;

  /// Every finished stroke, plus the one in progress. Read by the painter.
  List<List<Offset>> get strokes => <List<Offset>>[
        ..._strokes,
        if (_current != null && _current!.isNotEmpty) _current!,
      ];

  bool get isEmpty => _strokes.isEmpty && (_current?.isEmpty ?? true);

  bool get isNotEmpty => !isEmpty;

  int get strokeCount => strokes.length;

  /// Recorded by the pad on layout. The export needs it to know the aspect the marks were made
  /// at; without it a signature would be stretched to whatever the exporter guessed.
  void reportCanvasSize(Size size) {
    _canvasSize = size;
  }

  void begin(Offset point) {
    _current = <Offset>[point];
    notifyListeners();
  }

  void extend(Offset point) {
    final stroke = _current;
    if (stroke == null) return;
    // Drop sub-pixel jitter: a resting fingertip emits dozens of points a second and every one
    // of them would go into the PNG as a smudge.
    final last = stroke.isEmpty ? null : stroke.last;
    if (last != null && (point - last).distanceSquared < 1.0) return;
    stroke.add(point);
    notifyListeners();
  }

  void end() {
    final stroke = _current;
    _current = null;
    if (stroke == null || stroke.isEmpty) return;
    _strokes.add(stroke);
    notifyListeners();
  }

  /// Remove the last stroke. A signature is usually two or three strokes, so undo is far more
  /// useful than a clear — a mis-drawn flourish should not cost the whole name.
  void undo() {
    if (_current != null) {
      _current = null;
      notifyListeners();
      return;
    }
    if (_strokes.isEmpty) return;
    _strokes.removeLast();
    notifyListeners();
  }

  void clear() {
    if (isEmpty) return;
    _strokes.clear();
    _current = null;
    notifyListeners();
  }

  /// Rasterise to PNG bytes, or null when nothing has been drawn.
  ///
  /// [pixelRatio] is the device ratio: 3 on a modern handset, so a 320x160 pad exports a
  /// 960x480 image — legible when printed on a docket.
  Future<Uint8List?> toPng({
    double pixelRatio = 3,
    double strokeWidth = 2.6,
  }) async {
    if (isEmpty) return null;
    final size = _canvasSize;
    if (size.width <= 0 || size.height <= 0) return null;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(pixelRatio);

    // White ground, always. See the library comment.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFFFFFFFF),
    );

    final ink = Paint()
      ..color = const Color(0xFF000000)
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    paintStrokes(canvas, strokes, ink);

    final picture = recorder.endRecording();
    final image = await picture.toImage(
      (size.width * pixelRatio).round(),
      (size.height * pixelRatio).round(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    return data?.buffer.asUint8List();
  }

  /// Shared by the on-screen painter and the exporter, so what the operator signed is exactly
  /// what gets filed.
  static void paintStrokes(Canvas canvas, List<List<Offset>> strokes, Paint ink) {
    for (final stroke in strokes) {
      if (stroke.isEmpty) continue;
      if (stroke.length == 1) {
        // A dot — a full stop, or an initial jabbed at the screen.
        canvas.drawCircle(
          stroke.first,
          ink.strokeWidth / 2,
          Paint()
            ..color = ink.color
            ..style = PaintingStyle.fill
            ..isAntiAlias = true,
        );
        continue;
      }
      final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
      for (var i = 1; i < stroke.length; i++) {
        path.lineTo(stroke[i].dx, stroke[i].dy);
      }
      canvas.drawPath(path, ink);
    }
  }
}

/// The pad itself: a bordered box with a baseline, an undo and a clear.
final class SignaturePad extends StatelessWidget {
  const SignaturePad({
    super.key,
    required this.controller,
    this.height = 180,
    this.label = 'Recipient signature',
    this.hint = 'Sign inside the box',
    this.enabled = true,
  });

  final SignatureController controller;
  final double height;
  final String label;
  final String hint;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label.toUpperCase(),
                style: context.text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            ListenableBuilder(
              listenable: controller,
              builder: (context, _) {
                final empty = controller.isEmpty;
                return Row(
                  children: [
                    TextButton(
                      onPressed: enabled && !empty ? controller.undo : null,
                      child: const Text('Undo'),
                    ),
                    TextButton(
                      onPressed: enabled && !empty ? controller.clear : null,
                      child: const Text('Clear'),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
        const SizedBox(height: Spacing.sm),
        LayoutBuilder(
          builder: (context, constraints) {
            final width =
                constraints.maxWidth.isFinite ? constraints.maxWidth : 320.0;
            final size = Size(width, height);
            controller.reportCanvasSize(size);

            return Container(
              height: height,
              decoration: BoxDecoration(
                color: dh.surfaceContainerLowest,
                borderRadius: Radii.rMd,
                border: Border.all(color: dh.outlineVariant),
              ),
              clipBehavior: Clip.antiAlias,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: enabled
                    ? (event) => controller.begin(_clamp(event.localPosition, size))
                    : null,
                onPointerMove: enabled
                    ? (event) => controller.extend(_clamp(event.localPosition, size))
                    : null,
                onPointerUp: enabled ? (_) => controller.end() : null,
                onPointerCancel: enabled ? (_) => controller.end() : null,
                child: ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) => CustomPaint(
                    painter: _SignaturePainter(
                      strokes: controller.strokes,
                      ink: scheme.onSurface,
                      baseline: dh.outlineVariant,
                    ),
                    child: controller.isEmpty
                        ? Center(
                            child: Text(
                              hint,
                              style: context.text.bodyMedium
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          )
                        : const SizedBox.expand(),
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: Spacing.xs),
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Text(
            controller.isEmpty
                ? 'The signature is filed as an image against this shipment.'
                : '${controller.strokeCount} stroke'
                    '${controller.strokeCount == 1 ? '' : 's'} captured. '
                    'Filed as a black-on-white PNG.',
            style: AppTheme.mono(size: 10.5, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  /// Keep a finger that slid off the edge inside the box, so the exported image never clips a
  /// stroke at an arbitrary point.
  static Offset _clamp(Offset point, Size size) => Offset(
        point.dx.clamp(0.0, size.width),
        point.dy.clamp(0.0, size.height),
      );
}

final class _SignaturePainter extends CustomPainter {
  const _SignaturePainter({
    required this.strokes,
    required this.ink,
    required this.baseline,
  });

  final List<List<Offset>> strokes;
  final Color ink;
  final Color baseline;

  @override
  void paint(Canvas canvas, Size size) {
    // The signing line, at the same place a paper docket puts it.
    final y = size.height * 0.78;
    canvas.drawLine(
      Offset(size.width * 0.08, y),
      Offset(size.width * 0.92, y),
      Paint()
        ..color = baseline
        ..strokeWidth = 1,
    );

    SignatureController.paintStrokes(
      canvas,
      strokes,
      Paint()
        ..color = ink
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_SignaturePainter old) =>
      old.ink != ink ||
      old.baseline != baseline ||
      old.strokes.length != strokes.length ||
      (strokes.isNotEmpty &&
          old.strokes.isNotEmpty &&
          old.strokes.last.length != strokes.last.length);
}
