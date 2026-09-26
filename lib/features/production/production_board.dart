/// The production board — all eight columns of it.
///
/// The mockup shipped three: Assembly, Setting, QC and Certification were simply absent, so half
/// the shop floor had no representation on the screen that claimed to show the shop floor. The
/// columns here are [LifecycleStage.operational] (D-002) — the same eight the dashboard counts,
/// derived from the one 14-stage rail rather than from a rival enum — and every count is computed
/// from the cards in the column, because the mockup's own source admitted its counts never moved.
///
/// Moving a card commits `fn_complete_stage` through the repository. The card relocates in the
/// same frame and goes back if the server refuses, with the refusal printed in Postgres's own
/// words (D-011 rules 1 and 3). The gesture is a long press: the drop writes an append-only
/// transition that cannot be undone, and it should not be possible to fire one by brushing the
/// screen while scrolling.
///
/// Wide layouts scroll eight columns sideways. Below [ProductionBoardScreen.wideBoard] one column
/// fills the width and a pill rail picks it, because eight kanban columns on a 360dp handset are
/// eight columns nobody can read — and the shop floor is where the handsets are.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:dhanaos/core/router.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/realtime.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/features/auth/permissions.dart';
import 'package:dhanaos/features/production/board_card.dart';
import 'package:dhanaos/features/production/board_controller.dart';
import 'package:dhanaos/shared/widgets/widgets.dart';

final class ProductionBoardScreen extends ConsumerStatefulWidget {
  const ProductionBoardScreen({super.key});

  /// Enough room for two full columns plus a hint of the third, which is what makes sideways
  /// scrolling legible rather than a guessing game.
  static const wideBoard = 760.0;

  static const columnWidth = 300.0;

  @override
  ConsumerState<ProductionBoardScreen> createState() => _ProductionBoardScreenState();
}

class _ProductionBoardScreenState extends ConsumerState<ProductionBoardScreen> {
  /// Owned rather than inherited so the horizontal [Scrollbar] has something to attach to — a
  /// horizontal scroll view is never the primary one.
  final ScrollController _columns = ScrollController();

  @override
  void dispose() {
    _columns.dispose();
    super.dispose();
  }

  void _refresh() => ref.invalidate(liveProductionBoardProvider);

  @override
  Widget build(BuildContext context) {
    final boardAsync = ref.watch(liveProductionBoardProvider);
    final moves = ref.watch(boardMovesProvider);
    final live = boardAsync.valueOrNull;

    // No data yet. An error with nothing behind it is the whole screen; an error *over* good data
    // is a banner, because throwing away a board an operator is working from to show a failed
    // re-read would be the worse trade.
    if (live == null) {
      final error = boardAsync.error;
      if (error != null) {
        return Scaffold(
          backgroundColor: context.scheme.surface,
          body: ErrorState(
            title: 'The production board did not load',
            message: failureMessageOf(error),
            detail: error is DhFailure ? error.detail : null,
            onRetry: _refresh,
          ),
        );
      }
      return Scaffold(
        backgroundColor: context.scheme.surface,
        body: const Padding(
          padding: EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LoadingSkeleton(width: 180, height: 16),
              SizedBox(height: Spacing.md),
              Expanded(child: LoadingSkeleton.list(count: 4)),
            ],
          ),
        ),
      );
    }

    final view = BoardView(live.data, moves);
    final wide = MediaQuery.sizeOf(context).width >= ProductionBoardScreen.wideBoard;

    return Scaffold(
      backgroundColor: context.scheme.surface,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BoardHeader(
            view: view,
            status: live.status,
            statusLabel: live.pulseLabel,
            onRefresh: _refresh,
            showDragHint: wide,
          ),
          if (boardAsync.hasError)
            _StaleBanner(
              message: failureMessageOf(boardAsync.error),
              onRetry: _refresh,
            ),
          Expanded(
            child: view.isEmpty
                ? EmptyState(
                    icon: Icons.account_tree_outlined,
                    title: 'Nothing is in production',
                    message: 'The eight columns fill as jobs are committed and move down the '
                        'rail. Commit a job order and it appears at CAD.',
                    actionLabel: 'Open the job list',
                    onAction: () => context.go(Paths.jobs),
                  )
                : wide
                    ? _wideBoard(view)
                    : _narrowBoard(view),
          ),
        ],
      ),
    );
  }

  /// Eight columns side by side. Every one is drawn even when empty — "nothing at Casting" and
  /// "Casting is missing from this screen" have to look different.
  Widget _wideBoard(BoardView view) {
    final columns = view.columns;
    return Scrollbar(
      controller: _columns,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _columns,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < columns.length; i++) ...[
              if (i > 0) const SizedBox(width: Spacing.sm),
              SizedBox(
                width: ProductionBoardScreen.columnWidth,
                child: BoardColumnPanel(
                  stage: columns[i],
                  view: view,
                  feedbackWidth: ProductionBoardScreen.columnWidth,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// One column at a time, picked from a rail that still shows all eight counts — so the phone
  /// never hides the fact that seven other columns exist.
  Widget _narrowBoard(BoardView view) {
    final focused = ref.watch(focusedColumnProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.sm),
          child: Row(
            children: [
              for (final stage in view.columns) ...[
                if (stage != view.columns.first) const SizedBox(width: Spacing.sm),
                StagePill(
                  stage: stage,
                  count: view.countIn(stage),
                  selected: stage == focused,
                  onTap: () => ref.read(focusedColumnProvider.notifier).select(stage),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.md),
            child: BoardColumnPanel(
              // The whole column is rebuilt when the focus changes, so the list starts at the top
              // of the new stage rather than at the old scroll offset.
              key: ValueKey<LifecycleStage>(focused),
              stage: focused,
              view: view,
              acceptsDrops: false,
            ),
          ),
        ),
      ],
    );
  }
}

/// The server's words when there are any, and a sentence that says what to do when there are not.
String failureMessageOf(Object? error) => error is DhFailure
    ? error.message
    : 'DhanaOS could not read the board. Check the shop Wi-Fi and refresh.';

// ================================================================= header

final class _BoardHeader extends ConsumerWidget {
  const _BoardHeader({
    required this.view,
    required this.status,
    required this.statusLabel,
    required this.onRefresh,
    required this.showDragHint,
  });

  final BoardView view;
  final LiveStatus status;
  final String statusLabel;
  final VoidCallback onRefresh;
  final bool showDragHint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final overdue = view.overdueCount;
    // The hint is only true for someone who may actually move a card, so it is only shown to them.
    final canMove = ref.watch(permissionsProvider).can(Capability.editJob);

    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.sm, Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '${view.total} ${view.total == 1 ? 'job' : 'jobs'} on the board',
                style: AppTheme.mono(
                  size: 12,
                  weight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              // The pulse and the cards come off the same subscription, so the chip cannot read
              // Live while the columns are stale.
              StatusChip(
                label: status.label,
                dot: true,
                dense: true,
                tooltip: statusLabel,
                tone: switch (status) {
                  LiveStatus.live => ChipTone.success,
                  LiveStatus.connecting => ChipTone.neutral,
                  LiveStatus.retrying => ChipTone.warning,
                  LiveStatus.offline => ChipTone.danger,
                },
              ),
              if (overdue > 0) ...[
                const SizedBox(width: Spacing.sm),
                StatusChip(
                  label: '$overdue overdue',
                  tone: ChipTone.danger,
                  dense: true,
                  icon: Icons.event_busy_outlined,
                  tooltip: 'Past the requested delivery date and still on the board.',
                ),
              ],
              const Spacer(),
              IconButton(
                onPressed: onRefresh,
                tooltip: 'Re-read the board',
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          if (showDragHint && canMove)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xs),
              child: Text(
                'Press and hold a card to move it to the next stage. A job advances one stage at '
                'a time and never backwards.',
                style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

/// A read failed while good data was already on screen.
final class _StaleBanner extends StatelessWidget {
  const _StaleBanner({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.sm),
      padding: const EdgeInsets.all(Spacing.sm + Spacing.xs),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: Radii.rMd,
      ),
      child: Row(
        children: [
          Icon(Icons.sync_problem_rounded, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              'Showing the last good read. $message',
              style: context.text.bodySmall?.copyWith(color: scheme.onErrorContainer),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(foregroundColor: scheme.onErrorContainer),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

// ================================================================= column picker

/// One stage of the phone layout's rail: the stage name and its live count.
///
/// Not a [DhSegmented] — that control is for a short closed set that fits one row, and asserting
/// eight scrolling options into it would squash every label to two letters.
final class StagePill extends StatelessWidget {
  const StagePill({
    super.key,
    required this.stage,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final LifecycleStage stage;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final foreground = selected ? scheme.onPrimary : scheme.onSurfaceVariant;

    return Material(
      color: selected ? scheme.primary : dh.surfaceContainerLow,
      borderRadius: Radii.rFull,
      child: InkWell(
        onTap: onTap,
        borderRadius: Radii.rFull,
        child: Semantics(
          selected: selected,
          button: true,
          child: Container(
            height: Spacing.rowHeightSm + Spacing.xs,
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            decoration: BoxDecoration(
              borderRadius: Radii.rFull,
              border: Border.all(
                color: selected ? scheme.primary : dh.outlineVariant,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  stage.label,
                  style: context.text.bodyMedium?.copyWith(
                    color: foreground,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Text(
                  '$count',
                  style: AppTheme.mono(size: 11.5, weight: FontWeight.w600, color: foreground),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
