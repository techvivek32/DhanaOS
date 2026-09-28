/// The job record — the product's hub, and the richest screen in the source corpus.
///
/// Modelled on `job_detail_dh_1048`, which was the only mockup that put the whole shape of a job
/// on one page: a metadata quad, the 14-node lifecycle rail, the current action with its received
/// and expected timestamps, a "Network Hub" of everyone involved, the project files, and the
/// digital thread. Everything below it was hardcoded — the rail's position, the "1d in stage", the
/// participant list, the "12 project files" counter and the live dot. Every one of those now comes
/// off a row.
///
/// D-005 decides what this screen believes. `jobs.current_stage` is a trigger-maintained cache;
/// the truth is the newest `job_stages` row with `state = active`, and `JobSnapshot.stage` returns
/// the rail's answer. When the two disagree — which happens for a second after a transition, and
/// permanently if a trigger is missing — the rail wins.
///
/// D-008 decides what it renders. Every name on this screen came out of a table: the customer from
/// `customers`, the holders from `app_users` and `partners`, the poster from the session. There is
/// no fallback literal anywhere, because the mockups' one hardcoded identity leaked onto the
/// vendor's screen and the customer's approval screen.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:dhanaos/core/router.dart';
import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/repositories/customer_repository.dart';
import 'package:dhanaos/data/repositories/job_repository.dart';
import 'package:dhanaos/data/repositories/quote_repository.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/data/supabase/realtime.dart';
import 'package:dhanaos/data/supabase/storage.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/permissions.dart';
import 'package:dhanaos/features/auth/session.dart';
import 'package:dhanaos/features/jobs/assign_sheet.dart';
import 'package:dhanaos/features/jobs/digital_thread.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/features/jobs/stage_actions.dart';
import 'package:dhanaos/shared/widgets/widgets.dart';

part 'job_detail_screen.g.dart';

/// The manufacturing entity itself — "AuraForge India" in the mockups, where it was a string.
///
/// The metadata quad's Manufacturer cell reads the partner holding the active stage when the work
/// has left the building, and this when it has not. That is the informative reading of a field the
/// source printed identically on every job.
@Riverpod(keepAlive: true)
Future<Org?> currentOrg(Ref ref) async {
  final user = await ref.watch(currentUserProvider.future);
  if (user == null) return null;
  final client = ref.watch(supabaseProvider);
  final row = await guardOrNull(
    () => client.from('orgs').select().eq('id', user.orgId).maybeSingle(),
  );
  return row == null ? null : Org.fromJson(row);
}

// ================================================================= screen

final class JobDetailScreen extends ConsumerWidget {
  const JobDetailScreen({super.key, required this.jobId});

  final String jobId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(jobSnapshotProvider(jobId));

    return switch (snapshot) {
      AsyncValue(value: final live?) => _JobDetailBody(jobId: jobId, live: live),
      AsyncError(error: final error) => _DetailError(
          jobId: jobId,
          failure: error is DhFailure ? error : null,
        ),
      _ => const Padding(
          padding: EdgeInsets.all(Spacing.md),
          child: LoadingSkeleton.list(count: 4),
        ),
    };
  }
}

final class _DetailError extends ConsumerWidget {
  const _DetailError({required this.jobId, required this.failure});

  final String jobId;
  final DhFailure? failure;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notFound = failure?.kind == FailureKind.notFound;
    return ErrorState(
      icon: notFound ? Icons.search_off_rounded : Icons.error_outline_rounded,
      title: notFound ? 'That job is not here' : 'The job did not load',
      message: failure?.message ??
          'Check the connection and try again. Nothing on the job has changed.',
      detail: failure?.detail,
      onRetry: () => ref.invalidate(jobSnapshotProvider(jobId)),
      secondaryLabel: 'Back to the job list',
      onSecondary: () => context.go(Paths.jobs),
    );
  }
}

final class _JobDetailBody extends ConsumerWidget {
  const _JobDetailBody({required this.jobId, required this.live});

  final String jobId;
  final Live<JobSnapshot> live;

  JobSnapshot get snapshot => live.data;
  Job get job => snapshot.job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(permissionsProvider);
    final open = snapshot.openExceptions;

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(jobSnapshotProvider(jobId)),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.xxl),
        children: [
          _Header(job: job, status: live.status),
          const SizedBox(height: Spacing.md),
          _MetadataQuad(snapshot: snapshot),
          const SizedBox(height: Spacing.md),
          _RailCard(snapshot: snapshot),
          const SizedBox(height: Spacing.md),
          _CurrentActionCard(snapshot: snapshot),
          if (open.isNotEmpty) ...[
            const SizedBox(height: Spacing.md),
            SectionHeading(title: 'Open issues', count: open.length),
            const SizedBox(height: Spacing.sm + Spacing.xs),
            for (final exception in open) ...[
              ExceptionCard(exception: exception, canResolve: permissions.canEditJob),
              const SizedBox(height: Spacing.sm),
            ],
          ],
          const SizedBox(height: Spacing.md),
          _NetworkHub(snapshot: snapshot),
          const SizedBox(height: Spacing.md),
          _ProjectFiles(jobId: jobId, canUpload: permissions.canEditJob),
          const SizedBox(height: Spacing.lg),
          DigitalThread(jobId: jobId, stage: snapshot.stage),
        ],
      ),
    );
  }
}

// ================================================================= header

final class _Header extends StatelessWidget {
  const _Header({required this.job, required this.status});

  final Job job;
  final LiveStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // D-001: `DH-2026-01842` before anything else on the screen. It is the thing an
            // operator reads out over a bench.
            Text(
              job.displayCode,
              style: AppTheme.mono(size: 15, weight: FontWeight.w700, color: scheme.onSurface),
            ),
            const SizedBox(width: Spacing.sm),
            LivePulse(status: status, dense: true),
            const Spacer(),
            StatusChip.job(job.status, dense: true),
          ],
        ),
        const SizedBox(height: Spacing.sm),
        Text(job.displayTitle, style: context.text.headlineMedium),
        const SizedBox(height: Spacing.sm),
        Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.xs,
          children: [
            PriorityChip(job.priority, dense: true),
            if (job.jobType != null) StatusChip(label: job.jobType!.label, dense: true),
            if (job.category != null) StatusChip(label: job.category!.label, dense: true),
            if (job.quantity > 1) StatusChip.code('×${job.quantity}', dense: true),
            if (job.hardDeadline)
              const StatusChip(
                label: 'Hard deadline',
                tone: ChipTone.warning,
                icon: Icons.push_pin_outlined,
                dense: true,
              ),
            // D-006 / D-012: a client's own stone puts the workshop in custody of something it
            // does not own, which is a different job from start to finish.
            if (job.takesCustody)
              const StatusChip(
                label: 'Customer materials',
                tone: ChipTone.warning,
                icon: Icons.diamond_outlined,
                dense: true,
                tooltip: 'This job holds a stone the workshop does not own. Declared value, '
                    'verifier and receipt are on the custody record.',
              ),
          ],
        ),
      ],
    );
  }
}

// ================================================================= metadata quad

/// Customer · Manufacturer · Due · Value — the four cells `job_detail` opened with.
final class _MetadataQuad extends ConsumerWidget {
  const _MetadataQuad({required this.snapshot});

  final JobSnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final job = snapshot.job;
    final customerId = job.customerId;
    final customer =
        customerId == null ? null : ref.watch(customerProvider(customerId)).value;
    final partners = ref.watch(partnersByIdProvider).value ?? const <String, Partner>{};
    final org = ref.watch(currentOrgProvider).value;
    final quote = ref.watch(latestJobQuoteProvider(job.id)).value;

    final activePartnerId = snapshot.activeStage?.assignedPartner;
    final partner = activePartnerId == null ? null : partners[activePartnerId];

    final due = job.promisedDelivery ?? job.requestedDelivery;
    final daysToDue = job.daysToDue;

    return DhCard(
      child: DataPairGrid(
        children: [
          DataPair(
            label: 'Customer',
            value: customer?.name ?? (customerId == null ? 'Not linked' : '…'),
            icon: Icons.storefront_outlined,
          ),
          DataPair(
            label: 'Manufacturer',
            // The mockup printed the org on every job, which is no information at all. The
            // informative answer is who physically holds the piece right now.
            value: partner?.name ?? org?.displayName ?? 'In-house',
            icon: partner == null
                ? Icons.precision_manufacturing_outlined
                : Icons.local_shipping_outlined,
          ),
          DataPair.mono(
            label: 'Due',
            value: due == null
                ? 'Not set'
                : DateFormat('d MMM yyyy').format(due.toLocal()),
            valueColor: job.overdue ? context.scheme.error : null,
            trailing: daysToDue == null
                ? null
                : StatusChip.code(
                    daysToDue < 0
                        ? '${-daysToDue}d late'
                        : daysToDue == 0
                            ? 'today'
                            : '${daysToDue}d',
                    dense: true,
                    tone: job.overdue
                        ? ChipTone.danger
                        : (job.dueSoon ? ChipTone.warning : ChipTone.neutral),
                  ),
          ),
          if (quote == null)
            const DataPair(
              label: 'Value',
              // An unpriced job must show nothing, not zero — zero is a price.
              value: 'Not quoted',
            )
          else
            DataPair.money(
              label: 'Value',
              amount: quote.grandTotal,
              trailing: StatusChip.quote(quote.status, dense: true),
            ),
        ],
      ),
    );
  }
}

// ================================================================= rail

/// The 14-node lifecycle rail. Tapping a node opens what is known about that stage.
final class _RailCard extends ConsumerWidget {
  const _RailCard({required this.snapshot});

  final JobSnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rail = snapshot.rail;

    if (!rail.isSeeded) {
      return DhCard(
        tone: DhCardTone.inset,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.timeline_outlined, size: 20, color: context.scheme.onSurfaceVariant),
            const SizedBox(width: Spacing.sm + Spacing.xs),
            Expanded(
              child: Text(
                'The rail is seeded when the job order is committed — all fourteen stages at '
                'once, so the timeline reads complete from day one. This job has '
                '${rail.length} of 14.',
                style: context.text.bodyMedium?.copyWith(
                  color: context.scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return DhSectionCard(
      title: 'Lifecycle',
      subtitle: '${rail.settledCount} of 14 settled · '
          '${(rail.progress * 100).round()}% of the rail travelled',
      padding: const EdgeInsets.symmetric(vertical: Spacing.md),
      child: JobStageRail(
        nodes: [
          for (final row in rail.stages)
            StageNode(
              stage: row.stage,
              state: row.state,
              detail: row.enteredAt == null ? null : row.dwellLabel,
              isLate: row.isLate,
              withPartner: row.isWithPartner,
            ),
        ],
        onTap: (node) => unawaited(_openStage(context, ref, node.stage)),
      ),
    );
  }

  /// The sheet returns true when the operator asked to assign the stage. Opening the assign sheet
  /// is done from *this* context rather than from inside the first sheet, because that sheet's
  /// element is gone the moment it pops.
  Future<void> _openStage(BuildContext context, WidgetRef ref, LifecycleStage stage) async {
    final row = snapshot.rail.stageFor(stage);
    if (row == null) return;

    final wantsAssign = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (_) => _StageSheet(row: row),
    );
    if (wantsAssign != true || !context.mounted) return;

    await AssignSheet.show(
      context,
      jobId: snapshot.job.id,
      stage: row.stage,
      current: row,
    );
  }
}

/// What is known about one rail node: when it opened, what it was promised for, who holds it, and
/// whatever the bench wrote on it.
final class _StageSheet extends ConsumerWidget {
  const _StageSheet({required this.row});

  final JobStage row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(orgUsersByIdProvider).value ?? const <String, AppUser>{};
    final partners = ref.watch(partnersByIdProvider).value ?? const <String, Partner>{};
    final permissions = ref.watch(permissionsProvider);

    final assignee = row.assignedTo == null ? null : users[row.assignedTo];
    final partner = row.assignedPartner == null ? null : partners[row.assignedPartner];

    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${row.seq}. ${row.stage.label}',
                  style: context.text.headlineSmall,
                ),
              ),
              StatusChip.stage(row.state, dense: true),
            ],
          ),
          const SizedBox(height: Spacing.md),
          DataPairGrid(
            children: [
              if (row.enteredAt != null)
                DataPair.timestamp(label: 'Received', utc: row.enteredAt!)
              else
                const DataPair.mono(label: 'Received', value: 'Not reached'),
              if (row.expectedAt != null)
                DataPair.timestamp(
                  label: 'Expected',
                  utc: row.expectedAt!,
                  valueColor: row.isLate ? context.scheme.error : null,
                )
              else
                const DataPair.mono(label: 'Expected', value: 'Not promised'),
              if (row.completedAt != null)
                DataPair.timestamp(label: 'Completed', utc: row.completedAt!),
              DataPair.mono(label: 'Time in stage', value: row.dwellLabel),
            ],
          ),
          const SizedBox(height: Spacing.md),
          DataPair(
            label: 'Held by',
            value: partner?.displayName ??
                assignee?.fullName ??
                (row.isUnassigned ? 'Nobody yet' : 'Someone outside your directory'),
            icon: partner == null ? Icons.person_outline_rounded : Icons.local_shipping_outlined,
          ),
          if (row.blockedReason != null) ...[
            const SizedBox(height: Spacing.md),
            DhCard(
              tone: DhCardTone.inset,
              accent: context.scheme.error,
              child: Text(row.blockedReason!, style: context.text.bodyMedium),
            ),
          ],
          if (row.notes != null) ...[
            const SizedBox(height: Spacing.md),
            DataPair(label: 'Notes', value: row.notes!, maxLines: 6),
          ],
          if (permissions.canEditJob && !row.isClosed) ...[
            const SizedBox(height: Spacing.lg),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.person_add_alt_rounded, size: 18),
              label: Text('Assign ${row.stage.label}'),
            ),
          ],
        ],
      ),
    );
  }
}

// ================================================================= current action

/// Where the job stands, and everything that can be done to it from here.
final class _CurrentActionCard extends ConsumerWidget {
  const _CurrentActionCard({required this.snapshot});

  final JobSnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = snapshot.activeStage;
    final users = ref.watch(orgUsersByIdProvider).value ?? const <String, AppUser>{};
    final partners = ref.watch(partnersByIdProvider).value ?? const <String, Partner>{};

    final assignee = active?.assignedTo == null ? null : users[active!.assignedTo];
    final partner = active?.assignedPartner == null ? null : partners[active!.assignedPartner];
    final holder = partner?.name ?? assignee?.fullName;

    return DhSectionCard(
      title: 'Current action',
      subtitle: active == null
          ? 'No stage is active'
          : '${active.stage.label} · ${active.state.label}',
      action: active == null ? null : StatusChip.stage(active.state, dense: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (active != null) ...[
            DataPairGrid(
              children: [
                if (active.enteredAt != null)
                  DataPair.timestamp(label: 'Received', utc: active.enteredAt!)
                else
                  const DataPair.mono(label: 'Received', value: '—'),
                if (active.expectedAt != null)
                  DataPair.timestamp(
                    label: 'Expected',
                    utc: active.expectedAt!,
                    valueColor: active.isLate ? context.scheme.error : null,
                  )
                else
                  const DataPair.mono(label: 'Expected', value: 'Not promised'),
                DataPair.mono(
                  label: 'Time in stage',
                  value: active.dwellLabel,
                  emphasis: DataEmphasis.strong,
                  valueColor: active.isLate ? context.scheme.error : null,
                ),
                DataPair.custom(
                  label: 'Held by',
                  child: Row(
                    children: [
                      PersonAvatar(
                        name: holder,
                        size: 24,
                        tone: partner != null ? AvatarTone.gold : AvatarTone.neutral,
                      ),
                      const SizedBox(width: Spacing.sm),
                      Flexible(
                        child: Text(
                          holder ?? 'Unassigned',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.bodyMedium?.copyWith(
                            color: holder == null
                                ? context.scheme.onSurfaceVariant
                                : context.scheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: Spacing.md),
          ],
          StageActionsBar(snapshot: snapshot),
        ],
      ),
    );
  }
}

// ================================================================= network hub

/// Everyone this job touches — the retailer, whoever opened it, and every holder on the rail.
///
/// `job_detail` drew a "Network Hub" participant list with three hardcoded names and no source.
/// This is built from the rail itself, so a partner appears the moment a stage is assigned to
/// them and disappears when it is cleared — which is exactly the event that decides what they can
/// see (D-008).
final class _NetworkHub extends ConsumerWidget {
  const _NetworkHub({required this.snapshot});

  final JobSnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(orgUsersByIdProvider).value ?? const <String, AppUser>{};
    final partners = ref.watch(partnersByIdProvider).value ?? const <String, Partner>{};
    final customerId = snapshot.job.customerId;
    final customer =
        customerId == null ? null : ref.watch(customerProvider(customerId)).value;

    final entries = <_Participant>[];

    if (customer != null) {
      entries.add(
        _Participant(
          name: customer.name,
          role: 'Customer',
          detail: customer.contactName ?? customer.email,
          icon: Icons.storefront_outlined,
          tone: AvatarTone.accent,
        ),
      );
    }

    final createdBy = snapshot.job.createdBy;
    final opener = createdBy == null ? null : users[createdBy];
    if (opener != null) {
      entries.add(
        _Participant(
          name: opener.fullName,
          role: 'Opened the job',
          detail: opener.subtitle,
          icon: Icons.play_circle_outline_rounded,
        ),
      );
    }

    // Rail order, not alphabetical: the list reads as the route the piece takes.
    final seen = <String>{};
    for (final row in snapshot.rail.stages) {
      final partnerId = row.assignedPartner;
      if (partnerId != null && seen.add('p:$partnerId')) {
        final partner = partners[partnerId];
        entries.add(
          _Participant(
            name: partner?.name ?? 'Partner outside your directory',
            role: row.stage.label,
            detail: partner == null
                ? null
                : [
                    partner.kind.label,
                    if (partner.contactName != null) partner.contactName!,
                    if (partner.phone != null) partner.phone!,
                  ].join(' · '),
            icon: Icons.local_shipping_outlined,
            tone: AvatarTone.gold,
          ),
        );
      }
      final userId = row.assignedTo;
      if (userId != null && seen.add('u:$userId') && userId != createdBy) {
        final user = users[userId];
        entries.add(
          _Participant(
            name: user?.fullName ?? 'Someone outside your directory',
            role: row.stage.label,
            detail: user?.subtitle,
            icon: Icons.person_outline_rounded,
          ),
        );
      }
    }

    return DhSectionCard(
      title: 'Network hub',
      subtitle: entries.isEmpty
          ? 'Nobody is attached to this job yet'
          : '${entries.length} ${entries.length == 1 ? 'party' : 'parties'} on this job',
      child: entries.isEmpty
          ? const EmptyState(
              compact: true,
              icon: Icons.hub_outlined,
              title: 'No participants yet',
              message: 'Link a customer and assign the active stage. Whoever holds a stage '
                  'appears here — and only then can they see the job at all.',
            )
          : Column(
              children: [
                for (var i = 0; i < entries.length; i++) ...[
                  if (i > 0) const SizedBox(height: Spacing.sm + Spacing.xs),
                  _ParticipantRow(participant: entries[i]),
                ],
              ],
            ),
    );
  }
}

@immutable
final class _Participant {
  const _Participant({
    required this.name,
    required this.role,
    required this.icon,
    this.detail,
    this.tone = AvatarTone.neutral,
  });

  final String name;
  final String role;
  final String? detail;
  final IconData icon;
  final AvatarTone tone;
}

final class _ParticipantRow extends StatelessWidget {
  const _ParticipantRow({required this.participant});

  final _Participant participant;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Row(
      children: [
        PersonAvatar(name: participant.name, tone: participant.tone),
        const SizedBox(width: Spacing.sm + Spacing.xs),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                participant.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (participant.detail != null)
                Text(
                  participant.detail!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
            ],
          ),
        ),
        const SizedBox(width: Spacing.sm),
        StatusChip(label: participant.role, dense: true, icon: participant.icon),
      ],
    );
  }
}

// ================================================================= files

/// The project files, with a real populated state.
///
/// The corpus counted "12 project files" and drew a dashed dropzone; the photos it did show were
/// remote URLs that will rot. These are `attachments` rows in a Supabase bucket, thumbnailed
/// through signed URLs that expire in thirty minutes.
final class _ProjectFiles extends ConsumerWidget {
  const _ProjectFiles({required this.jobId, required this.canUpload});

  final String jobId;
  final bool canUpload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final files = ref.watch(jobFilesProvider(jobId));
    final urls = ref.watch(jobFileUrlsProvider(jobId)).value ?? const <String, String>{};

    return DhSectionCard(
      title: 'Project files',
      subtitle: switch (files) {
        AsyncValue(value: final list?) when list.isEmpty => 'Nothing attached yet',
        AsyncValue(value: final list?) =>
          '${list.length} ${list.length == 1 ? 'file' : 'files'} on this job',
        _ => 'Loading',
      },
      child: switch (files) {
        AsyncValue(value: final list?) when list.isEmpty => const EmptyState(
            compact: true,
            icon: Icons.folder_open_outlined,
            title: 'No files on this job',
            message: 'Reference photos, CAD renders, casting evidence and certificates all land '
                'here. Post one on the thread below to attach it.',
          ),
        AsyncValue(value: final list?) => AttachmentGrid(
            items: [
              for (final file in list) attachmentViewOf(file, signedUrl: urls[file.id]),
            ],
            onDelete: canUpload
                ? (view) {
                    final byId = {for (final file in list) file.id: file};
                    final file = byId[view.id];
                    if (file != null) unawaited(_delete(context, ref, file));
                  }
                : null,
          ),
        AsyncError(error: final error) => ErrorState(
            compact: true,
            title: 'The files did not load',
            message: error is DhFailure ? error.message : 'Pull down to refresh.',
            detail: error is DhFailure ? error.detail : null,
            onRetry: () => ref.invalidate(jobFilesProvider(jobId)),
          ),
        _ => const LoadingSkeleton.lines(count: 2),
      },
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Attachment file) async {
    final confirmed = await confirmAction(
      context,
      title: 'Remove ${file.filename}?',
      message: file.isCastingEvidence
          ? 'This is the casting evidence. Removing it re-blocks the casting stage — a photo is '
              'required before it can be marked complete.'
          : 'The file is deleted from storage as well as from this job. It cannot be recovered '
              'from here.',
      confirmLabel: 'Remove the file',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;

    try {
      await ref.read(attachmentStoreProvider).delete(file);
      ref.invalidate(jobFilesProvider(jobId));
      if (!context.mounted) return;
      showDone(context, '${file.filename} removed.');
    } on DhFailure catch (failure) {
      if (!context.mounted) return;
      showFailure(context, failure);
    }
  }
}
