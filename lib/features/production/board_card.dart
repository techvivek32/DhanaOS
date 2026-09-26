/// One card on the board, and one column of them.
///
/// The mockup's card carried a code, a title and nothing else actionable: no owner, no dwell
/// figure, no date. The five things a production manager actually triages on are all here —
/// client, due date, days in stage, who holds it, priority — and each is drawn from the row
/// rather than from a literal.
///
/// The drag gesture is a long press, not an immediate drag. A kanban card sits inside a vertical
/// list inside a horizontal scroller, so an immediate drag would fight both; and a press-and-hold
/// reads as the deliberate act it is, given that the drop writes an irreversible transition.
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
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/features/auth/permissions.dart';
import 'package:dhanaos/features/production/board_actions.dart';
import 'package:dhanaos/features/production/board_controller.dart';
import 'package:dhanaos/shared/widgets/widgets.dart';

/// Compact calendar day. The view's `requested_delivery` is a `date` column, so it arrives as a
/// local midnight and needs no timezone shift — only a year when it is not the current one.
final _dayMonth = DateFormat('d MMM');
final _dayMonthYear = DateFormat('d MMM yyyy');

String formatDueDate(DateTime date) {
  final now = DateTime.now();
  return date.year == now.year ? _dayMonth.format(date) : _dayMonthYear.format(date);
}

// ================================================================= card

final class BoardCardTile extends StatelessWidget {
  const BoardCardTile({
    super.key,
    required this.card,
    this.move,
    this.onTap,
    this.onComplete,
    this.completeLabel,
    this.dimmed = false,
  });

  final BoardCard card;

  /// Set while a commit for this job is open, so the card can say where it is going.
  final PendingMove? move;

  final VoidCallback? onTap;

  /// Null when the operator may not move this stage, which is what greys the menu entry.
  final VoidCallback? onComplete;

  /// 'Complete Casting' — passed in so the menu names the stage rather than the gesture.
  final String? completeLabel;

  /// True for the card left behind under a drag.
  final bool dimmed;

  bool get _moving => move != null;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final due = card.requestedDelivery;

    final tile = DhCard(
      onTap: _moving ? null : onTap,
      // A 3px bar is how the source system marked an exception card. Overdue is the one state on
      // this board that changes what happens next.
      accent: card.overdue ? scheme.error : null,
      padding: const EdgeInsets.all(Spacing.sm + Spacing.xs),
      semanticLabel: '${card.displayCode}, ${card.displayTitle}, '
          '${card.columnStage.label}, ${card.dwellLabel}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Flexible(child: StatusChip.code(card.displayCode, dense: true)),
              const SizedBox(width: Spacing.xs),
              PriorityChip(card.priority, dense: true, showStandard: false),
              const Spacer(),
              if (onComplete != null && !_moving)
                _CardMenu(
                  completeLabel: completeLabel ?? 'Complete ${card.columnStage.label}',
                  onComplete: onComplete!,
                  onOpen: onTap,
                ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            card.displayTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.text.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          if (card.customerName != null) ...[
            const SizedBox(height: Spacing.xs),
            _MetaLine(
              icon: Icons.storefront_outlined,
              text: card.customerName!,
              color: scheme.onSurfaceVariant,
            ),
          ],
          const SizedBox(height: Spacing.sm),
          Row(
            children: [
              // Dates and dwell figures are data, so they are monospaced (convention 5) — an
              // operator scanning a column compares digits down it.
              Expanded(
                child: _MetaLine(
                  icon: Icons.event_outlined,
                  text: due == null ? 'No date set' : formatDueDate(due),
                  color: card.overdue ? scheme.error : scheme.onSurfaceVariant,
                  mono: due != null,
                  tooltip: due == null
                      ? 'This job has no requested delivery date.'
                      : 'Requested ${_dayMonthYear.format(due)}',
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Text(
                card.dwellLabel,
                style: AppTheme.mono(size: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          if (card.isUnassigned)
            // The mockup's board had no such state, so an unclaimed job looked identical to a
            // claimed one and nobody picked it up.
            const StatusChip(
              label: 'Unassigned',
              tone: ChipTone.warning,
              dense: true,
              icon: Icons.person_off_outlined,
            )
          else
            StatusChip(
              label: card.holderName!,
              dense: true,
              tone: card.isWithPartner ? ChipTone.accent : ChipTone.neutral,
              icon: card.isWithPartner
                  ? Icons.handshake_outlined
                  : Icons.person_outline_rounded,
              tooltip: card.isWithPartner
                  ? 'With an outside partner — a delay here needs a phone call.'
                  : 'On the bench with ${card.holderName}',
            ),
          if (_moving) ...[
            const SizedBox(height: Spacing.sm),
            Row(
              children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.secondary,
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    'Moving to ${move!.to.label}…',
                    style: context.text.bodySmall?.copyWith(color: dh.goldText),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );

    return dimmed ? Opacity(opacity: 0.35, child: tile) : tile;
  }
}

final class _CardMenu extends StatelessWidget {
  const _CardMenu({
    required this.completeLabel,
    required this.onComplete,
    required this.onOpen,
  });

  final String completeLabel;
  final VoidCallback onComplete;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        tooltip: 'Actions for this job',
        position: PopupMenuPosition.under,
        padding: EdgeInsets.zero,
        iconSize: 18,
        onSelected: (value) {
          switch (value) {
            case 'complete':
              onComplete();
            case 'open':
              onOpen?.call();
          }
        },
        itemBuilder: (_) => <PopupMenuEntry<String>>[
          PopupMenuItem<String>(
            value: 'complete',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.task_alt_rounded),
              title: Text(completeLabel),
            ),
          ),
          if (onOpen != null)
            const PopupMenuItem<String>(
              value: 'open',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.open_in_new_rounded),
                title: Text('Open the job order'),
              ),
            ),
        ],
      );
}

final class _MetaLine extends StatelessWidget {
  const _MetaLine({
    required this.icon,
    required this.text,
    required this.color,
    this.mono = false,
    this.tooltip,
  });

  final IconData icon;
  final String text;
  final Color color;
  final bool mono;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final line = Row(
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: Spacing.xs + 1),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: mono
                ? AppTheme.mono(size: 11.5, color: color)
                : context.text.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
    final message = tooltip;
    return message == null ? line : Tooltip(message: message, child: line);
  }
}

// ================================================================= column

/// One of the eight columns: a header whose count is recomputed from the cards below it, and a
/// drop zone that either accepts the one legal transition or says why it will not.
final class BoardColumnPanel extends ConsumerWidget {
  const BoardColumnPanel({
    super.key,
    required this.stage,
    required this.view,
    this.feedbackWidth = 300,
    this.acceptsDrops = true,
  });

  final LifecycleStage stage;
  final BoardView view;

  /// Width the dragged copy is drawn at, so the card does not reflow under the finger.
  final double feedbackWidth;

  /// False on the phone layout, where only one column is on screen and there is nowhere to drop.
  final bool acceptsDrops;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cards = view.cardsIn(stage);
    final transition = StageTransition.after(stage);
    final permissions = ref.watch(permissionsProvider);
    final canMove = transition != null && permissions.can(transition.capability);

    final list = cards.isEmpty
        ? EmptyState(
            compact: true,
            icon: Icons.inbox_outlined,
            title: 'Nothing at ${stage.label}',
            message: acceptsDrops
                ? 'Jobs appear here when the stage before it is completed.'
                : 'Jobs appear here when the stage before it is completed. Pick another column '
                    'above to see where the work is.',
          )
        : ListView.separated(
            padding: const EdgeInsets.all(Spacing.sm),
            itemCount: cards.length,
            separatorBuilder: (_, __) => const SizedBox(height: Spacing.sm),
            itemBuilder: (context, index) {
              final card = cards[index];
              final move = view.moveFor(card.jobId);
              final tile = BoardCardTile(
                card: card,
                move: move,
                // `go`, not `push`: `/jobs/:id` belongs to the Jobs branch, and pushing a route
                // onto another branch's navigator in a StatefulShellRoute puts the page somewhere
                // the operator cannot see. The board's own scroll position survives, because the
                // shell keeps one navigator per branch.
                onTap: () => context.go(Paths.job(card.jobId)),
                onComplete: canMove && move == null
                    ? () => unawaited(completeCardStage(context, ref, card))
                    : null,
                completeLabel: transition == null
                    ? null
                    : 'Complete ${transition.from.label} → ${transition.to.label}',
              );

              if (!canMove || move != null || !acceptsDrops) return tile;

              return LongPressDraggable<BoardCard>(
                data: card,
                feedback: SizedBox(
                  width: feedbackWidth,
                  child: Material(
                    type: MaterialType.transparency,
                    child: BoardCardTile(card: card),
                  ),
                ),
                childWhenDragging: BoardCardTile(card: card, dimmed: true),
                child: tile,
              );
            },
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ColumnHeader(
          stage: stage,
          count: view.countIn(stage),
          transition: transition,
        ),
        Divider(height: 1, thickness: 1, color: context.dh.outlineVariant),
        Expanded(
          child: acceptsDrops
              ? DragTarget<BoardCard>(
                  // Every drop from another column is accepted so that every drop can be
                  // *answered*. Rejecting the gesture silently is the fault the mockup's dead
                  // controls already had; the refusal sentence is the point.
                  onWillAcceptWithDetails: (details) => details.data.columnStage != stage,
                  onAcceptWithDetails: (details) => unawaited(
                    dropCardOnColumn(context, ref, card: details.data, onto: stage),
                  ),
                  builder: (context, candidate, _) {
                    final incoming = candidate.isEmpty ? null : candidate.first;
                    final legal = incoming != null &&
                        dropRefusal(from: incoming.columnStage, onto: stage) == null;
                    return _DropSurface(
                      hovering: incoming != null,
                      legal: legal,
                      child: list,
                    );
                  },
                )
              : _DropSurface(hovering: false, legal: false, child: list),
        ),
      ],
    );
  }
}

final class _ColumnHeader extends StatelessWidget {
  const _ColumnHeader({
    required this.stage,
    required this.count,
    required this.transition,
  });

  final LifecycleStage stage;
  final int count;
  final StageTransition? transition;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final offBoard = transition != null && !transition!.staysOnBoard;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.sm + Spacing.xs,
        Spacing.sm + Spacing.xs,
        Spacing.sm,
        Spacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              stage.label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          if (offBoard) ...[
            Tooltip(
              message: 'Completing ${stage.label} moves the job to ${transition!.to.label}, '
                  'which is not a board column. Complete it from the card menu.',
              child: Icon(
                Icons.call_made_rounded,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: Spacing.sm),
          ],
          Text(
            '$count',
            style: AppTheme.mono(
              size: 13,
              weight: FontWeight.w600,
              color: count == 0 ? scheme.onSurfaceVariant : scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

/// The drop affordance: a ring in the accent colour for the transition that is real, and in the
/// error colour for one that is not — so the answer is visible before the finger lifts.
final class _DropSurface extends StatelessWidget {
  const _DropSurface({
    required this.hovering,
    required this.legal,
    required this.child,
  });

  final bool hovering;
  final bool legal;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    // A hairline at rest, so the column reads as a column; the accent ring only on hover.
    final border = !hovering
        ? dh.outlineVariant
        : legal
            ? scheme.secondary
            : scheme.error;
    final fill = !hovering
        ? dh.surfaceContainerLow
        : legal
            ? scheme.secondaryContainer.withValues(alpha: 0.25)
            : scheme.errorContainer.withValues(alpha: 0.35);

    return AnimatedContainer(
      duration: context.motion(Motion.fast),
      curve: context.motionCurve,
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: border, width: hovering ? 2 : 1),
        borderRadius: Radii.rMd,
      ),
      child: child,
    );
  }
}
