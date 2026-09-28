/// The CAD designer's work queue. NEW — nobody in the corpus owned one.
///
/// "Elena Rostova — Lead CAD Designer" was named on four mockups and had no screen: the CAD stage
/// was something that happened *to* a job between the engineer's dashboard and the reviewer's
/// approval. So the one person whose whole day is this stage had nowhere to stand.
///
/// Two D-008 corrections are structural here, not cosmetic:
///
///  * "Mine" is `job_stages.assigned_to == the session user`. `caster_dashboard` scoped its queue
///    with an "Assigned to Me" pill that had nothing behind it, on a screen that rendered the same
///    hardcoded identity as the other 45.
///  * Claiming a job writes that row, which is the only thing that makes it mine — there is no
///    local "taken" flag, so two designers cannot both believe they hold it.
///
/// The queue also has to notice something the rail cannot say on its own: a rejected version does
/// not walk the job backwards (D-005 is append-only), so a job sitting at `approval` with a
/// revision request against it is *designer* work even though the rail says otherwise. That is
/// [CadWorkState.revisionsRequested], and it is why this screen is not just a filtered job list.
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
import 'package:dhanaos/features/auth/session.dart';
import 'package:dhanaos/features/cad/assign_designer.dart';
import 'package:dhanaos/features/cad/cad_actions.dart';
import 'package:dhanaos/features/cad/cad_gateway.dart';
import 'package:dhanaos/features/cad/cad_review_screen.dart';
import 'package:dhanaos/features/cad/revision_response.dart';
import 'package:dhanaos/features/cad/revision_upload.dart';
import 'package:dhanaos/features/cad/widgets/cad_widgets.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class DesignerQueueScreen extends ConsumerStatefulWidget {
  const DesignerQueueScreen({super.key});

  static Future<void> push(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const DesignerQueueScreen()),
      );

  @override
  ConsumerState<DesignerQueueScreen> createState() => _DesignerQueueScreenState();
}

class _DesignerQueueScreenState extends ConsumerState<DesignerQueueScreen> {
  /// Null until the operator picks one; the default depends on who they are.
  CadQueueScope? _chosen;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(designerQueueLiveProvider);
    final me = ref.watch(currentUserProvider).value;

    // A designer opens on their own work; anybody else — a production manager checking the
    // board — opens on all of it.
    final scope = _chosen ??
        ((me?.hasRole(UserRole.cadDesigner) ?? false)
            ? CadQueueScope.mine
            : CadQueueScope.everyone);

    return Scaffold(
      appBar: AppBar(
        title: const Text('CAD Queue'),
        actions: [
          if (async.value case final live?) LivePulse(status: live.status, dense: true),
          const SizedBox(width: Spacing.sm),
        ],
      ),
      body: async.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(Spacing.md),
          child: LoadingSkeleton.list(count: 4),
        ),
        error: (error, _) => ErrorState(
          title: 'The CAD queue did not load',
          message: error is DhFailure
              ? error.message
              : 'DhanaOS could not read the jobs at CAD. Check the connection and try again.',
          detail: error is DhFailure ? error.detail : error.toString(),
          onRetry: () => ref.invalidate(designerQueueLiveProvider),
        ),
        data: (live) => _body(live.data, scope: scope, me: me),
      ),
    );
  }

  Widget _body(DesignerQueue queue, {required CadQueueScope scope, required AppUser? me}) {
    final rows = queue.forScope(scope);

    return RefreshIndicator(
      // The stream re-reads on its own; this is for the case a socket quietly died.
      onRefresh: () async => ref.invalidate(designerQueueLiveProvider),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.xl),
        children: [
          _summary(queue),
          const SizedBox(height: Spacing.md),
          DhSegmented<CadQueueScope>(
            value: scope,
            segments: [
              for (final option in CadQueueScope.values)
                DhSegment(
                  value: option,
                  label: '${option.label} · ${queue.forScope(option).length}',
                ),
            ],
            onChanged: (value) => setState(() => _chosen = value),
          ),
          const SizedBox(height: Spacing.md),
          if (rows.isEmpty)
            _empty(scope, queue)
          else
            for (final item in rows) ...[
              _QueueCard(item: item, viewer: me),
              const SizedBox(height: Spacing.sm + Spacing.xs),
            ],
        ],
      ),
    );
  }

  Widget _summary(DesignerQueue queue) {
    return DhCard(
      child: DataPairGrid(
        columns: 3,
        minColumnWidth: 96,
        children: [
          DataPair.mono(
            label: 'Sent back',
            value: '${queue.sentBackCount}',
            emphasis: DataEmphasis.strong,
            valueColor: queue.sentBackCount > 0 ? context.scheme.error : null,
          ),
          DataPair.mono(
            label: 'Awaiting review',
            value: '${queue.awaitingReviewCount}',
            emphasis: DataEmphasis.strong,
          ),
          DataPair.mono(
            label: 'Unclaimed',
            value: '${queue.unassigned.length}',
            emphasis: DataEmphasis.strong,
            valueColor: queue.unassigned.isNotEmpty ? context.dh.goldText : null,
          ),
        ],
      ),
    );
  }

  Widget _empty(CadQueueScope scope, DesignerQueue queue) {
    return switch (scope) {
      CadQueueScope.mine => EmptyState(
          icon: Icons.draw_outlined,
          title: 'Nothing assigned to you',
          message: queue.unassigned.isEmpty
              ? 'No CAD work is waiting anywhere. When an intake commits, the job lands at CAD '
                  'and shows up here.'
              : '${queue.unassigned.length} job'
                  '${queue.unassigned.length == 1 ? '' : 's'} at CAD '
                  '${queue.unassigned.length == 1 ? 'has' : 'have'} no designer yet.',
          actionLabel: queue.unassigned.isEmpty ? null : 'See what is unclaimed',
          onAction: queue.unassigned.isEmpty
              ? null
              : () => setState(() => _chosen = CadQueueScope.unassigned),
        ),
      CadQueueScope.unassigned => const EmptyState(
          icon: Icons.how_to_reg_outlined,
          title: 'Every CAD job has a designer',
          message: 'Nothing is waiting to be claimed. Switch to All CAD to see what the shop is '
              'drawing.',
        ),
      CadQueueScope.everyone => const EmptyState(
          icon: Icons.architecture_outlined,
          title: 'No CAD work outstanding',
          message: 'Every committed job has moved past CAD. A new job order lands here the moment '
              'intake commits it.',
        ),
    };
  }
}

// ================================================================= one row

final class _QueueCard extends ConsumerWidget {
  const _QueueCard({required this.item, required this.viewer});

  final CadQueueItem item;
  final AppUser? viewer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final job = item.job;
    final state = item.state;
    final request = item.requestComment;
    final mine = item.isHeldBy(viewer?.id);

    return DhCard(
      accent: state == CadWorkState.revisionsRequested ? context.scheme.error : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CadJobLine(
            code: job.displayCode,
            title: job.displayTitle,
            customerName: job.customerName,
            priority: job.priority,
            trailing: CadStateChip(state, dense: true),
          ),
          const SizedBox(height: Spacing.sm + Spacing.xs),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.xs,
            children: [
              StatusChip(
                label: item.versionLabel,
                tone: ChipTone.neutral,
                dense: true,
                mono: true,
                icon: Icons.layers_outlined,
              ),
              StatusChip(
                label: '${job.currentStage?.label ?? 'Unstaged'} · ${job.dwellLabel}',
                tone: ChipTone.neutral,
                dense: true,
              ),
              if (job.overdue)
                const StatusChip(label: 'Overdue', tone: ChipTone.danger, dense: true)
              else if (job.dueSoon)
                const StatusChip(label: 'Due soon', tone: ChipTone.warning, dense: true),
              if (job.isBlocked)
                StatusChip(
                  label: '${job.openExceptions} open issue'
                      '${job.openExceptions == 1 ? '' : 's'}',
                  tone: ChipTone.danger,
                  dense: true,
                  icon: Icons.report_problem_outlined,
                ),
            ],
          ),
          const SizedBox(height: Spacing.sm + Spacing.xs),
          Row(
            children: [
              PersonAvatar(
                name: job.assigneeName,
                size: 26,
                tone: mine ? AvatarTone.accent : AvatarTone.neutral,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  mine
                      ? 'Yours'
                      : job.assigneeName ?? 'Nobody is drawing this yet',
                  style: context.text.bodySmall?.copyWith(
                    color: context.scheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (request != null) ...[
            const SizedBox(height: Spacing.sm + Spacing.xs),
            CadNote(
              tone: CadNoteTone.risk,
              icon: Icons.format_quote_rounded,
              text: request,
            ),
          ],
          const SizedBox(height: Spacing.sm + Spacing.xs),
          _actions(context, ref),
        ],
      ),
    );
  }

  Widget _actions(BuildContext context, WidgetRef ref) {
    final task = ref.watch(cadActionsProvider);
    final busy = task != null;
    final permissions = ref.watch(permissionsProvider);
    final revisionId = item.revision?.id;
    final stage = CadActions.stageFor(item.job.currentStage);

    final assign = OutlinedButton.icon(
      onPressed: busy
          ? null
          : () => unawaited(
                AssignDesignerSheet.show(
                  context,
                  jobId: item.job.id,
                  jobCode: item.job.displayCode,
                  stage: stage,
                  currentAssigneeId: item.job.assignedTo,
                ),
              ),
      icon: const Icon(Icons.person_search_outlined, size: 18),
      label: Text(item.isUnassigned ? 'Assign' : 'Reassign'),
    );

    return switch (item.state) {
      CadWorkState.unassigned => Row(
          children: [
            Expanded(child: assign),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: FilledButton.icon(
                onPressed: busy || !permissions.isInternal ? null : () => _claim(context, ref),
                icon: task == CadTask.assign
                    ? const _Spinner()
                    : const Icon(Icons.front_hand_outlined, size: 18),
                label: const Text('Take it'),
              ),
            ),
          ],
        ),
      CadWorkState.drawing => Row(
          children: [
            Expanded(child: assign),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: FilledButton.icon(
                onPressed: busy
                    ? null
                    : () => unawaited(
                          RevisionUploadScreen.push(context, jobId: item.job.id),
                        ),
                icon: const Icon(Icons.upload_file_rounded, size: 18),
                label: const Text('Offer a version'),
              ),
            ),
          ],
        ),
      CadWorkState.revisionsRequested => FilledButton.icon(
          onPressed: busy || revisionId == null
              ? null
              : () => unawaited(RevisionResponseScreen.push(context, revisionId)),
          icon: const Icon(Icons.replay_rounded, size: 18),
          label: const Text('Open the revision request'),
        ),
      CadWorkState.awaitingReview => OutlinedButton.icon(
          onPressed: revisionId == null
              ? null
              : () => unawaited(CadReviewScreen.push(context, revisionId)),
          icon: const Icon(Icons.rate_review_outlined, size: 18),
          label: Text(
            permissions.canApproveDesign
                ? 'Review ${item.versionLabel}'
                : 'Open ${item.versionLabel}',
          ),
        ),
      CadWorkState.approved => OutlinedButton.icon(
          onPressed: revisionId == null
              ? null
              : () => unawaited(CadReviewScreen.push(context, revisionId)),
          icon: const Icon(Icons.lock_outline_rounded, size: 18),
          label: Text('${item.versionLabel} is locked'),
        ),
    };
  }

  Future<void> _claim(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(cadActionsProvider.notifier).claim(
            jobId: item.job.id,
            stage: CadActions.stageFor(item.job.currentStage),
          );
      if (!context.mounted) return;
      showDone(context, '${item.job.displayCode} is yours. It is on your queue now.');
    } on DhFailure catch (failure) {
      if (!context.mounted) return;
      showFailure(context, failure);
    }
  }
}

final class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
}
