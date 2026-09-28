/// Step 2 — capture the brief, and say who it is for.
///
/// D-011 rule 4, extended: intake cannot advance without a reference, and a reference is a photo
/// **or** a voice note **or** an uploaded file. The mockup gated on the camera alone, which meant a
/// bench jeweller describing a repair out loud — giving us more than a blurry photo would — was
/// refused. `CaptureGate` is the rule; this screen only renders it.
///
/// D-012 also merges `reference_material_capture`'s form into this step, which is why the job
/// header lives here: the customer, the working title, the quantity and the currency all belong
/// with the brief rather than three screens later.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/intake/intake_controller.dart';
import 'package:dhanaos/features/intake/intake_draft.dart';
import 'package:dhanaos/features/intake/intake_step.dart';
import 'package:dhanaos/features/intake/steps/step_shell.dart';
import 'package:dhanaos/features/intake/widgets/capture_gallery.dart';
import 'package:dhanaos/features/intake/widgets/customer_picker.dart';
import 'package:dhanaos/features/intake/widgets/intake_fields.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class StepMedia extends ConsumerStatefulWidget {
  const StepMedia({super.key, required this.draft, required this.jobKey});

  final IntakeDraft draft;
  final String? jobKey;

  @override
  ConsumerState<StepMedia> createState() => _StepMediaState();
}

class _StepMediaState extends ConsumerState<StepMedia> {
  bool _busy = false;

  IntakeController get _controller => ref.intake(widget.jobKey);

  Future<void> _guarded(Future<String?> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final failure = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    if (failure != null) showFailure(context, failure);
  }

  // ---------------------------------------------------------------- capture

  Future<void> _capture() async {
    final source = await pickCaptureSource(context);
    if (!mounted || source == null) return;
    if (source == CaptureSource.camera) {
      await _photo(ImageSource.camera);
    } else if (source == CaptureSource.gallery) {
      await _photo(ImageSource.gallery);
    } else if (source == CaptureSource.file) {
      await _files();
    } else {
      showDone(context, 'Use the recorder below — hold the phone close and speak normally.');
    }
  }

  Future<void> _photo(ImageSource source) async {
    XFile? picked;
    try {
      // 88 keeps a 12MP shop photo under a megabyte, which matters on a 4G upload and loses
      // nothing an operator or a CAD designer will ever look at.
      picked = await ImagePicker().pickImage(source: source, imageQuality: 88);
    } on Exception catch (error) {
      if (!mounted) return;
      showFailure(
        context,
        'The camera could not be opened. Check that DhanaOS has camera permission. ($error)',
      );
      return;
    }
    final shot = picked;
    if (shot == null || !mounted) return;
    await _guarded(
      () => _controller.addCapture(
        kind: AttachmentKind.referenceImage,
        file: File(shot.path),
        filename: shot.name,
      ),
    );
  }

  Future<void> _files() async {
    List<PlatformFile> chosen;
    try {
      chosen = await FilePicker.pickFiles();
    } on Exception catch (error) {
      if (!mounted) return;
      showFailure(context, 'The file browser could not be opened. ($error)');
      return;
    }
    if (chosen.isEmpty || !mounted) return;

    for (final picked in chosen) {
      final path = picked.path;
      if (path == null) continue;
      await _guarded(
        () => _controller.addCapture(
          kind: kindForUpload(filename: picked.name, fromCamera: false),
          file: File(path),
          filename: picked.name,
        ),
      );
      if (!mounted) return;
    }
  }

  Future<void> _recorded(VoiceNote note) => _guarded(
        () => _controller.addCapture(
          kind: AttachmentKind.voiceNote,
          file: File(note.path),
          filename: 'brief_${note.durationLabel.replaceAll(':', 'm')}s.m4a',
          durationMs: note.duration.inMilliseconds,
          caption: 'Spoken brief · ${note.durationLabel}',
        ),
      );

  Future<void> _delete(Attachment attachment) async {
    final confirmed = await confirmAction(
      context,
      title: 'Delete ${attachment.filename}?',
      message: 'The file is removed from this job order and from storage. If it is the only '
          'reference on the job, you will not be able to continue until another one is captured.',
      confirmLabel: 'Delete the file',
    );
    if (!confirmed || !mounted) return;
    await _guarded(() => _controller.removeCapture(attachment));
  }

  Future<void> _chooseCustomer() async {
    final draft = widget.draft;
    final chosen = await pickCustomer(context, selectedId: draft.job?.customerId);
    if (!mounted || chosen == null) return;
    await _guarded(() async {
      final failure = await _controller.setCustomer(chosen);
      if (failure != null) return failure;
      // D-004: a retailer who trades in dollars should not have their job quoted in rupees by
      // default. The operator can still override on the pricing step.
      if (chosen.currency != draft.currency) {
        return _controller.setCurrency(chosen.currency);
      }
      return null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    final gate = draft.capture;
    final primary = _primaryAttachmentId(draft);

    return IntakeStepScaffold(
      draft: draft,
      jobKey: widget.jobKey,
      step: IntakeStep.media,
      busy: _busy,
      footerNote: gate.isSatisfied
          ? 'On file: ${gate.evidenceLabel}. References are cited by their RF- code from here on.'
          : null,
      children: [
        DhSectionCard(
          title: 'References',
          subtitle: 'What the piece has to look like. One is enough; more is better.',
          leading: const Icon(Icons.collections_outlined),
          action: StatusChip(
            label: gate.isSatisfied ? gate.evidenceLabel : 'Nothing yet',
            tone: gate.isSatisfied ? ChipTone.success : ChipTone.warning,
            dense: true,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (draft.attachments.isEmpty)
                AddAttachmentTile(
                  onTap: _busy ? () {} : _capture,
                  label: 'Capture a reference',
                  icon: Icons.add_a_photo_outlined,
                  height: 132,
                  hint: 'Photo · voice note · PDF · sketch',
                )
              else
                CaptureGallery(
                  attachments: draft.attachments,
                  primaryAttachmentId: primary,
                  onAdd: _capture,
                  onDelete: _delete,
                  onMakePrimary: (attachment) {
                    final reference = draft.referenceFor(attachment);
                    if (reference == null || reference.isPrimary) return;
                    _guarded(() => _controller.makePrimaryReference(reference));
                  },
                ),
              const Gap.md(),
              VoiceNoteRecorder(
                enabled: !_busy,
                label: 'Spoken brief',
                hint: 'Sizing, stones, what the client actually said. Five minutes maximum.',
                onRecorded: _recorded,
              ),
            ],
          ),
        ),
        const Gap.md(),
        DhSectionCard(
          title: 'Job header',
          subtitle: 'Who it is for, and what to call it on the shop floor.',
          leading: const Icon(Icons.badge_outlined),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FieldBlock(
                label: 'Customer',
                helper: draft.customer == null
                    ? 'Required. The retailer this order came from.'
                    : (draft.customer!.isGstRegistered
                        ? 'GSTIN on file — the invoice will split correctly.'
                        : 'No GSTIN on this retailer. A tax invoice cannot be raised until one '
                            'is added.'),
                child: SelectableTile(
                  title: draft.customer?.name ?? 'Choose the retailer',
                  blurb: draft.customer == null
                      ? 'Search the directory, or add a new one'
                      : _customerBlurb(draft),
                  icon: Icons.storefront_outlined,
                  selected: draft.customer != null,
                  onTap: _busy ? null : _chooseCustomer,
                ),
              ),
              const Gap.md(),
              FieldBlock(
                label: 'Working title',
                helper: 'What the bench will call it — "Solitaire Crown", "Mrs Shah eternity".',
                child: IntakeTextField(
                  value: draft.job?.title,
                  hint: 'Solitaire Crown',
                  prefixIcon: Icons.title_rounded,
                  onChanged: (value) => _controller.setTitle(value),
                ),
              ),
              const Gap.md(),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: FieldBlock(
                      label: 'Quantity',
                      child: StepperField.count(
                        value: draft.job?.quantity ?? 1,
                        min: 1,
                        max: 500,
                        unit: 'pcs',
                        onChanged: (value) => _controller.setQuantity(value),
                      ),
                    ),
                  ),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: FieldBlock(
                      label: 'Currency',
                      helper: 'D-004: quotes, costs and the invoice all follow this.',
                      child: DhSegmented<String>(
                        value: draft.currency,
                        segments: const [
                          DhSegment(value: 'INR', label: '₹ INR'),
                          DhSegment(value: 'USD', label: r'$ USD'),
                        ],
                        onChanged: (code) => _controller.setCurrency(code),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (draft.references.isNotEmpty) ...[
          const Gap.md(),
          DhSectionCard(
            title: 'Reference codes',
            subtitle: 'Cite these on the CAD brief and the job bag.',
            leading: const Icon(Icons.tag_rounded),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final reference in draft.references) ...[
                  Row(
                    children: [
                      StatusChip.code(
                        reference.displayCode,
                        dense: true,
                        tone: reference.isPrimary ? ChipTone.accent : ChipTone.neutral,
                      ),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: Text(
                          reference.note?.trim().isNotEmpty ?? false
                              ? reference.note!.trim()
                              : _filenameFor(draft, reference),
                          style: AppTheme.mono(
                            size: 12,
                            color: context.scheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (!reference.isPrimary)
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _guarded(
                                    () => _controller.makePrimaryReference(reference),
                                  ),
                          child: const Text('Make primary'),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
                          child: Text(
                            'Primary',
                            style: context.text.bodySmall
                                ?.copyWith(color: context.scheme.onSurfaceVariant),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: Spacing.sm),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  static String _customerBlurb(IntakeDraft draft) {
    final customer = draft.customer!;
    final parts = <String>[
      if (customer.code?.trim().isNotEmpty ?? false) customer.code!.trim(),
      customer.currency,
      if (customer.gstin?.trim().isNotEmpty ?? false) 'GSTIN ${customer.gstin!.trim()}',
    ];
    return parts.join(' · ');
  }

  static String _filenameFor(IntakeDraft draft, JobReference reference) {
    for (final attachment in draft.attachments) {
      if (attachment.id == reference.attachmentId) return attachment.filename;
    }
    return 'Awaiting a file';
  }

  static String? _primaryAttachmentId(IntakeDraft draft) {
    for (final reference in draft.references) {
      if (reference.isPrimary) return reference.attachmentId;
    }
    return null;
  }
}
