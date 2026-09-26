/// File tiles with a real populated state — thumbnail, filename, and per-file retake and delete.
///
/// No mockup had one. Every file surface in the 46 exports drew either an empty dashed dropzone or
/// a count with nothing behind it ("12 project files"), and the images that were shown pointed at
/// remote Google URLs that will rot. So the states that actually matter on a shop floor — a photo
/// that uploaded, a photo that is still uploading, a photo whose upload failed and needs retrying,
/// a file the operator wants to replace — had to be designed here.
///
/// Thumbnails arrive as an [ImageProvider] so this layer stays out of the storage question: the
/// caller decides between a `FileImage` for a just-captured local file and a
/// `CachedNetworkImageProvider` for a signed Supabase URL.
library;

import 'package:flutter/material.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/shared/widgets/reduced_motion.dart';

/// What a tile needs to draw itself. Map an `Attachment` row (or an in-flight local capture) onto
/// this; the widget layer never touches storage.
@immutable
final class AttachmentView {
  const AttachmentView({
    required this.id,
    required this.kind,
    required this.filename,
    this.meta,
    this.thumbnail,
    this.uploadProgress,
    this.errorText,
    this.durationLabel,
  });

  /// The attachment id, or a local capture's temporary key.
  final String id;

  final AttachmentKind kind;

  /// `cad_mesh_v2.png`, `Client_Instructions.wav`. Rendered monospaced — it is an identifier.
  final String filename;

  /// "Casting Photo · 1.4 MB". `Attachment.metaLabel` produces exactly this.
  final String? meta;

  final ImageProvider? thumbnail;

  /// 0.0–1.0 while the file is in flight; null once it has landed.
  final double? uploadProgress;

  /// Set when the upload failed. The tile then offers a retry instead of a retake.
  final String? errorText;

  /// Voice notes only — "01:20".
  final String? durationLabel;

  bool get isUploading => uploadProgress != null && errorText == null;
  bool get hasFailed => errorText != null;

  /// A glyph for every kind, so a tile without a thumbnail is still identifiable at a glance.
  IconData get icon => switch (kind) {
        AttachmentKind.referenceImage => Icons.image_outlined,
        AttachmentKind.sketch => Icons.draw_outlined,
        AttachmentKind.cadFile => Icons.architecture_outlined,
        AttachmentKind.cadRender => Icons.view_in_ar_outlined,
        AttachmentKind.stl => Icons.hexagon_outlined,
        AttachmentKind.stonePhoto => Icons.diamond_outlined,
        AttachmentKind.certificatePdf => Icons.workspace_premium_outlined,
        AttachmentKind.castingPhoto => Icons.local_fire_department_outlined,
        AttachmentKind.qcEvidence => Icons.fact_check_outlined,
        AttachmentKind.voiceNote => Icons.graphic_eq_rounded,
        AttachmentKind.invoice => Icons.receipt_long_outlined,
        AttachmentKind.proofOfDelivery => Icons.assignment_turned_in_outlined,
        AttachmentKind.other => Icons.attach_file_rounded,
      };
}

final class AttachmentTile extends StatelessWidget {
  const AttachmentTile({
    super.key,
    required this.item,
    this.onOpen,
    this.onRetake,
    this.onDelete,
    this.onRetry,
  }) : _row = false;

  /// A single-line row instead of a card. For voice notes, PDFs and meshes, which have no useful
  /// thumbnail.
  const AttachmentTile.row({
    super.key,
    required this.item,
    this.onOpen,
    this.onRetake,
    this.onDelete,
    this.onRetry,
  }) : _row = true;

  final AttachmentView item;
  final VoidCallback? onOpen;

  /// "Retake" for a camera capture, "Replace" for a chosen file. Labelled by [item] kind.
  final VoidCallback? onRetake;

  final VoidCallback? onDelete;
  final VoidCallback? onRetry;

  final bool _row;

  String get _retakeLabel =>
      item.kind == AttachmentKind.castingPhoto || item.kind == AttachmentKind.referenceImage
          ? 'Retake'
          : 'Replace';

  @override
  Widget build(BuildContext context) => _row ? _buildRow(context) : _buildCard(context);

  // ---------------------------------------------------------------- card

  Widget _buildCard(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final failed = item.hasFailed;

    return Container(
      decoration: BoxDecoration(
        color: dh.surfaceContainerLowest,
        borderRadius: Radii.rMd,
        border: Border.all(color: failed ? scheme.error : dh.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _Preview(item: item),
                if (onOpen != null)
                  Material(
                    type: MaterialType.transparency,
                    child: InkWell(onTap: onOpen),
                  ),
                if (item.isUploading) _UploadVeil(progress: item.uploadProgress!),
                if (onDelete != null && !item.isUploading)
                  Positioned(
                    top: Spacing.xs,
                    right: Spacing.xs,
                    child: _OverlayButton(
                      icon: Icons.close_rounded,
                      tooltip: 'Remove ${item.filename}',
                      onTap: onDelete!,
                    ),
                  ),
                if (item.durationLabel != null)
                  Positioned(
                    left: Spacing.xs,
                    bottom: Spacing.xs,
                    child: _Pill(text: item.durationLabel!),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(Spacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.mono(size: 11, color: scheme.onSurface),
                ),
                const SizedBox(height: 2),
                Text(
                  failed ? item.errorText! : (item.meta ?? item.kind.label),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodySmall?.copyWith(
                    fontSize: 11,
                    color: failed ? scheme.error : scheme.onSurfaceVariant,
                  ),
                ),
                if (failed && onRetry != null) ...[
                  const SizedBox(height: Spacing.xs),
                  _TinyAction(
                    icon: Icons.refresh_rounded,
                    label: 'Retry upload',
                    onTap: onRetry!,
                  ),
                ] else if (onRetake != null && !item.isUploading) ...[
                  const SizedBox(height: Spacing.xs),
                  _TinyAction(
                    icon: Icons.cameraswitch_outlined,
                    label: _retakeLabel,
                    onTap: onRetake!,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- row

  Widget _buildRow(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final failed = item.hasFailed;

    return Container(
      decoration: BoxDecoration(
        color: dh.surfaceContainerLowest,
        borderRadius: Radii.rMd,
        border: Border.all(color: failed ? scheme.error : dh.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(Spacing.sm + Spacing.xs),
            child: Row(
              children: [
                SizedBox(
                  width: 42,
                  height: 42,
                  child: ClipRRect(
                    borderRadius: Radii.rSm,
                    child: _Preview(item: item, compact: true),
                  ),
                ),
                const SizedBox(width: Spacing.sm + Spacing.xs),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        item.filename,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.mono(
                          size: 12,
                          weight: FontWeight.w500,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      if (item.isUploading)
                        _InlineProgress(progress: item.uploadProgress!)
                      else
                        Text(
                          failed
                              ? item.errorText!
                              : [
                                  item.meta ?? item.kind.label,
                                  if (item.durationLabel != null) item.durationLabel!,
                                ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.bodySmall?.copyWith(
                            color: failed ? scheme.error : scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                if (failed && onRetry != null)
                  IconButton(
                    onPressed: onRetry,
                    tooltip: 'Retry upload',
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                  )
                else if (onRetake != null && !item.isUploading)
                  IconButton(
                    onPressed: onRetake,
                    tooltip: _retakeLabel,
                    icon: const Icon(Icons.cameraswitch_outlined, size: 20),
                  ),
                if (onDelete != null && !item.isUploading)
                  IconButton(
                    onPressed: onDelete,
                    tooltip: 'Remove ${item.filename}',
                    icon: Icon(Icons.delete_outline_rounded, size: 20, color: scheme.error),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _Preview extends StatelessWidget {
  const _Preview({required this.item, this.compact = false});

  final AttachmentView item;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final dh = context.dh;
    final thumb = item.thumbnail;
    if (thumb != null) {
      return Image(
        image: thumb,
        fit: BoxFit.cover,
        errorBuilder: (context, _, __) => _glyph(context),
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : ColoredBox(color: dh.surfaceContainerHigh),
      );
    }
    return _glyph(context);
  }

  Widget _glyph(BuildContext context) => ColoredBox(
        color: context.dh.surfaceContainerHigh,
        child: Center(
          child: Icon(
            item.icon,
            size: compact ? 20 : 30,
            color: context.scheme.onSurfaceVariant,
          ),
        ),
      );
}

/// Dims the thumbnail and states the percentage. The mockups' dropzones had no in-flight state at
/// all, which on a 4G shop connection is the state an operator sees most.
final class _UploadVeil extends StatelessWidget {
  const _UploadVeil({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return ColoredBox(
      color: scheme.surface.withValues(alpha: 0.72),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 30,
              height: 30,
              child: CircularProgressIndicator(
                value: context.reduceMotion ? progress : null,
                strokeWidth: 2.5,
              ),
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              '${(progress * 100).round()}%',
              style: AppTheme.mono(size: 11, color: scheme.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}

final class _InlineProgress extends StatelessWidget {
  const _InlineProgress({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: Radii.rFull,
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                backgroundColor: context.dh.surfaceContainerHigh,
              ),
            ),
          ),
          const SizedBox(width: Spacing.sm),
          Text(
            'Uploading ${(progress * 100).round()}%',
            style: AppTheme.mono(size: 10.5, color: context.scheme.onSurfaceVariant),
          ),
        ],
      );
}

final class _OverlayButton extends StatelessWidget {
  const _OverlayButton({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: scheme.surface.withValues(alpha: 0.88),
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.all(Spacing.xs + 1),
            child: Icon(icon, size: 16, color: scheme.onSurface),
          ),
        ),
      ),
    );
  }
}

final class _Pill extends StatelessWidget {
  const _Pill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 2),
        decoration: BoxDecoration(
          color: context.scheme.surface.withValues(alpha: 0.85),
          borderRadius: Radii.rFull,
        ),
        child: Text(
          text,
          style: AppTheme.mono(size: 10, color: context.scheme.onSurface),
        ),
      );
}

final class _TinyAction extends StatelessWidget {
  const _TinyAction({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return InkWell(
      onTap: onTap,
      borderRadius: Radii.rSm,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: scheme.secondary),
            const SizedBox(width: Spacing.xs),
            Text(
              label,
              style: context.text.bodySmall?.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: scheme.secondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A responsive grid of [AttachmentTile]s with a dashed "add" cell.
///
/// The add cell is the only part the mockups drew, and they drew it as the whole feature. Here it
/// is one cell among the files that already exist, and it disappears at [maxItems] instead of
/// accepting a file the step cannot hold.
final class AttachmentGrid extends StatelessWidget {
  const AttachmentGrid({
    super.key,
    required this.items,
    this.onAdd,
    this.addLabel = 'Add file',
    this.addIcon = Icons.add_rounded,
    this.onOpen,
    this.onRetake,
    this.onDelete,
    this.onRetry,
    this.columns = 3,
    this.minTileWidth = 104,
    this.maxItems,
    this.spacing = Spacing.sm + Spacing.xs,
  });

  final List<AttachmentView> items;

  /// Null hides the add cell — a read-only view of someone else's files.
  final VoidCallback? onAdd;

  final String addLabel;
  final IconData addIcon;

  final void Function(AttachmentView)? onOpen;
  final void Function(AttachmentView)? onRetake;
  final void Function(AttachmentView)? onDelete;
  final void Function(AttachmentView)? onRetry;

  final int columns;
  final double minTileWidth;

  /// Hides the add cell once this many files are attached.
  final int? maxItems;

  final double spacing;

  bool get _canAdd => onAdd != null && (maxItems == null || items.length < maxItems!);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available =
            constraints.maxWidth.isFinite ? constraints.maxWidth : minTileWidth * columns;
        var count = columns;
        while (count > 1 && (available - spacing * (count - 1)) / count < minTileWidth) {
          count--;
        }
        final tileWidth = (available - spacing * (count - 1)) / count;

        final cells = <Widget>[
          for (final item in items)
            SizedBox(
              width: tileWidth,
              child: AttachmentTile(
                item: item,
                onOpen: onOpen == null ? null : () => onOpen!(item),
                onRetake: onRetake == null ? null : () => onRetake!(item),
                onDelete: onDelete == null ? null : () => onDelete!(item),
                onRetry: onRetry == null ? null : () => onRetry!(item),
              ),
            ),
          if (_canAdd)
            SizedBox(
              width: tileWidth,
              child: AddAttachmentTile(
                label: addLabel,
                icon: addIcon,
                onTap: onAdd!,
                height: tileWidth,
              ),
            ),
        ];

        return Wrap(spacing: spacing, runSpacing: spacing, children: cells);
      },
    );
  }
}

/// The dashed capture cell. Dashes are painted rather than faked with a dotted image, so they stay
/// crisp at any density and take their colour from the theme.
final class AddAttachmentTile extends StatelessWidget {
  const AddAttachmentTile({
    super.key,
    required this.onTap,
    this.label = 'Add file',
    this.icon = Icons.add_rounded,
    this.height,
    this.hint,
  });

  final VoidCallback onTap;
  final String label;
  final IconData icon;

  /// Square by default when used inside [AttachmentGrid]; pass a height for a banner-shaped cell.
  final double? height;

  /// A second line — "JPG, PNG, PDF or STL".
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _DashedBorderPainter(
          color: context.dh.outlineVariant,
          radius: Radii.md,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: Radii.rMd,
            child: Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 22, color: scheme.onSurfaceVariant),
                  const SizedBox(height: Spacing.xs + 2),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    style: context.text.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (hint != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      hint!,
                      textAlign: TextAlign.center,
                      style: AppTheme.mono(size: 9.5, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  static const _dash = 5.0;
  static const _gap = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0.6, 0.6, size.width - 1.2, size.height - 1.2),
          Radius.circular(radius),
        ),
      );

    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + _dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}
