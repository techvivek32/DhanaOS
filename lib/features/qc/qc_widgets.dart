/// The shop-floor pieces QC and certification share, plus the checklist row itself.
///
/// [ShopNote], [ShopFooter], [ShopJobLine] and [ShopSpinner] are named for the shop floor rather
/// than for QC on purpose: the certification screen needs exactly the same four, and a second
/// copy of a bordered warning strip is how the mockups ended up rendering "In Production" three
/// different colours across the corpus. `features/certification` imports them from here.
///
/// [QcChecklistTile] is the one genuinely QC-specific widget. It renders three states, not two —
/// `passed == null` is "not yet checked", which is a different fact from "checked and failed" —
/// and it carries the real evidence control the mockup's dropzone never had behind it.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/qc/qc_gateway.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

// ================================================================= notes

/// What a strip of prose is doing on the screen.
enum ShopNoteTone {
  /// Context the operator did not ask for but needs.
  info,

  /// What pressing the button will do. Gold, the house milestone colour.
  consequence,

  /// Something that will bite later — an out-of-tolerance weight, a missing certificate.
  risk,

  /// A rule that has been satisfied.
  good,
}

/// A bordered line of prose. Every "here is why" on these screens goes through it, so no screen
/// invents its own warning treatment.
final class ShopNote extends StatelessWidget {
  const ShopNote({
    super.key,
    required this.text,
    this.tone = ShopNoteTone.info,
    this.icon,
    this.action,
  });

  final String text;
  final ShopNoteTone tone;
  final IconData? icon;

  /// A single affordance on the right — "Record it", "Refresh".
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    final (Color background, Color foreground, IconData glyph) = switch (tone) {
      ShopNoteTone.info => (
          dh.surfaceContainerLow,
          scheme.onSurfaceVariant,
          Icons.info_outline_rounded,
        ),
      ShopNoteTone.consequence => (
          dh.gold.withValues(alpha: 0.14),
          dh.goldText,
          Icons.bolt_outlined,
        ),
      ShopNoteTone.risk => (
          scheme.errorContainer,
          scheme.onErrorContainer,
          Icons.warning_amber_rounded,
        ),
      ShopNoteTone.good => (
          dh.successContainer,
          dh.success,
          Icons.check_circle_outline_rounded,
        ),
    };

    return Container(
      padding: const EdgeInsets.all(Spacing.sm + Spacing.xs),
      decoration: BoxDecoration(
        color: background,
        borderRadius: Radii.rMd,
        border: Border.all(color: dh.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon ?? glyph, size: 16, color: foreground),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(text, style: context.text.bodySmall?.copyWith(color: foreground)),
          ),
          if (action != null) ...[
            const SizedBox(width: Spacing.sm),
            action!,
          ],
        ],
      ),
    );
  }
}

// ================================================================= footer

/// The pinned action bar. A control that is shut always says why, directly above itself.
final class ShopFooter extends StatelessWidget {
  const ShopFooter({
    super.key,
    required this.children,
    this.blockedReason,
    this.note,
    this.progress,
  });

  final List<Widget> children;

  /// Rendered as a risk note above the buttons — [QcInspection.authorizationBlockedReason] and
  /// friends are already written from the operator's side.
  final String? blockedReason;

  /// Small print under the buttons: what pressing one will do.
  final String? note;

  /// Set while a file is in flight — 'Uploading qc_weight_dh_2026_01842.jpg'.
  final String? progress;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: dh.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (progress != null) ...[
                Row(
                  children: [
                    const ShopSpinner(size: 14),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        progress!,
                        style: AppTheme.mono(size: 11, color: scheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.sm + Spacing.xs),
              ],
              if (blockedReason != null) ...[
                ShopNote(text: blockedReason!, tone: ShopNoteTone.risk),
                const SizedBox(height: Spacing.sm + Spacing.xs),
              ],
              ...children,
              if (note != null) ...[
                const SizedBox(height: Spacing.sm),
                Text(
                  note!,
                  textAlign: TextAlign.center,
                  style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The in-button spinner, sized to sit inside a `FilledButton.icon` without resizing it.
final class ShopSpinner extends StatelessWidget {
  const ShopSpinner({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: const CircularProgressIndicator(strokeWidth: 2),
      );
}

// ================================================================= job identity line

/// D-001's code in the mono face, the working title beside it, and the priority.
final class ShopJobLine extends StatelessWidget {
  const ShopJobLine({
    super.key,
    required this.code,
    required this.title,
    this.customerName,
    this.priority,
    this.trailing,
  });

  /// 'DH-2026-01842'. Monospaced — it is an identifier, and operators read it down a column.
  final String code;
  final String title;
  final String? customerName;
  final Priority? priority;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    code,
                    style: AppTheme.mono(
                      size: 12,
                      weight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (priority != null) ...[
                    const SizedBox(width: Spacing.sm),
                    PriorityChip(priority!, dense: true, showStandard: false),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                title,
                style: context.text.headlineSmall?.copyWith(color: scheme.onSurface),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (customerName != null) ...[
                const SizedBox(height: 2),
                Text(
                  customerName!,
                  style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: Spacing.sm),
          trailing!,
        ],
      ],
    );
  }
}

// ================================================================= file capture

/// Where a shop-floor file comes from.
///
/// A voice note is deliberately absent. It satisfies the intake capture gate (D-011 rule 4) but
/// not this one: QC evidence and a certificate scan are things a later reader has to be able to
/// *look* at.
enum ShopFileSource {
  camera('Take a photo', Icons.photo_camera_outlined, 'The piece on the bench, under the loupe'),
  gallery('Choose a photo', Icons.photo_library_outlined, 'Something already on this device'),
  file('Attach a file', Icons.attach_file_rounded, 'A scan, a report, a printout');

  const ShopFileSource(this.label, this.icon, this.blurb);

  final String label;
  final IconData icon;
  final String blurb;
}

/// A file chosen on the device, before it has an attachment id.
final class PickedFile {
  const PickedFile(this.file, this.filename);

  final File file;

  /// The name the operator will recognise in the file list.
  final String filename;
}

/// Ask where the file is coming from. Null when the operator backed out.
Future<ShopFileSource?> pickShopFileSource(
  BuildContext context, {
  required String title,
  required String blurb,
  bool allowFiles = true,
}) {
  final sources = allowFiles
      ? ShopFileSource.values
      : [ShopFileSource.camera, ShopFileSource.gallery];

  return showModalBottomSheet<ShopFileSource>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: sheetContext.text.headlineSmall
                  ?.copyWith(color: sheetContext.scheme.onSurface),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              blurb,
              style: sheetContext.text.bodySmall
                  ?.copyWith(color: sheetContext.scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.md),
            for (final source in sources) ...[
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

/// Run the chosen picker. Returns null when the operator cancelled inside it.
///
/// Throws a [StorageFailure] when the picker itself could not open — a denied camera permission
/// is the common one, and "nothing happened" is not something an operator can act on. Takes no
/// [BuildContext] on purpose, so no caller has to reason about a context that crossed an await.
Future<PickedFile?> takeShopFile(ShopFileSource source) => switch (source) {
      ShopFileSource.camera => _pickPhoto(ImageSource.camera),
      ShopFileSource.gallery => _pickPhoto(ImageSource.gallery),
      ShopFileSource.file => _pickFile(),
    };

Future<PickedFile?> _pickPhoto(ImageSource source) async {
  try {
    // 88 keeps a 12MP shop photo under a megabyte, which matters on a 4G upload and loses
    // nothing an inspector or an auditor will ever look at.
    final shot = await ImagePicker().pickImage(source: source, imageQuality: 88);
    return shot == null ? null : PickedFile(File(shot.path), shot.name);
  } on Exception catch (error, stack) {
    Error.throwWithStackTrace(
      StorageFailure(
        message: source == ImageSource.camera
            ? 'The camera could not be opened. Check that DhanaOS has camera permission in '
                'Android settings, then try again.'
            : 'The photo library could not be opened. Check that DhanaOS has photo permission '
                'in Android settings.',
        detail: '$error',
        code: 'picker_unavailable',
      ),
      stack,
    );
  }
}

Future<PickedFile?> _pickFile() async {
  try {
    final chosen = await FilePicker.platform.pickFiles();
    final files = chosen?.files ?? const <PlatformFile>[];
    if (files.isEmpty) return null;
    final first = files.first;
    final path = first.path;
    return path == null ? null : PickedFile(File(path), first.name);
  } on Exception catch (error, stack) {
    Error.throwWithStackTrace(
      StorageFailure(
        message: 'The file browser could not be opened. Take a photo instead.',
        detail: '$error',
        code: 'file_picker_unavailable',
      ),
      stack,
    );
  }
}

// ================================================================= attempt chip

/// 'Attempt 2' — so an inspector never mistakes a reinspection for a fresh piece.
///
/// D-006: a reinspection after rework is its own `qc_inspections` row, not an overwrite of the
/// failure, which is the only reason this can be shown at all.
final class QcAttemptChip extends StatelessWidget {
  const QcAttemptChip(this.inspection, {super.key, this.dense = false});

  final QcInspection inspection;
  final bool dense;

  @override
  Widget build(BuildContext context) => StatusChip(
        label: 'Attempt ${inspection.attempt}',
        tone: inspection.isReinspection ? ChipTone.warning : ChipTone.neutral,
        mono: true,
        dense: dense,
        tooltip: inspection.isReinspection
            ? 'The piece failed a previous inspection and came back from rework. The failed '
                'attempt stays on the record.'
            : 'First inspection of this piece.',
      );
}

// ================================================================= the checklist row

/// One line of the inspection.
///
/// The mockup's version was a tick and a label. This one carries four things it did not:
///
///  * **Three states.** Null is "not yet checked"; false is "checked and failed". A two-state
///    tick cannot express the difference, which is why its 5/5 counter could not be trusted.
///  * **The binding figure.** 'Target: 4.8 g Pt 950. Allowable variance: ± 0.2 g.' comes off the
///    job's own metal spec, not off a hardcoded string.
///  * **The D-009 citation**, where one governs the line.
///  * **Real evidence.** The mockup's "inspection evidence" dropzone had no file input at all.
final class QcChecklistTile extends StatelessWidget {
  const QcChecklistTile({
    super.key,
    required this.item,
    required this.position,
    this.plan,
    this.requirement,
    this.evidence,
    this.evidenceUrl,
    this.checkedByName,
    this.onAnswer,
    this.onClear,
    this.onAddEvidence,
    this.onOpenEvidence,
    this.busy = false,
    this.readOnly = false,
  });

  final QcChecklistItem item;

  /// 1-based, so the row reads '3 · All stones secure' the way an inspector calls it out.
  final int position;

  /// The generated plan behind the stored row, for the helper and the critical flag.
  final QcChecklistPlan? plan;

  final Requirement? requirement;

  /// The uploaded evidence row, when there is one.
  final Attachment? evidence;

  /// A short-lived signed URL for the thumbnail. Signed, never public — QC evidence sits in the
  /// `vault` bucket and never reaches the portal.
  final String? evidenceUrl;

  final String? checkedByName;

  /// Pass true or false. Bound to the segmented control.
  final ValueChanged<bool>? onAnswer;

  /// Back to "not yet checked", which is what an inspector needs when they tick the wrong row.
  final VoidCallback? onClear;

  final VoidCallback? onAddEvidence;
  final VoidCallback? onOpenEvidence;

  final bool busy;

  /// An authorised or failed attempt is the record of what was decided. Reworking its ticks
  /// would rewrite history rather than move the job forward.
  final bool readOnly;

  bool get _answerable => !busy && !readOnly && onAnswer != null;

  void _answer(bool passed) {
    if (!_answerable) return;
    onAnswer!(passed);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final critical = plan?.critical ?? false;

    final accent = switch (item.passed) {
      true => dh.success,
      false => scheme.error,
      null => critical ? dh.gold : null,
    };

    return DhCard(
      tone: DhCardTone.inset,
      accent: accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$position',
                style: AppTheme.mono(
                  size: 12,
                  weight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.label,
                      style: context.text.titleMedium?.copyWith(color: scheme.onSurface),
                    ),
                    if (plan?.helper != null) ...[
                      const SizedBox(height: Spacing.xs),
                      Text(
                        plan!.helper!,
                        style: context.text.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ] else if (item.helper != null) ...[
                      const SizedBox(height: Spacing.xs),
                      Text(
                        item.helper!,
                        style: context.text.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                    if (requirement != null) ...[
                      const SizedBox(height: Spacing.sm),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: ReqTag(
                          code: requirement!.code,
                          critical: requirement!.isCritical,
                          label: requirement!.label,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (item.isAnswered && !readOnly)
                IconButton(
                  onPressed: busy ? null : onClear,
                  tooltip: 'Clear this answer',
                  icon: const Icon(Icons.restart_alt_rounded, size: 18),
                ),
            ],
          ),
          const SizedBox(height: Spacing.sm + Spacing.xs),
          if (readOnly)
            _decidedLine(context)
          else
            DhSegmented<bool>(
              segments: [
                DhSegment<bool>(
                  value: true,
                  label: 'Pass',
                  icon: Icons.check_rounded,
                  enabled: _answerable,
                ),
                // D-006: the FAIL half of the control. The mockup's own JavaScript removed a
                // `bg-error` class in an else branch it could never reach, because no screen
                // ever offered this.
                DhSegment<bool>(
                  value: false,
                  label: 'Fail',
                  icon: Icons.close_rounded,
                  enabled: _answerable,
                  disabledReason: _answerable
                      ? null
                      : 'This inspection is closed. Open a reinspection to record a new result.',
                ),
              ],
              // Null highlights nothing, which is the honest rendering of "not yet checked".
              value: item.passed,
              onChanged: _answer,
              dense: true,
            ),
          if (item.isAnswered && checkedByName != null) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              '${item.isPassed ? 'Passed' : 'Failed'} by $checkedByName',
              style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: Spacing.sm + Spacing.xs),
          _evidence(context),
        ],
      ),
    );
  }

  Widget _decidedLine(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    return Row(
      children: [
        Icon(
          switch (item.passed) {
            true => Icons.check_circle_outline_rounded,
            false => Icons.cancel_outlined,
            null => Icons.remove_circle_outline_rounded,
          },
          size: 16,
          color: switch (item.passed) {
            true => dh.success,
            false => scheme.error,
            null => scheme.onSurfaceVariant,
          },
        ),
        const SizedBox(width: Spacing.sm),
        Text(
          switch (item.passed) {
            true => 'Passed',
            false => 'Failed',
            null => 'Never checked',
          },
          style: context.text.bodyMedium?.copyWith(
            color: switch (item.passed) {
              true => dh.success,
              false => scheme.error,
              null => scheme.onSurfaceVariant,
            },
          ),
        ),
      ],
    );
  }

  Widget _evidence(BuildContext context) {
    final file = evidence;
    if (file != null) {
      return AttachmentTile.row(
        item: AttachmentView(
          id: file.id,
          kind: file.kind,
          filename: file.filename,
          meta: file.metaLabel,
          thumbnail: evidenceUrl == null ? null : NetworkImage(evidenceUrl!),
        ),
        onOpen: onOpenEvidence,
      );
    }

    // D-006's smaller sibling: a failed line with no photo is an assertion, with one it is a
    // record. Said out loud rather than enforced — an inspector holding a piece that is visibly
    // wrong should not be blocked from saying so.
    if (item.needsEvidence) {
      return ShopNote(
        text: 'This line failed with no photo attached. Attach one so the bench can see the '
            'defect without coming to find you.',
        tone: ShopNoteTone.risk,
        action: readOnly
            ? null
            : TextButton(
                onPressed: busy ? null : onAddEvidence,
                child: const Text('Attach'),
              ),
      );
    }

    if (readOnly) return const SizedBox.shrink();

    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: busy ? null : onAddEvidence,
        icon: const Icon(Icons.add_a_photo_outlined, size: 18),
        label: const Text('Attach evidence'),
      ),
    );
  }
}
