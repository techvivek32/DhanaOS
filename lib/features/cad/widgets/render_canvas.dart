/// The render pane: one CAD image, its positioned annotation pins, and the tap that drops a new
/// one.
///
/// `cad_review_dh_1048` is the best screen in the corpus and this is the part worth keeping: pins
/// sitting *on* the geometry being discussed, rather than a list of remarks beside it. Two things
/// it did not have are here because a real review needs them — the pin coordinates are
/// percentages of a fixed-aspect, `contain`-fitted box, so the same pin lands on the same prong
/// on a phone and on a workstation; and a render whose signed link has expired says so instead of
/// drawing a grey square.
library;

import 'package:flutter/material.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

/// How a pane presents itself in a comparison: the version under review, or the one before it.
enum RenderRole {
  current('CURRENT'),
  previous('PREVIOUS'),
  plain('');

  const RenderRole(this.tag);

  final String tag;
}

/// One image with its pins.
final class RenderPane extends StatelessWidget {
  const RenderPane({
    super.key,
    required this.version,
    required this.image,
    this.role = RenderRole.plain,
    this.pins = const <CadAnnotation>[],
    this.selectedPinId,
    this.onPinTap,
    this.onTapAt,
    this.dropping = false,
    this.caption,
    this.emptyMessage = 'No render was attached to this version.',
    this.aspectRatio = 4 / 5,
    this.onExpand,
  });

  /// 'v2.0' — rendered monospaced, because it is an identifier.
  final String version;

  /// Null draws the empty pane rather than a broken image.
  final ImageProvider? image;

  final RenderRole role;

  /// Ordered oldest first; the numbers on screen are this list's 1-based positions.
  final List<CadAnnotation> pins;

  final String? selectedPinId;
  final void Function(CadAnnotation pin)? onPinTap;

  /// Percentages, clamped to the image. Null means this pane does not take new pins — a previous
  /// version never does.
  final void Function(double xPct, double yPct)? onTapAt;

  /// True while the operator is placing a pin: the cursor changes and the pane invites the tap
  /// instead of silently accepting one.
  final bool dropping;

  /// 'cad_mesh_v2.png · 1.4 MB'.
  final String? caption;

  final String emptyMessage;
  final double aspectRatio;

  /// Opens the full-screen zoomable view. A halo of 1.5mm melee is not judged at 160px wide.
  final VoidCallback? onExpand;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              version,
              style: AppTheme.mono(size: 13, weight: FontWeight.w700, color: scheme.onSurface),
            ),
            if (role != RenderRole.plain) ...[
              const SizedBox(width: Spacing.sm),
              StatusChip(
                label: role.tag,
                tone: role == RenderRole.current ? ChipTone.accent : ChipTone.neutral,
                dense: true,
                mono: true,
              ),
            ],
            const Spacer(),
            if (onExpand != null && image != null)
              IconButton(
                onPressed: onExpand,
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                tooltip: 'Open $version full screen',
                icon: const Icon(Icons.open_in_full_rounded),
              ),
          ],
        ),
        const SizedBox(height: Spacing.sm),
        ClipRRect(
          borderRadius: Radii.rMd,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: dh.surfaceContainerLow,
              borderRadius: Radii.rMd,
              border: Border.all(
                color: dropping ? scheme.secondary : dh.outlineVariant,
                width: dropping ? 2 : 1,
              ),
            ),
            child: AspectRatio(
              aspectRatio: aspectRatio,
              child: image == null ? _empty(context) : _canvas(context),
            ),
          ),
        ),
        if (caption != null) ...[
          const SizedBox(height: Spacing.xs + 2),
          Text(
            caption!,
            style: AppTheme.mono(size: 10.5, color: scheme.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }

  Widget _empty(BuildContext context) => Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: EmptyState(
          compact: true,
          icon: Icons.view_in_ar_outlined,
          title: 'No render',
          message: emptyMessage,
        ),
      );

  Widget _canvas(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: onTapAt == null
              ? null
              : (details) {
                  final local = details.localPosition;
                  onTapAt!(
                    (local.dx / width * 100).clamp(0.0, 100.0),
                    (local.dy / height * 100).clamp(0.0, 100.0),
                  );
                },
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image(
                image: image!,
                // `contain`, not `cover`. A pin is stored as a percentage of this box, so the
                // box-to-image mapping has to be the same on every device: the pane's aspect
                // ratio is fixed, and `contain` letterboxes identically at any scale. `cover`
                // would crop a different part of the render on a phone than on a workstation,
                // and the pin would drift off the prong it was placed on.
                fit: BoxFit.contain,
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  final expected = progress.expectedTotalBytes;
                  return Center(
                    child: SizedBox(
                      width: Spacing.lg,
                      height: Spacing.lg,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: expected == null
                            ? null
                            : progress.cumulativeBytesLoaded / expected,
                      ),
                    ),
                  );
                },
                errorBuilder: (context, error, stack) => _Unreachable(version: version),
              ),
              for (var i = 0; i < pins.length; i++)
                Positioned(
                  left: width * pins[i].xPct / 100 - _AnnotationPin.size / 2,
                  top: height * pins[i].yPct / 100 - _AnnotationPin.size / 2,
                  child: _AnnotationPin(
                    number: i + 1,
                    pin: pins[i],
                    selected: pins[i].id == selectedPinId,
                    onTap: onPinTap == null ? null : () => onPinTap!(pins[i]),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// A signed URL lives 30 minutes. Past that the image really is unreachable, and saying which
/// version failed is what lets the operator reload the right thing.
final class _Unreachable extends StatelessWidget {
  const _Unreachable({required this.version});

  final String version;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(Spacing.sm),
        child: ErrorState(
          compact: true,
          icon: Icons.image_not_supported_outlined,
          title: '$version did not load',
          message: 'The signed link to this render has expired. Pull down to refresh the '
              'review and it will be re-signed.',
        ),
      );
}

final class _AnnotationPin extends StatelessWidget {
  const _AnnotationPin({
    required this.number,
    required this.pin,
    required this.selected,
    required this.onTap,
  });

  static const size = 28.0;

  final int number;
  final CadAnnotation pin;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    // A resolved pin stays on the render — the record of what was asked for is the point — but
    // it steps back so the open remarks read first.
    final background = pin.isResolved ? dh.successContainer : scheme.secondary;
    final foreground = pin.isResolved ? dh.success : scheme.onSecondary;

    return Semantics(
      button: onTap != null,
      label: 'Annotation $number, ${pin.isResolved ? 'addressed' : 'open'}',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: context.motion(Motion.fast),
          curve: context.motionCurve,
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: background,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? scheme.onSurface : dh.surfaceContainerLowest,
              width: selected ? 3 : 2,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            '$number',
            style: AppTheme.mono(size: 12, weight: FontWeight.w700, color: foreground),
          ),
        ),
      ),
    );
  }
}

/// Full-screen, zoomable. The pins are deliberately left behind: this view is for judging the
/// geometry, and a pin is a thing you place against the layout, not against a 4x zoom.
Future<void> openRenderViewer(
  BuildContext context, {
  required ImageProvider image,
  required String title,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog.fullscreen(
      backgroundColor: dialogContext.scheme.surface,
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              maxScale: 6,
              child: Center(
                child: Image(
                  image: image,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stack) => _Unreachable(version: title),
                ),
              ),
            ),
          ),
          Positioned(
            top: Spacing.md,
            left: Spacing.md,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.sm + Spacing.xs,
                  vertical: Spacing.xs + 2,
                ),
                decoration: BoxDecoration(
                  color: dialogContext.dh.surfaceContainerLowest,
                  borderRadius: Radii.rFull,
                ),
                child: Text(
                  title,
                  style: AppTheme.mono(
                    size: 12,
                    weight: FontWeight.w700,
                    color: dialogContext.scheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: Spacing.sm,
            right: Spacing.sm,
            child: SafeArea(
              child: IconButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                tooltip: 'Close the render',
                style: IconButton.styleFrom(
                  backgroundColor: dialogContext.dh.surfaceContainerLowest,
                  foregroundColor: dialogContext.scheme.onSurface,
                ),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
