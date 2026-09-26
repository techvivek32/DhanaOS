/// Everything that moves a job, and the gates in front of each one.
///
/// Five verbs live here — advance, hold, release, rework, cancel — plus raising and closing an
/// exception. Four of the seven did not exist anywhere in the 46 mockups: every gate there was
/// one-way, `pricing_approval` offered only "Approve", and `caster_dashboard`'s "Report Issue"
/// was a 50/50 peer of the happy path with no screen behind it. D-006 is why they ship now rather
/// than later — retrofitting states into a live append-only audit log is far worse than defining
/// them up front.
///
/// The division of labour with Postgres is deliberate and is the same everywhere in this file:
///
///  * **The database owns the rule.** `fn_complete_stage` refuses a casting stage with no photo
///    and a QC stage with unticked items (D-011 rules 1 and 3), in sentences already written from
///    the operator's side. Those sentences reach the screen verbatim through [showFailure].
///  * **The screen owns the explanation.** A button that fires a guaranteed refusal is worse than
///    a button that waits, so [stageGateProvider] reads the same two rows the function checks and
///    holds the button shut *with the reason printed underneath it*. The server refusal is the
///    backstop, not the experience.
///
/// Nothing here writes `jobs.current_stage` or `job_stages.state` for an advance. D-005 makes
/// those the RPC's and the trigger's business; two devices that both "know" where a job is end up
/// disagreeing about it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:dhanaos/core/router.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/repositories/production_repository.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/permissions.dart';
import 'package:dhanaos/features/jobs/assign_sheet.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/shared/widgets/widgets.dart';

part 'stage_actions.g.dart';

// ================================================================= the gate

/// Whether a stage can be closed right now, and the sentence to print when it cannot.
@immutable
final class StageGate {
  const StageGate.open() : reason = null;

  const StageGate.blocked(String this.reason);

  /// Null when the stage may be closed. Otherwise phrased for whoever is looking at the button.
  final String? reason;

  bool get isOpen => reason == null;
}

/// The client-side half of D-011 rules 1 and 3.
///
/// Reads the same two rows `fn_complete_stage` checks — `casting_params.photo_id` and the
/// `qc_checklist_items` for the newest inspection — so the button is shut before it is pressed and
/// the operator is told what would open it. Every other stage is ungated here; the RPC is still
/// the authority.
@riverpod
Future<StageGate> stageGate(Ref ref, String jobId, LifecycleStage stage) async {
  switch (stage) {
    // D-011 rule 1: the caster cannot complete without a photo of the cast tree.
    case LifecycleStage.casting:
      final params = await ref.watch(castingParamsProvider(jobId).future);
      if (params == null) {
        return const StageGate.blocked(
          'No casting sheet has been opened for this job yet. Record the alloy and flask '
          'temperatures, then upload a photo of the cast tree.',
        );
      }
      final blocked = params.blockedReason;
      return blocked == null ? const StageGate.open() : StageGate.blocked(blocked);

    // D-011 rule 3: authorisation enables only at a full checklist.
    case LifecycleStage.qc:
      final inspection = await ref.watch(latestQcInspectionProvider(jobId).future);
      if (inspection == null) {
        return const StageGate.blocked(
          'No inspection has been opened for this job. Open QC and generate the checklist first.',
        );
      }
      final blocked = inspection.authorizationBlockedReason;
      return blocked == null ? const StageGate.open() : StageGate.blocked(blocked);

    case _:
      return const StageGate.open();
  }
}

/// The work surface that owns a stage, when one exists. Null for the stages whose whole record is
/// the job detail screen itself.
String? workSurfaceFor(LifecycleStage stage, String jobId) => switch (stage) {
      LifecycleStage.qc => Paths.qc(jobId),
      LifecycleStage.cert => Paths.certification(jobId),
      LifecycleStage.dispatch || LifecycleStage.delivered => Paths.shipping(jobId),
      _ => null,
    };

// ================================================================= controller

/// The writes. Each returns the failure to show, or null when it landed.
///
/// Returning the failure rather than throwing keeps the call sites honest: a caller cannot
/// accidentally swallow a `RuleViolation`, because the value it gets back is the thing it has to
/// render. [state] carries only the busy flag.
@riverpod
class StageActions extends _$StageActions {
  @override
  FutureOr<void> build(String jobId) {}

  JobRepository get _jobs => ref.read(jobRepositoryProvider);

  /// D-005: the RPC closes the stage and opens the next one, the trigger updates the cache and
  /// writes the audit row. Nothing here touches either.
  Future<DhFailure?> completeStage(LifecycleStage stage, {String? notes}) =>
      _run(() => _jobs.completeStage(jobId: jobId, stage: stage, notes: notes));

  /// D-006. Status is orthogonal to stage, so the job holds where it stands and resumes there.
  Future<DhFailure?> hold(String reason) => _run(() => _jobs.holdJob(jobId, reason: reason));

  Future<DhFailure?> releaseHold({String? note}) =>
      _run(() => _jobs.releaseHold(jobId, note: note));

  /// D-006. Sends a finished piece back to the bench without erasing what happened to it.
  Future<DhFailure?> rework(String reason) =>
      _run(() => _jobs.markForRework(jobId, reason: reason));

  /// D-006. The rail is left exactly as it stands — the record of how far the piece got is the
  /// whole reason to keep it.
  Future<DhFailure?> cancel(String reason) => _run(() => _jobs.cancelJob(jobId, reason: reason));

  /// "Caster delayed on DH-2026-01048". Blocks the stage by default: an issue that does not show
  /// on the board is an issue nobody acts on.
  Future<DhFailure?> raiseException({
    required LifecycleStage stage,
    required String title,
    String? detail,
    ActionSeverity severity = ActionSeverity.warning,
    bool blockStage = true,
  }) =>
      _run(
        () => _jobs.raiseException(
          jobId: jobId,
          stage: stage,
          title: title,
          detail: detail,
          severity: severity,
          blockStage: blockStage,
        ),
      );

  /// Closing an exception without saying what was done leaves the audit trail unable to answer
  /// the only question anyone will ask of it later.
  Future<DhFailure?> resolveException({
    required String exceptionId,
    required String resolution,
  }) =>
      _run(
        () => _jobs.resolveException(exceptionId: exceptionId, resolution: resolution),
      );

  Future<DhFailure?> _run(Future<void> Function() body) async {
    state = const AsyncLoading<void>().copyWithPrevious(state);
    try {
      await body();
      state = const AsyncData<void>(null);
      // The job and its rail arrive back over the socket; the two gate rows do not, because
      // neither `casting_params` nor `qc_inspections` is on the job channel.
      ref
        ..invalidate(castingParamsProvider(jobId))
        ..invalidate(latestQcInspectionProvider(jobId));
      return null;
    } on Object catch (error, stack) {
      final failure = toDhFailure(error, stack);
      state = AsyncError<void>(failure, stack);
      return failure;
    }
  }
}

// ================================================================= the bar

/// Every action available on a job, laid out for the detail screen.
///
/// What is offered depends on three things and is never guessed at: the session user's roles
/// (D-008), the job's status, and the gate on the active stage (D-011). A control that is present
/// but shut always says why underneath itself.
final class StageActionsBar extends ConsumerWidget {
  const StageActionsBar({super.key, required this.snapshot});

  final JobSnapshot snapshot;

  Job get _job => snapshot.job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(permissionsProvider);
    final busy = ref.watch(stageActionsProvider(_job.id)).isLoading;

    if (_job.status == JobStatus.cancelled) {
      return _ClosedNotice(
        icon: Icons.block_rounded,
        title: 'This job was cancelled',
        message: _job.cancelReason ?? 'No reason was recorded.',
      );
    }
    if (_job.status == JobStatus.completed || _job.status == JobStatus.archived) {
      return const _ClosedNotice(
        icon: Icons.verified_outlined,
        title: 'This job is finished',
        message: 'The rail is complete. Nothing further moves from here.',
      );
    }

    if (_job.isOnHold) {
      return _HoldBanner(job: _job, busy: busy, canAct: permissions.canEditJob);
    }

    final active = snapshot.activeStage;
    if (active == null) {
      return _ClosedNotice(
        icon: Icons.hourglass_empty_rounded,
        title: _job.isDraft ? 'Not committed yet' : 'No active stage',
        message: _job.isDraft
            ? 'This is still a draft. Finish the job order and commit it — the 14-stage rail is '
                'seeded at commit, not at creation.'
            : 'No stage on the rail is active. Open the rail and check for a blocked stage.',
      );
    }

    return _ActiveStageActions(
      snapshot: snapshot,
      stage: active,
      busy: busy,
      permissions: permissions,
    );
  }
}

final class _ActiveStageActions extends ConsumerWidget {
  const _ActiveStageActions({
    required this.snapshot,
    required this.stage,
    required this.busy,
    required this.permissions,
  });

  final JobSnapshot snapshot;
  final JobStage stage;
  final bool busy;
  final Permissions permissions;

  String get _jobId => snapshot.job.id;

  /// QC authorisation is one of the three decisions the business cannot take back, so it asks for
  /// its own role rather than the general edit permission.
  bool get _mayAdvance => stage.stage == LifecycleStage.qc
      ? permissions.canAuthorizeQc
      : permissions.canEditJob || permissions.canCompleteAssignedStage;

  String get _advanceLabel => switch (stage.stage) {
        LifecycleStage.qc => 'Authorise QC and advance',
        LifecycleStage.casting => 'Mark casting complete',
        LifecycleStage.delivered => 'Close the job as delivered',
        final other => 'Complete ${other.label} and advance',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gate = ref.watch(stageGateProvider(_jobId, stage.stage));
    final blockedByException = snapshot.openExceptions.isNotEmpty;

    final String? shutReason;
    if (!_mayAdvance) {
      shutReason = permissions.blockReason(
        stage.stage == LifecycleStage.qc ? Capability.authorizeQc : Capability.editJob,
      );
    } else if (blockedByException) {
      shutReason = 'An open issue is holding this stage. Close it below, then advance.';
    } else {
      shutReason = switch (gate) {
        AsyncData(value: final value) => value.reason,
        AsyncError(error: final DhFailure failure) => failure.message,
        AsyncError() => 'The gate on this stage could not be read. Pull down to refresh.',
        _ => 'Checking what this stage needs…',
      };
    }

    final surface = workSurfaceFor(stage.stage, _jobId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: busy || shutReason != null ? null : () => _advance(context, ref),
          icon: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.arrow_forward_rounded, size: 18),
          label: Text(_advanceLabel),
        ),
        if (shutReason != null) ...[
          const SizedBox(height: Spacing.sm),
          _ShutReason(reason: shutReason),
        ],
        const SizedBox(height: Spacing.sm + Spacing.xs),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy || !permissions.canEditJob
                    ? null
                    : () => unawaited(
                          AssignSheet.show(context, jobId: _jobId, stage: stage.stage),
                        ),
                icon: const Icon(Icons.person_add_alt_rounded, size: 18),
                label: const Text('Assign'),
              ),
            ),
            const SizedBox(width: Spacing.sm + Spacing.xs),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : () => _reportIssue(context, ref),
                icon: const Icon(Icons.report_outlined, size: 18),
                label: const Text('Report issue'),
              ),
            ),
          ],
        ),
        if (surface != null) ...[
          const SizedBox(height: Spacing.sm),
          TextButton.icon(
            onPressed: () => context.push(surface),
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: Text('Open ${stage.stage.label}'),
          ),
        ],
        if (permissions.canEditJob) ...[
          const SizedBox(height: Spacing.sm),
          _StatusMenu(jobId: _jobId, busy: busy),
        ],
      ],
    );
  }

  Future<void> _advance(BuildContext context, WidgetRef ref) async {
    final next = snapshot.rail.nextStage;
    final confirmed = await confirmAction(
      context,
      title: _advanceLabel,
      message: next == null
          ? 'This closes ${stage.stage.label} and finishes the job. The transition is written to '
              'the audit trail and cannot be edited afterwards.'
          : 'This closes ${stage.stage.label} and opens ${next.stage.label}. The transition is '
              'written to the audit trail and cannot be edited afterwards.',
      confirmLabel: 'Advance',
    );
    if (!confirmed || !context.mounted) return;

    final failure =
        await ref.read(stageActionsProvider(_jobId).notifier).completeStage(stage.stage);
    if (!context.mounted) return;
    if (failure != null) {
      showFailure(context, failure);
      return;
    }
    showDone(
      context,
      next == null
          ? '${stage.stage.label} closed. The job is finished.'
          : '${stage.stage.label} closed. Now at ${next.stage.label}.',
    );
  }

  Future<void> _reportIssue(BuildContext context, WidgetRef ref) async {
    final report = await showModalBottomSheet<_ExceptionReport>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _RaiseExceptionSheet(stage: stage.stage),
    );
    if (report == null || !context.mounted) return;

    final failure = await ref.read(stageActionsProvider(_jobId).notifier).raiseException(
          stage: stage.stage,
          title: report.title,
          detail: report.detail,
          severity: report.severity,
          blockStage: report.blockStage,
        );
    if (!context.mounted) return;
    if (failure != null) {
      showFailure(context, failure);
      return;
    }
    showDone(
      context,
      report.blockStage
          ? 'Issue logged. ${stage.stage.label} is now blocked.'
          : 'Issue logged against ${stage.stage.label}.',
    );
  }
}

/// Hold, rework and cancel — the three D-006 states, behind one menu because none of them is the
/// thing an operator normally came here to do.
final class _StatusMenu extends ConsumerWidget {
  const _StatusMenu({required this.jobId, required this.busy});

  final String jobId;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Align(
      alignment: Alignment.centerLeft,
      child: PopupMenuButton<_StatusChange>(
        enabled: !busy,
        tooltip: 'Change the job status',
        position: PopupMenuPosition.under,
        onSelected: (change) => unawaited(_apply(context, ref, change)),
        itemBuilder: (menuContext) => const [
          PopupMenuItem(
            value: _StatusChange.hold,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.pause_circle_outline_rounded),
              title: Text('Put on hold'),
              subtitle: Text('Stops the clock where the job stands'),
            ),
          ),
          PopupMenuItem(
            value: _StatusChange.rework,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.replay_rounded),
              title: Text('Send back for rework'),
              subtitle: Text('Keeps the rail, records what has to be redone'),
            ),
          ),
          PopupMenuItem(
            value: _StatusChange.cancel,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.cancel_outlined),
              title: Text('Cancel the job'),
              subtitle: Text('Permanent. The rail is kept as the record'),
            ),
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.sm, horizontal: Spacing.xs),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.more_horiz_rounded, size: 18, color: context.scheme.onSurfaceVariant),
              const SizedBox(width: Spacing.xs + 2),
              Text(
                'Change status',
                style: context.text.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: context.scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _apply(BuildContext context, WidgetRef ref, _StatusChange change) async {
    final reason = await promptForText(
      context,
      title: switch (change) {
        _StatusChange.hold => 'Put this job on hold',
        _StatusChange.rework => 'Send this job back for rework',
        _StatusChange.cancel => 'Cancel this job',
      },
      message: switch (change) {
        _StatusChange.hold =>
          'The shop floor reads this reason on the job. The job stays exactly where it is on the '
              'rail and resumes there.',
        _StatusChange.rework =>
          'Say what has to be redone. The rail is kept intact — this records the decision, it '
              'does not erase the work.',
        _StatusChange.cancel =>
          'This cannot be undone, and the reason goes on the permanent record. The rail stays as '
              'it is, because how far the piece got is the whole reason to keep it.',
      },
      fieldLabel: switch (change) {
        _StatusChange.hold => 'Reason for the hold',
        _StatusChange.rework => 'What has to be redone',
        _StatusChange.cancel => 'Reason for cancelling',
      },
      submitLabel: switch (change) {
        _StatusChange.hold => 'Put on hold',
        _StatusChange.rework => 'Send back',
        _StatusChange.cancel => 'Cancel the job',
      },
      hint: switch (change) {
        _StatusChange.hold => 'Waiting on the client to confirm the centre stone',
        _StatusChange.rework => 'Prong height is uneven on the left shoulder',
        _StatusChange.cancel => 'Client withdrew the order',
      },
      destructive: change == _StatusChange.cancel,
    );
    if (reason == null || !context.mounted) return;

    if (change == _StatusChange.cancel) {
      final sure = await confirmAction(
        context,
        title: 'Cancel this job for good?',
        message: 'Cancelling is permanent. Nothing after this point can be produced against this '
            'job order.',
        confirmLabel: 'Cancel the job',
        cancelLabel: 'Keep the job open',
        destructive: true,
      );
      if (!sure || !context.mounted) return;
    }

    final notifier = ref.read(stageActionsProvider(jobId).notifier);
    final failure = switch (change) {
      _StatusChange.hold => await notifier.hold(reason),
      _StatusChange.rework => await notifier.rework(reason),
      _StatusChange.cancel => await notifier.cancel(reason),
    };
    if (!context.mounted) return;
    if (failure != null) {
      showFailure(context, failure);
      return;
    }
    showDone(
      context,
      switch (change) {
        _StatusChange.hold => 'Job placed on hold.',
        _StatusChange.rework => 'Sent back for rework.',
        _StatusChange.cancel => 'Job cancelled.',
      },
    );
  }
}

enum _StatusChange { hold, rework, cancel }

/// The banner a held job wears, with the one action that matters while it is held.
final class _HoldBanner extends ConsumerWidget {
  const _HoldBanner({required this.job, required this.busy, required this.canAct});

  final Job job;
  final bool busy;
  final bool canAct;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dh = context.dh;
    return DhCard(
      accent: dh.gold,
      background: dh.gold.withValues(alpha: 0.10),
      borderColor: dh.gold.withValues(alpha: 0.45),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.pause_circle_outline_rounded, size: 20, color: dh.goldText),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  'On hold',
                  style: context.text.titleMedium?.copyWith(color: context.scheme.onSurface),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            job.holdReason ?? 'No reason was recorded on the hold.',
            style: context.text.bodyMedium?.copyWith(color: context.scheme.onSurfaceVariant),
          ),
          const SizedBox(height: Spacing.md),
          FilledButton.icon(
            onPressed: busy || !canAct ? null : () => unawaited(_release(context, ref)),
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('Lift the hold'),
          ),
          if (!canAct) ...[
            const SizedBox(height: Spacing.sm),
            _ShutReason(
              reason: ref.watch(permissionsProvider).blockReason(Capability.editJob) ??
                  'You cannot change this job.',
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _release(BuildContext context, WidgetRef ref) async {
    final confirmed = await confirmAction(
      context,
      title: 'Lift the hold?',
      message: 'The job returns to the stage it was on when it was held, and the shop floor can '
          'pick it up again.',
      confirmLabel: 'Lift the hold',
    );
    if (!confirmed || !context.mounted) return;

    final failure = await ref.read(stageActionsProvider(job.id).notifier).releaseHold();
    if (!context.mounted) return;
    if (failure != null) {
      showFailure(context, failure);
      return;
    }
    showDone(context, 'Hold lifted. The job is running again.');
  }
}

/// One open `job_exceptions` row, with the only action it has.
final class ExceptionCard extends ConsumerWidget {
  const ExceptionCard({super.key, required this.exception, required this.canResolve});

  final JobException exception;
  final bool canResolve;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final open = exception.isOpen;
    final busy = ref.watch(stageActionsProvider(exception.jobId)).isLoading;

    return DhCard(
      tone: DhCardTone.inset,
      accent: open ? scheme.error : context.dh.success,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SeverityChip(exception.severity, dense: true),
              const SizedBox(width: Spacing.sm),
              StatusChip.lifecycle(exception.stage, dense: true),
              const Spacer(),
              Text(
                _ageLabel(exception.age),
                style: AppTheme.mono(size: 10.5, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm + Spacing.xs),
          Text(exception.title, style: context.text.titleMedium),
          if (exception.detail != null) ...[
            const SizedBox(height: Spacing.xs),
            Text(
              exception.detail!,
              style: context.text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          if (!open) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              'Closed: ${exception.resolution ?? 'no resolution was recorded'}',
              style: context.text.bodySmall?.copyWith(color: context.dh.success),
            ),
          ],
          if (open && canResolve) ...[
            const SizedBox(height: Spacing.sm + Spacing.xs),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: busy ? null : () => unawaited(_resolve(context, ref)),
                icon: const Icon(Icons.task_alt_rounded, size: 18),
                label: const Text('Close this issue'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _resolve(BuildContext context, WidgetRef ref) async {
    final resolution = await promptForText(
      context,
      title: 'Close: ${exception.title}',
      message: 'Write what was done. A closed issue with no note leaves the audit trail unable to '
          'say what happened. Closing the last open issue on a stage un-blocks it.',
      fieldLabel: 'What was done',
      submitLabel: 'Close the issue',
      hint: 'Caster re-poured the tree; new delivery date confirmed for the 14th',
    );
    if (resolution == null || !context.mounted) return;

    final failure = await ref
        .read(stageActionsProvider(exception.jobId).notifier)
        .resolveException(exceptionId: exception.id, resolution: resolution);
    if (!context.mounted) return;
    if (failure != null) {
      showFailure(context, failure);
      return;
    }
    showDone(context, 'Issue closed.');
  }

  static String _ageLabel(Duration age) {
    if (age.inDays >= 1) return '${age.inDays}d open';
    if (age.inHours >= 1) return '${age.inHours}h open';
    return '${age.inMinutes}m open';
  }
}

// ================================================================= raise-exception sheet

@immutable
final class _ExceptionReport {
  const _ExceptionReport({
    required this.title,
    required this.detail,
    required this.severity,
    required this.blockStage,
  });

  final String title;
  final String? detail;
  final ActionSeverity severity;
  final bool blockStage;
}

/// `caster_dashboard` gave "Report Issue" equal visual weight with "Mark Complete" and wired
/// neither. This is the screen behind it: what happened, how bad, and whether the board should
/// stop.
final class _RaiseExceptionSheet extends StatefulWidget {
  const _RaiseExceptionSheet({required this.stage});

  final LifecycleStage stage;

  @override
  State<_RaiseExceptionSheet> createState() => _RaiseExceptionSheetState();
}

class _RaiseExceptionSheetState extends State<_RaiseExceptionSheet> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _detail = TextEditingController();
  ActionSeverity _severity = ActionSeverity.warning;
  bool _block = true;

  @override
  void initState() {
    super.initState();
    _title.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _title
      ..removeListener(_onChanged)
      ..dispose();
    _detail.dispose();
    super.dispose();
  }

  bool get _ready => _title.text.trim().isNotEmpty;

  /// Read at press time, not at build time: the detail field has no listener, so a value captured
  /// during build would be whatever the field held one keystroke of the *title* ago.
  _ExceptionReport _report() {
    final detail = _detail.text.trim();
    return _ExceptionReport(
      title: _title.text.trim(),
      detail: detail.isEmpty ? null : detail,
      severity: _severity,
      blockStage: _block,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: Spacing.md,
        right: Spacing.md,
        bottom: MediaQuery.viewInsetsOf(context).bottom + Spacing.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Report an issue', style: context.text.headlineSmall),
            const SizedBox(height: Spacing.xs),
            Text(
              'Raised against ${widget.stage.label}. It appears on the board and on the job until '
              'someone closes it.',
              style: context.text.bodyMedium?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.lg),
            TextField(
              controller: _title,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'What is wrong',
                hintText: 'Caster delayed',
              ),
            ),
            const SizedBox(height: Spacing.md),
            TextField(
              controller: _detail,
              minLines: 3,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Detail (optional)',
                hintText: 'Foundry has a furnace down. New pour promised for Thursday morning.',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: Spacing.md),
            DhSegmented<ActionSeverity>(
              label: 'How bad is it',
              value: _severity,
              onChanged: (value) => setState(() => _severity = value),
              segments: const [
                DhSegment(value: ActionSeverity.info, label: 'Note'),
                DhSegment(value: ActionSeverity.warning, label: 'Attention'),
                DhSegment(value: ActionSeverity.error, label: 'Exception'),
              ],
            ),
            const SizedBox(height: Spacing.sm),
            SwitchListTile.adaptive(
              value: _block,
              onChanged: (value) => setState(() => _block = value),
              contentPadding: EdgeInsets.zero,
              title: const Text('Block the stage'),
              subtitle: const Text(
                'On by default. An issue that does not show on the board is an issue nobody acts '
                'on.',
              ),
            ),
            const SizedBox(height: Spacing.md),
            FilledButton.icon(
              onPressed: _ready ? () => Navigator.of(context).pop(_report()) : null,
              icon: const Icon(Icons.report_outlined, size: 18),
              label: const Text('Log the issue'),
            ),
            if (!_ready) ...[
              const SizedBox(height: Spacing.sm),
              const _ShutReason(
                reason: 'Say what is wrong before logging it — the board shows this line.',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ================================================================= small parts

/// The sentence under a shut control. Never let a dead button go unexplained.
final class _ShutReason extends StatelessWidget {
  const _ShutReason({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.lock_outline_rounded, size: 15, color: scheme.onSurfaceVariant),
        const SizedBox(width: Spacing.sm),
        Expanded(
          child: Text(
            reason,
            style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

final class _ClosedNotice extends StatelessWidget {
  const _ClosedNotice({required this.icon, required this.title, required this.message});

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return DhCard(
      tone: DhCardTone.inset,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: Spacing.sm + Spacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.text.titleMedium),
                const SizedBox(height: Spacing.xs),
                Text(
                  message,
                  style: context.text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
