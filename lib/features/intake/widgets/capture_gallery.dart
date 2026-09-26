/// The populated state of the capture step.
///
/// No mockup had one. Every file surface in the 46 exports drew an empty dashed dropzone or a bare
/// count ("12 project files"), and the one screen that showed images pointed at remote Google URLs
/// that will rot. So this is where an uploaded reference actually looks like something: a
/// thumbnail from a signed Supabase URL, the filename monospaced because it is an identifier, and
/// per-file delete.
///
/// Signed URLs expire, which is why they are fetched here per attachment set rather than stored
/// anywhere. The set is keyed by attachment ids, so adding a photo refetches and a rebuild for any
/// other reason does not.
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/storage.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/intake/widgets/intake_fields.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class CaptureGallery extends ConsumerStatefulWidget {
  const CaptureGallery({
    super.key,
    required this.attachments,
    required this.onAdd,
    required this.onDelete,
    this.primaryAttachmentId,
    this.onMakePrimary,
    this.addLabel = 'Add a reference',
    this.addHint = 'Photo, sketch, PDF or audio',
  });

  /// Everything filed against the job. Voice notes are split out into rows; the rest go in the
  /// grid, thumbnailed where the file is an image.
  final List<Attachment> attachments;
  final VoidCallback onAdd;
  final void Function(Attachment attachment) onDelete;

  /// The reference the job list will show. Marked with a chip so it is obvious which one it is.
  final String? primaryAttachmentId;
  final void Function(Attachment attachment)? onMakePrimary;

  final String addLabel;
  final String addHint;

  @override
  ConsumerState<CaptureGallery> createState() => _CaptureGalleryState();
}

class _CaptureGalleryState extends ConsumerState<CaptureGallery> {
  Map<String, String> _urls = const <String, String>{};
  String _signature = '';
  String? _urlFailure;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(CaptureGallery old) {
    super.didUpdateWidget(old);
    if (_signatureOf(widget.attachments) != _signature) _resolve();
  }

  static String _signatureOf(List<Attachment> items) =>
      [for (final a in items) a.id].join('|');

  Future<void> _resolve() async {
    final signature = _signatureOf(widget.attachments);
    _signature = signature;
    final images = [for (final a in widget.attachments) if (a.isImage) a];
    if (images.isEmpty) {
      if (mounted) setState(() => _urls = const <String, String>{});
      return;
    }
    try {
      final urls = await ref.read(attachmentStoreProvider).signedUrls(images);
      if (!mounted || _signature != signature) return;
      setState(() {
        _urls = urls;
        _urlFailure = null;
      });
    } on DhFailure catch (failure) {
      if (!mounted || _signature != signature) return;
      // A thumbnail that will not load is a cosmetic problem, not a lost file — say so and move on.
      setState(() => _urlFailure = failure.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final voiceNotes = [for (final a in widget.attachments) if (a.isVoiceNote) a];
    final visuals = [for (final a in widget.attachments) if (!a.isVoiceNote) a];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AttachmentGrid(
          items: [for (final a in visuals) _viewOf(a)],
          onAdd: widget.onAdd,
          addLabel: widget.addLabel,
          addIcon: Icons.add_a_photo_outlined,
          onDelete: (view) => _deleteById(view.id, visuals),
          onOpen: widget.onMakePrimary == null
              ? null
              : (view) => _promoteById(view.id, visuals),
        ),
        if (_urlFailure != null) ...[
          const Gap.sm(),
          NoteStrip(
            tone: NoteTone.info,
            icon: Icons.image_not_supported_outlined,
            text: 'Thumbnails could not be loaded: $_urlFailure The files themselves are '
                'attached and safe.',
          ),
        ],
        if (voiceNotes.isNotEmpty) ...[
          const Gap.md(),
          Text(
            'VOICE NOTES',
            style: context.text.labelSmall?.copyWith(color: context.scheme.onSurfaceVariant),
          ),
          const Gap.sm(),
          for (final note in voiceNotes) ...[
            AttachmentTile.row(
              item: _viewOf(note),
              onDelete: () => widget.onDelete(note),
            ),
            const SizedBox(height: Spacing.sm),
          ],
        ],
      ],
    );
  }

  void _deleteById(String id, List<Attachment> pool) {
    for (final a in pool) {
      if (a.id == id) {
        widget.onDelete(a);
        return;
      }
    }
  }

  void _promoteById(String id, List<Attachment> pool) {
    for (final a in pool) {
      if (a.id == id) {
        widget.onMakePrimary?.call(a);
        return;
      }
    }
  }

  AttachmentView _viewOf(Attachment a) {
    final url = _urls[a.id];
    final isPrimary = a.id == widget.primaryAttachmentId;
    return AttachmentView(
      id: a.id,
      kind: a.kind,
      filename: a.filename,
      meta: isPrimary ? 'Primary · ${a.metaLabel}' : a.metaLabel,
      durationLabel: a.durationLabel,
      thumbnail: url == null ? null : CachedNetworkImageProvider(url),
    );
  }
}

/// The capture menu: camera, gallery, file, voice. Four routes to satisfying D-011 rule 4, where
/// the mockup had one.
enum CaptureSource {
  camera('Take a photo', Icons.photo_camera_outlined, 'The piece, the sketch, the broken shank'),
  gallery('Choose a photo', Icons.photo_library_outlined, 'Something the client already sent'),
  file('Upload a file', Icons.upload_file_outlined, 'PDF, image, scan or mesh'),
  voice('Record a voice note', Icons.mic_none_rounded, 'Describe it in your own words');

  const CaptureSource(this.label, this.icon, this.blurb);
  final String label;
  final IconData icon;
  final String blurb;
}

/// Asks which way the operator wants to capture. Returns null if they back out.
Future<CaptureSource?> pickCaptureSource(BuildContext context) {
  return showModalBottomSheet<CaptureSource>(
    context: context,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Capture the reference',
              style: sheetContext.text.headlineSmall
                  ?.copyWith(color: sheetContext.scheme.onSurface),
            ),
            const Gap.md(),
            for (final source in CaptureSource.values) ...[
              SelectableTile(
                title: source.label,
                blurb: source.blurb,
                icon: source.icon,
                onTap: () => Navigator.of(sheetContext).pop(source),
              ),
              const SizedBox(height: Spacing.sm),
            ],
          ],
        ),
      ),
    ),
  );
}

/// The monospaced filename rule, for places that render a name outside an [AttachmentTile].
TextStyle filenameStyle(BuildContext context) =>
    AppTheme.mono(size: 12.5, color: context.scheme.onSurfaceVariant);

/// Which `AttachmentKind` a chosen file should be filed under.
///
/// Everything here satisfies the capture gate on purpose: an uploaded STL from a retailer is a
/// better brief than a blurry photo, and `AttachmentKind.stl` would not count.
AttachmentKind kindForUpload({required String filename, required bool fromCamera}) {
  if (fromCamera) return AttachmentKind.referenceImage;
  final dot = filename.lastIndexOf('.');
  final extension = dot <= 0 ? '' : filename.substring(dot + 1).toLowerCase();
  return switch (extension) {
    'png' || 'jpg' || 'jpeg' || 'webp' || 'heic' => AttachmentKind.referenceImage,
    'svg' || 'ai' || 'psd' => AttachmentKind.sketch,
    _ => AttachmentKind.other,
  };
}
