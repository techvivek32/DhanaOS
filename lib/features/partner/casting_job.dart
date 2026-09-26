/// The caster's job screen — and the one rule in the corpus worth porting verbatim.
///
/// **D-011 rule 1.** `caster_dashboard` shipped "Mark Complete" *disabled*, behind a mandatory
/// `accept="image/*"` upload, with the helper "Required before marking complete". Out of 46 screens
/// that was the single best idea in the whole export: the vendor cannot say the work is done
/// without leaving evidence that it is. It is preserved here exactly — the button's `onPressed` is
/// really null (not dimmed with `opacity`, the mistake the same corpus made on its shipping
/// screen), the helper sits attached to it in those words, and `fn_complete_stage` refuses the
/// transition server-side regardless, so the rule survives a rewrite of this file.
///
/// The spec card is read-only on purpose. Alloy, flask temperature and metal temperature are the
/// workshop's instruction, not the vendor's to edit — and the metal temperature is rendered as the
/// critical value because pouring 18K at 1020 °C and pouring it at 1200 °C are not equivalent
/// mistakes. What the caster writes is the evidence, the tree weight they actually pulled, and
/// issues.
///
/// "Report Issue" sits beside "Mark Complete" as a genuine 50/50 peer, which is how
/// `caster_dashboard` framed it — and unlike the mockup there is a screen behind it.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/storage.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/features/partner/partner_actions.dart';
import 'package:dhanaos/features/partner/partner_gateway.dart';
import 'package:dhanaos/features/partner/partner_surface.dart';
import 'package:dhanaos/features/partner/report_issue.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

/// A signed URL becomes an [ImageProvider]; an absent one becomes an absent thumbnail rather than
/// a broken tile. A file that could not be signed is simply missing from the map, so one bad
/// object does not blank the gallery.
ImageProvider? thumbnailFor(String? signedUrl) =>
    signedUrl == null || signedUrl.isEmpty ? null : NetworkImage(signedUrl);

final class CastingJobScreen extends ConsumerWidget {
  const CastingJobScreen({super.key, required this.jobId});

  final String jobId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(partnerJobBriefProvider(jobId));

    return ShopFloorSurface(
      child: async.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LoadingSkeleton(height: 28, width: 200),
              SizedBox(height: Spacing.md),
              LoadingSkeleton.card(),
              SizedBox(height: Spacing.md),
              LoadingSkeleton.card(),
            ],
          ),
        ),
        error: (error, _) => ErrorState(
          title: 'This job did not open',
          message: error is DhFailure
              ? error.message
              : 'DhanaOS could not read the job. Go back to your queue and open it again.',
          detail: error is DhFailure ? error.detail : error.toString(),
          onRetry: () => ref.invalidate(partnerJobBriefProvider(jobId)),
        ),
        data: (brief) => _Body(brief: brief),
      ),
    );
  }
}

// ================================================================= body

final class _Body extends ConsumerWidget {
  const _Body({required this.brief});

  final PartnerJobBrief brief;

  /// Convention 7: Postgres holds instants in UTC; the caster reads local time.
  static final _stamp = DateFormat('d MMM yyyy · HH:mm');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCasting = brief.stage.stage == LifecycleStage.casting;

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(partnerJobBriefProvider(brief.job.id)),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.xxl),
        children: [
          VendorJobLine(
            code: brief.job.displayCode,
            title: brief.job.displayTitle,
            priority: brief.job.priority,
            stage: brief.stage.stage,
            trailing: StatusChip.stage(brief.stage.state, dense: true),
          ),
          const SizedBox(height: Spacing.md),

          // D-002's 14-stage rail. A vendor seeing the whole pipeline is not a leak — it is how a
          // caster knows the piece goes to setting next and not straight out of the door.
          DhCard(
            padding: const EdgeInsets.symmetric(vertical: Spacing.md),
            child: JobStageRail(nodes: _railNodes(brief)),
          ),
          const SizedBox(height: Spacing.md),

          if (brief.openExceptions.isNotEmpty) ...[
            _OpenIssues(brief: brief),
            const SizedBox(height: Spacing.md),
          ],

          _Dates(brief: brief, stamp: _stamp),
          const SizedBox(height: Spacing.md),

          if (isCasting) ...[
            _CastingSpec(brief: brief),
            const SizedBox(height: Spacing.md),
          ],

          _References(brief: brief),
          const SizedBox(height: Spacing.md),

          if (isCasting) ...[
            _Evidence(brief: brief),
            const SizedBox(height: Spacing.md),
            _PourRecord(brief: brief),
            const SizedBox(height: Spacing.md),
          ],

          _Footer(brief: brief),
        ],
      ),
    );
  }

  /// The 14 rail nodes. Built here rather than on [PartnerJobBrief] because [StageNode] belongs to
  /// the component set, and a read model that returned one would make the data layer depend on the
  /// widget layer.
  ///
  /// An unseeded rail falls back to the single known position, so a draft — or a rail
  /// `fn_seed_job_stages` has not reached — cannot read as complete.
  static List<StageNode> _railNodes(PartnerJobBrief brief) {
    if (brief.rail.isEmpty) {
      return StageNode.railFor(
        active: brief.stage.stage,
        blocked: brief.stage.isBlocked,
      );
    }
    return [
      for (final row in brief.rail.stages)
        StageNode(
          stage: row.stage,
          state: row.state,
          // A dwell figure only means something on a stage that has actually been entered.
          detail: row.isClosed || row.isActive || row.isBlocked ? row.dwellLabel : null,
          isLate: row.isLate,
          withPartner: row.isWithPartner,
        ),
    ];
  }
}

// ================================================================= issues

final class _OpenIssues extends StatelessWidget {
  const _OpenIssues({required this.brief});

  final PartnerJobBrief brief;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return DhSectionCard(
      title: 'Open issues',
      leading: const Icon(Icons.report_problem_outlined),
      accent: scheme.error,
      subtitle: 'The workshop closes these. Reporting one does not stop you finishing the work.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final issue in brief.openExceptions) ...[
            DhCard(
              tone: DhCardTone.inset,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          issue.title,
                          style: context.text.titleMedium?.copyWith(color: scheme.onSurface),
                        ),
                      ),
                      const SizedBox(width: Spacing.sm),
                      SeverityChip(issue.severity, dense: true),
                    ],
                  ),
                  if (issue.detail != null && issue.detail!.trim().isNotEmpty) ...[
                    const SizedBox(height: Spacing.xs),
                    Text(
                      issue.detail!.trim(),
                      style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                  const SizedBox(height: Spacing.sm),
                  DataPair.timestamp(
                    label: 'Reported',
                    utc: issue.createdAt,
                    emphasis: DataEmphasis.quiet,
                  ),
                ],
              ),
            ),
            const SizedBox(height: Spacing.sm),
          ],
        ],
      ),
    );
  }
}

// ================================================================= dates

/// When the tree arrived and when it is promised back.
///
/// Deliberately the vendor's own two dates. `jobs.requested_delivery` is the customer's date and
/// is not a caster's business — the promise they were given is `job_stages.expected_at`, which is
/// also what `v_partner_queue.is_late` is computed against.
final class _Dates extends StatelessWidget {
  const _Dates({required this.brief, required this.stamp});

  final PartnerJobBrief brief;
  final DateFormat stamp;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final received = brief.receivedAt;
    final expected = brief.expectedAt;

    return DhCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DataPairGrid(
            columns: 2,
            children: [
              DataPair.mono(
                label: 'Received',
                value:
                    received == null ? DataPair.placeholder : stamp.format(received.toLocal()),
                icon: Icons.inbox_outlined,
              ),
              DataPair.mono(
                label: 'Promised back',
                value:
                    expected == null ? DataPair.placeholder : stamp.format(expected.toLocal()),
                icon: Icons.event_outlined,
                valueColor: brief.isLate ? scheme.error : null,
                emphasis: DataEmphasis.strong,
              ),
            ],
          ),
          if (brief.isLate) ...[
            const SizedBox(height: Spacing.sm + Spacing.xs),
            const GateNote(
              tone: GateTone.risk,
              icon: Icons.schedule_outlined,
              reason: 'This stage is past the date it was promised back. If it is going to slip '
                  'further, report an issue so the workshop can tell the client.',
            ),
          ],
        ],
      ),
    );
  }
}

// ================================================================= the spec card

/// The workshop's instruction, read-only.
///
/// `caster_dashboard` drew this as a card, not a form, and that is correct: a vendor pours what
/// they were told to pour. The metal temperature is the critical value.
final class _CastingSpec extends StatelessWidget {
  const _CastingSpec({required this.brief});

  final PartnerJobBrief brief;

  @override
  Widget build(BuildContext context) {
    final casting = brief.casting;
    final hallmark = brief.metal?.hallmark?.trim();
    final alloyNotes = brief.metal?.alloyNotes?.trim();
    final workshopNotes = casting?.notes?.trim();

    return DhSectionCard(
      title: 'Casting spec',
      leading: const Icon(Icons.local_fire_department_outlined),
      subtitle: 'Set by the workshop. If any of it looks wrong, report an issue rather than '
          'pouring it.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: CriticalValue.hazard(
                  label: 'Metal temp',
                  value: casting?.metalTempC == null
                      ? DataPair.placeholder
                      : '${casting!.metalTempC} °C',
                  caption: casting?.metalTempC == null
                      ? 'Not specified — ask before you pour.'
                      : 'Pour at this temperature.',
                ),
              ),
              const SizedBox(width: Spacing.sm + Spacing.xs),
              Expanded(
                child: CriticalValue(
                  label: 'Flask temp',
                  value: casting?.flaskTempC == null
                      ? DataPair.placeholder
                      : '${casting!.flaskTempC} °C',
                  icon: Icons.thermostat_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          DataPairGrid(
            columns: 2,
            children: [
              DataPair.mono(label: 'Alloy', value: brief.alloyLabel),
              // The binding weight. `order_details` rendered this in gold as the one spec that
              // governs the bench, then made it read-only with nowhere to record the actual —
              // which is what the pour record below fixes.
              DataPair.mono(
                label: 'Target weight',
                value: brief.targetWeightLabel,
                emphasis: DataEmphasis.strong,
              ),
              if (hallmark != null && hallmark.isNotEmpty)
                DataPair.mono(label: 'Hallmark', value: hallmark),
              DataPair.mono(label: 'Pieces', value: '${brief.job.quantity}'),
            ],
          ),
          if (alloyNotes != null && alloyNotes.isNotEmpty) ...[
            const SizedBox(height: Spacing.md),
            DataPair(label: 'Alloy notes', value: alloyNotes, maxLines: 4),
          ],
          if (workshopNotes != null && workshopNotes.isNotEmpty) ...[
            const SizedBox(height: Spacing.md),
            DataPair(label: 'Workshop notes', value: workshopNotes, maxLines: 6),
          ],
        ],
      ),
    );
  }
}

// ================================================================= references

/// What the vendor works from.
///
/// The mesh gets its own row: a render is a picture and you cannot grow a tree from it, so
/// whether the model is there is the fact a caster needs and a thumbnail grid buries it.
final class _References extends ConsumerWidget {
  const _References({required this.brief});

  final PartnerJobBrief brief;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final images = brief.images;
    final model = brief.model;

    return DhSectionCard(
      title: 'Reference files',
      leading: const Icon(Icons.view_in_ar_outlined),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (model != null) ...[
            AttachmentTile.row(
              item: AttachmentView(
                id: model.id,
                kind: model.kind,
                filename: model.filename,
                meta: model.metaLabel,
              ),
              onOpen: () => unawaited(_copyLink(context, ref, model)),
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              'Tap the mesh to copy a download link for the workstation.',
              style: context.text.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.sm + Spacing.xs),
          ],
          if (images.isEmpty && model == null)
            const EmptyState(
              compact: true,
              icon: Icons.image_not_supported_outlined,
              title: 'No reference files yet',
              message: 'The workshop attaches the CAD renders and the mesh to the job. Ask them '
                  'for the model before you build the tree.',
            )
          else if (images.isNotEmpty)
            AttachmentGrid(
              items: [
                for (final file in images)
                  AttachmentView(
                    id: file.id,
                    kind: file.kind,
                    filename: file.filename,
                    meta: file.metaLabel,
                    thumbnail: thumbnailFor(brief.urlFor(file)),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// A mesh cannot be previewed in-app and this dependency set carries no share sheet, so the
  /// useful thing is a link the caster can paste into a browser on the machine that drives the
  /// printer. Signed, never public: thirty minutes is long enough to open it and short enough
  /// that a link pasted into a chat is dead before it leaves the building.
  Future<void> _copyLink(BuildContext context, WidgetRef ref, Attachment file) async {
    try {
      final url = await ref.read(attachmentStoreProvider).signedUrl(file);
      await Clipboard.setData(ClipboardData(text: url));
      if (!context.mounted) return;
      showDone(context, 'Link copied. Paste it in a browser — it expires in 30 minutes.');
    } on DhFailure catch (failure) {
      if (!context.mounted) return;
      showFailure(context, failure);
    }
  }
}

// ================================================================= D-011 rule 1

/// The mandatory casting photo.
///
/// This section is the rule. Nothing here is optional and nothing here is decorative: until an
/// `attachments` row of kind `casting_photo` is pointed at by `casting_params.photo_id`, the
/// footer's primary action is disabled and `fn_complete_stage` refuses the transition anyway.
final class _Evidence extends ConsumerWidget {
  const _Evidence({required this.brief});

  final PartnerJobBrief brief;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = ref.watch(partnerActionsProvider);
    final busy = task != null;
    final uploading = task == PartnerTask.photo;
    final evidence = brief.evidence;
    final dh = context.dh;

    return DhSectionCard(
      title: 'Casting evidence',
      leading: const Icon(Icons.photo_camera_outlined),
      accent: evidence == null ? dh.gold : dh.success,
      subtitle: evidence == null
          // The mockup's own helper, kept word for word.
          ? 'Required before marking complete'
          : 'On file. You can retake it while the stage is still open.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (evidence != null)
            AttachmentTile(
              item: AttachmentView(
                id: evidence.id,
                kind: evidence.kind,
                filename: evidence.filename,
                meta: evidence.metaLabel,
                thumbnail: thumbnailFor(brief.evidenceUrl),
              ),
              onRetake:
                  busy || brief.isClosed ? null : () => unawaited(_capture(context, ref)),
            )
          else
            // Held shut by ignoring the gesture rather than by handing the tile a no-op callback:
            // a control that looks live and does nothing is the exact defect this screen exists
            // to avoid repeating.
            IgnorePointer(
              ignoring: busy,
              child: Opacity(
                opacity: busy ? 0.6 : 1,
                child: AddAttachmentTile(
                  onTap: () => unawaited(_capture(context, ref)),
                  icon: Icons.photo_camera_outlined,
                  label: uploading ? 'Uploading the photo…' : 'Photograph the cast tree',
                  hint: 'JPG or PNG. Show the whole tree with the sprues attached.',
                  height: 132,
                ),
              ),
            ),
          if (evidence == null) ...[
            const SizedBox(height: Spacing.sm + Spacing.xs),
            const GateNote(
              icon: Icons.photo_camera_outlined,
              reason: 'The workshop cannot check a casting it cannot see. One photo of the tree '
                  'with the sprues on is enough.',
            ),
          ],
        ],
      ),
    );
  }

  /// Camera or gallery. Both are offered because a shop-floor tablet often has no usable camera
  /// and the photo was taken on somebody's phone and shared onto the device.
  Future<void> _capture(BuildContext context, WidgetRef ref) async {
    final source = await showModalBottomSheet<_PhotoSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo now'),
              onTap: () => Navigator.of(sheetContext).pop(_PhotoSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose one from this device'),
              onTap: () => Navigator.of(sheetContext).pop(_PhotoSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !context.mounted) return;

    final ({File file, String filename})? picked;
    try {
      picked = await _pick(source);
    } on Object catch (error, stack) {
      if (!context.mounted) return;
      showFailure(context, toDhFailure(error, stack));
      return;
    }
    // Backing out of the camera is not a failure and owes the caster no message.
    if (picked == null || !context.mounted) return;

    try {
      await ref.read(partnerActionsProvider.notifier).attachPhoto(
            brief: brief,
            file: picked.file,
            filename: picked.filename,
          );
      if (!context.mounted) return;
      showDone(context, 'Photo on file. You can mark the stage complete now.');
    } on DhFailure catch (failure) {
      if (!context.mounted) return;
      showFailure(context, failure);
    }
  }

  static Future<({File file, String filename})?> _pick(_PhotoSource source) async {
    switch (source) {
      case _PhotoSource.camera:
        final shot = await ImagePicker().pickImage(
          source: ImageSource.camera,
          // A tree photo is evidence, not a print. 2000px is plenty, and it keeps the upload
          // inside a shop-floor connection.
          maxWidth: 2000,
          imageQuality: 85,
        );
        return shot == null ? null : (file: File(shot.path), filename: shot.name);
      case _PhotoSource.gallery:
        // file_picker 13's API is static and hands back the file itself. `FilePicker.platform`
        // and `FilePickerResult` are the 8.x shape and no longer exist — the pubspec pins >=13
        // because 8.x compiles against android-34 and fails the APK at checkDebugAarMetadata.
        final chosen = await FilePicker.pickFile(type: FileType.image);
        final path = chosen?.path;
        // A picked file with no path is a web result; this is an Android-first build, so there
        // would be nothing on disk to upload.
        return path == null ? null : (file: File(path), filename: chosen!.name);
    }
  }
}

enum _PhotoSource { camera, gallery }

// ================================================================= the pour record

/// What the caster actually pulled off the tree.
///
/// NO screen in the 46 mockups captured a production measurement: `order_details` showed the
/// binding spec as read-only while a note in the same thread said "Update spec sheet". This is the
/// vendor half of that missing surface — the tree weight, against the target the spec set.
final class _PourRecord extends ConsumerStatefulWidget {
  const _PourRecord({required this.brief});

  final PartnerJobBrief brief;

  @override
  ConsumerState<_PourRecord> createState() => _PourRecordState();
}

class _PourRecordState extends ConsumerState<_PourRecord> {
  late double _weight = widget.brief.casting?.treeWeightG ?? 0;
  late final TextEditingController _notes =
      TextEditingController(text: widget.brief.casting?.notes ?? '');

  @override
  void didUpdateWidget(_PourRecord old) {
    super.didUpdateWidget(old);
    // The brief is re-read after every write. Adopting the server's figure keeps the field from
    // quietly disagreeing with what was saved.
    final saved = widget.brief.casting?.treeWeightG;
    if (saved != null && old.brief.casting?.treeWeightG != saved) _weight = saved;
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  bool get _dirty {
    final saved = widget.brief.casting;
    final savedWeight = saved?.treeWeightG ?? 0;
    final savedNotes = saved?.notes?.trim() ?? '';
    return _weight != savedWeight || _notes.text.trim() != savedNotes;
  }

  @override
  Widget build(BuildContext context) {
    final task = ref.watch(partnerActionsProvider);
    final busy = task != null;
    final saving = task == PartnerTask.record;
    final closed = widget.brief.isClosed;

    return DhSectionCard(
      title: 'What you pulled',
      leading: const Icon(Icons.scale_outlined),
      subtitle: 'Target ${widget.brief.targetWeightLabel}. The bench checks the returned casting '
          'against this figure first.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StepperField(
            value: _weight,
            onChanged: (value) => setState(() => _weight = value),
            max: 500,
            step: 0.1,
            decimals: 2,
            label: 'Tree weight',
            unit: 'g',
            enabled: !busy && !closed,
            helperText: 'Weigh the tree before you cut the sprues.',
          ),
          const SizedBox(height: Spacing.md),
          TextField(
            controller: _notes,
            minLines: 2,
            maxLines: 5,
            enabled: !busy && !closed,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Notes for the workshop',
              hintText: 'Porosity on two prongs, moved the sprue placement…',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: Spacing.md),
          OutlinedButton.icon(
            onPressed: busy || closed || !_dirty ? null : () => unawaited(_save()),
            icon: saving ? const ButtonSpinner() : const Icon(Icons.save_outlined, size: 18),
            label: Text(_dirty ? 'Save the pour record' : 'Saved'),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    try {
      await ref.read(partnerActionsProvider.notifier).recordPour(
            brief: widget.brief,
            treeWeightG: _weight <= 0 ? null : _weight,
            notes: _notes.text.trim(),
          );
      if (!mounted) return;
      showDone(context, 'Pour record saved.');
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }
}

// ================================================================= the two actions

/// "Mark Complete" and "Report Issue", side by side.
///
/// The mockup framed the exception path as a 50/50 peer of the happy path, and that framing is
/// right: on a shop floor the two outcomes of a shift are "it is done" and "something went wrong",
/// and burying the second behind a menu is how a delay reaches the customer instead of the
/// workshop.
final class _Footer extends ConsumerWidget {
  const _Footer({required this.brief});

  final PartnerJobBrief brief;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = ref.watch(partnerActionsProvider);
    final busy = task != null;
    final blocked = brief.completeBlockedReason;
    final canComplete = brief.canComplete && !busy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // D-011 rule 1: the real `onPressed` is null. `shipping_dispatch` toggled opacity classes
        // and never set `.disabled`, so its gate could be pressed straight through — that is the
        // failure mode this line exists to rule out.
        FilledButton.icon(
          onPressed: canComplete ? () => unawaited(_complete(context, ref)) : null,
          icon: task == PartnerTask.complete
              ? const ButtonSpinner()
              : const Icon(Icons.check_rounded, size: 18),
          label: Text(
            brief.isClosed
                ? '${brief.stage.stage.label} is closed'
                : 'Mark ${brief.stage.stage.label} complete',
          ),
        ),
        if (blocked != null) ...[
          const SizedBox(height: Spacing.sm),
          GateNote(
            reason: blocked,
            icon: brief.needsCastingEvidence
                ? Icons.photo_camera_outlined
                : Icons.check_circle_outline_rounded,
            tone: brief.isClosed ? GateTone.calm : GateTone.blocked,
          ),
        ],
        const SizedBox(height: Spacing.md),
        OutlinedButton.icon(
          onPressed: busy
              ? null
              : () => unawaited(ReportIssueScreen.push(context, jobId: brief.job.id)),
          icon: const Icon(Icons.report_problem_outlined, size: 18),
          label: const Text('Report an issue'),
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          'An issue blocks the stage on the workshop board and puts it in their action queue. '
          'Use it for a delay, a bad mould, or anything in the spec that does not add up.',
          style: context.text.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Future<void> _complete(BuildContext context, WidgetRef ref) async {
    final warning = brief.openIssueWarning;
    final agreed = await confirmAction(
      context,
      title: 'Mark ${brief.stage.stage.label} complete?',
      message: [
        'This hands the work back to the workshop and moves the job on. It cannot be undone from '
            'here.',
        if (brief.casting?.treeWeightG != null)
          'Recorded tree weight: ${gramLabel(brief.casting!.treeWeightG)}.',
        if (warning != null) warning,
      ].join('\n\n'),
      confirmLabel: 'Yes, it is done',
      cancelLabel: 'Not yet',
    );
    if (!agreed || !context.mounted) return;

    try {
      await ref.read(partnerActionsProvider.notifier).completeStage(brief: brief);
      if (!context.mounted) return;
      showDone(context, '${brief.job.displayCode} handed back. It is off your queue.');
    } on DhFailure catch (failure) {
      if (!context.mounted) return;
      showFailure(context, failure);
    }
  }
}
