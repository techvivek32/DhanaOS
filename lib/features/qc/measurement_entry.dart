/// The production measurement. **No screen in the 46 mockups captured one.**
///
/// `order_details` displayed the binding spec — "Target Weight 4.2g ±0.1g" — as the only
/// specification in the entire corpus rendered in gold, which is the source system saying as
/// plainly as it could that this is the number that governs the bench. It then made it read-only,
/// with a note in the same thread reading "Update spec sheet" and nowhere to do it. A shop that
/// cannot record what it actually made cannot answer why 0.4 g of gold is missing.
///
/// So this screen is net-new, and it captures three things the corpus never had:
///
///  * **The actual against the target**, with the verdict computed as the operator types rather
///    than discovered later. `stage_measurements.within_tol` is a generated column, so the
///    database agrees with what is on screen by construction.
///  * **Which stage it was taken at.** A variance that appears at casting is a different problem
///    from one that appears after polishing, and a single figure per job cannot tell them apart.
///  * **Scrap and loss** — filings, polishing loss, casting sprues. The mockups' own dashboard
///    raised stock mismatch alerts while nothing in the app recorded where metal went.
///
/// The target and tolerance are copied onto the row at the moment of measurement, so a later spec
/// edit cannot retroactively turn a passed measurement into a failed one.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/permissions.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/features/qc/qc_actions.dart';
import 'package:dhanaos/features/qc/qc_gateway.dart';
import 'package:dhanaos/features/qc/qc_widgets.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class MeasurementEntryScreen extends ConsumerStatefulWidget {
  const MeasurementEntryScreen({super.key, required this.jobId, this.stage});

  final String jobId;

  /// Which stage the measurement belongs to. Defaults to wherever the job is standing, because
  /// that is what it is nine times out of ten.
  final LifecycleStage? stage;

  static Future<void> push(
    BuildContext context, {
    required String jobId,
    LifecycleStage? stage,
  }) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MeasurementEntryScreen(jobId: jobId, stage: stage),
        ),
      );

  @override
  ConsumerState<MeasurementEntryScreen> createState() => _MeasurementEntryScreenState();
}

class _MeasurementEntryScreenState extends ConsumerState<MeasurementEntryScreen> {
  final _notes = TextEditingController();

  LifecycleStage? _stage;
  double _weightG = 0;
  double _scrapG = 0;
  PickedFile? _photo;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  /// Only the stages it makes sense to weigh at, and never a value the picker cannot show.
  LifecycleStage _stageFor(MeasurementContext data) {
    final chosen = _stage;
    if (chosen != null) return chosen;
    final wanted = widget.stage ?? data.defaultStage;
    return MeasurementContext.measurableStages.contains(wanted)
        ? wanted
        : LifecycleStage.qc;
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(measurementContextProvider(widget.jobId));

    return async.when(
      loading: () => const _Frame(
        child: Padding(
          padding: EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LoadingSkeleton(height: 72),
              SizedBox(height: Spacing.md),
              LoadingSkeleton.card(),
              SizedBox(height: Spacing.md),
              LoadingSkeleton.lines(count: 4),
            ],
          ),
        ),
      ),
      error: (error, _) => _Frame(
        child: ErrorState(
          title: 'The measurement sheet did not open',
          message: error is DhFailure
              ? error.message
              : 'DhanaOS could not read the job specification. Check the connection and try '
                  'again.',
          detail: error is DhFailure ? error.detail : error.toString(),
          onRetry: () => ref.invalidate(measurementContextProvider(widget.jobId)),
        ),
      ),
      data: _loaded,
    );
  }

  // -------------------------------------------------------------- loaded

  Widget _loaded(MeasurementContext data) {
    final permissions = ref.watch(permissionsProvider);
    final task = ref.watch(qcActionsProvider);
    final busy = task != null;
    final stage = _stageFor(data);

    return Scaffold(
      appBar: AppBar(title: const Text('Record a measurement')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.xl),
        children: [
          _header(data),
          const SizedBox(height: Spacing.md),
          _verdict(data),
          const SizedBox(height: Spacing.md),
          _form(data, stage: stage, busy: busy),
          const SizedBox(height: Spacing.md),
          _history(data, stage: stage),
        ],
      ),
      bottomNavigationBar: _footer(data, stage: stage, permissions: permissions, task: task),
    );
  }

  // -------------------------------------------------------------- header

  Widget _header(MeasurementContext data) {
    final dh = context.dh;
    return DhCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShopJobLine(
            code: data.job.displayCode,
            title: data.job.displayTitle,
            priority: data.job.priority,
          ),
          const SizedBox(height: Spacing.md),
          DataPairGrid(
            children: [
              // Gold, as the source system rendered it. This is the figure the bench is held to.
              DataPair.mono(
                label: 'Binding Spec',
                value: data.specLabel,
                emphasis: DataEmphasis.strong,
                valueColor: dh.goldText,
              ),
              DataPair.mono(label: 'Alloy', value: data.metal?.alloyLabel ?? '—'),
              DataPair.mono(
                label: 'Loss to date',
                value: data.hasScrap ? gramLabel(data.totalScrapG) : '—',
              ),
              DataPair.mono(
                label: 'Measurements',
                value: '${data.measurements.length}',
              ),
            ],
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- verdict

  /// The whole point of the screen: the verdict, live, before anything is written.
  Widget _verdict(MeasurementContext data) {
    final scheme = context.scheme;
    final dh = context.dh;
    final target = data.targetG;
    final tol = data.toleranceG;

    if (!data.hasSpec) {
      return const ShopNote(
        text: 'No target weight was agreed for this job, so nothing here can pass or fail. The '
            'reading is still worth recording — it is what a later variance is measured from.',
      );
    }

    if (_weightG <= 0) {
      return ShopNote(
        text: 'Target is ${gramLabel(target)}'
            '${tol == null ? ' with no agreed variance' : ' ${toleranceLabel(tol)}'}. '
            'Enter what the scale reads and the verdict appears here.',
      );
    }

    final variance = _weightG - target!;
    final within = tol == null || variance.abs() <= tol;
    final sign = variance > 0 ? '+' : '';

    return DhCard(
      accent: within ? dh.success : scheme.error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                within ? Icons.check_circle_outline_rounded : Icons.warning_amber_rounded,
                size: 20,
                color: within ? dh.success : scheme.error,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  within ? 'Within tolerance' : 'Out of tolerance',
                  style: context.text.headlineSmall?.copyWith(
                    color: within ? dh.success : scheme.error,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          DataPairGrid(
            children: [
              DataPair.mono(
                label: 'Actual',
                value: gramLabel(_weightG),
                emphasis: DataEmphasis.display,
              ),
              DataPair.mono(
                label: 'Variance',
                value: '$sign${trimDecimal(variance)} g',
                emphasis: DataEmphasis.display,
                valueColor: within ? dh.success : scheme.error,
              ),
            ],
          ),
          if (!within) ...[
            const SizedBox(height: Spacing.md),
            ShopNote(
              // The sign matters and the mockups never said so: heavy can be filed down, light
              // cannot be fixed at all.
              text: variance > 0
                  ? 'The piece is heavy by ${trimDecimal(variance)} g. That can usually be taken '
                      'off at the bench — say so in the note so the next operator knows why.'
                  : 'The piece is light by ${trimDecimal(variance.abs())} g. Weight cannot be '
                      'added back: this needs a decision before the piece goes any further.',
              tone: ShopNoteTone.risk,
            ),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------- form

  Widget _form(MeasurementContext data, {required LifecycleStage stage, required bool busy}) {
    return DhSectionCard(
      title: 'The reading',
      subtitle: 'Kept against the stage it was taken at, so a variance can be traced to where it '
          'appeared.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'TAKEN AT',
            style: context.text.labelSmall?.copyWith(color: context.scheme.onSurfaceVariant),
          ),
          const SizedBox(height: Spacing.sm),
          SelectableTileGroup<LifecycleStage>(
            values: MeasurementContext.measurableStages,
            selected: stage,
            dense: true,
            labelOf: (option) => option.label,
            // The last reading at each stage, so the picker tells the operator something instead
            // of just taking an answer.
            blurbOf: (option) {
              final last = data.latestFor(option);
              return last == null
                  ? null
                  : 'Last: ${gramLabel(last.weightG)} (${last.varianceLabel})';
            },
            enabledOf: (_) => !busy,
            onChanged: (option) => setState(() => _stage = option),
          ),
          const SizedBox(height: Spacing.md),
          StepperField(
            value: _weightG,
            onChanged: (value) => setState(() => _weightG = value),
            min: 0,
            max: 5000,
            // A bench scale resolves to a hundredth of a gram; the centre field is typable, so
            // the stepper is for nudging rather than for entering the whole figure.
            step: 0.01,
            decimals: 2,
            label: 'Actual weight',
            unit: Uom.gram.symbol,
            helperText: data.hasSpec
                ? 'Target ${data.specLabel}. Type the reading or nudge it.'
                : 'No target was agreed. Record what the scale says.',
            enabled: !busy,
          ),
          const SizedBox(height: Spacing.md),
          StepperField(
            value: _scrapG,
            onChanged: (value) => setState(() => _scrapG = value),
            min: 0,
            max: 5000,
            step: 0.01,
            decimals: 2,
            label: 'Loss and scrap',
            unit: Uom.gram.symbol,
            helperText: 'Filings, polishing loss and sprues. Leave at zero if none was recovered '
                'separately.',
            enabled: !busy,
          ),
          const SizedBox(height: Spacing.md),
          TextField(
            controller: _notes,
            enabled: !busy,
            minLines: 2,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Note',
              hintText: 'Heavy at the shank — taking 0.15 g off before setting.',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: Spacing.md),
          _photoBlock(busy: busy),
        ],
      ),
    );
  }

  Widget _photoBlock({required bool busy}) {
    final picked = _photo;
    if (picked == null) {
      return AddAttachmentTile(
        onTap: () => unawaited(_choosePhoto()),
        label: 'Photograph the scale',
        icon: Icons.photo_camera_outlined,
        height: 96,
        hint: 'Optional. A reading nobody can check later is a number, not a record.',
      );
    }
    // The file is held locally until the measurement is recorded — a photo with no reading behind
    // it is an orphan in the vault.
    return AttachmentTile.row(
      item: AttachmentView(
        id: picked.file.path,
        kind: AttachmentKind.qcEvidence,
        filename: picked.filename,
        meta: 'Scale reading · uploads with the reading',
      ),
      onRetake: busy ? null : () => unawaited(_choosePhoto()),
      onDelete: busy ? null : () => setState(() => _photo = null),
    );
  }

  // -------------------------------------------------------------- history

  Widget _history(MeasurementContext data, {required LifecycleStage stage}) {
    final rows = data.measurements;
    return DhSectionCard(
      title: 'Recorded so far',
      subtitle: rows.isEmpty
          ? null
          : '${rows.length} reading${rows.length == 1 ? '' : 's'} on this job'
              '${data.hasScrap ? ' · ${gramLabel(data.totalScrapG)} loss' : ''}',
      child: rows.isEmpty
          ? const EmptyState(
              compact: true,
              icon: Icons.scale_outlined,
              title: 'Nothing weighed yet',
              message: 'The first reading on this job will appear here, against the stage it was '
                  'taken at.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final row in rows) ...[
                  _MeasurementRow(
                    measurement: row,
                    highlighted: row.stage == stage,
                  ),
                  const SizedBox(height: Spacing.sm),
                ],
              ],
            ),
    );
  }

  // -------------------------------------------------------------- footer

  Widget _footer(
    MeasurementContext data, {
    required LifecycleStage stage,
    required Permissions permissions,
    required QcTask? task,
  }) {
    final busy = task != null;
    // Anyone who may work a job may weigh a piece — a bench operator recording the actual is the
    // whole point. QC authorisation is a different, narrower permission.
    final mayRecord = permissions.canEditJob || permissions.canAuthorizeQc;

    final blocked = !mayRecord
        ? permissions.blockReason(Capability.editJob)
        : _weightG <= 0
            ? 'Enter the weight the scale reads. A measurement of zero is not a measurement.'
            : null;

    return ShopFooter(
      blockedReason: blocked,
      progress: task == QcTask.measure && _photo != null
          ? 'Uploading ${_photo!.filename}'
          : null,
      note: data.hasSpec
          ? 'The target and tolerance are copied onto the record now, so a later spec change '
              'cannot rewrite this verdict.'
          : 'Recorded against ${stage.label}.',
      children: [
        FilledButton.icon(
          onPressed: busy || blocked != null ? null : () => unawaited(_record(data, stage)),
          icon: task == QcTask.measure
              ? const ShopSpinner()
              : const Icon(Icons.save_outlined, size: 18),
          label: Text('Record ${gramLabel(_weightG)} at ${stage.label}'),
        ),
      ],
    );
  }

  // -------------------------------------------------------------- actions

  Future<void> _choosePhoto() async {
    final source = await pickShopFileSource(
      context,
      title: 'Photograph the scale',
      blurb: 'It goes to the vault with the rest of the QC evidence.',
    );
    if (source == null || !mounted) return;

    final PickedFile? picked;
    try {
      picked = await takeShopFile(source);
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
      return;
    }
    if (picked == null || !mounted) return;
    setState(() => _photo = picked);
  }

  Future<void> _record(MeasurementContext data, LifecycleStage stage) async {
    final target = data.targetG;
    final tol = data.toleranceG;
    final variance = target == null ? null : _weightG - target;
    final within = variance == null || tol == null || variance.abs() <= tol;

    // A reading that misses the agreed tolerance is a decision, not a typo — so it is confirmed
    // before it goes on the record. One inside tolerance is not worth a dialog.
    if (!within) {
      final miss = variance!;
      final confirmed = await confirmAction(
        context,
        title: 'Record an out-of-tolerance weight?',
        message: 'The spec is ${data.specLabel}. You are recording ${gramLabel(_weightG)}, which '
            'is ${trimDecimal(miss.abs())} g ${miss > 0 ? 'heavy' : 'light'}.\n\n'
            'This goes on the job permanently and QC will see it. If it is a mis-read, fix the '
            'number instead.',
        confirmLabel: 'Record it anyway',
        cancelLabel: 'Go back and check',
      );
      if (!confirmed || !mounted) return;
    }

    final notes = _notes.text.trim();
    try {
      final measurement = await ref.read(qcActionsProvider.notifier).recordMeasurement(
            jobId: widget.jobId,
            stage: stage,
            weightG: _weightG,
            // Copied at the moment of measurement, not read back later.
            targetG: target,
            toleranceG: tol,
            scrapG: _scrapG > 0 ? _scrapG : null,
            notes: notes.isEmpty ? null : notes,
            photo: _photo?.file,
            photoFilename: _photo?.filename,
          );
      if (!mounted) return;
      setState(() {
        _photo = null;
        _notes.clear();
      });
      showDone(
        context,
        '${stage.label}: ${measurement.measurementLabel} recorded'
        '${measurement.isWithinTolerance ? '' : ' — outside tolerance'}.',
      );
      unawaited(Navigator.of(context).maybePop());
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }
}

// ================================================================= rows

final class _MeasurementRow extends StatelessWidget {
  const _MeasurementRow({required this.measurement, required this.highlighted});

  final StageMeasurement measurement;

  /// The stage currently selected in the form, so an operator sees the history they are adding to.
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final ok = measurement.isWithinTolerance;

    return DhCard(
      tone: highlighted ? DhCardTone.inset : DhCardTone.outline,
      accent: ok ? dh.success : scheme.error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusChip(label: measurement.stage.label, dense: true),
              const Spacer(),
              Text(
                measurement.varianceLabel,
                style: AppTheme.mono(
                  size: 12,
                  weight: FontWeight.w600,
                  color: ok ? dh.success : scheme.error,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            measurement.measurementLabel,
            style: AppTheme.mono(size: 13, color: scheme.onSurface),
          ),
          if ((measurement.scrapG ?? 0.0) > 0) ...[
            const SizedBox(height: 2),
            Text(
              'Loss ${gramLabel(measurement.scrapG)}',
              style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          if (measurement.notes != null && measurement.notes!.trim().isNotEmpty) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              measurement.notes!.trim(),
              style: context.text.bodySmall?.copyWith(color: scheme.onSurface),
            ),
          ],
        ],
      ),
    );
  }
}

final class _Frame extends StatelessWidget {
  const _Frame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Record a measurement')),
        body: child,
      );
}
