/// The command centre.
///
/// Every figure on `manufacturer_dashboard` was a literal. Its eight counters were hardcoded
/// numbers that happened to sum to the hardcoded "55 Total Active"; its "3 At Risk" never moved;
/// its Action Queue was three sentences of sample text behind a "Follow Up" button with no
/// handler. That arithmetic coincidence is the best evidence in the corpus for D-002 — the eight
/// are the in-production subset of the fourteen — so it is honoured structurally: Total Active is
/// the **sum of the tiles**, not a ninth query that could contradict them.
///
/// Four things are real here that were not there:
///
///  * the counters come from `v_stage_counters` and stay live on the rail's own channel;
///  * Total Delayed and At Risk are counted in Postgres, recounted whenever the counters move, so
///    the headline can never be a different age from the tiles under it;
///  * the Action Queue is generated from job state (see `dashboard_data.dart`) and **every row
///    drills through to the job it names**;
///  * a stage tile opens that column of the production board, which is the action a counter
///    implies and the mockup never offered.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:dhanaos/core/router.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/repositories/dashboard_repository.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/realtime.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/job.dart';
import 'package:dhanaos/features/dashboard/dashboard_data.dart';
import 'package:dhanaos/features/production/board_controller.dart';
import 'package:dhanaos/shared/shell/top_bar.dart';
import 'package:dhanaos/shared/widgets/widgets.dart';

final _dayMonth = DateFormat('d MMM');

/// The server's words when there are any, and what to do when there are not.
String dashboardFailureMessage(Object? error) => error is DhFailure
    ? error.message
    : 'DhanaOS could not read this. Check the shop Wi-Fi and pull down to refresh.';

// ================================================================= screen

final class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  /// Above this the queue and the priority list sit side by side; below it they stack, because two
  /// 300px columns of sentences are worse than one 600px column of them.
  static const twoColumn = 1040.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: context.scheme.surface,
      body: RefreshIndicator(
        onRefresh: () => refreshDashboard(ref),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Spacing.md,
            Spacing.md,
            Spacing.md,
            Spacing.xxl,
          ),
          children: [
            const _Headline(),
            const SizedBox(height: Spacing.md),
            const _StageCounterPanel(),
            const SizedBox(height: Spacing.md),
            LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < twoColumn) {
                  return const Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _ActionQueuePanel(),
                      SizedBox(height: Spacing.md),
                      _PriorityPanel(),
                    ],
                  );
                }
                return const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: _ActionQueuePanel()),
                    SizedBox(width: Spacing.md),
                    Expanded(flex: 2, child: _PriorityPanel()),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Re-reads everything the screen shows.
///
/// Each panel renders its own failure, so a refresh that fails must not throw out of the
/// indicator and leave the spinner turning.
Future<void> refreshDashboard(WidgetRef ref) async {
  ref
    ..invalidate(liveStageCountersProvider)
    ..invalidate(dashboardRiskProvider)
    ..invalidate(actionQueueProvider)
    ..invalidate(jobListProvider(queueScope))
    ..invalidate(jobListProvider(priorityFilter));
  try {
    await ref.read(dashboardQueueProvider.future);
  } on Object {
    // Shown by the queue panel.
  }
}

// ================================================================= headline

final class _Headline extends ConsumerWidget {
  const _Headline();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final countersAsync = ref.watch(liveStageCountersProvider);
    final riskAsync = ref.watch(dashboardRiskProvider);
    final live = countersAsync.value;
    final counters = live?.data;
    final risk = riskAsync.value;

    if (counters == null && countersAsync.hasError) {
      return DhCard(
        child: ErrorState(
          compact: true,
          title: 'The counters did not load',
          message: dashboardFailureMessage(countersAsync.error),
          onRetry: () => ref.invalidate(liveStageCountersProvider),
        ),
      );
    }

    // D-002: their sum *is* Total Active. A ninth query here could disagree with the eight tiles
    // below, and then the screen would be arguing with itself.
    final active = counters?.totalActive;
    // The repository is explicit that a disagreement between the rail counters and the job status
    // count means a job is in production with no active stage row — a seeding fault worth seeing
    // rather than smoothing over.
    final statusActive = risk?.totalActive;
    final mismatch = active != null && statusActive != null && statusActive != active;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Workshop now',
                style: context.text.headlineMedium,
              ),
            ),
            if (live != null)
              StatusChip(
                label: live.status.label,
                dot: true,
                dense: true,
                tooltip: live.pulseLabel,
                tone: switch (live.status) {
                  LiveStatus.live => ChipTone.success,
                  LiveStatus.connecting => ChipTone.neutral,
                  LiveStatus.retrying => ChipTone.warning,
                  LiveStatus.offline => ChipTone.danger,
                },
              ),
            IconButton(
              onPressed: () => unawaited(refreshDashboard(ref)),
              tooltip: 'Re-read the dashboard',
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: Spacing.sm),
        DataPairGrid(
          columns: 4,
          minColumnWidth: 152,
          children: [
            _MetricTile(
              label: 'Total active',
              value: active,
              hint: 'The eight stage counters, summed',
              onTap: () => context.go(Paths.production),
            ),
            _MetricTile(
              label: 'Total delayed',
              value: risk?.overdue,
              alarming: (risk?.overdue ?? 0) > 0,
              hint: 'Past the requested date. Each one is in the queue below.',
            ),
            _MetricTile(
              label: 'At risk',
              value: risk?.atRisk,
              warn: (risk?.atRisk ?? 0) > 0,
              hint: 'Late, or blocked by an open exception',
            ),
            _MetricTile(
              label: 'Blocked',
              value: risk?.blocked,
              alarming: (risk?.blocked ?? 0) > 0,
              hint: 'Carrying an unresolved exception',
            ),
          ],
        ),
        if (mismatch) ...[
          const SizedBox(height: Spacing.sm),
          StatusChip(
            label: 'Rail and status counts disagree',
            tone: ChipTone.warning,
            dense: true,
            icon: Icons.rule_rounded,
            tooltip: 'The rail counts $active active stages; $statusActive jobs carry the In '
                'Production status. A job is in production with no active stage row — check its '
                'rail.',
          ),
        ],
      ],
    );
  }
}

final class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    this.hint,
    this.onTap,
    this.alarming = false,
    this.warn = false,
  });

  final String label;

  /// Null while the figure is still being read. A tile that shows 0 for "not yet known" is how a
  /// dashboard tells its first lie.
  final int? value;

  final String? hint;
  final VoidCallback? onTap;

  /// Non-zero and bad — drawn in the error colour.
  final bool alarming;

  /// Non-zero and worth a look — drawn in the house gold.
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final count = value;
    final colour = count == null || count == 0
        ? scheme.onSurface
        : alarming
            ? scheme.error
            : warn
                ? dh.goldText
                : scheme.onSurface;

    return DhCard(
      onTap: onTap,
      padding: const EdgeInsets.all(Spacing.sm + Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (count == null)
            DataPair.custom(
              label: label,
              child: const LoadingSkeleton(width: 52, height: 22),
            )
          else
            DataPair.mono(
              label: label,
              value: '$count',
              emphasis: DataEmphasis.display,
              valueColor: colour,
            ),
          if (hint != null) ...[
            const SizedBox(height: Spacing.xs + 2),
            Text(
              hint!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

// ================================================================= stage counters

final class _StageCounterPanel extends ConsumerWidget {
  const _StageCounterPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final countersAsync = ref.watch(liveStageCountersProvider);
    final counters = countersAsync.value?.data;
    final busiest = counters?.busiest;

    return DhSectionCard(
      title: 'Stage counters',
      subtitle: busiest == null
          ? 'The eight operational stages, derived from the 14-stage rail'
          : 'Busiest right now: ${busiest.stage.label} with ${busiest.jobCount}',
      leading: const Icon(Icons.stacked_bar_chart_rounded),
      action: counters == null
          ? null
          : StatusChip.code('${counters.totalActive} active', dense: true),
      child: counters == null
          ? countersAsync.hasError
              ? ErrorState(
                  compact: true,
                  title: 'The stage counters did not load',
                  message: dashboardFailureMessage(countersAsync.error),
                  onRetry: () => ref.invalidate(liveStageCountersProvider),
                )
              : const DataPairGrid(
                  columns: 4,
                  minColumnWidth: 132,
                  children: [
                    // Eight placeholders, because eight tiles is what lands — a row that grows
                    // from two to eight makes the whole screen jump.
                    LoadingSkeleton(height: 66, radius: Radii.rMd),
                    LoadingSkeleton(height: 66, radius: Radii.rMd),
                    LoadingSkeleton(height: 66, radius: Radii.rMd),
                    LoadingSkeleton(height: 66, radius: Radii.rMd),
                    LoadingSkeleton(height: 66, radius: Radii.rMd),
                    LoadingSkeleton(height: 66, radius: Radii.rMd),
                    LoadingSkeleton(height: 66, radius: Radii.rMd),
                    LoadingSkeleton(height: 66, radius: Radii.rMd),
                  ],
                )
          : DataPairGrid(
              columns: 4,
              minColumnWidth: 132,
              children: [
                // Always all eight, in rail order. A quiet Monday must shorten the numbers, not
                // the row: an operator reading a shorter row cannot tell "nothing at Casting"
                // from "Casting is missing from this screen".
                for (final tile in counters.tiles)
                  _StageTile(
                    stage: tile.stage,
                    count: tile.jobCount,
                    onTap: () {
                      ref.read(focusedColumnProvider.notifier).select(tile.stage);
                      context.go(Paths.production);
                    },
                  ),
              ],
            ),
    );
  }
}

final class _StageTile extends StatelessWidget {
  const _StageTile({required this.stage, required this.count, required this.onTap});

  final LifecycleStage stage;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final quiet = count == 0;

    return DhCard(
      tone: DhCardTone.inset,
      onTap: onTap,
      padding: const EdgeInsets.all(Spacing.sm + Spacing.xs),
      semanticLabel: '${stage.label}, $count jobs. Opens the ${stage.label} column.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            stage.label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            '$count',
            style: AppTheme.mono(
              size: 24,
              weight: FontWeight.w600,
              color: quiet ? scheme.onSurfaceVariant : scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

// ================================================================= action queue

final class _ActionQueuePanel extends ConsumerWidget {
  const _ActionQueuePanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queueAsync = ref.watch(dashboardQueueProvider);
    final entries = queueAsync.value;

    return DhSectionCard(
      title: 'Action queue',
      subtitle: 'Raised items, plus what the jobs themselves are saying',
      leading: const Icon(Icons.checklist_rtl_rounded),
      action: entries == null || entries.isEmpty
          ? null
          : StatusChip.code('${entries.length}', dense: true),
      child: switch (entries) {
        null when queueAsync.hasError => ErrorState(
            compact: true,
            title: 'The action queue did not load',
            message: dashboardFailureMessage(queueAsync.error),
            onRetry: () => unawaited(refreshDashboard(ref)),
          ),
        null => const LoadingSkeleton.list(count: 3),
        final List<QueueEntry> list when list.isEmpty => const EmptyState(
            compact: true,
            icon: Icons.verified_outlined,
            title: 'Nothing needs chasing',
            message: 'No job is late, blocked, stalled or unowned, and nobody has raised an '
                'item. This list fills itself as that changes.',
          ),
        final List<QueueEntry> list => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < list.length; i++) ...[
                if (i > 0) const SizedBox(height: Spacing.sm),
                _QueueRow(entry: list[i]),
              ],
            ],
          ),
      },
    );
  }
}

final class _QueueRow extends ConsumerWidget {
  const _QueueRow({required this.entry});

  final QueueEntry entry;

  Color _accent(BuildContext context) => switch (entry.severity) {
        ActionSeverity.error => context.scheme.error,
        ActionSeverity.warning => context.dh.gold,
        ActionSeverity.info => context.scheme.secondary,
        ActionSeverity.success => context.dh.success,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final route = entry.route;

    return DhCard(
      tone: DhCardTone.inset,
      accent: _accent(context),
      padding: const EdgeInsets.all(Spacing.sm + Spacing.xs),
      // Every row drills through to the job it names. The mockup's queue rows went nowhere.
      onTap: route == null ? null : () => context.go(route),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SeverityChip(entry.severity, dense: true),
              if (entry.code != null) ...[
                const SizedBox(width: Spacing.sm),
                Flexible(child: StatusChip.code(entry.code!, dense: true)),
              ],
              const Spacer(),
              if (entry.waitingSince != null)
                Text(
                  waitingLabel(entry.waitingSince!),
                  style: AppTheme.mono(size: 10.5, color: scheme.onSurfaceVariant),
                ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            entry.label,
            style: context.text.bodyLarge?.copyWith(color: scheme.onSurface),
          ),
          if (entry.detail != null) ...[
            const SizedBox(height: Spacing.xs),
            Text(
              entry.detail!,
              style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: Spacing.sm),
          Row(
            children: [
              if (route != null)
                Text(
                  entry.actionLabel,
                  style: context.text.labelMedium?.copyWith(color: scheme.secondary),
                )
              else
                Text(
                  'No job attached',
                  style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              const Spacer(),
              // Only a raised row can be marked done. A derived row clears when the job state
              // behind it clears — offering a "done" button that cannot change anything would be
              // the mockup's decorative "Follow Up" all over again.
              if (entry.isRaised)
                TextButton.icon(
                  onPressed: () => unawaited(_resolve(context, ref)),
                  icon: const Icon(Icons.done_rounded, size: 16),
                  label: const Text('Mark done'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _resolve(BuildContext context, WidgetRef ref) async {
    final confirmed = await confirmDashboardAction(
      context,
      title: 'Mark this done?',
      message: '"${entry.label}" leaves the queue and the notification bell. It stays on the '
          'record as resolved.',
      confirmLabel: 'Mark it done',
      cancelLabel: 'Leave it open',
    );
    if (!confirmed || !context.mounted) return;
    try {
      await ref.read(dashboardRepositoryProvider).resolveActionItem(entry.raisedId!);
      if (!context.mounted) return;
      ref
        ..invalidate(actionQueueProvider)
        // The bell in the top bar counts the same rows, so it has to be told too.
        ..invalidate(openActionsProvider);
      notifyDashboard(context, 'Marked done.');
    } on Object catch (error) {
      if (!context.mounted) return;
      notifyDashboard(context, dashboardFailureMessage(error), isError: true);
    }
  }
}

/// '3d waiting' / '4h waiting'. Monospaced, because it is a figure being compared down a column.
String waitingLabel(DateTime since) {
  final elapsed = DateTime.now().toUtc().difference(since.toUtc());
  if (elapsed.isNegative) return 'upcoming';
  if (elapsed.inDays >= 1) return '${elapsed.inDays}d waiting';
  if (elapsed.inHours >= 1) return '${elapsed.inHours}h waiting';
  return '${elapsed.inMinutes}m waiting';
}

// ================================================================= priority jobs

final class _PriorityPanel extends ConsumerWidget {
  const _PriorityPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobsAsync = ref.watch(jobListProvider(priorityFilter));
    final jobs = jobsAsync.value;

    return DhSectionCard(
      title: 'Priority jobs',
      subtitle: 'Rush and Critical, highest first',
      leading: const Icon(Icons.bolt_rounded),
      action: jobs == null || jobs.isEmpty
          ? null
          : StatusChip.code('${jobs.length}', dense: true),
      child: switch (jobs) {
        null when jobsAsync.hasError => ErrorState(
            compact: true,
            title: 'The priority list did not load',
            message: dashboardFailureMessage(jobsAsync.error),
            onRetry: () => ref.invalidate(jobListProvider(priorityFilter)),
          ),
        null => const LoadingSkeleton.list(count: 2),
        final List<JobListItem> list when list.isEmpty => const EmptyState(
            compact: true,
            icon: Icons.bolt_outlined,
            title: 'No rush work',
            message: 'Nothing is marked Rush or Critical. Raise a job priority and it appears '
                'here.',
          ),
        final List<JobListItem> list => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < list.length; i++) ...[
                if (i > 0) const SizedBox(height: Spacing.sm),
                _PriorityRow(job: list[i]),
              ],
            ],
          ),
      },
    );
  }
}

final class _PriorityRow extends StatelessWidget {
  const _PriorityRow({required this.job});

  final JobListItem job;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final due = job.requestedDelivery;

    return DhCard(
      tone: DhCardTone.inset,
      accent: job.overdue ? scheme.error : null,
      padding: const EdgeInsets.all(Spacing.sm + Spacing.xs),
      onTap: () => context.go(Paths.job(job.id)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(child: StatusChip.code(job.displayCode, dense: true)),
              const SizedBox(width: Spacing.xs),
              PriorityChip(job.priority, dense: true, showStandard: false),
              const Spacer(),
              if (job.currentStage != null)
                StatusChip.lifecycle(job.currentStage!, dense: true),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            job.displayTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.text.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: Spacing.xs),
          Row(
            children: [
              // The client is prose; the date and the dwell figure are data, so they take the
              // monospace face (convention 5) and line up down the column.
              Expanded(
                child: Text(
                  job.customerName ?? DataPair.placeholder,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Text(
                [
                  if (due != null) 'due ${_dayMonth.format(due)}',
                  job.dwellLabel,
                ].join(' · '),
                style: AppTheme.mono(
                  size: 11,
                  color: job.overdue ? scheme.error : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ================================================================= small helpers

/// A yes/no gate. The cancel label is the safe sentence rather than the word "Cancel", which on a
/// screen full of work items is ambiguous at exactly the wrong moment.
Future<bool> confirmDashboardAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  required String cancelLabel,
}) async {
  final answer = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message, style: dialogContext.text.bodyMedium),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return answer ?? false;
}

void notifyDashboard(BuildContext context, String message, {bool isError = false}) {
  final scheme = context.scheme;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: context.text.bodyMedium?.copyWith(
            color: isError ? scheme.onErrorContainer : null,
          ),
        ),
        backgroundColor: isError ? scheme.errorContainer : null,
        duration: Duration(seconds: isError ? 8 : 3),
        behavior: SnackBarBehavior.floating,
        showCloseIcon: isError,
      ),
    );
}
