/// The vendor's job queue.
///
/// This screen replaces `caster_dashboard`'s "Assigned to Me" chip, which was a decorative pill
/// with nothing behind it on a screen that rendered the same hardcoded identity — "Ravi S. —
/// Manufacturing Engineer" — as the other forty-five. D-008 calls a vendor reading another
/// vendor's job a business-ending defect, so the scope here is `partner_users.partner_id` for the
/// session user and nothing else, over `v_partner_queue`. There is no filter on this screen that
/// can widen it, because there is nothing on this screen that decides it.
///
/// One surface, two viewers. A partner principal reaches `/partner` as their entire app (the
/// router fences them to that subtree and `AppShell` drops the rail, because a rail with one
/// destination is a decoration). An internal engineer, production manager or logistics operator
/// reaches the same area as a *vendor desk* and sees every outsourced stage in the org, grouped by
/// who is holding it — which is the honest answer to "who is the bottleneck" that
/// `manufacturer_dashboard` printed as a literal.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:dhanaos/core/router.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/realtime.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/features/auth/session.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/features/partner/partner_gateway.dart';
import 'package:dhanaos/features/partner/partner_surface.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class PartnerQueueScreen extends ConsumerStatefulWidget {
  const PartnerQueueScreen({super.key});

  @override
  ConsumerState<PartnerQueueScreen> createState() => _PartnerQueueScreenState();
}

class _PartnerQueueScreenState extends ConsumerState<PartnerQueueScreen> {
  /// Null until the operator picks one. The default is [PartnerQueueScope.open] rather than
  /// "needs a photo", because a queue that opens pre-filtered hides work.
  PartnerQueueScope? _chosen;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(partnerQueueLiveProvider);
    final me = ref.watch(currentUserProvider).valueOrNull;
    final scope = _chosen ?? PartnerQueueScope.open;

    return ShopFloorSurface(
      child: async.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(Spacing.md),
          child: LoadingSkeleton.list(count: 4),
        ),
        error: (error, _) => ErrorState(
          title: 'Your queue did not load',
          message: error is DhFailure
              ? error.message
              : 'DhanaOS could not read the stages assigned to you. Check the shop Wi-Fi and try '
                  'again — nothing has been lost.',
          detail: error is DhFailure ? error.detail : error.toString(),
          onRetry: () => ref.invalidate(partnerQueueLiveProvider),
        ),
        data: (live) => _Body(
          queue: live.data,
          status: live.status,
          scope: scope,
          viewerName: me?.fullName,
          onScope: (value) => setState(() => _chosen = value),
          onRefresh: () => ref.invalidate(partnerQueueLiveProvider),
        ),
      ),
    );
  }
}

// ================================================================= body

final class _Body extends StatelessWidget {
  const _Body({
    required this.queue,
    required this.status,
    required this.scope,
    required this.viewerName,
    required this.onScope,
    required this.onRefresh,
  });

  final PartnerQueue queue;
  final LiveStatus status;
  final PartnerQueueScope scope;

  /// D-008: the operator's own name, off the session row. There is no other source.
  final String? viewerName;

  final ValueChanged<PartnerQueueScope> onScope;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final rows = queue.forScope(scope);

    return RefreshIndicator(
      // The stream re-reads on its own; this is for the case a socket quietly died on shop Wi-Fi.
      onRefresh: () async => onRefresh(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.xl),
        children: [
          _Header(queue: queue, status: status, viewerName: viewerName),
          const SizedBox(height: Spacing.md),
          _Counters(queue: queue),
          const SizedBox(height: Spacing.md),
          DhSegmented<PartnerQueueScope>(
            value: scope,
            onChanged: onScope,
            segments: [
              for (final option in PartnerQueueScope.values)
                DhSegment(
                  value: option,
                  label: '${option.label} · ${queue.countIn(option)}',
                ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          if (rows.isEmpty)
            _empty(scope, queue)
          else
            for (final row in rows) ...[
              _QueueCard(row: row, queue: queue),
              const SizedBox(height: Spacing.sm + Spacing.xs),
            ],
        ],
      ),
    );
  }

  Widget _empty(PartnerQueueScope scope, PartnerQueue queue) => switch (scope) {
        PartnerQueueScope.open => EmptyState(
            icon: Icons.local_fire_department_outlined,
            title: queue.isVendorView ? 'Nothing with you right now' : 'Nothing is out with a vendor',
            message: queue.isVendorView
                ? 'When the workshop sends a job to you, it lands here with the alloy, the '
                    'temperatures and the date it is promised back.'
                : 'Every stage is in-house. Casting and certification are the only two that leave '
                    'the building — assign one from the job and it shows up here.',
          ),
        PartnerQueueScope.needsEvidence => const EmptyState(
            icon: Icons.photo_camera_outlined,
            title: 'Every casting has its photo',
            message: 'Nothing is waiting on evidence. A casting stage appears here until a photo '
                'of the cast tree is on file.',
          ),
        PartnerQueueScope.overdue => const EmptyState(
            icon: Icons.schedule_outlined,
            title: 'Nothing is past its date',
            message: 'Every stage is inside the date it was promised back.',
          ),
        PartnerQueueScope.blocked => const EmptyState(
            icon: Icons.verified_outlined,
            title: 'No open issues',
            message: 'Nothing is blocked. Report an issue from a job and it appears here until the '
                'workshop closes it.',
          ),
      };
}

// ================================================================= header

final class _Header extends StatelessWidget {
  const _Header({required this.queue, required this.status, required this.viewerName});

  final PartnerQueue queue;
  final LiveStatus status;
  final String? viewerName;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    // D-008: a vendor screen names the vendor, and the name comes off the `partners` row the
    // session's own `partner_users` link pointed at.
    final who = queue.isVendorView
        ? queue.nameFor(queue.viewerPartnerId!)
        : 'Vendor desk';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                queue.isVendorView ? 'YOUR QUEUE' : 'OUTSOURCED STAGES',
                style: context.text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: Spacing.xs),
              Text(
                who,
                style: context.text.headlineMedium?.copyWith(color: scheme.onSurface),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (viewerName != null) ...[
                const SizedBox(height: Spacing.xs),
                Text(
                  'Signed in as $viewerName',
                  style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: Spacing.sm),
        LivePulse(status: status, dense: true),
      ],
    );
  }
}

/// The four figures a vendor or a desk opens with. Every one is counted from the rows on screen,
/// so none of them can disagree with the list under it — `manufacturer_dashboard`'s "3 At Risk"
/// was a literal that never moved.
final class _Counters extends StatelessWidget {
  const _Counters({required this.queue});

  final PartnerQueue queue;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    return DhCard(
      child: DataPairGrid(
        columns: 4,
        minColumnWidth: 78,
        children: [
          DataPair.mono(
            label: 'Open',
            value: '${queue.rows.length}',
            emphasis: DataEmphasis.strong,
          ),
          DataPair.mono(
            label: 'Need a photo',
            value: '${queue.needsEvidenceCount}',
            emphasis: DataEmphasis.strong,
            valueColor: queue.needsEvidenceCount > 0 ? dh.goldText : null,
          ),
          DataPair.mono(
            label: 'Late',
            value: '${queue.lateCount}',
            emphasis: DataEmphasis.strong,
            valueColor: queue.lateCount > 0 ? scheme.error : null,
          ),
          DataPair.mono(
            label: 'Ready',
            value: '${queue.readyCount}',
            emphasis: DataEmphasis.strong,
            valueColor: queue.readyCount > 0 ? dh.success : null,
          ),
        ],
      ),
    );
  }
}

// ================================================================= one row

final class _QueueCard extends StatelessWidget {
  const _QueueCard({required this.row, required this.queue});

  final PartnerQueueRow row;
  final PartnerQueue queue;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;
    final state = row.workState;

    return DhCard(
      onTap: () => context.go(Paths.partnerJob(row.jobId)),
      accent: switch (state) {
        PartnerWorkState.blocked => scheme.error,
        PartnerWorkState.awaitingEvidence => dh.gold,
        PartnerWorkState.readyToClose => null,
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          VendorJobLine(
            code: row.displayCode,
            title: row.displayTitle,
            priority: row.priority,
            stage: row.stage,
            trailing: PartnerStateChip(state, dense: true),
          ),
          const SizedBox(height: Spacing.sm + Spacing.xs),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.xs,
            children: [
              // On the desk the vendor's name is the first thing a manager needs; on a vendor's
              // own queue it is their own name on every row, which is noise.
              if (!queue.isVendorView)
                StatusChip(
                  label: queue.nameFor(row.partnerId),
                  tone: ChipTone.neutral,
                  dense: true,
                  icon: Icons.handshake_outlined,
                ),
              StatusChip(
                label: row.dwellLabel,
                tone: ChipTone.neutral,
                dense: true,
                icon: Icons.hourglass_bottom_outlined,
              ),
              if (row.lateLabel case final lateBy?)
                StatusChip(label: lateBy, tone: ChipTone.danger, dense: true, dot: true),
            ],
          ),
          const SizedBox(height: Spacing.sm + Spacing.xs),
          DataPairGrid(
            columns: 3,
            minColumnWidth: 104,
            children: [
              DataPair.mono(label: 'Alloy', value: row.alloy ?? DataPair.placeholder),
              DataPair.mono(
                label: 'Flask',
                value: row.flaskTempC == null ? DataPair.placeholder : '${row.flaskTempC} °C',
              ),
              // The hazardous figure, coloured even in the compact row. Pouring 18K at 1020 °C and
              // at 1200 °C are not equivalent mistakes.
              DataPair.mono(
                label: 'Metal',
                value: row.metalTempC == null ? DataPair.placeholder : '${row.metalTempC} °C',
                valueColor: row.metalTempC == null ? null : dh.goldText,
                emphasis: DataEmphasis.strong,
              ),
            ],
          ),
          if (row.expectedAt case final due?) ...[
            const SizedBox(height: Spacing.sm + Spacing.xs),
            Row(
              children: [
                Icon(Icons.event_outlined, size: 15, color: scheme.onSurfaceVariant),
                const SizedBox(width: Spacing.xs + 2),
                Text(
                  'Promised back ',
                  style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
                Text(
                  // Convention 7: Postgres hands us UTC, the caster reads local time.
                  _promiseLabel(due),
                  style: AppTheme.mono(
                    size: 12,
                    weight: FontWeight.w600,
                    color: row.isLate ? scheme.error : scheme.onSurface,
                  ),
                ),
              ],
            ),
          ],
          // D-011 rule 1, stated on the card so a caster knows before they open it.
          if (row.needsCastingEvidence && !row.isBlocked) ...[
            const SizedBox(height: Spacing.sm + Spacing.xs),
            const GateNote(
              icon: Icons.photo_camera_outlined,
              reason: 'Required before marking complete: a photo of the cast tree.',
            ),
          ],
        ],
      ),
    );
  }

  /// '12 Aug · 17:00'. Short because it sits inline; the full date is on the job screen.
  /// Convention 7: the instant arrives in UTC and is rendered in the caster's own time.
  static final _promiseFormat = DateFormat('d MMM · HH:mm');

  static String _promiseLabel(DateTime utc) => _promiseFormat.format(utc.toLocal());
}
