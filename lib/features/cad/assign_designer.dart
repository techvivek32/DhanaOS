/// "Assign CAD Designer" — the button `job_order_created` ended on, which went nowhere.
///
/// The mockup's last screen finished with "Next Step: CAD — Unassigned" and a button behind which
/// there was no picker, no directory and no notion that a workshop contains more than one person:
/// all 46 files rendered the same hardcoded identity (D-008). This is the picker, and it writes
/// the row that actually means something — `job_stages.assigned_to`, which is what
/// `v_job_list.assigned_to` joins and therefore what puts the job on somebody's queue.
///
/// Two things this sheet knows that the intake-time picker cannot:
///
///  * **Workload.** Handing a fifth open CAD to the person already carrying four is the decision
///    this screen exists to prevent, so every row carries their unfinished count, and the list is
///    ordered by it.
///  * **Which rail row to write.** A rejected version does not walk the job backwards (D-005), so
///    a job answering a revision request can be standing at `approval` while the work is CAD
///    work. Writing the assignment onto the `cad` row there would be a record no queue ever
///    reads — see [CadActions.stageFor].
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';
import 'package:dhanaos/features/auth/session.dart';
import 'package:dhanaos/features/cad/cad_actions.dart';
import 'package:dhanaos/features/cad/cad_gateway.dart';
import 'package:dhanaos/features/cad/widgets/cad_widgets.dart';
import 'package:dhanaos/features/intake/intake_gateway.dart';
import 'package:dhanaos/features/jobs/job_widgets.dart';
import 'package:dhanaos/shared/widgets/widgets.dart' hide StageRail;

final class AssignDesignerSheet extends ConsumerStatefulWidget {
  const AssignDesignerSheet({
    super.key,
    required this.jobId,
    required this.jobCode,
    this.stage = LifecycleStage.cad,
    this.currentAssigneeId,
  });

  final String jobId;

  /// 'DH-2026-01842' — shown so the operator can see which job they are handing over.
  final String jobCode;

  /// The rail row the assignment is written to. Use [CadActions.stageFor].
  final LifecycleStage stage;

  final String? currentAssigneeId;

  /// Opens the sheet. Returns true when an assignment was written.
  static Future<bool> show(
    BuildContext context, {
    required String jobId,
    required String jobCode,
    LifecycleStage stage = LifecycleStage.cad,
    String? currentAssigneeId,
  }) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.9,
        child: AssignDesignerSheet(
          jobId: jobId,
          jobCode: jobCode,
          stage: stage,
          currentAssigneeId: currentAssigneeId,
        ),
      ),
    );
    return saved ?? false;
  }

  @override
  ConsumerState<AssignDesignerSheet> createState() => _AssignDesignerSheetState();
}

class _AssignDesignerSheetState extends ConsumerState<AssignDesignerSheet> {
  final _search = TextEditingController();

  /// The promise written onto `job_stages.expected_at`. Optional: a date nobody agreed to is
  /// worse than no date, because the rail then reports a stage as late on the strength of a
  /// number the picker invented.
  DateTime? _expectedAt;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(cadDesignerDirectoryProvider);
    final workload = ref.watch(cadWorkloadProvider);
    final task = ref.watch(cadActionsProvider);
    final busy = task == CadTask.assign;
    final me = ref.watch(currentUserProvider).value;

    return SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _head(context),
          Expanded(
            child: async.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(Spacing.md),
                child: LoadingSkeleton.list(count: 4),
              ),
              error: (error, _) => Padding(
                padding: const EdgeInsets.all(Spacing.md),
                child: ErrorState(
                  title: 'The team directory did not load',
                  message: error is DhFailure
                      ? error.message
                      : 'DhanaOS could not read the list of people in this workshop.',
                  detail: error is DhFailure ? error.detail : error.toString(),
                  onRetry: () => ref.invalidate(cadDesignerDirectoryProvider),
                ),
              ),
              data: (directory) => _list(
                directory,
                workload: workload,
                busy: busy,
                me: me,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _head(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.currentAssigneeId == null ? 'Assign the CAD' : 'Reassign the CAD',
                  style: context.text.headlineSmall?.copyWith(color: context.scheme.onSurface),
                ),
              ),
              StatusChip(
                label: widget.jobCode,
                tone: ChipTone.neutral,
                dense: true,
                mono: true,
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            'Whoever takes it draws from the references captured at intake. The assignment is '
            'written onto the ${widget.stage.label} row of the rail, which is what puts the job '
            'on their queue.',
            style: context.text.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant),
          ),
          const SizedBox(height: Spacing.md),
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search the workshop',
              prefixIcon: const Icon(Icons.search_rounded),
              isDense: true,
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      onPressed: () => setState(_search.clear),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      tooltip: 'Clear the search',
                    ),
            ),
          ),
          const SizedBox(height: Spacing.sm + Spacing.xs),
          _expectedRow(context),
        ],
      ),
    );
  }

  Widget _expectedRow(BuildContext context) {
    final chosen = _expectedAt;

    return Row(
      children: [
        Icon(Icons.event_outlined, size: 18, color: context.scheme.onSurfaceVariant),
        const SizedBox(width: Spacing.sm),
        Expanded(
          child: Text(
            chosen == null
                ? 'No date promised'
                : 'Expected by ${localStamp(chosen, withTime: false)}',
            style: chosen == null
                ? context.text.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant)
                : AppTheme.mono(size: 12, color: context.scheme.onSurface),
          ),
        ),
        if (chosen != null)
          IconButton(
            onPressed: () => setState(() => _expectedAt = null),
            icon: const Icon(Icons.close_rounded, size: 18),
            tooltip: 'Drop the date',
          ),
        TextButton(
          onPressed: () => unawaited(_pickDate()),
          child: Text(chosen == null ? 'Set a date' : 'Change'),
        ),
      ],
    );
  }

  Widget _list(
    DesignerDirectory directory, {
    required Map<String, int> workload,
    required bool busy,
    required AppUser? me,
  }) {
    if (directory.isEmpty) {
      return const EmptyState(
        icon: Icons.person_search_outlined,
        title: 'Nobody to assign yet',
        message: 'This workshop has no other active internal users. Add the team in Settings and '
            'they will appear here.',
      );
    }

    final designers = _matching(directory.designers, workload);
    final others = _matching(directory.others, workload);
    final nothingMatched = designers.isEmpty && others.isEmpty;

    return ListView(
      padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.md),
      children: [
        CadNote(text: directory.note),
        const SizedBox(height: Spacing.md),
        if (nothingMatched)
          EmptyState(
            compact: true,
            icon: Icons.search_off_rounded,
            title: 'Nobody matches "${_search.text.trim()}"',
            message: 'Try part of a first or last name.',
          )
        else ...[
          if (designers.isNotEmpty) ...[
            Text(
              directory.rolesVisible ? 'CAD DESIGNERS' : 'THE TEAM',
              style: context.text.labelSmall
                  ?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.sm),
            for (final user in designers) ...[
              _PersonRow(
                user: user,
                openJobs: workload[user.id] ?? 0,
                selected: user.id == widget.currentAssigneeId,
                isSelf: user.id == me?.id,
                enabled: !busy,
                onTap: () => unawaited(_assign(user)),
              ),
              const SizedBox(height: Spacing.sm),
            ],
            const SizedBox(height: Spacing.sm),
          ],
          if (others.isNotEmpty) ...[
            Text(
              directory.rolesVisible ? 'EVERYONE ELSE' : 'ALSO INTERNAL',
              style: context.text.labelSmall
                  ?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.sm),
            for (final user in others) ...[
              _PersonRow(
                user: user,
                openJobs: workload[user.id] ?? 0,
                selected: user.id == widget.currentAssigneeId,
                isSelf: user.id == me?.id,
                enabled: !busy,
                onTap: () => unawaited(_assign(user)),
              ),
              const SizedBox(height: Spacing.sm),
            ],
          ],
        ],
        if (widget.currentAssigneeId != null) ...[
          const SizedBox(height: Spacing.sm),
          OutlinedButton.icon(
            onPressed: busy ? null : () => unawaited(_unassign()),
            icon: const Icon(Icons.person_remove_outlined, size: 18),
            label: const Text('Leave it unassigned'),
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            'An unassigned job stays at ${widget.stage.label} and shows up as unclaimed on the '
            'CAD queue. It does not stop being due.',
            style: context.text.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  /// Search, then order by who is carrying the least. A picker that lists the workshop
  /// alphabetically makes the person at the top of the alphabet the busiest person in the shop.
  List<AppUser> _matching(List<AppUser> users, Map<String, int> workload) {
    final term = _search.text.trim().toLowerCase();
    final matched = [
      for (final user in users)
        if (term.isEmpty ||
            user.fullName.toLowerCase().contains(term) ||
            (user.title?.toLowerCase().contains(term) ?? false))
          user,
    ];
    matched.sort((a, b) {
      final load = (workload[a.id] ?? 0).compareTo(workload[b.id] ?? 0);
      return load != 0 ? load : a.fullName.compareTo(b.fullName);
    });
    return matched;
  }

  // -------------------------------------------------------------- actions

  Future<void> _pickDate() async {
    final today = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _expectedAt ?? today.add(const Duration(days: 2)),
      firstDate: today.subtract(const Duration(days: 1)),
      lastDate: today.add(const Duration(days: 365)),
      helpText: 'When is the CAD expected?',
    );
    if (picked == null || !mounted) return;
    setState(() => _expectedAt = picked);
  }

  Future<void> _assign(AppUser user) async {
    final replacing = widget.currentAssigneeId;
    if (replacing != null && replacing != user.id) {
      final confirmed = await confirmAction(
        context,
        title: 'Move ${widget.jobCode} to ${user.fullName}?',
        message: 'The job leaves the current designer\'s queue and appears on '
            '${user.fullName}\'s. Anything already offered on this job stays on the record with '
            'the name of whoever drew it.',
        confirmLabel: 'Reassign to ${user.fullName}',
        cancelLabel: 'Leave it where it is',
      );
      if (!confirmed || !mounted) return;
    }

    try {
      await ref.read(cadActionsProvider.notifier).assignDesigner(
            jobId: widget.jobId,
            userId: user.id,
            stage: widget.stage,
            expectedAt: _expectedAt,
          );
      if (!mounted) return;
      showDone(context, '${widget.jobCode} is with ${user.fullName}.');
      Navigator.of(context).pop(true);
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }

  Future<void> _unassign() async {
    final confirmed = await confirmAction(
      context,
      title: 'Leave ${widget.jobCode} unassigned?',
      message: 'It drops off the current designer\'s queue and shows up as unclaimed. Nobody is '
          'drawing it until somebody takes it.',
      confirmLabel: 'Leave it unassigned',
      cancelLabel: 'Keep the designer',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    try {
      await ref.read(cadActionsProvider.notifier).unassign(
            jobId: widget.jobId,
            stage: widget.stage,
          );
      if (!mounted) return;
      showDone(context, '${widget.jobCode} is unclaimed.');
      Navigator.of(context).pop(true);
    } on DhFailure catch (failure) {
      if (!mounted) return;
      showFailure(context, failure);
    }
  }
}

// ================================================================= one person

final class _PersonRow extends StatelessWidget {
  const _PersonRow({
    required this.user,
    required this.openJobs,
    required this.selected,
    required this.isSelf,
    required this.enabled,
    required this.onTap,
  });

  final AppUser user;

  /// Unfinished CAD already on this person.
  final int openJobs;

  final bool selected;
  final bool isSelf;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SelectableTile(
      title: isSelf ? '${user.fullName} (you)' : user.fullName,
      blurb: user.subtitle,
      selected: selected,
      enabled: enabled,
      inGroup: true,
      onTap: onTap,
      leading: PersonAvatar(
        name: user.fullName,
        size: 38,
        tone: selected ? AvatarTone.accent : AvatarTone.neutral,
      ),
      trailing: StatusChip(
        label: openJobs == 0 ? 'Free' : '$openJobs open',
        tone: openJobs == 0 ? ChipTone.success : ChipTone.neutral,
        dense: true,
        mono: openJobs != 0,
        tooltip: openJobs == 0
            ? 'No unfinished CAD on this person'
            : '$openJobs unfinished CAD job${openJobs == 1 ? '' : 's'} already assigned',
      ),
    );
  }
}
