/// The retailer's own orders.
///
/// This is the screen the mockups named and never drew. `certification` listed "Client Portal" as
/// an actor in its audit trail and `quality_acceptance` offered "Customer" as a sign-off
/// authority, yet across four exports and 46 screens not one customer-facing surface existed — the
/// retailer was a row in somebody else's feed.
///
/// Status only, by design. A client needs to know where their piece is, what it will cost and what
/// is waiting on them; they do not need the vendor's name, the bench's dwell times or the internal
/// thread. D-008 enforces that in Postgres (`auth_can_see_job` restricts a customer to
/// `jobs.customer_id = auth_customer()`); this screen simply never asks for the rest.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:dhanaos/core/router.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/realtime.dart';
import 'package:dhanaos/features/auth/session.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/features/portal/portal_approvals.dart';
import 'package:dhanaos/features/portal/portal_gateway.dart';
import 'package:dhanaos/features/portal/portal_surface.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

/// Which slice of the client's orders is on screen.
enum PortalScope {
  active('In progress'),
  finished('Delivered'),
  all('All orders');

  const PortalScope(this.label);

  final String label;

  bool accepts(PortalJobCard card) => switch (this) {
        active => !card.isFinished,
        finished => card.isFinished,
        all => true,
      };
}

final class PortalJobsScreen extends ConsumerStatefulWidget {
  const PortalJobsScreen({super.key});

  @override
  ConsumerState<PortalJobsScreen> createState() => _PortalJobsScreenState();
}

class _PortalJobsScreenState extends ConsumerState<PortalJobsScreen> {
  PortalScope _scope = PortalScope.active;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(portalJobsLiveProvider);
    final me = ref.watch(currentUserProvider).value;
    // A failure here must not take the orders list down with it — the banner is a convenience,
    // the list is the screen.
    final approvals = ref.watch(portalApprovalsProvider).value;

    return ClientSurface(
      child: async.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(Spacing.md),
          child: LoadingSkeleton.list(count: 3),
        ),
        error: (error, _) => ErrorState(
          title: 'Your orders did not load',
          message: error is DhFailure
              ? error.message
              : 'DhanaOS could not reach the workshop just now. Check your connection and try '
                  'again.',
          detail: error is DhFailure ? error.detail : error.toString(),
          onRetry: () => ref.invalidate(portalJobsLiveProvider),
        ),
        data: (live) => _list(live, me?.fullName, approvals),
      ),
    );
  }

  Widget _list(
    Live<List<PortalJobCard>> live,
    String? viewerName,
    PortalApprovals? approvals,
  ) {
    final cards = [for (final card in live.data) if (_scope.accepts(card)) card];
    final waiting = approvals?.outstandingCount ?? 0;

    return RefreshIndicator(
      onRefresh: () async {
        ref
          ..invalidate(portalJobsLiveProvider)
          ..invalidate(portalApprovalsProvider);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.xl),
        children: [
          _Header(viewerName: viewerName, status: live.status),
          if (waiting > 0) ...[
            const SizedBox(height: Spacing.md),
            _WaitingBanner(count: waiting),
          ],
          const SizedBox(height: Spacing.md),
          DhSegmented<PortalScope>(
            value: _scope,
            onChanged: (value) => setState(() => _scope = value),
            segments: [
              for (final option in PortalScope.values)
                DhSegment(
                  value: option,
                  label: '${option.label} · '
                      '${live.data.where(option.accepts).length}',
                ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          if (cards.isEmpty)
            _empty(live.data.isEmpty)
          else
            for (final card in cards) ...[
              _OrderCard(card: card),
              const SizedBox(height: Spacing.sm + Spacing.xs),
            ],
        ],
      ),
    );
  }

  Widget _empty(bool nothingAtAll) {
    if (nothingAtAll) {
      return const EmptyState(
        icon: Icons.diamond_outlined,
        title: 'No orders yet',
        message: 'When the workshop opens a job order for you, it appears here with its progress, '
            'its documents and anything waiting on your approval.',
      );
    }
    return switch (_scope) {
      PortalScope.active => EmptyState(
          icon: Icons.task_alt_rounded,
          title: 'Nothing in progress',
          message: 'Every order of yours has been delivered.',
          actionLabel: 'See delivered orders',
          onAction: () => setState(() => _scope = PortalScope.finished),
        ),
      PortalScope.finished => EmptyState(
          icon: Icons.local_shipping_outlined,
          title: 'Nothing delivered yet',
          message: 'Your orders are still being made. They move here once they are handed over.',
          actionLabel: 'See what is in progress',
          onAction: () => setState(() => _scope = PortalScope.active),
        ),
      PortalScope.all => const EmptyState(
          icon: Icons.diamond_outlined,
          title: 'No orders',
          message: 'Nothing is on your account.',
        ),
    };
  }
}

// ================================================================= header

final class _Header extends StatelessWidget {
  const _Header({required this.viewerName, required this.status});

  /// D-008: the client's own name, off the session row. All 46 mockups printed one hardcoded
  /// internal identity — "Ravi S. — Manufacturing Engineer" — including on the screen a customer
  /// would have been looking at.
  final String? viewerName;

  final LiveStatus status;

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
              Text(
                'YOUR ORDERS',
                style: context.text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: Spacing.xs),
              Text(
                viewerName ?? 'Client portal',
                style: context.text.headlineMedium?.copyWith(color: scheme.onSurface),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        const SizedBox(width: Spacing.sm),
        LivePulse(status: status, dense: true),
      ],
    );
  }
}

/// The one thing a client must not scroll past.
final class _WaitingBanner extends StatelessWidget {
  const _WaitingBanner({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final dh = context.dh;
    return DhCard(
      accent: dh.gold,
      // Pushed rather than routed: deciding is a task inside the portal, and it belongs on the
      // stack above the orders list so backing out returns there.
      onTap: () => unawaited(PortalApprovalsScreen.push(context)),
      child: Row(
        children: [
          Icon(Icons.pending_actions_outlined, size: 20, color: dh.goldText),
          const SizedBox(width: Spacing.sm + Spacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  count == 1 ? '1 thing needs your approval' : '$count things need your approval',
                  style: context.text.titleMedium?.copyWith(color: context.scheme.onSurface),
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  'Until you decide, the workshop holds the piece where it is.',
                  style: context.text.bodySmall
                      ?.copyWith(color: context.scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: context.scheme.onSurfaceVariant),
        ],
      ),
    );
  }
}

// ================================================================= one order

final class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.card});

  final PortalJobCard card;

  /// Convention 7: a `date` column is a calendar day; it renders as one.
  static final _due = DateFormat('d MMM yyyy');

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final due = card.dueDate;

    return DhCard(
      onTap: () => context.go(Paths.portalJob(card.id)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OrderLine(
            code: card.code,
            title: card.title,
            trailing: StatusChip.job(card.job.status, dense: true),
          ),
          const SizedBox(height: Spacing.md),
          PortalPhaseBar(
            phase: card.phase,
            progress: card.progress,
            paused: card.isPaused,
            note: card.isPaused
                ? 'Paused. The workshop will be in touch about what they need.'
                : card.phase.blurb,
          ),
          if (due != null) ...[
            const SizedBox(height: Spacing.md),
            Row(
              children: [
                Icon(Icons.event_outlined, size: 15, color: scheme.onSurfaceVariant),
                const SizedBox(width: Spacing.xs + 2),
                Text(
                  card.isFinished ? 'Was due ' : 'Expected ',
                  style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
                Text(
                  _due.format(due.toLocal()),
                  style: AppTheme.mono(
                    size: 12,
                    weight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
