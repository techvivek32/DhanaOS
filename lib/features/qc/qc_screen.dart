/// Quality control. A rebuild of `quality_control`, which was the most confidently wrong screen
/// in the corpus.
///
/// What the source got right and is kept:
///
///  * **D-011 rule 3.** Authorisation enables only at a full checklist. Here the button is held
///    shut and says what would open it, because the fix is ticking a line the inspector is
///    already looking at — unlike a CAD rejection, where the rule is learned by pressing.
///  * A running counter above the list, which is the one number an inspector watches.
///
/// What it did not have, and a real inspection needs:
///
///  * **A checklist that belongs to this job.** The mockup's five items were a hardcoded list
///    with no relationship to what the shop had agreed to build. Here they are generated from
///    `acceptance_criteria`, carry the binding figure off the job's own metal spec, and cite
///    their D-009 requirement where one governs the line.
///  * **Evidence.** The "inspection evidence" dropzone had no file input at all behind it.
///  * **The FAIL path** (D-006). Its CSS carried a `bg-error` class that its own JavaScript
///    removed in an else branch nothing could reach: a failed state was designed and then left
///    with no button. Failing requires a defect reason, sends the job to rework, and a
///    reinspection is a new attempt rather than an overwrite.
///  * **A production measurement.** Nothing in 46 screens captured one, despite the target
///    weight being the only spec in the corpus rendered in gold. See `measurement_entry.dart`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:dhanaos/core/router.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/permissions.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/features/qc/measurement_entry.dart';
import 'package:dhanaos/features/qc/qc_actions.dart';
import 'package:dhanaos/features/qc/qc_gateway.dart';
import 'package:dhanaos/features/qc/qc_widgets.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class QcScreen extends ConsumerStatefulWidget {
  const QcScreen({super.key, required this.jobId});

  /// `jobs.id`. The route is `/qc/:jobId` — an inspection is addressed by the piece, not by the
  /// attempt, because an inspector opening the job wants whichever attempt is live.
  final String jobId;

  /// Open QC from the job detail screen, keeping the operator's place behind them.
  static Future<void> push(BuildContext context, String jobId) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => QcScreen(jobId: jobId)),
      );

  @override
  ConsumerState<QcScreen> createState() => _QcScreenState();
}

class _QcScreenState extends ConsumerState<QcScreen> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(qcBundleProvider(widget.jobId));

    return async.when(
      loading: () => const _Frame(
        child: Padding(
          padding: EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LoadingSkeleton(height: 72),
              SizedBox(height: Spacing.md),
              LoadingSkeleton(height: 40, radius: Radii.rMd),
              SizedBox(height: Spacing.md),
              LoadingSkeleton.card(),
              SizedBox(height: Spacing.md),
              LoadingSkeleton.list(count: 4),
            ],
          ),
        ),
      ),
      error: (error, _) => _Frame(
        child: ErrorState(
          title: 'This inspection did not open',
          message: error is DhFailure
              ? error.message
              : 'DhanaOS could not read the job. Check the shop Wi-Fi and try again — nothing '
                  'you ticked has been lost.',
          detail: error is DhFailure ? error.detail : error.toString(),
          onRetry: () => ref.invalidate(qcBundleProvider(widget.jobId)),
        ),
      ),
      data: _loaded,
    );
  }

  // -------------------------------------------------------------- loaded

  Widget _loaded(QcBundle bundle) {
    final permissions = ref.watch(permissionsProvider);
    final task = ref.watch(qcActionsProvider);
    final busy = task != null;
    final inspection = bundle.current;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Quality Control'),
        actions: [
          IconButton(
            onPressed: busy ? null : () => ref.invalidate(qcBundleProvider(widget.jobId)),
            tooltip: 'Re-read this inspection',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(qcBundleProvider(widget.jobId).future),
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.xl),
          children: [
            _header(bundle),
            const SizedBox(height: Spacing.md),
            if (bundle.rail.isSeeded) ...[
              JobStageRail.compact(nodes: _railNodes(bundle)),
              const SizedBox(height: Spacing.md),
            ],
            ..._banners(bundle),
            _measurementCard(bundle, busy: busy),
            const SizedBox(height: Spacing.md),
            if (inspection == null)
              _planPreview(bundle)
            else
              _checklist(bundle, inspection, permissions: permissions, busy: busy, task: task),
            if (bundle.earlierAttempts.isNotEmpty) ...[
              const SizedBox(height: Spacing.md),
              _history(bundle),
            ],
          ],
        ),
      ),
      bottomNavigationBar: _footer(bundle, permissions: permissions, task: task),
    );
  }

  List<StageNode> _railNodes(QcBundle bundle) => [
        for (final row in bundle.rail.stages)
          StageNode(
            stage: row.stage,
            state: row.state,
            detail: row.isActive ? row.dwellLabel : null,
            isLate: row.isLate,
            withPartner: row.isWithPartner,
          ),
      ];

  // -------------------------------------------------------------- header

  Widget _header(QcBundle bundle) {
    final inspection = bundle.current;
    final dh = context.dh;

    return DhCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShopJobLine(
            code: bundle.job.displayCode,
            title: bundle.job.displayTitle,
            priority: bundle.job.priority,
            trailing: inspection == null
                ? const StatusChip(label: 'Not started', dense: true)
                : StatusChip.qc(inspection.status, dense: true),
          ),
          const SizedBox(height: Spacing.md),
          DataPairGrid(
            children: [
              if (inspection != null)
                DataPair.custom(
                  label: 'Attempt',
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: QcAttemptChip(inspection, dense: true),
                  ),
                ),
              DataPair(
                label: 'Authority',
                value: bundle.acceptance?.authority.label ?? 'Not agreed',
                icon: Icons.gavel_rounded,
              ),
              DataPair(
                label: 'Inspector',
                value: inspection == null
                    ? 'Unassigned'
                    : bundle.nameFor(inspection.inspectorId, fallback: 'Unassigned'),
                icon: Icons.person_outline_rounded,
              ),
              DataPair.mono(
                label: 'Measured against',
                value: bundle.cad?.version ?? 'No locked CAD',
              ),
              // The one spec `order_details` rendered in gold. It is the figure that governs the
              // bench, so it keeps the house milestone colour here too.
              DataPair.mono(
                label: 'Target Weight',
                value: bundle.metal?.weightLabel ?? '—',
                emphasis: DataEmphasis.strong,
                valueColor: dh.goldText,
              ),
              DataPair.mono(
                label: 'Dim. Tolerance',
                value: bundle.acceptance == null
                    ? '—'
                    : '± ${mmLabel(bundle.acceptance!.effectiveToleranceMm)}',
              ),
            ],
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- banners

  List<Widget> _banners(QcBundle bundle) {
    final notes = <Widget>[];

    if (!bundle.hasAgreement) {
      notes.add(
        ShopNote(
          text: 'Nothing was agreed for this job at intake, so there is no checklist to '
              'generate. Fill in the quality step on the job order first.',
          tone: ShopNoteTone.risk,
          action: TextButton(
            onPressed: () => context.go(Paths.job(bundle.job.id)),
            child: const Text('Open the job'),
          ),
        ),
      );
    }

    final advance = bundle.advanceNote;
    if (advance != null && bundle.hasAgreement) {
      notes.add(ShopNote(text: advance));
    }

    // Selecting `customer` as the authority inserts a portal approval gate before sign-off. The
    // mockups offered the option and had no such transition or screen; stating it is the least
    // this screen owes the inspector.
    if (bundle.needsCustomerGate) {
      notes.add(
        const ShopNote(
          text: 'The customer is the acceptance authority on this job. Your authorisation is the '
              'shop record; the piece is not released until the customer approves it in the '
              'portal.',
          tone: ShopNoteTone.consequence,
        ),
      );
    }

    final current = bundle.current;
    if (current != null && current.isFailed) {
      notes.add(
        ShopNote(
          text: 'Attempt ${current.attempt} failed. Defect recorded: '
              '${current.defectReason ?? 'no reason on file'}',
          tone: ShopNoteTone.risk,
          icon: Icons.report_gmailerrorred_rounded,
        ),
      );
    }

    if (current != null && current.isAuthorized) {
      notes.add(
        ShopNote(
          text: 'Authorised by ${bundle.nameFor(current.inspectorId)}. This attempt is the record '
              'of the sign-off and cannot be reworked — a further inspection is a new attempt.',
          tone: ShopNoteTone.good,
        ),
      );
    }

    return [
      for (final note in notes) ...[note, const SizedBox(height: Spacing.md)],
    ];
  }

  // -------------------------------------------------------------- measurement

  Widget _measurementCard(QcBundle bundle, {required bool busy}) {
    final latest = bundle.latestMeasurement;
    final dh = context.dh;

    return DhSectionCard(
      title: 'Production measurement',
      subtitle: 'What the piece actually weighs, against what was agreed.',
      action: TextButton.icon(
        onPressed: busy ? null : () => _openMeasurement(bundle),
        icon: const Icon(Icons.scale_outlined, size: 18),
        label: Text(latest == null ? 'Record' : 'Record another'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (latest == null)
            EmptyState(
              compact: true,
              icon: Icons.scale_outlined,
              title: bundle.measurementMissing
                  ? 'Nothing has been weighed yet'
                  : 'No measurement on file',
              message: bundle.measurementMissing
                  ? 'This job binds the bench to ${bundle.metal!.weightLabel}. Weigh the piece '
                      'and record the actual before you sign anything off.'
                  : 'Record the weight at any bench stage. It is kept against the stage it was '
                      'taken at, so a variance can be traced to where it appeared.',
            )
          else ...[
            DataPairGrid(
              children: [
                DataPair.mono(
                  label: 'Actual',
                  value: gramLabel(latest.weightG),
                  emphasis: DataEmphasis.strong,
                ),
                DataPair.mono(
                  label: 'Variance',
                  value: latest.varianceLabel,
                  emphasis: DataEmphasis.strong,
                  valueColor: latest.isWithinTolerance ? dh.success : context.scheme.error,
                ),
                DataPair.mono(label: 'Loss', value: gramLabel(latest.scrapG)),
                DataPair(label: 'Taken at', value: latest.stage.label),
                DataPair.timestamp(label: 'When', utc: latest.createdAt),
                DataPair(
                  label: 'By',
                  value: bundle.nameFor(latest.measuredBy),
                ),
              ],
            ),
            if (bundle.measurementOutOfTolerance) ...[
              const SizedBox(height: Spacing.md),
              const ShopNote(
                text: 'The recorded weight is outside the agreed tolerance. You can still pass '
                    'the piece — but the variance is on the record, so say why in the defect '
                    'note if you fail it, or in the thread if you pass it.',
                tone: ShopNoteTone.risk,
              ),
            ],
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------- plan preview

  Widget _planPreview(QcBundle bundle) {
    final plan = bundle.plan;
    if (plan.isEmpty) {
      return DhCard(
        child: EmptyState(
          compact: true,
          icon: Icons.fact_check_outlined,
          title: 'No checklist to generate',
          message: bundle.openBlockedReason ??
              'Every acceptance criterion on this job is turned off, so there is nothing to '
                  'inspect against.',
          actionLabel: 'Open the job order',
          onAction: () => context.go(Paths.job(bundle.job.id)),
        ),
      );
    }

    return DhSectionCard(
      title: 'Checklist to generate',
      subtitle: '${plan.length} checks, built from the acceptance criteria agreed at intake — '
          'not a fixed list.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < plan.length; i++) ...[
            if (i > 0) const SizedBox(height: Spacing.sm),
            _PlanLine(
              position: i + 1,
              line: plan[i],
              requirement: bundle.requirementFor(plan[i].requirementCode),
            ),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------- the checklist

  Widget _checklist(
    QcBundle bundle,
    QcInspection inspection, {
    required Permissions permissions,
    required bool busy,
    required QcTask? task,
  }) {
    final items = inspection.orderedItems;
    // An authorised or failed attempt is the record of what was decided. Reworking its ticks
    // would rewrite history rather than move the job forward.
    final readOnly = inspection.isAuthorized ||
        inspection.isFailed ||
        !(permissions.canAuthorizeQc || permissions.canEditJob);

    return DhSectionCard(
      title: 'Inspection',
      subtitle: 'Attempt ${inspection.attempt} · ${inspection.status.label}',
      action: _ProgressPill(inspection: inspection),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: Radii.rFull,
            child: LinearProgressIndicator(
              value: items.isEmpty ? 0.0 : inspection.passedCount / items.length,
              minHeight: 6,
              color: inspection.isFailed ? context.scheme.error : context.dh.success,
            ),
          ),
          const SizedBox(height: Spacing.md),
          if (items.isEmpty)
            const ShopNote(
              text: 'This inspection has no items, so it can never be authorised. Fail it with a '
                  'note and open a fresh attempt.',
              tone: ShopNoteTone.risk,
            )
          else
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const SizedBox(height: Spacing.sm),
              QcChecklistTile(
                item: items[i],
                position: i + 1,
                plan: bundle.planFor(items[i]),
                requirement: bundle.requirementOf(items[i]),
                evidence: bundle.evidenceOf(items[i]),
                evidenceUrl: bundle.evidenceUrlOf(items[i]),
                checkedByName: items[i].checkedBy == null
                    ? null
                    : bundle.nameFor(items[i].checkedBy),
                busy: busy,
                readOnly: readOnly,
                onAnswer: (passed) => unawaited(_answer(bundle, items[i], passed)),
                onClear: () => unawaited(_answer(bundle, items[i], null)),
                onAddEvidence: () => unawaited(_addEvidence(bundle, items[i])),
                onOpenEvidence: bundle.evidenceUrlOf(items[i]) == null
                    ? null
                    : () => unawaited(
                          _openEvidence(
                            bundle.evidenceOf(items[i])!,
                            bundle.evidenceUrlOf(items[i])!,
                          ),
                        ),
              ),
            ],
          if (task == QcTask.evidence) ...[
            const SizedBox(height: Spacing.md),
            const Row(
              children: [
                ShopSpinner(size: 14),
                SizedBox(width: Spacing.sm),
                Text('Uploading evidence'),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------- history

  Widget _history(QcBundle bundle) {
    return DhSectionCard(
      title: 'Earlier attempts',
      subtitle: 'D-006: a failed inspection is kept, never overwritten. This is why a defect can '
          'be traced after the piece has shipped.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final attempt in bundle.earlierAttempts) ...[
            _AttemptSummary(
              inspection: attempt,
              inspectorName: bundle.nameFor(attempt.inspectorId),
            ),
            const SizedBox(height: Spacing.sm),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------- footer

  Widget? _footer(
    QcBundle bundle, {
    required Permissions permissions,
    required QcTask? task,
  }) {
    final busy = task != null;
    final inspection = bundle.current;
    final mayWork = permissions.canAuthorizeQc || permissions.canEditJob;

    if (inspection == null) {
      if (!bundle.hasAgreement) return null;
      return ShopFooter(
        blockedReason: mayWork
            ? bundle.openBlockedReason
            : permissions.blockReason(Capability.authorizeQc),
        note: 'The checklist is generated from this job\'s own acceptance criteria. Opening it '
            'records you as the inspector.',
        children: [
          FilledButton.icon(
            onPressed: busy || !mayWork || !bundle.canOpenInspection
                ? null
                : () => unawaited(_open(bundle)),
            icon: task == QcTask.open
                ? const ShopSpinner()
                : const Icon(Icons.playlist_add_check_rounded, size: 18),
            label: Text('Generate the checklist · attempt ${bundle.nextAttempt}'),
          ),
        ],
      );
    }

    if (inspection.isFailed) {
      return ShopFooter(
        blockedReason: mayWork ? null : permissions.blockReason(Capability.authorizeQc),
        note: 'A reinspection is a new attempt. Attempt ${inspection.attempt} and its defect '
            'note stay on the record.',
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => context.go(Paths.job(bundle.job.id)),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('Open the job'),
                ),
              ),
              const SizedBox(width: Spacing.sm + Spacing.xs),
              Expanded(
                child: FilledButton.icon(
                  onPressed:
                      busy || !mayWork ? null : () => unawaited(_reinspect(bundle)),
                  icon: task == QcTask.reinspect
                      ? const ShopSpinner()
                      : const Icon(Icons.replay_rounded, size: 18),
                  label: Text('Reinspect · attempt ${bundle.nextAttempt}'),
                ),
              ),
            ],
          ),
        ],
      );
    }

    if (inspection.isAuthorized) {
      return ShopFooter(
        note: 'Signed off. The piece is released to ${_nextStageLabel(bundle)}.',
        children: [
          OutlinedButton.icon(
            onPressed: () => context.go(Paths.job(bundle.job.id)),
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: const Text('Open the job'),
          ),
        ],
      );
    }

    // D-011 rule 3: the authorisation is held shut until every line has passed, and the reason it
    // is shut is printed directly above it. Unlike a CAD rejection the fix is one tap away in the
    // list the inspector is already reading, so teaching by refusal would just be rude.
    final canAuthorize = permissions.canAuthorizeQc;
    return ShopFooter(
      blockedReason: canAuthorize
          ? inspection.authorizationBlockedReason
          : permissions.blockReason(Capability.authorizeQc),
      note: bundle.stageToClose == null
          ? bundle.advanceNote
          : 'Authorising closes the QC stage and moves the job to ${_nextStageLabel(bundle)}.',
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy || !canAuthorize ? null : () => unawaited(_fail(bundle)),
                icon: task == QcTask.fail
                    ? const ShopSpinner()
                    : const Icon(Icons.report_gmailerrorred_rounded, size: 18),
                label: const Text('Fail the piece'),
              ),
            ),
            const SizedBox(width: Spacing.sm + Spacing.xs),
            Expanded(
              child: FilledButton.icon(
                onPressed: busy || !canAuthorize || !inspection.canAuthorize
                    ? null
                    : () => unawaited(_authorize(bundle)),
                icon: task == QcTask.authorize
                    ? const ShopSpinner()
                    : const Icon(Icons.verified_rounded, size: 18),
                label: Text('Authorise ${inspection.progressLabel}'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _nextStageLabel(QcBundle bundle) =>
      bundle.rail.nextStage?.stage.label ?? LifecycleStage.cert.label;

  // -------------------------------------------------------------- actions

  Future<void> _open(QcBundle bundle) async {
    try {
      final inspection = await ref.read(qcActionsProvider.notifier).openInspection(bundle);
      if (!mounted) return;
      showDone(
        context,
        'Attempt ${inspection.attempt} open with ${inspection.items.length} checks.',
      );
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _answer(QcBundle bundle, QcChecklistItem item, bool? passed) async {
    try {
      await ref
          .read(qcActionsProvider.notifier)
          .setCheck(bundle: bundle, item: item, passed: passed);
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _addEvidence(QcBundle bundle, QcChecklistItem item) async {
    final source = await pickShopFileSource(
      context,
      title: 'Attach inspection evidence',
      blurb: 'It goes to the vault, not to the customer portal.',
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

    try {
      await ref.read(qcActionsProvider.notifier).attachEvidence(
            bundle: bundle,
            item: item,
            file: picked.file,
            filename: picked.filename,
          );
      if (!mounted) return;
      showDone(context, '${picked.filename} attached to "${item.label}".');
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _openEvidence(Attachment file, String url) => showDialog<void>(
        context: context,
        builder: (dialogContext) => Dialog(
          insetPadding: const EdgeInsets.all(Spacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(Spacing.md),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        file.filename,
                        style: AppTheme.mono(size: 12, color: dialogContext.scheme.onSurface),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.close_rounded),
                      tooltip: 'Close',
                    ),
                  ],
                ),
              ),
              Flexible(
                child: InteractiveViewer(
                  maxScale: 6,
                  child: Image.network(
                    url,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stack) => Padding(
                      padding: const EdgeInsets.all(Spacing.lg),
                      child: Text(
                        'The signed link for this file has expired. Pull to refresh the '
                        'inspection and open it again.',
                        style: context.text.bodyMedium,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: Spacing.md),
            ],
          ),
        ),
      );

  Future<void> _openMeasurement(QcBundle bundle) async {
    await MeasurementEntryScreen.push(
      context,
      jobId: bundle.job.id,
      stage: bundle.rail.activeLifecycle ?? LifecycleStage.qc,
    );
    if (!mounted) return;
    ref.invalidate(qcBundleProvider(widget.jobId));
  }

  /// D-011 rule 3's consequential half. The checklist is already full or the button would not be
  /// pressable, so the dialog's job is to say what the signature *does*.
  Future<void> _authorize(QcBundle bundle) async {
    final inspection = bundle.current;
    if (inspection == null) return;

    final lines = <String>[
      'This records your name against attempt ${inspection.attempt} of '
          '${bundle.job.displayCode} and cannot be undone.',
      if (bundle.stageToClose != null)
        'The QC stage closes and the job moves to ${_nextStageLabel(bundle)}.'
      else
        bundle.advanceNote ?? '',
      if (bundle.measurementOutOfTolerance)
        'The recorded weight is OUTSIDE the agreed tolerance '
            '(${bundle.latestMeasurement!.varianceLabel}). Passing it anyway is your call and it '
            'stays on the record.',
      if (bundle.measurementMissing)
        'No weight has ever been recorded on this job, although the spec binds the bench to '
            '${bundle.metal!.weightLabel}.',
      if (bundle.needsCustomerGate)
        'The customer is the acceptance authority here, so the piece still needs their approval '
            'in the portal before it ships.',
    ].where((line) => line.isNotEmpty).toList();

    final confirmed = await confirmAction(
      context,
      title: 'Authorise QC on ${bundle.job.displayCode}?',
      message: lines.join('\n\n'),
      confirmLabel: 'Authorise and release',
      cancelLabel: 'Keep inspecting',
    );
    if (!confirmed || !mounted) return;

    try {
      await ref.read(qcActionsProvider.notifier).authorize(bundle);
      if (!mounted) return;
      showDone(context, '${bundle.job.displayCode} is authorised and released.');
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  /// D-006 — the path the mockup designed and made unreachable.
  ///
  /// The defect reason is asked for before anything is written, the same asymmetry a CAD
  /// rejection carries: `qc_fail_needs_reason` refuses a blank one in Postgres, and the bench
  /// cannot rework a fault nobody described.
  Future<void> _fail(QcBundle bundle) async {
    final inspection = bundle.current;
    if (inspection == null) return;

    final failedLines = inspection.orderedItems.where((i) => i.isFailed).toList();
    final suggested = failedLines.isEmpty
        ? null
        : 'Failed: ${failedLines.map((i) => i.label).join('; ')}.';

    final reason = await promptForText(
      context,
      title: 'Fail ${bundle.job.displayCode}?',
      message: 'Name the defect. The piece goes back to the bench for rework and this text is '
          'what the bench reads — "failed QC" tells them nothing.'
          '${suggested == null ? '' : '\n\n$suggested'}',
      fieldLabel: 'Defect',
      hint: 'Prong 3 is short and the halo sits 0.3 mm proud on the east side.',
      submitLabel: 'Fail and send for rework',
      destructive: true,
    );
    if (reason == null || !mounted) return;

    final confirmed = await confirmAction(
      context,
      title: 'Send ${bundle.job.displayCode} back for rework?',
      message: 'Attempt ${inspection.attempt} is recorded as failed and stays on the record. The '
          'job status goes to Rework, which takes it out of the In QC count until a '
          'reinspection is opened.\n\n$reason',
      confirmLabel: 'Fail the piece',
      cancelLabel: 'Keep inspecting',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    try {
      await ref.read(qcActionsProvider.notifier).fail(bundle: bundle, defectReason: reason);
      if (!mounted) return;
      showDone(context, 'Attempt ${inspection.attempt} failed. The bench has it back.');
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _reinspect(QcBundle bundle) async {
    final confirmed = await confirmAction(
      context,
      title: 'Open attempt ${bundle.nextAttempt}?',
      message: 'A fresh checklist is generated from the same acceptance criteria and the job goes '
          'back into production. The failed attempt and its defect note are kept.',
      confirmLabel: 'Open the reinspection',
      cancelLabel: 'Not yet',
    );
    if (!confirmed || !mounted) return;

    try {
      final inspection = await ref.read(qcActionsProvider.notifier).reinspect(bundle);
      if (!mounted) return;
      showDone(context, 'Attempt ${inspection.attempt} is open.');
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }
}

// ================================================================= small pieces

/// One line of the checklist that does not exist yet.
final class _PlanLine extends StatelessWidget {
  const _PlanLine({required this.position, required this.line, this.requirement});

  final int position;
  final QcChecklistPlan line;
  final Requirement? requirement;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return DhCard(
      tone: DhCardTone.inset,
      accent: line.critical ? context.dh.gold : null,
      child: Row(
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
                  line.label,
                  style: context.text.titleMedium?.copyWith(color: scheme.onSurface),
                ),
                if (line.helper != null) ...[
                  const SizedBox(height: Spacing.xs),
                  Text(
                    line.helper!,
                    style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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
        ],
      ),
    );
  }
}

/// '5/7' — the counter the authorisation button watches.
final class _ProgressPill extends StatelessWidget {
  const _ProgressPill({required this.inspection});

  final QcInspection inspection;

  /// A failure outranks completeness: a list that is full but contains a failed line is not a
  /// pass, and colouring it green is how an inspector signs the wrong thing.
  ChipTone get _tone {
    if (inspection.failedCount > 0) return ChipTone.danger;
    if (inspection.isChecklistComplete) return ChipTone.success;
    return ChipTone.accent;
  }

  @override
  Widget build(BuildContext context) => StatusChip(
        label: inspection.progressLabel,
        mono: true,
        dense: true,
        tone: _tone,
        tooltip: '${inspection.passedCount} passed · ${inspection.failedCount} failed · '
            '${inspection.unansweredCount} to confirm',
      );
}

/// A closed attempt, summarised.
final class _AttemptSummary extends StatelessWidget {
  const _AttemptSummary({required this.inspection, required this.inspectorName});

  final QcInspection inspection;
  final String inspectorName;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final defect = inspection.defectReason?.trim();

    return DhCard(
      tone: DhCardTone.inset,
      accent: inspection.isFailed ? scheme.error : context.dh.success,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              QcAttemptChip(inspection, dense: true),
              const SizedBox(width: Spacing.sm),
              StatusChip.qc(inspection.status, dense: true),
              const Spacer(),
              Text(
                inspection.progressLabel,
                style: AppTheme.mono(size: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            '$inspectorName · ${inspection.items.length} checks',
            style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (defect != null && defect.isNotEmpty) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              defect,
              style: context.text.bodyMedium?.copyWith(color: scheme.onSurface),
            ),
          ],
        ],
      ),
    );
  }
}

/// The screen frame the loading and error states share with the real thing, so the header does
/// not appear only once the data lands.
final class _Frame extends StatelessWidget {
  const _Frame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Quality Control')),
        body: child,
      );
}
